package host

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/engine"
	"github.com/Tetrix-Technologies/tetrix-host/internal/events"
	"github.com/Tetrix-Technologies/tetrix-host/internal/session"
	"github.com/Tetrix-Technologies/tetrix-host/internal/stats"
)

const maxRequestBody = 32 << 20

// openAIRoutes mounts the routes an app calls. The same handlers serve a
// paired device through the tunnel and a local program over loopback.
func (h *Host) openAIRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/chat/completions", h.handleProxy)
	mux.HandleFunc("POST /v1/completions", h.handleProxy)
	mux.HandleFunc("POST /v1/embeddings", h.handleProxy)
	mux.HandleFunc("GET /v1/models", h.handleModels)
	mux.HandleFunc("GET /v1/host", h.handleHostInfo)
	mux.HandleFunc("DELETE /v1/device", h.handleUnpairSelf)
}

// windowFor returns the context window the host gives a model for a role,
// or zero when the engine decides. One model that serves both roles runs
// with the deep window for both, so that it is loaded once and not twice.
func (h *Host) windowFor(role string, model engine.Model) int {
	cfg := h.cfg.Get()
	if role != config.RoleQuick || cfg.Roles.Quick == "" || cfg.Roles.Quick == cfg.Roles.Deep {
		role = config.RoleDeep
	}
	tokens := cfg.Window.For(role)
	if tokens > 0 && model.ContextLength > 0 && tokens > model.ContextLength {
		tokens = model.ContextLength
	}
	return tokens
}

// upstreamName is the name the engine is asked for: the model itself, or
// its variant with the window the host chose.
func (h *Host) upstreamName(ctx context.Context, eng engine.Engine, model engine.Model, role string) string {
	windowed, ok := eng.(engine.Windowed)
	tokens := h.windowFor(role, model)
	if !ok || tokens <= 0 {
		return model.Name
	}
	name, err := windowed.WithWindow(ctx, model.Name, tokens)
	if err != nil {
		// Serve the request with the engine's own window. That is worse
		// than the window asked for and better than no answer.
		h.log.Warn("could not set the context window", "model", model.ID, "tokens", tokens, "error", err)
		return model.Name
	}
	return name
}

// handleUnpairSelf lets a device end its own pairing, so that an app's
// "unpair" does not leave a dead entry in the host's device list.
func (h *Host) handleUnpairSelf(w http.ResponseWriter, r *http.Request) {
	caller, _ := session.CallerFrom(r.Context())
	if caller.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "Only a paired device can unpair itself.")
		return
	}
	if _, err := h.devices.Remove(caller.DeviceID); err != nil {
		h.log.Error("could not save the device list", "error", err)
	}
	h.log.Info("a device unpaired itself", "device", caller.DeviceID)
	h.hub.Publish(events.Changed, nil)
	w.WriteHeader(http.StatusNoContent)
	// Let the answer leave before the session closes under it.
	go func() {
		time.Sleep(300 * time.Millisecond)
		h.session.Disconnect(caller.DeviceID)
	}()
}

// deviceHandler is what a paired device can reach. It has no admin routes.
func (h *Host) deviceHandler() http.Handler {
	mux := http.NewServeMux()
	h.openAIRoutes(mux)
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// writeError answers in the shape OpenAI clients already parse.
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]any{"message": message, "type": "host_error", "code": code},
	})
}

// roleName strips the optional prefix an app can put before a role.
func roleName(model string) string {
	for _, prefix := range []string{"tetrix/", brand.CLI + "/"} {
		if rest, ok := strings.CutPrefix(model, prefix); ok {
			return rest
		}
	}
	return model
}

// resolve turns the model an app asked for into an engine and a model.
// An app normally asks for a role, "deep" or "quick", and the host's
// owner decides which model serves it.
func (h *Host) resolve(ctx context.Context, requested string) (engine.Engine, engine.Model, string, int, string, string) {
	roles := h.cfg.Get().Roles
	name := roleName(requested)
	if name == "" {
		name = config.RoleDeep
	}
	role := ""
	modelID := requested
	if id, ok := roles.Resolve(name); ok {
		role = name
		modelID = id
		if modelID == "" {
			return nil, engine.Model{}, role, http.StatusServiceUnavailable, "no_model_assigned",
				"This host has no model assigned yet. Its owner can assign one in " + brand.Name + "."
		}
	}
	e, m, ok := h.engines.Find(ctx, modelID)
	if !ok {
		if role != "" {
			return nil, engine.Model{}, role, http.StatusServiceUnavailable, "model_unavailable",
				"The model assigned to " + role + " work is not available on this host right now."
		}
		return nil, engine.Model{}, role, http.StatusNotFound, "model_not_found",
			"This host has no model named " + requested + "."
	}
	return e, m, role, 0, "", ""
}

