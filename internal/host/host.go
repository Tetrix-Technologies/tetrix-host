// Package host assembles a running host: the local API, the tunnel, the
// engines, and the device list.
package host

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/engine"
	"github.com/Tetrix-Technologies/tetrix-host/internal/events"
	"github.com/Tetrix-Technologies/tetrix-host/internal/hardware"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
	"github.com/Tetrix-Technologies/tetrix-host/internal/session"
	"github.com/Tetrix-Technologies/tetrix-host/internal/stats"
	"github.com/Tetrix-Technologies/tetrix-host/internal/tunnel"
)

// Host is one running host.
type Host struct {
	Paths config.Paths
	// ListenOverride replaces the configured listen address for one run.
	ListenOverride string

	cfg     *config.Store
	id      *identity.Identity
	devices *config.Devices
	engines *engine.Registry
	tickets *pairing.Manager
	stats   *stats.Stats
	hub     *events.Hub
	session *session.Server
	log     *slog.Logger

	adminToken string
	apiKey     string
	startedAt  time.Time
	hw         hardware.Info
	upstream   *http.Client

	mu        sync.Mutex
	address   string
	tun       *tunnel.Tunnel
	tunStop   context.CancelFunc
	runCtx    context.Context
	online    map[string]int
	load      hardware.Load
	pulls     map[string]*pull
	requestID uint64
}

type pull struct {
	progress engine.Progress
	cancel   context.CancelFunc
}

// Open loads a host's files from paths, and creates the ones that are
// missing. It does not start anything.
func Open(paths config.Paths, log *slog.Logger) (*Host, error) {
	if log == nil {
		log = slog.Default()
	}
	if err := os.MkdirAll(paths.Dir, 0o700); err != nil {
		return nil, err
	}
	cfg, err := config.OpenStore(paths.Config())
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %w", paths.Config(), err)
	}
	id, created, err := identity.LoadOrCreate(paths.Identity())
	if err != nil {
		return nil, err
	}
	if created {
		log.Info("made a new host identity", "host", id.HostID())
	}
	devices, err := config.OpenDevices(paths.Devices())
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %w", paths.Devices(), err)
	}
	adminToken, err := config.LoadOrCreateSecret(paths.AdminToken(), "hadm_")
	if err != nil {
		return nil, err
	}
	apiKey, err := config.LoadOrCreateSecret(paths.APIKey(), "hk_")
	if err != nil {
		return nil, err
	}

	// A model can take minutes to load before its first byte, so only the
	// connection has a deadline.
	transport := &http.Transport{
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		MaxIdleConnsPerHost: 16,
		IdleConnTimeout:     90 * time.Second,
	}
	h := &Host{
		Paths:      paths,
		cfg:        cfg,
		id:         id,
		devices:    devices,
		engines:    engine.NewRegistry(&http.Client{Transport: transport}),
		tickets:    pairing.NewManager(pairing.DefaultTTL),
		stats:      stats.New(),
		hub:        events.NewHub(),
		log:        log,
		adminToken: adminToken,
		apiKey:     apiKey,
		upstream:   &http.Client{Transport: transport},
		online:     map[string]int{},
		pulls:      map[string]*pull{},
	}
	if err := h.engines.Set(cfg.Get().Engines); err != nil {
		log.Warn("skipped a bad engine entry", "error", err)
	}
	h.session = &session.Server{
		Identity: id,
		HostName: func() string { return h.cfg.Get().Name },
		Tickets:  h.tickets,
		Devices:  devices,
		Handler:  h.deviceHandler(),
		Log:      log,
		OnPaired: func(dev config.Device) {
			log.Info("paired a device", "device", dev.ID, "name", dev.Name)
			h.hub.Publish(events.Paired, dev)
			h.hub.Publish(events.Changed, nil)
		},
		OnPresence: func(deviceID string, online bool) {
			h.mu.Lock()
			if online {
				h.online[deviceID]++
			} else if h.online[deviceID] > 0 {
				h.online[deviceID]--
			}
			h.mu.Unlock()
			h.hub.Publish(events.Changed, nil)
		},
	}
	return h, nil
}

// HostID is this host's ID.
func (h *Host) HostID() string { return h.id.HostID() }

