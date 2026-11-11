package session_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Tetrix-Technologies/tetrix-host/internal/client"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
	"github.com/Tetrix-Technologies/tetrix-host/internal/relay"
	"github.com/Tetrix-Technologies/tetrix-host/internal/secure"
	"github.com/Tetrix-Technologies/tetrix-host/internal/session"
	"github.com/Tetrix-Technologies/tetrix-host/internal/tunnel"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// rig is a relay, a host connected to it, and the host's parts.
type rig struct {
	relayURL string
	id       *identity.Identity
	tickets  *pairing.Manager
	devices  *config.Devices

	mu       sync.Mutex
	presence map[string]bool
}

func newRig(t *testing.T) *rig {
	t.Helper()
	srv := httptest.NewServer(relay.New(relay.Options{}).Handler())
	t.Cleanup(srv.Close)

	id, err := identity.Generate()
	if err != nil {
		t.Fatal(err)
	}
	devices, _ := config.OpenDevices("")
	r := &rig{
		relayURL: "ws" + strings.TrimPrefix(srv.URL, "http"),
		id:       id,
		tickets:  pairing.NewManager(time.Minute),
		devices:  devices,
		presence: map[string]bool{},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/echo", func(w http.ResponseWriter, req *http.Request) {
		caller, _ := session.CallerFrom(req.Context())
		body, _ := io.ReadAll(req.Body)
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-Device", caller.DeviceID)
		w.Write(body)
	})
	mux.HandleFunc("GET /v1/stream", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for i := 0; i < 5; i++ {
			fmt.Fprintf(w, "data: %d\n\n", i)
			w.(http.Flusher).Flush()
		}
	})
	mux.HandleFunc("GET /v1/slow", func(w http.ResponseWriter, req *http.Request) {
		w.WriteHeader(200)
		<-req.Context().Done()
	})
	mux.HandleFunc("GET /v1/panic", func(http.ResponseWriter, *http.Request) {
		panic("a bug in a handler")
	})
	mux.HandleFunc("GET /v1/abort", func(w http.ResponseWriter, req *http.Request) {
		w.Write([]byte("half an ans"))
		panic(http.ErrAbortHandler)
	})

	server := &session.Server{
		Identity:         id,
		HostName:         func() string { return "Test host" },
		Tickets:          r.tickets,
		Devices:          devices,
		Handler:          mux,
		HandshakeTimeout: 300 * time.Millisecond,
		Log:              slog.New(slog.NewTextHandler(io.Discard, nil)),
		OnPresence: func(deviceID string, online bool) {
			r.mu.Lock()
			r.presence[deviceID] = online
			r.mu.Unlock()
		},
	}
	tun := &tunnel.Tunnel{Relay: r.relayURL, Identity: id, Serve: server.ServeConn}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go tun.Run(ctx)

	deadline := time.Now().Add(5 * time.Second)
	for tun.Status().State != tunnel.StateConnected {
		if time.Now().After(deadline) {
			t.Fatalf("tunnel did not connect: %+v", tun.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
	return r
}

func (r *rig) code(t *testing.T) string {
	t.Helper()
	ticket, err := r.tickets.Create()
	if err != nil {
		t.Fatal(err)
	}
	code, err := pairing.Code(r.id.HostID(), ticket.Secret)
	if err != nil {
		t.Fatal(err)
	}
	return pairing.Link(code, r.relayURL)
}

func TestPairThenRequest(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "Test laptop", App: "Cue", Platform: "macOS"})
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	if p.HostName != "Test host" || p.DeviceID == "" {
		t.Fatalf("unexpected pairing: %+v", p)
	}
	if !bytes.Equal(p.HostStatic, r.id.Static.Public) {
		t.Fatal("the client pinned the wrong host key")
	}
	devices := r.devices.List()
	if len(devices) != 1 || devices[0].Name != "Test laptop" || devices[0].ID != p.DeviceID {
		t.Fatalf("unexpected devices: %+v", devices)
	}

	s, err := client.Connect(ctx, p, wire.ClientHello{App: "Cue"})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer s.Close()
	if s.Host.Name != "Test host" {
		t.Fatalf("unexpected host hello: %+v", s.Host)
	}

	// A body larger than one frame crosses in pieces and comes back whole.
	big := bytes.Repeat([]byte("0123456789abcdef"), 20_000)
	resp, err := s.Do(ctx, "POST", "/v1/echo", map[string]string{"content-type": "text/plain"}, big)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if resp.Status != 200 || !bytes.Equal(got, big) {
		t.Fatalf("echo mismatch: status %d, %d bytes", resp.Status, len(got))
	}
	if resp.Headers["x-device"] != p.DeviceID {
		t.Fatalf("the host saw device %q, want %q", resp.Headers["x-device"], p.DeviceID)
	}

	resp, err = s.Do(ctx, "GET", "/v1/stream", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	stream, _ := io.ReadAll(resp.Body)
	if string(stream) != "data: 0\n\ndata: 1\n\ndata: 2\n\ndata: 3\n\ndata: 4\n\n" {
		t.Fatalf("unexpected stream: %q", stream)
	}

	r.mu.Lock()
	online := r.presence[p.DeviceID]
	r.mu.Unlock()
	if !online {
		t.Fatal("the device should be present while its session is open")
	}
}

func TestConcurrentRequests(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	s, err := client.Connect(ctx, p, wire.ClientHello{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			want := fmt.Sprintf("request %d", i)
			resp, err := s.Do(ctx, "POST", "/v1/echo", nil, []byte(want))
			if err != nil {
				t.Errorf("do %d: %v", i, err)
				return
			}
			got, _ := io.ReadAll(resp.Body)
			if string(got) != want {
				t.Errorf("got %q, want %q", got, want)
			}
		}(i)
	}
	wg.Wait()
}

func TestWrongCodeIsRefused(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// A code for the right host with the wrong secret names no open ticket.
	bad, _ := pairing.Code(r.id.HostID(), bytes.Repeat([]byte{7}, pairing.SecretSize))
	_, err := client.Pair(ctx, pairing.Link(bad, r.relayURL), wire.ClientHello{Name: "Intruder"})
	var closed *wire.CloseError
	if !errors.As(err, &closed) || closed.Code != wire.ClosePairingFailed {
		t.Fatalf("want a pairing-failed close, got %v", err)
	}
	if len(r.devices.List()) != 0 {
		t.Fatal("a refused pairing must not add a device")
	}
}

func TestCodeWorksOnce(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	code := r.code(t)
	if _, err := client.Pair(ctx, code, wire.ClientHello{Name: "First"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Pair(ctx, code, wire.ClientHello{Name: "Second"}); err == nil {
		t.Fatal("a spent code paired a second device")
	}
	if n := len(r.devices.List()); n != 1 {
		t.Fatalf("want 1 device, have %d", n)
	}
}

func TestUnpairedDeviceIsRefused(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "Leaving"})
	if err != nil {
		t.Fatal(err)
	}
	r.devices.Remove(p.DeviceID)

	// The refusal arrives inside the handshake, so the client knows the
	// host said it and not the relay.
	if _, err = client.Connect(ctx, p, wire.ClientHello{}); !errors.Is(err, client.ErrDeviceNotPaired) {
		t.Fatalf("want ErrDeviceNotPaired, got %v", err)
	}
}

func TestWrongHostKeyIsRefused(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	// A client that pinned another key cannot be talked into a session,
	// which is what stops a relay from standing in for the host.
	other, _ := identity.Generate()
	p.HostStatic = other.Static.Public
	if _, err := client.Connect(ctx, p, wire.ClientHello{}); err == nil {
		t.Fatal("a session opened against the wrong host key")
	}
}

func TestOfflineHost(t *testing.T) {
	srv := httptest.NewServer(relay.New(relay.Options{}).Handler())
	defer srv.Close()
	id, _ := identity.Generate()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	p := &client.Pairing{HostID: id.HostID(), Relay: "ws" + strings.TrimPrefix(srv.URL, "http"), HostStatic: id.Static.Public, Static: id.Static}
	_, err := client.Connect(ctx, p, wire.ClientHello{})
	var closed *wire.CloseError
	if !errors.As(err, &closed) || closed.Code != wire.CloseHostOffline {
		t.Fatalf("want a host-offline close, got %v", err)
	}
}

func TestCancelStopsTheHandler(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	s, err := client.Connect(ctx, p, wire.ClientHello{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	resp, err := s.Do(ctx, "GET", "/v1/slow", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	// The session still works after one request is abandoned.
	resp, err = s.Do(ctx, "POST", "/v1/echo", nil, []byte("still here"))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	if string(got) != "still here" {
		t.Fatalf("got %q", got)
	}
}

func TestHandlerPanicDoesNotStopTheHost(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	s, err := client.Connect(ctx, p, wire.ClientHello{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if _, err := s.Do(ctx, "GET", "/v1/panic", nil, nil); err == nil || !strings.Contains(err.Error(), "host_error") {
		t.Fatalf("want a host_error reset, got %v", err)
	}
	// The host is still up, and so is this session.
	resp, err := s.Do(ctx, "POST", "/v1/echo", nil, []byte("after the panic"))
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := io.ReadAll(resp.Body); string(got) != "after the panic" {
		t.Fatalf("got %q", got)
	}
}

func TestBrokenAnswerIsNotEndedAsWhole(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	s, err := client.Connect(ctx, p, wire.ClientHello{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	resp, err := s.Do(ctx, "GET", "/v1/abort", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(resp.Body)
	if err == nil || !strings.Contains(err.Error(), "upstream_failed") {
		t.Fatalf("half an answer read as whole: %q, %v", got, err)
	}
}

func TestReplayedHelloIsDropped(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, r.code(t), wire.ClientHello{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}

	// A valid first handshake message, as an eavesdropper would record it.
	hs, err := secure.NewSession(secure.Options{Static: p.Static, HostID: p.HostID, Initiator: true}, p.HostStatic)
	if err != nil {
		t.Fatal(err)
	}
	m1, _, _, _ := hs.WriteMessage(nil, []byte("{}"))
	hello := append([]byte{wire.HelloSession}, m1...)

	// Replaying it gets an answer, but no sealed message can follow, so
	// the host hangs up once the handshake deadline passes.
	for i := 0; i < 2; i++ {
		ws, _, err := websocket.Dial(ctx, r.relayURL+"/v1/connect/"+p.HostID, &websocket.DialOptions{Subprotocols: []string{wire.Subprotocol}})
		if err != nil {
			t.Fatal(err)
		}
		defer ws.CloseNow()
		ws.Write(ctx, websocket.MessageBinary, hello)
		if _, _, err := ws.Read(ctx); err != nil {
			t.Fatalf("replay %d: the host did not answer the hello: %v", i, err)
		}
		started := time.Now()
		_, _, err = ws.Read(ctx)
		if websocket.CloseStatus(err) != wire.CloseBadRequest {
			t.Fatalf("replay %d: want the host to close with %d, got %v", i, wire.CloseBadRequest, err)
		}
		if waited := time.Since(started); waited > 3*time.Second {
			t.Fatalf("replay %d: the host held the session for %s", i, waited)
		}
	}
	r.mu.Lock()
	present := r.presence[p.DeviceID]
	r.mu.Unlock()
	if present {
		t.Fatal("a replay made the device look connected")
	}
}
