// Package session is the host's end of one client connection. It runs the
// handshake, then turns the sealed frames into HTTP requests against the
// host's own handler. A request that arrives here has already proved which
// paired device sent it.
package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
	"github.com/Tetrix-Technologies/tetrix-host/internal/secure"
	"github.com/Tetrix-Technologies/tetrix-host/internal/tunnel"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

const (
	handshakeTimeout = 15 * time.Second
	maxStreams       = 16
)

// Caller says who sent a request.
type Caller struct {
	// DeviceID is set for a request that came through the tunnel.
	DeviceID   string
	DeviceName string
	// Local is true for a request that came over loopback with a key.
	Local bool
}

type callerKey struct{}

// WithCaller attaches a caller to a context.
func WithCaller(ctx context.Context, c Caller) context.Context {
	return context.WithValue(ctx, callerKey{}, c)
}

// CallerFrom reads the caller a context carries.
func CallerFrom(ctx context.Context) (Caller, bool) {
	c, ok := ctx.Value(callerKey{}).(Caller)
	return c, ok
}

// Devices is the part of the device list a session needs.
type Devices interface {
	ByStaticKey(pub []byte) (config.Device, bool)
	Enroll(pub []byte, hello wire.ClientHello) (config.Device, error)
	Touch(id string, hello wire.ClientHello)
}

// Server serves client connections for one host.
type Server struct {
	Identity *identity.Identity
	HostName func() string
	Tickets  *pairing.Manager
	Devices  Devices
	// Handler receives every tunnel request. Mount only the routes a paired
	// device may call.
	Handler http.Handler
	// OnPaired runs after a device pairs.
	OnPaired func(config.Device)
	// OnPresence runs when a device's session starts and ends.
	OnPresence func(deviceID string, online bool)
	Log        *slog.Logger
	// HandshakeTimeout bounds each wait for a handshake message and for the
	// first sealed message after it. Zero means 15 seconds.
	HandshakeTimeout time.Duration

	mu   sync.Mutex
	live map[*running]struct{}
}

// Disconnect ends every open session of a device. Call it after the device
// is unpaired, so that a session already open stops at once.
func (s *Server) Disconnect(deviceID string) {
	s.mu.Lock()
	var hit []*running
	for r := range s.live {
		if r.device.ID == deviceID {
			hit = append(hit, r)
		}
	}
	s.mu.Unlock()
	for _, r := range hit {
		r.conn.Close(wire.CloseUnknownDevice, "unknown device")
	}
}

func (s *Server) track(r *running, on bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.live == nil {
		s.live = map[*running]struct{}{}
	}
	if on {
		s.live[r] = struct{}{}
	} else {
		delete(s.live, r)
	}
}

func (s *Server) hello() []byte {
	b, _ := json.Marshal(wire.HostHello{HostID: s.Identity.HostID(), Name: s.HostName(), Version: brand.Version})
	return b
}

func (s *Server) timeout() time.Duration {
	if s.HandshakeTimeout > 0 {
		return s.HandshakeTimeout
	}
	return handshakeTimeout
}

func (s *Server) logger() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}

// ServeConn handles one client from its first message to its last.
func (s *Server) ServeConn(ctx context.Context, c tunnel.Conn) {
	hctx, cancel := context.WithTimeout(ctx, s.timeout())
	first, err := c.Recv(hctx)
	cancel()
	if err != nil {
		c.Close(wire.CloseBadRequest, "no hello")
		return
	}
	if len(first) < 2 {
		c.Close(wire.CloseBadRequest, "bad hello")
		return
	}
	switch first[0] {
	case wire.HelloPair:
		s.servePair(ctx, c, first[1:])
	case wire.HelloSession:
		s.serveSession(ctx, c, first[1:])
	default:
		c.Close(wire.CloseBadRequest, "bad hello")
	}
}

