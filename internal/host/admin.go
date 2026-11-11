package host

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/engine"
	"github.com/Tetrix-Technologies/tetrix-host/internal/events"
	"github.com/Tetrix-Technologies/tetrix-host/internal/hardware"
	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
	"github.com/Tetrix-Technologies/tetrix-host/internal/session"
	"github.com/Tetrix-Technologies/tetrix-host/internal/stats"
	"github.com/Tetrix-Technologies/tetrix-host/internal/tunnel"
)

// Status is the whole state of a host in one document. The app draws its
// board from it, and `tetrix-host status` prints it. docs/reference/admin-api.md
// describes every field.
type Status struct {
	Product  string            `json:"product"`
	Version  string            `json:"version"`
	Host     HostStatus        `json:"host"`
	Hardware hardware.Info     `json:"hardware"`
	Load     hardware.Load     `json:"load"`
	Tunnel   TunnelStatus      `json:"tunnel"`
	Engines  []engine.Status   `json:"engines"`
	Roles    RolesStatus       `json:"roles"`
	Devices  []DeviceStatus    `json:"devices"`
	Stats    stats.Snapshot    `json:"stats"`
	Pairing  *PairingStatus    `json:"pairing"`
	Pulls    []engine.Progress `json:"pulls"`
}

// HostStatus identifies the host.
type HostStatus struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	StartedAt time.Time `json:"startedAt"`
	Address   string    `json:"address"`
	// Endpoint is the base URL a local program gives an OpenAI client.
	Endpoint string `json:"endpoint"`
}

// TunnelStatus is the tunnel's setting and state.
type TunnelStatus struct {
	Enabled bool `json:"enabled"`
	tunnel.Status
}

// RolesStatus is the model for each kind of work.
type RolesStatus struct {
	Deep  string `json:"deep"`
	Quick string `json:"quick"`
	// Single is true when one model serves both kinds of work.
	Single bool `json:"single"`
	// Window is the context window the host asks for, per role, in
	// tokens. Zero means the host leaves it to the engine.
	Window WindowStatus `json:"window"`
}

// WindowStatus is the window setting for each role.
type WindowStatus struct {
	Deep  int `json:"deep"`
	Quick int `json:"quick"`
}

// DeviceStatus is a paired device and its activity since the host started.
type DeviceStatus struct {
	config.Device
	Online bool `json:"online"`
	stats.Totals
}