func (h *Host) handleProxy(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	caller, _ := session.CallerFrom(r.Context())
	record := stats.Record{ID: h.nextRequestID(), At: started.UTC(), DeviceID: caller.DeviceID, Source: "tunnel"}
	if caller.Local {
		record.Source = "local"
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxRequestBody+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "The request body could not be read.")
		return
	}
	if len(body) > maxRequestBody {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large", "The request is larger than 32 MB.")
		return
	}
	var fields map[string]json.RawMessage
	// The JSON value null decodes into a nil map without an error.
	if err := json.Unmarshal(body, &fields); err != nil || fields == nil {
		writeError(w, http.StatusBadRequest, "bad_request", "The request body is not a JSON object.")
		return
	}
	var requested string
	json.Unmarshal(fields["model"], &requested)
	eng, model, role, status, code, message := h.resolve(r.Context(), requested)
	if status != 0 {
		writeError(w, status, code, message)
		return
	}
	record.Role, record.Model = role, model.ID
	fields["model"], _ = json.Marshal(h.upstreamName(r.Context(), eng, model, role))

	// An engine answers a tool request to a model without tools in its own
	// words, with no code an app can act on. Answer first when the host
	// knows.
	if tools := bytes.TrimSpace(fields["tools"]); len(tools) > 2 && model.Capabilities != nil && !slices.Contains(model.Capabilities, "tools") {
		kind := "the model " + model.ID
		if role != "" {
			kind = "the model assigned to " + role + " work"
		}
		writeError(w, http.StatusBadRequest, "tools_unsupported", "This host cannot run tools with "+kind+". Its owner can assign a model that can.")
		return
	}

	var streaming bool
	json.Unmarshal(fields["stream"], &streaming)
	record.Stream = streaming
	if streaming && r.URL.Path != "/v1/embeddings" {
		// Ask for the usage chunk so the host can count tokens. An app that
		// set stream_options keeps what it set.
		if _, set := fields["stream_options"]; !set {
			fields["stream_options"] = json.RawMessage(`{"include_usage":true}`)
		}
	}
	out, _ := json.Marshal(fields)

	req, err := http.NewRequestWithContext(r.Context(), "POST", eng.Upstream(r.URL.Path), bytes.NewReader(out))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "host_error", "The host could not build the request.")
		return
	}
	req.Header.Set("Content-Type", "application/json")
	eng.Authorize(req)

	h.stats.Begin(stats.Running{
		ID: record.ID, At: record.At, DeviceID: record.DeviceID,
		Source: record.Source, Role: record.Role, Model: record.Model,
	})
	h.hub.Publish(events.Changed, nil)
	var firstByte, lastByte time.Time
	finish := func(status int, usage usage) {
		record.Status = status
		record.DurationMs = time.Since(started).Milliseconds()
		record.TokensIn, record.TokensOut = usage.in, usage.out
		h.stats.End(record, lastByte.Sub(firstByte))
		h.hub.Publish(events.Request, record)
		h.hub.Publish(events.Changed, nil)
	}

	resp, err := h.upstream.Do(req)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			finish(499, usage{})
			return
		}
		h.engines.Invalidate()
		writeError(w, http.StatusBadGateway, "engine_unreachable", "The model server on this host is not answering.")
		finish(http.StatusBadGateway, usage{})
		return
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Host-Model", model.ID)
	w.WriteHeader(resp.StatusCode)

	counter := &usageCounter{stream: strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream")}
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 16<<10)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			now := time.Now()
			if firstByte.IsZero() {
				firstByte = now
			}
			lastByte = now
			counter.feed(buf[:n])
			if _, werr := w.Write(buf[:n]); werr != nil {
				finish(499, counter.result())
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if rerr != nil {
			if rerr != io.EOF {
				// The engine died or the connection broke partway. Do not
				// end the answer as if it were whole. The status line has
				// already gone, so abort: over loopback the connection
				// drops, and over the tunnel the stream is reset.
				status := http.StatusBadGateway
				if errors.Is(rerr, context.Canceled) {
					status = 499
				}
				h.engines.Invalidate()
				finish(status, counter.result())
				if status == 499 {
					return
				}
				panic(http.ErrAbortHandler)
			}
			break
		}
	}
	finish(resp.StatusCode, counter.result())
}