func (s *Server) servePair(ctx context.Context, c tunnel.Conn, msg []byte) {
	if len(msg) <= wire.HintSize {
		c.Close(wire.CloseBadRequest, "bad hello")
		return
	}
	var hint pairing.Hint
	copy(hint[:], msg)
	ticket, ok := s.Tickets.Lookup(hint)
	if !ok {
		c.Close(wire.ClosePairingFailed, "no open pairing")
		return
	}
	hs, err := secure.NewPair(secure.Options{Static: s.Identity.Static, HostID: s.Identity.HostID()}, pairing.PSK(ticket.Secret))
	if err != nil {
		c.Close(wire.CloseHostError, "host error")
		return
	}
	if _, _, _, err := hs.ReadMessage(nil, msg[wire.HintSize:]); err != nil {
		s.Tickets.Fail(ticket)
		c.Close(wire.ClosePairingFailed, "pairing failed")
		return
	}
	m2, _, _, err := hs.WriteMessage(nil, s.hello())
	if err != nil || c.Send(m2) != nil {
		c.Close(wire.CloseHostError, "host error")
		return
	}
	hctx, cancel := context.WithTimeout(ctx, s.timeout())
	m3, err := c.Recv(hctx)
	cancel()
	if err != nil {
		c.Close(wire.ClosePairingFailed, "pairing failed")
		return
	}
	payload, cs0, cs1, err := hs.ReadMessage(nil, m3)
	if err != nil || cs0 == nil || cs1 == nil {
		s.Tickets.Fail(ticket)
		c.Close(wire.ClosePairingFailed, "pairing failed")
		return
	}
	var hello wire.ClientHello
	json.Unmarshal(payload, &hello)

	if !s.Tickets.Claim(ticket) {
		c.Close(wire.ClosePairingFailed, "pairing failed")
		return
	}
	channel := secure.NewChannel(cs0, cs1, false)
	result := wire.PairResult{OK: true, HostID: s.Identity.HostID(), HostName: s.HostName()}
	dev, err := s.Devices.Enroll(hs.PeerStatic(), hello)
	if err != nil {
		result = wire.PairResult{OK: false, Error: "The host could not save this device."}
	} else {
		result.DeviceID = dev.ID
	}
	body, _ := json.Marshal(result)
	if err := channel.Seal(wire.AppendTunnelFrame(nil, wire.FramePaired, 0, body), c.Send); err != nil {
		return
	}
	if result.OK && s.OnPaired != nil {
		s.OnPaired(dev)
	}
	// Give the client a moment to read the result and hang up first.
	wctx, wcancel := context.WithTimeout(ctx, 5*time.Second)
	c.Recv(wctx)
	wcancel()
	c.Close(1000, "")
}

func (s *Server) serveSession(ctx context.Context, c tunnel.Conn, msg []byte) {
	hs, err := secure.NewSession(secure.Options{Static: s.Identity.Static, HostID: s.Identity.HostID()}, nil)
	if err != nil {
		c.Close(wire.CloseHostError, "host error")
		return
	}
	payload, _, _, err := hs.ReadMessage(nil, msg)
	if err != nil {
		c.Close(wire.CloseUnauthorized, "handshake failed")
		return
	}
	dev, ok := s.Devices.ByStaticKey(hs.PeerStatic())
	if !ok {
		// Say so inside the handshake. The client can then tell the host's
		// own refusal from a close code, which a relay could send. The
		// refusal carries no name: this key has no standing here.
		refusal, _ := json.Marshal(wire.HostHello{HostID: s.Identity.HostID(), Refused: wire.RefusedUnknownDevice})
		if m2, _, _, err := hs.WriteMessage(nil, refusal); err == nil {
			c.Send(m2)
		}
		c.Close(wire.CloseUnknownDevice, "unknown device")
		return
	}
	var hello wire.ClientHello
	json.Unmarshal(payload, &hello)

	m2, cs0, cs1, err := hs.WriteMessage(nil, s.hello())
	if err != nil || cs0 == nil || cs1 == nil || c.Send(m2) != nil {
		c.Close(wire.CloseHostError, "host error")
		return
	}
	run := &running{
		server:  s,
		conn:    c,
		channel: secure.NewChannel(cs0, cs1, false),
		device:  dev,
		key:     append([]byte(nil), hs.PeerStatic()...),
		hello:   hello,
		streams: map[uint32]*stream{},
	}
	run.loop(ctx)
}

// running is one session after its handshake.
type running struct {
	server  *Server
	conn    tunnel.Conn
	channel *secure.Channel
	device  config.Device
	key     []byte
	hello   wire.ClientHello

	mu      sync.Mutex
	streams map[uint32]*stream
	present bool
}

type stream struct {
	body   *io.PipeWriter
	cancel context.CancelFunc
}

func (r *running) send(kind byte, id uint32, payload []byte) error {
	frame := wire.AppendTunnelFrame(make([]byte, 0, wire.TunnelHeaderSize+len(payload)), kind, id, payload)
	return r.channel.Seal(frame, r.conn.Send)
}

func (r *running) reset(id uint32, code, message string) {
	body, _ := json.Marshal(wire.Reset{Code: code, Message: message})
	r.send(wire.FrameReset, id, body)
}