// PairingStatus is the open pairing offer.
type PairingStatus struct {
	Code      string    `json:"code"`
	Link      string    `json:"link"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func (h *Host) status(ctx context.Context) Status {
	cfg := h.cfg.Get()
	h.mu.Lock()
	address := h.address
	tun := h.tun
	online := map[string]int{}
	for k, v := range h.online {
		online[k] = v
	}
	pulls := make([]engine.Progress, 0, len(h.pulls))
	for _, p := range h.pulls {
		pulls = append(pulls, p.progress)
	}
	h.mu.Unlock()

	st := Status{
		Product: brand.Name,
		Version: brand.Version,
		Host: HostStatus{
			ID: h.id.HostID(), Name: cfg.Name, StartedAt: h.startedAt,
			Address: address, Endpoint: "http://" + address + "/v1",
		},
		Hardware: h.hw,
		Load:     h.currentLoad(),
		Tunnel:   TunnelStatus{Enabled: cfg.Tunnel.Enabled, Status: tunnel.Status{State: tunnel.StateDisabled, Relay: cfg.Tunnel.Relay}},
		Engines:  h.engines.Snapshot(ctx, 5*time.Second),
		Roles: RolesStatus{
			Deep: cfg.Roles.Deep, Quick: cfg.Roles.Quick,
			Single: cfg.Roles.Quick == "" || cfg.Roles.Quick == cfg.Roles.Deep,
			Window: WindowStatus{Deep: cfg.Window.For(config.RoleDeep), Quick: cfg.Window.For(config.RoleQuick)},
		},
		Devices: []DeviceStatus{},
		Stats:   h.stats.Snapshot(),
		Pulls:   pulls,
	}
	if free := hardware.DiskFree(); free > 0 {
		st.Hardware.DiskFreeBytes = free
	}
	if tun != nil {
		st.Tunnel.Status = tun.Status()
	}
	for _, d := range h.devices.List() {
		st.Devices = append(st.Devices, DeviceStatus{Device: d, Online: online[d.ID] > 0, Totals: h.stats.Device(d.ID)})
	}
	if t := h.tickets.Active(); t != nil {
		st.Pairing = h.pairingStatus(t)
	}
	return st
}

func (h *Host) pairingStatus(t *pairing.Ticket) *PairingStatus {
	code, err := pairing.Code(h.id.HostID(), t.Secret)
	if err != nil {
		return nil
	}
	return &PairingStatus{Code: code, Link: pairing.Link(code, h.cfg.Get().Tunnel.Relay), ExpiresAt: t.ExpiresAt.UTC()}
}

// localHandler serves loopback: the app, the CLI, and local programs.
func (h *Host) localHandler() http.Handler {
	api := http.NewServeMux()
	h.openAIRoutes(api)

	admin := http.NewServeMux()
	admin.HandleFunc("GET /admin/v1/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, h.status(r.Context()))
	})
	admin.HandleFunc("GET /admin/v1/events", h.handleEvents)
	admin.HandleFunc("POST /admin/v1/pairing", h.handlePairingCreate)
	admin.HandleFunc("DELETE /admin/v1/pairing", func(w http.ResponseWriter, r *http.Request) {
		h.tickets.Cancel()
		h.hub.Publish(events.Changed, nil)
		w.WriteHeader(http.StatusNoContent)
	})
	admin.HandleFunc("PATCH /admin/v1/devices/{id}", h.handleDeviceRename)
	admin.HandleFunc("DELETE /admin/v1/devices/{id}", h.handleDeviceRemove)
	admin.HandleFunc("PUT /admin/v1/roles", h.handleRoles)
	admin.HandleFunc("PUT /admin/v1/settings", h.handleSettings)
	admin.HandleFunc("POST /admin/v1/models/pull", h.handlePull)
	admin.HandleFunc("DELETE /admin/v1/models/pull", h.handlePullCancel)
	admin.HandleFunc("DELETE /admin/v1/models", h.handleModelDelete)
	admin.HandleFunc("POST /admin/v1/engines", h.handleEngineAdd)
	admin.HandleFunc("DELETE /admin/v1/engines/{id}", h.handleEngineRemove)

	root := http.NewServeMux()
	root.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		answer := map[string]any{"ok": true, "product": brand.Name, "version": brand.Version}
		// A client that is about to send the admin token first checks that
		// it is talking to the host that owns the token.
		if nonce, err := base64.StdEncoding.DecodeString(r.Header.Get(ChallengeHeader)); err == nil && len(nonce) >= 16 && len(nonce) <= 64 {
			answer["proof"] = LocalProof(h.adminToken, nonce)
		}
		writeJSON(w, http.StatusOK, answer)
	})
	root.Handle("/v1/", h.guard(api, false))
	root.Handle("/admin/", h.guard(admin, true))
	return root
}

// ChallengeHeader carries a client's nonce to /healthz.
const ChallengeHeader = "X-Host-Challenge"

// LocalProof shows that its maker holds the admin token, without revealing
// the token: an HMAC over the client's nonce.
//
// A local client reads the host's address from daemon.json. If the host
// died without removing that file, another program could be listening on
// the port. The client asks for this proof before it sends the token, so a
// stand-in learns nothing.
func LocalProof(adminToken string, nonce []byte) string {
	mac := hmac.New(sha256.New, []byte(adminToken))
	mac.Write([]byte("tetrix-host/local-proof/1\x00"))
	mac.Write(nonce)
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// guard checks the bearer token. The admin token opens everything. The API
// key opens only the model routes, so a local program that holds it cannot
// pair a device or change a setting.
//
// A request from a web page never passes, because a page cannot read either
// token. That is what protects a loopback port from a hostile site.
func (h *Host) guard(next http.Handler, adminOnly bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		isAdmin := subtle.ConstantTimeCompare([]byte(token), []byte(h.adminToken)) == 1
		isKey := subtle.ConstantTimeCompare([]byte(token), []byte(h.apiKey)) == 1
		if !isAdmin && (adminOnly || !isKey) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "A valid key is required.")
			return
		}
		next.ServeHTTP(w, r.WithContext(session.WithCaller(r.Context(), session.Caller{Local: true})))
	})
}

func (h *Host) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "host_error", "Streaming is not available.")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, ": connected\n\n")
	flusher.Flush()

	ch, cancel := h.hub.Subscribe()
	defer cancel()
	beat := time.NewTicker(15 * time.Second)
	defer beat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-beat.C:
			fmt.Fprint(w, ": beat\n\n")
		case e := <-ch:
			data, err := json.Marshal(e)
			if err != nil {
				continue
			}
			fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.Type, data)
		}
		flusher.Flush()
	}
}

func (h *Host) handlePairingCreate(w http.ResponseWriter, r *http.Request) {
	t, err := h.tickets.Create()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "host_error", "The host could not make a pairing code.")
		return
	}
	h.hub.Publish(events.Changed, nil)
	writeJSON(w, http.StatusOK, h.pairingStatus(t))
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "The request body is not valid JSON.")
		return false
	}
	return true
}

func (h *Host) handleDeviceRename(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
	}
	if !decode(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Name) == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "Give the device a name.")
		return
	}
	renamed, err := h.devices.Rename(r.PathValue("id"), body.Name)
	if !renamed {
		writeError(w, http.StatusNotFound, "not_found", "No such device.")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "host_error", "The name changed but could not be saved: "+err.Error())
		return
	}
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleDeviceRemove(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	removed, err := h.devices.Remove(id)
	if !removed {
		writeError(w, http.StatusNotFound, "not_found", "No such device.")
		return
	}
	// The device's key is gone. End any session it still has open.
	h.session.Disconnect(id)
	h.log.Info("removed a device", "device", id)
	h.hub.Publish(events.Changed, nil)
	if err != nil {
		// The device is unpaired for now, but the file still lists it, so
		// it would return when the host restarts. The owner must know.
		h.log.Error("could not save the device list", "error", err)
		writeError(w, http.StatusInternalServerError, "host_error", "The device is unpaired, but the change could not be saved, so it will return when the host restarts: "+err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleRoles(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Deep  *string `json:"deep"`
		Quick *string `json:"quick"`
	}
	if !decode(w, r, &body) {
		return
	}
	for _, id := range []*string{body.Deep, body.Quick} {
		if id == nil || *id == "" {
			continue
		}
		if _, _, ok := h.engines.Find(r.Context(), *id); !ok {
			writeError(w, http.StatusNotFound, "model_not_found", "This host has no model named "+*id+".")
			return
		}
	}
	h.cfg.Update(func(c *config.Config) {
		if body.Deep != nil {
			c.Roles.Deep = *body.Deep
		}
		if body.Quick != nil {
			c.Roles.Quick = *body.Quick
		}
		if c.Roles.Quick == c.Roles.Deep {
			c.Roles.Quick = ""
		}
	})
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name   *string `json:"name"`
		Tunnel *struct {
			Enabled *bool   `json:"enabled"`
			Relay   *string `json:"relay"`
		} `json:"tunnel"`
		// Window sets the context window per role. A positive number is
		// tokens, zero is the default, and a negative number leaves the
		// window to the engine.
		Window *struct {
			Deep  *int `json:"deep"`
			Quick *int `json:"quick"`
		} `json:"window"`
	}
	if !decode(w, r, &body) {
		return
	}
	if body.Window != nil {
		for _, v := range []*int{body.Window.Deep, body.Window.Quick} {
			if v != nil && *v > 0 && *v < 1024 {
				writeError(w, http.StatusBadRequest, "bad_request", "A context window is at least 1,024 tokens.")
				return
			}
		}
	}
	if body.Tunnel != nil && body.Tunnel.Relay != nil {
		relay := strings.TrimSpace(*body.Tunnel.Relay)
		if !strings.HasPrefix(relay, "wss://") && !strings.HasPrefix(relay, "ws://") {
			writeError(w, http.StatusBadRequest, "bad_request", "A relay address starts with wss:// or ws://.")
			return
		}
		*body.Tunnel.Relay = strings.TrimRight(relay, "/")
	}
	before := h.cfg.Get().Tunnel
	h.cfg.Update(func(c *config.Config) {
		if body.Name != nil && strings.TrimSpace(*body.Name) != "" {
			c.Name = strings.TrimSpace(*body.Name)
		}
		if body.Window != nil {
			if body.Window.Deep != nil {
				c.Window.Deep = *body.Window.Deep
			}
			if body.Window.Quick != nil {
				c.Window.Quick = *body.Window.Quick
			}
		}
		if body.Tunnel != nil {
			if body.Tunnel.Enabled != nil {
				c.Tunnel.Enabled = *body.Tunnel.Enabled
			}
			if body.Tunnel.Relay != nil {
				c.Tunnel.Relay = *body.Tunnel.Relay
			}
		}
	})
	if after := h.cfg.Get().Tunnel; after != before {
		// A code names its relay, so an open code would point at the old one.
		h.tickets.Cancel()
		h.startTunnel()
	}
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handlePull(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Engine string `json:"engine"`
		Name   string `json:"name"`
	}
	if !decode(w, r, &body) {
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	if body.Name == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "Name the model to download.")
		return
	}
	if body.Engine == "" {
		body.Engine = h.pullEngine()
	}
	eng, ok := h.engines.Engine(body.Engine)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "No engine on this host can download models.")
		return
	}
	key := body.Engine + "/" + body.Name
	h.mu.Lock()
	if _, running := h.pulls[key]; running {
		h.mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
		return
	}
	ctx, cancel := context.WithCancel(h.runCtx)
	p := &pull{progress: engine.Progress{Engine: body.Engine, Name: body.Name, Status: "Starting"}, cancel: cancel}
	h.pulls[key] = p
	h.mu.Unlock()
	h.hub.Publish(events.Pull, p.progress)

	go func() {
		defer cancel()
		last := time.Time{}
		err := eng.Pull(ctx, body.Name, func(pr engine.Progress) {
			h.mu.Lock()
			p.progress = pr
			h.mu.Unlock()
			// Engines report many times a second. Four a second is enough
			// to draw a smooth bar.
			if pr.Done || time.Since(last) > 250*time.Millisecond {
				last = time.Now()
				h.hub.Publish(events.Pull, pr)
			}
		})
		final := engine.Progress{Engine: body.Engine, Name: body.Name, Status: "Done", Done: true}
		h.mu.Lock()
		final.Completed, final.Total = p.progress.Total, p.progress.Total
		delete(h.pulls, key)
		h.mu.Unlock()
		switch {
		case errors.Is(err, context.Canceled):
			final.Status, final.Error = "Cancelled", "cancelled"
		case errors.Is(err, engine.ErrUnsupported):
			final.Status, final.Error = "Failed", "This engine manages its own models. Download the model with the engine's own tools."
		case err != nil:
			final.Status, final.Error = "Failed", err.Error()
		}
		h.engines.Invalidate()
		if err == nil {
			h.assignRoles(h.runCtx)
		}
		h.hub.Publish(events.Pull, final)
		h.hub.Publish(events.Changed, nil)
	}()
	w.WriteHeader(http.StatusAccepted)
}

// pullEngine is the engine a download uses when the request names none:
// the first that can download.
func (h *Host) pullEngine() string {
	for _, e := range h.cfg.Get().Engines {
		if e.Kind == "ollama" {
			return e.ID
		}
	}
	return ""
}

func (h *Host) handlePullCancel(w http.ResponseWriter, r *http.Request) {
	engineID := r.URL.Query().Get("engine")
	if engineID == "" {
		engineID = h.pullEngine()
	}
	key := engineID + "/" + r.URL.Query().Get("name")
	h.mu.Lock()
	p := h.pulls[key]
	h.mu.Unlock()
	if p == nil {
		writeError(w, http.StatusNotFound, "not_found", "No such download.")
		return
	}
	p.cancel()
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleModelDelete(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	eng, model, ok := h.engines.Find(r.Context(), id)
	if !ok {
		writeError(w, http.StatusNotFound, "model_not_found", "This host has no model named "+id+".")
		return
	}
	if err := eng.Delete(r.Context(), model.Name); err != nil {
		if errors.Is(err, engine.ErrUnsupported) {
			writeError(w, http.StatusBadRequest, "unsupported", "This engine manages its own models. Remove the model with the engine's own tools.")
			return
		}
		writeError(w, http.StatusBadGateway, "engine_error", err.Error())
		return
	}
	h.cfg.Update(func(c *config.Config) {
		if c.Roles.Quick == id {
			c.Roles.Quick = ""
		}
		if c.Roles.Deep == id {
			c.Roles.Deep, c.Roles.Quick = c.Roles.Quick, ""
		}
	})
	h.engines.Invalidate()
	h.assignRoles(r.Context())
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleEngineAdd(w http.ResponseWriter, r *http.Request) {
	var cfg config.EngineConfig
	if !decode(w, r, &cfg) {
		return
	}
	if _, err := engine.New(cfg, h.upstream); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", strings.TrimPrefix(err.Error(), "engine: "))
		return
	}
	h.cfg.Update(func(c *config.Config) {
		for i := range c.Engines {
			if c.Engines[i].ID == cfg.ID {
				c.Engines[i] = cfg
				return
			}
		}
		c.Engines = append(c.Engines, cfg)
	})
	h.engines.Set(h.cfg.Get().Engines)
	h.assignRoles(r.Context())
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Host) handleEngineRemove(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	found := false
	h.cfg.Update(func(c *config.Config) {
		kept := c.Engines[:0]
		for _, e := range c.Engines {
			if e.ID == id {
				found = true
				continue
			}
			kept = append(kept, e)
		}
		c.Engines = kept
		if strings.HasPrefix(c.Roles.Quick, id+"/") {
			c.Roles.Quick = ""
		}
		if strings.HasPrefix(c.Roles.Deep, id+"/") {
			c.Roles.Deep, c.Roles.Quick = c.Roles.Quick, ""
		}
	})
	if !found {
		writeError(w, http.StatusNotFound, "not_found", "No such engine.")
		return
	}
	h.engines.Set(h.cfg.Get().Engines)
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
}