type usage struct{ in, out int }

// usageCounter reads token counts out of a response as it passes. It keeps
// no text.
type usageCounter struct {
	stream bool
	line   []byte
	whole  []byte
	found  bool
	chunks int
	usage  usage
}

type usageBody struct {
	Usage *struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

func (c *usageCounter) feed(b []byte) {
	if !c.stream {
		// A plain JSON answer is parsed once, at the end.
		if len(c.whole) < 16<<20 {
			c.whole = append(c.whole, b...)
		}
		return
	}
	for len(b) > 0 {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			if len(c.line) < 1<<20 {
				c.line = append(c.line, b...)
			}
			return
		}
		c.line = append(c.line, b[:i]...)
		c.take(c.line)
		c.line = c.line[:0]
		b = b[i+1:]
	}
}

func (c *usageCounter) take(line []byte) {
	data, ok := bytes.CutPrefix(line, []byte("data:"))
	if !ok {
		return
	}
	c.chunks++
	if !bytes.Contains(data, []byte(`"usage"`)) {
		return
	}
	var body usageBody
	if json.Unmarshal(bytes.TrimSpace(data), &body) == nil && body.Usage != nil {
		c.found = true
		c.usage = usage{body.Usage.PromptTokens, body.Usage.CompletionTokens}
	}
}

func (c *usageCounter) result() usage {
	if !c.stream {
		var body usageBody
		if json.Unmarshal(c.whole, &body) == nil && body.Usage != nil {
			return usage{body.Usage.PromptTokens, body.Usage.CompletionTokens}
		}
		return usage{}
	}
	if !c.found && c.chunks > 2 {
		// The engine sent no usage. One chunk is about one token, less the
		// opening and closing chunks.
		return usage{out: c.chunks - 2}
	}
	return c.usage
}

func (h *Host) handleModels(w http.ResponseWriter, r *http.Request) {
	roles := h.cfg.Get().Roles
	type entry struct {
		ID         string `json:"id"`
		Object     string `json:"object"`
		OwnedBy    string `json:"owned_by"`
		ResolvesTo string `json:"resolves_to,omitempty"`
	}
	list := []entry{}
	for _, role := range []string{config.RoleDeep, config.RoleQuick} {
		if id, _ := roles.Resolve(role); id != "" {
			list = append(list, entry{ID: role, Object: "model", OwnedBy: "role", ResolvesTo: id})
		}
	}
	for _, m := range h.engines.All(r.Context()) {
		list = append(list, entry{ID: m.ID, Object: "model", OwnedBy: m.Engine})
	}
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": list})
}

// RoleInfo tells an app what the model behind a role can do.
type RoleInfo struct {
	Model     string `json:"model"`
	Available bool   `json:"available"`
	// ContextLength is the largest window the model supports.
	ContextLength int `json:"contextLength,omitempty"`
	// ContextInUse is the window the engine is running the model with now.
	// A request longer than this is cut short. Absent when the model is
	// not loaded or the engine does not say.
	ContextInUse int `json:"contextInUse,omitempty"`
	// Capabilities is null when the engine does not say what the model
	// can do, and a list, possibly empty, when it does.
	Capabilities []string `json:"capabilities"`
}

// handleHostInfo is the first thing an app asks a host after it connects.
func (h *Host) handleHostInfo(w http.ResponseWriter, r *http.Request) {
	cfg := h.cfg.Get()
	info := map[string]any{
		"id":      h.id.HostID(),
		"name":    cfg.Name,
		"product": brand.Name,
		"version": brand.Version,
		"single":  cfg.Roles.Quick == "" || cfg.Roles.Quick == cfg.Roles.Deep,
	}
	roles := map[string]RoleInfo{}
	for _, role := range []string{config.RoleDeep, config.RoleQuick} {
		id, _ := cfg.Roles.Resolve(role)
		ri := RoleInfo{Model: id}
		if e, m, ok := h.engines.Find(r.Context(), id); ok {
			ri.Available = true
			ri.ContextLength = m.ContextLength
			ri.ContextInUse = m.ContextInUse
			// When the host sets the window, that is the window a request
			// gets, whether or not the model is loaded yet.
			if _, windowed := e.(engine.Windowed); windowed {
				if tokens := h.windowFor(role, m); tokens > 0 {
					ri.ContextInUse = tokens
				}
			}
			ri.Capabilities = m.Capabilities
		}
		roles[role] = ri
	}
	info["roles"] = roles
	writeJSON(w, http.StatusOK, info)
}