func (r *running) loop(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	r.server.track(r, true)
	defer func() {
		cancel()
		r.server.track(r, false)
		r.mu.Lock()
		for _, st := range r.streams {
			st.cancel()
			st.body.CloseWithError(context.Canceled)
		}
		r.mu.Unlock()
		if r.present && r.server.OnPresence != nil {
			r.server.OnPresence(r.device.ID, false)
		}
	}()

	// The device may have been unpaired between the key lookup and the
	// moment this session became visible to Disconnect. Look again.
	if _, ok := r.server.Devices.ByStaticKey(r.key); !ok {
		r.conn.Close(wire.CloseUnknownDevice, "unknown device")
		return
	}

	for {
		// Until the client has sent one sealed message, this session could
		// be a replay of a recorded hello. Give it the handshake's deadline
		// and no longer, so replays cannot pile up.
		rctx, rcancel := ctx, context.CancelFunc(func() {})
		if !r.present {
			rctx, rcancel = context.WithTimeout(ctx, r.server.timeout())
		}
		sealed, err := r.conn.Recv(rctx)
		rcancel()
		if err != nil {
			if !r.present && ctx.Err() == nil {
				r.conn.Close(wire.CloseBadRequest, "no first message")
			}
			return
		}
		plain, err := r.channel.Open(sealed)
		if err != nil {
			r.conn.Close(wire.CloseBadRequest, "bad message")
			return
		}
		// A replayed first handshake message gets this far only if it is
		// followed by a message sealed with this session's keys. Presence
		// waits for that proof.
		if !r.present {
			r.present = true
			r.server.Devices.Touch(r.device.ID, r.hello)
			if r.server.OnPresence != nil {
				r.server.OnPresence(r.device.ID, true)
			}
		}
		kind, id, payload, err := wire.ParseTunnelFrame(plain)
		if err != nil {
			r.conn.Close(wire.CloseBadRequest, "bad frame")
			return
		}
		switch kind {
		case wire.FrameRequest:
			r.open(ctx, id, payload)
		case wire.FrameBody:
			if st := r.stream(id); st != nil {
				st.body.Write(payload)
			}
		case wire.FrameEnd:
			if st := r.stream(id); st != nil {
				st.body.Close()
			}
		case wire.FrameReset:
			if st := r.stream(id); st != nil {
				st.cancel()
				st.body.CloseWithError(context.Canceled)
			}
		case wire.FramePing:
			r.send(wire.FramePong, id, payload)
		}
	}
}

func (r *running) stream(id uint32) *stream {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.streams[id]
}

func (r *running) open(ctx context.Context, id uint32, payload []byte) {
	var head wire.RequestHead
	if err := json.Unmarshal(payload, &head); err != nil || head.Method == "" || !strings.HasPrefix(head.Path, "/") {
		r.reset(id, "bad_request", "The request head is not valid.")
		return
	}
	pr, pw := io.Pipe()
	rctx, cancel := context.WithCancel(ctx)

	r.mu.Lock()
	if _, exists := r.streams[id]; exists || len(r.streams) >= maxStreams {
		r.mu.Unlock()
		cancel()
		r.reset(id, "too_many_streams", "Too many requests are open on this connection.")
		return
	}
	r.streams[id] = &stream{body: pw, cancel: cancel}
	r.mu.Unlock()

	go func() {
		// A handler that panics must not take the host down with it. This
		// goroutine is not under net/http, which would recover for us.
		// http.ErrAbortHandler is how a handler says its answer is broken
		// and must not be ended as if it were whole.
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					r.reset(id, "upstream_failed", "The model server stopped before it finished.")
				} else {
					r.server.logger().Error("a request handler panicked", "panic", fmt.Sprint(v))
					r.reset(id, "host_error", "The host failed on this request.")
				}
			}
			cancel()
			pr.Close()
			r.mu.Lock()
			delete(r.streams, id)
			r.mu.Unlock()
		}()
		caller := Caller{DeviceID: r.device.ID, DeviceName: r.device.Name}
		req, err := http.NewRequestWithContext(WithCaller(rctx, caller), head.Method, "http://tunnel"+head.Path, pr)
		if err != nil {
			r.reset(id, "bad_request", "The request head is not valid.")
			return
		}
		for k, v := range head.Headers {
			k = strings.ToLower(k)
			// The tunnel authenticates the device. A header cannot.
			if k == "authorization" || k == "host" || k == "connection" {
				continue
			}
			req.Header.Set(k, v)
		}
		w := &responseWriter{run: r, id: id, header: http.Header{}}
		r.server.Handler.ServeHTTP(w, req)
		w.finish()
	}()
}

// responseWriter sends a handler's response as tunnel frames.
type responseWriter struct {
	run    *running
	id     uint32
	header http.Header
	wrote  bool
	err    error
}

func (w *responseWriter) Header() http.Header { return w.header }

func (w *responseWriter) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.wrote = true
	head := wire.ResponseHead{Status: status, Headers: map[string]string{}}
	for k, v := range w.header {
		if len(v) > 0 {
			head.Headers[strings.ToLower(k)] = v[0]
		}
	}
	body, _ := json.Marshal(head)
	w.err = w.run.send(wire.FrameResponse, w.id, body)
}

func (w *responseWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	written := 0
	for len(b) > 0 && w.err == nil {
		n := min(len(b), wire.BodyChunk)
		w.err = w.run.send(wire.FrameBody, w.id, b[:n])
		if w.err == nil {
			written += n
		}
		b = b[n:]
	}
	if w.err != nil {
		return written, errors.Join(io.ErrClosedPipe, w.err)
	}
	return written, nil
}

// Flush does nothing. Every Write already leaves as its own frame.
func (w *responseWriter) Flush() {}

func (w *responseWriter) finish() {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	if w.err == nil {
		w.run.send(wire.FrameEnd, w.id, nil)
	}
}