// Address is the address the local API listens on, once Run has bound it.
func (h *Host) Address() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.address
}

// Run serves until ctx ends.
func (h *Host) Run(ctx context.Context) error {
	listen := h.cfg.Get().Listen
	if h.ListenOverride != "" {
		listen = h.ListenOverride
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return fmt.Errorf("cannot listen on %s: %w. If another copy of %s is running, stop it first", listen, err, brand.Name)
	}
	h.startedAt = time.Now().UTC()
	h.hw = hardware.Probe()
	h.mu.Lock()
	h.address = ln.Addr().String()
	h.runCtx = ctx
	h.mu.Unlock()

	if err := config.WriteDaemon(h.Paths.Daemon(), config.Daemon{
		PID: os.Getpid(), Address: h.address, Version: brand.Version, StartedAt: h.startedAt,
	}); err != nil {
		ln.Close()
		return err
	}
	defer config.RemoveDaemon(h.Paths.Daemon(), os.Getpid())

	h.assignRoles(ctx)
	h.startTunnel()
	go h.sampleLoop(ctx)

	server := &http.Server{Handler: h.localHandler(), ReadHeaderTimeout: 10 * time.Second}
	h.log.Info("serving", "address", h.address, "host", h.id.HostID())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ln) }()
	select {
	case <-ctx.Done():
		h.stopTunnel()
		shutdown, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		server.Shutdown(shutdown)
		return nil
	case err := <-done:
		h.stopTunnel()
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// startTunnel dials the relay if the tunnel is enabled. It replaces a
// tunnel that already runs, which is how a change of relay takes effect.
func (h *Host) startTunnel() {
	h.stopTunnel()
	cfg := h.cfg.Get()
	h.mu.Lock()
	defer h.mu.Unlock()
	if !cfg.Tunnel.Enabled || h.runCtx == nil {
		return
	}
	ctx, cancel := context.WithCancel(h.runCtx)
	h.tun = &tunnel.Tunnel{
		Relay:    cfg.Tunnel.Relay,
		Identity: h.id,
		Serve:    h.session.ServeConn,
		Log:      h.log,
		OnChange: func(tunnel.Status) { h.hub.Publish(events.Changed, nil) },
	}
	h.tunStop = cancel
	go h.tun.Run(ctx)
}

func (h *Host) stopTunnel() {
	h.mu.Lock()
	stop := h.tunStop
	h.tun, h.tunStop = nil, nil
	h.mu.Unlock()
	if stop != nil {
		stop()
	}
}

// sampleLoop measures load while somebody watches.
func (h *Host) sampleLoop(ctx context.Context) {
	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if h.hub.Watchers() == 0 {
				continue
			}
			l := hardware.Sample()
			h.mu.Lock()
			h.load = l
			h.mu.Unlock()
			h.hub.Publish(events.Load, l)
		}
	}
}

func (h *Host) currentLoad() hardware.Load {
	h.mu.Lock()
	l := h.load
	h.mu.Unlock()
	if time.Since(l.At) > 5*time.Second {
		l = hardware.Sample()
		h.mu.Lock()
		h.load = l
		h.mu.Unlock()
	}
	return l
}

// assignRoles picks models for a host that has none assigned: the largest
// installed model for deep work, and the smallest for quick work. A person
// can change both. A host with one model uses it for everything.
func (h *Host) assignRoles(ctx context.Context) {
	if h.cfg.Get().Roles.Deep != "" {
		return
	}
	models := h.engines.All(ctx)
	if len(models) == 0 {
		return
	}
	sort.SliceStable(models, func(i, j int) bool { return models[i].SizeBytes > models[j].SizeBytes })
	roles := config.Roles{Deep: models[0].ID}
	if smallest := models[len(models)-1]; smallest.ID != roles.Deep {
		roles.Quick = smallest.ID
	}
	h.cfg.Update(func(c *config.Config) { c.Roles = roles })
	h.log.Info("assigned models", "deep", roles.Deep, "quick", roles.Quick)
	h.hub.Publish(events.Changed, nil)
}

func (h *Host) nextRequestID() string {
	h.mu.Lock()
	h.requestID++
	n := h.requestID
	h.mu.Unlock()
	return fmt.Sprintf("r%d", n)
}
