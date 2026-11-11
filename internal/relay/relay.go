// Package relay is the rendezvous server. A host behind a home router dials
// out to a relay and keeps one WebSocket open. A client dials the same relay
// and names the host. The relay copies messages between the two.
//
// A relay holds no key that opens those messages. The client and the host
// run a Noise handshake through it, and everything after the handshake is
// sealed. A relay can see which host ID a client asks for, when, and how
// many bytes pass. It stores nothing.
package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// Options tunes a relay. The zero value is usable.
type Options struct {
	// MaxSessionsPerHost bounds the clients one host serves at once.
	MaxSessionsPerHost int
	// MaxOpensPerMinute bounds new client connections to one host.
	MaxOpensPerMinute int
	// MaxSessionsPerAddress and MaxOpensPerAddress bound what one network
	// address can take of a host's budget, so that a stranger who knows a
	// host ID cannot lock the host's own devices out.
	MaxSessionsPerAddress int
	MaxOpensPerAddress    int
	// TrustForwarded makes the relay read a client's address from the last
	// entry of X-Forwarded-For. Set it only when one reverse proxy that you
	// run sits in front of the relay.
	TrustForwarded bool
	// MaxHosts bounds registered hosts. Zero means no bound.
	MaxHosts int
	// QueueBytes bounds the bytes waiting for one slow connection.
	QueueBytes int64
	Logger     *slog.Logger
}

func (o *Options) defaults() {
	if o.MaxSessionsPerHost <= 0 {
		o.MaxSessionsPerHost = 64
	}
	if o.MaxOpensPerMinute <= 0 {
		o.MaxOpensPerMinute = 240
	}
	if o.MaxSessionsPerAddress <= 0 {
		o.MaxSessionsPerAddress = 16
	}
	if o.MaxOpensPerAddress <= 0 {
		o.MaxOpensPerAddress = 60
	}
	if o.QueueBytes <= 0 {
		o.QueueBytes = 8 << 20
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
}

const (
	registerTimeout = 10 * time.Second
	writeTimeout    = 20 * time.Second
	pingEvery       = 25 * time.Second
)

// Relay is one rendezvous server.
type Relay struct {
	opts    Options
	log     *slog.Logger
	started time.Time

	mu    sync.Mutex
	hosts map[string]*hostConn

	sessionsTotal atomic.Int64
	bytesTotal    atomic.Int64
}

// New returns a relay.
func New(opts Options) *Relay {
	opts.defaults()
	return &Relay{opts: opts, log: opts.Logger, started: time.Now(), hosts: map[string]*hostConn{}}
}

// Handler serves the relay's routes.
func (r *Relay) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/host", r.serveHost)
	mux.HandleFunc("GET /v1/connect/{host}", r.serveClient)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		r.mu.Lock()
		hosts := len(r.hosts)
		r.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{
			"ok":       true,
			"version":  brand.Version,
			"hosts":    hosts,
			"sessions": r.sessionsTotal.Load(),
			"uptime":   int(time.Since(r.started).Seconds()),
		})
	})
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "%s relay %s\n\nThis server passes sealed messages between a host and the apps paired with it.\nIt holds no key that opens them. The source is at %s\n",
			brand.Name, brand.Version, brand.Source)
	})
	return mux
}

// queue is a bounded FIFO of outgoing messages for one socket.
type queue struct {
	ch    chan []byte
	bytes atomic.Int64
	limit int64
	done  chan struct{}
	once  sync.Once
}

func newQueue(limit int64) *queue {
	return &queue{ch: make(chan []byte, 4096), limit: limit, done: make(chan struct{})}
}

// push reports false when the queue is full or closed.
func (q *queue) push(b []byte) bool {
	n := int64(len(b))
	if q.bytes.Add(n) > q.limit {
		q.bytes.Add(-n)
		return false
	}
	select {
	case <-q.done:
		q.bytes.Add(-n)
		return false
	default:
	}
	select {
	case q.ch <- b:
		return true
	default:
		q.bytes.Add(-n)
		return false
	}
}

func (q *queue) close() { q.once.Do(func() { close(q.done) }) }

// drain writes queued messages to ws until the queue closes or a write
// fails.
func (q *queue) drain(ws *websocket.Conn) {
	for {
		select {
		case <-q.done:
			return
		case b := <-q.ch:
			q.bytes.Add(-int64(len(b)))
			ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
			err := ws.Write(ctx, websocket.MessageBinary, b)
			cancel()
			if err != nil {
				q.close()
				return
			}
		}
	}
}

type hostConn struct {
	id  string
	ws  *websocket.Conn
	out *queue

	mu        sync.Mutex
	sessions  map[uint64]*clientConn
	nextSID   uint64
	opens     []time.Time
	addresses map[string]*addressUse
	gone      bool
}

// addressUse is what one network address holds of a host's budget.
type addressUse struct {
	sessions int
	opens    []time.Time
}

type clientConn struct {
	sid     uint64
	address string
	ws      *websocket.Conn
	out     *queue

	closeOnce sync.Once
}

// end closes the client's socket with a code. It is safe to call twice.
//
// The close frame must reach the socket before anything cancels the read
// loop, because a cancelled read drops the connection without a code. So
// the queue closes only after the close handshake.
func (c *clientConn) end(code int, reason string) {
	c.closeOnce.Do(func() {
		go func() {
			c.ws.Close(websocket.StatusCode(code), reason)
			c.out.close()
		}()
	})
}

func (r *Relay) serveHost(w http.ResponseWriter, req *http.Request) {
	ws, err := websocket.Accept(w, req, &websocket.AcceptOptions{Subprotocols: []string{wire.Subprotocol}})
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ws.SetReadLimit(wire.MaxHostMessage)

	hostID, err := r.register(req.Context(), ws)
	// The address may name the host, so that a relay built from many parts
	// can route the connection. If it does, it must name the host that the
	// key proves.
	if named := req.URL.Query().Get("id"); err == nil && named != "" && named != hostID {
		err = errors.New("host ID does not match the key")
	}
	if err != nil {
		writeControl(req.Context(), ws, wire.Control{Type: "error", Code: "register_failed", Message: err.Error()})
		ws.Close(wire.CloseUnauthorized, "register failed")
		return
	}

	hc := &hostConn{
		id: hostID, ws: ws, out: newQueue(r.opts.QueueBytes * 4),
		sessions: map[uint64]*clientConn{}, addresses: map[string]*addressUse{},
	}
	if !r.admit(hc) {
		writeControl(req.Context(), ws, wire.Control{Type: "error", Code: "relay_full", Message: "this relay is full"})
		ws.Close(wire.CloseTooManySessions, "relay full")
		return
	}
	defer r.remove(hc)

	if err := writeControl(req.Context(), ws, wire.Control{Type: "registered", HostID: hostID}); err != nil {
		return
	}
	r.log.Info("host online", "host", hostID)
	defer r.log.Info("host offline", "host", hostID)

	go hc.out.drain(ws)
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, ws, cancel)
	go func() {
		// A failed write ends the read loop too.
		select {
		case <-hc.out.done:
			cancel()
		case <-ctx.Done():
		}
	}()

	for {
		typ, msg, err := ws.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageBinary {
			continue
		}
		kind, sid, payload, err := wire.ParseRelayFrame(msg)
		if err != nil {
			return
		}
		hc.mu.Lock()
		client := hc.sessions[sid]
		hc.mu.Unlock()
		if client == nil {
			continue
		}
		switch kind {
		case wire.RelayData:
			r.bytesTotal.Add(int64(len(payload)))
			if !client.out.push(payload) {
				client.end(wire.CloseSlowConsumer, "slow consumer")
			}
		case wire.RelayClose:
			code, reason := wire.ParseClose(payload)
			hc.remove(sid)
			// Let queued messages reach the client before the close frame.
			go func() {
				deadline := time.Now().Add(2 * time.Second)
				for client.out.bytes.Load() > 0 && time.Now().Before(deadline) {
					time.Sleep(10 * time.Millisecond)
				}
				client.end(code, reason)
			}()
		}
	}
}

// register runs the challenge and returns the host ID the caller proved.
func (r *Relay) register(ctx context.Context, ws *websocket.Conn) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, registerTimeout)
	defer cancel()

	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	if err := writeControl(ctx, ws, wire.Control{Type: "challenge", Nonce: base64.StdEncoding.EncodeToString(nonce)}); err != nil {
		return "", err
	}
	typ, data, err := ws.Read(ctx)
	if err != nil {
		return "", err
	}
	if typ != websocket.MessageText {
		return "", errors.New("expected a register message")
	}
	var msg wire.Control
	if err := json.Unmarshal(data, &msg); err != nil || msg.Type != "register" {
		return "", errors.New("expected a register message")
	}
	pub, err := base64.StdEncoding.DecodeString(msg.PublicKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return "", errors.New("bad public key")
	}
	sig, err := base64.StdEncoding.DecodeString(msg.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return "", errors.New("bad signature")
	}
	if !ed25519.Verify(pub, wire.RegisterMessage(nonce), sig) {
		return "", errors.New("signature does not verify")
	}
	hostID := identity.HostID(pub)
	if msg.HostID != hostID {
		return "", errors.New("host ID does not match the key")
	}
	return hostID, nil
}

// admit records a host. A host that registers again replaces its old
// connection, which is what a reconnect after a network change needs.
func (r *Relay) admit(hc *hostConn) bool {
	r.mu.Lock()
	old := r.hosts[hc.id]
	if old == nil && r.opts.MaxHosts > 0 && len(r.hosts) >= r.opts.MaxHosts {
		r.mu.Unlock()
		return false
	}
	r.hosts[hc.id] = hc
	r.mu.Unlock()
	if old != nil {
		old.shutdown(wire.CloseHostOffline, "host reconnected")
		go old.ws.Close(wire.CloseReplaced, "replaced")
	}
	return true
}

func (r *Relay) remove(hc *hostConn) {
	r.mu.Lock()
	if r.hosts[hc.id] == hc {
		delete(r.hosts, hc.id)
	}
	r.mu.Unlock()
	hc.shutdown(wire.CloseHostOffline, "host offline")
	hc.out.close()
}

// shutdown ends every client session of a host.
func (hc *hostConn) shutdown(code int, reason string) {
	hc.mu.Lock()
	hc.gone = true
	sessions := hc.sessions
	hc.sessions = map[uint64]*clientConn{}
	hc.addresses = map[string]*addressUse{}
	hc.mu.Unlock()
	for _, c := range sessions {
		c.end(code, reason)
	}
}

// remove forgets a session. It reports whether the session was still there.
func (hc *hostConn) remove(sid uint64) bool {
	hc.mu.Lock()
	defer hc.mu.Unlock()
	c, ok := hc.sessions[sid]
	if !ok {
		return false
	}
	delete(hc.sessions, sid)
	if use := hc.addresses[c.address]; use != nil {
		use.sessions--
		if use.sessions <= 0 && len(recent(use.opens, time.Now())) == 0 {
			delete(hc.addresses, c.address)
		}
	}
	return true
}

// recent keeps the times within the last minute.
func recent(times []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-time.Minute)
	kept := times[:0]
	for _, t := range times {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	return kept
}

// open adds a client. It returns a close code when the host cannot take it.
// The address limits are checked first, so that one address runs into its
// own limit before it can use up the host's.
func (hc *hostConn) open(c *clientConn, o Options) int {
	hc.mu.Lock()
	defer hc.mu.Unlock()
	if hc.gone {
		return wire.CloseHostOffline
	}
	now := time.Now()
	use := hc.addresses[c.address]
	if use == nil {
		// Forget addresses that hold nothing, so the map cannot grow
		// without bound.
		for address, other := range hc.addresses {
			if other.sessions <= 0 && len(recent(other.opens, now)) == 0 {
				delete(hc.addresses, address)
			}
		}
		use = &addressUse{}
		hc.addresses[c.address] = use
	}
	use.opens = recent(use.opens, now)
	if use.sessions >= o.MaxSessionsPerAddress || len(use.opens) >= o.MaxOpensPerAddress {
		return wire.CloseTooManySessions
	}
	hc.opens = recent(hc.opens, now)
	if len(hc.sessions) >= o.MaxSessionsPerHost || len(hc.opens) >= o.MaxOpensPerMinute {
		return wire.CloseTooManySessions
	}
	use.opens = append(use.opens, now)
	use.sessions++
	hc.opens = append(hc.opens, now)
	hc.nextSID++
	c.sid = hc.nextSID
	hc.sessions[c.sid] = c
	return 0
}

// clientAddress is the key the address limits use. An IPv6 client is keyed
// by its /64, because one subscriber holds the whole of it.
func (r *Relay) clientAddress(req *http.Request) string {
	address := req.RemoteAddr
	if r.opts.TrustForwarded {
		if forwarded := req.Header.Get("X-Forwarded-For"); forwarded != "" {
			parts := strings.Split(forwarded, ",")
			address = strings.TrimSpace(parts[len(parts)-1])
		}
	}
	if host, _, err := net.SplitHostPort(address); err == nil {
		address = host
	}
	ip, err := netip.ParseAddr(address)
	if err != nil {
		return address
	}
	ip = ip.Unmap()
	if ip.Is6() {
		if prefix, err := ip.Prefix(64); err == nil {
			return prefix.String()
		}
	}
	return ip.String()
}

func (r *Relay) serveClient(w http.ResponseWriter, req *http.Request) {
	hostID := req.PathValue("host")
	ws, err := websocket.Accept(w, req, &websocket.AcceptOptions{Subprotocols: []string{wire.Subprotocol}})
	if err != nil {
		return
	}
	defer ws.CloseNow()
	// A client message gains a 9-byte header on its way to the host. This
	// limit keeps the result within what the host accepts.
	ws.SetReadLimit(wire.MaxClientMessage)

	if !identity.ValidHostID(hostID) {
		ws.Close(wire.CloseBadRequest, "bad host ID")
		return
	}
	r.mu.Lock()
	hc := r.hosts[hostID]
	r.mu.Unlock()
	if hc == nil {
		ws.Close(wire.CloseHostOffline, "host offline")
		return
	}

	client := &clientConn{ws: ws, address: r.clientAddress(req), out: newQueue(r.opts.QueueBytes)}
	if code := hc.open(client, r.opts); code != 0 {
		ws.Close(websocket.StatusCode(code), "host cannot take this connection")
		return
	}
	r.sessionsTotal.Add(1)
	sid := client.sid

	if !hc.out.push(wire.AppendRelayFrame(nil, wire.RelayOpen, sid, nil)) {
		hc.remove(sid)
		ws.Close(wire.CloseHostOffline, "host offline")
		return
	}
	defer func() {
		if hc.remove(sid) {
			hc.out.push(wire.AppendRelayFrame(nil, wire.RelayClose, sid, nil))
		}
		client.out.close()
	}()

	go client.out.drain(ws)
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	go keepAlive(ctx, ws, cancel)
	go func() {
		select {
		case <-client.out.done:
			cancel()
		case <-ctx.Done():
		}
	}()

	for {
		typ, msg, err := ws.Read(ctx)
		if err != nil {
			return
		}
		if typ != websocket.MessageBinary {
			continue
		}
		r.bytesTotal.Add(int64(len(msg)))
		if !hc.out.push(wire.AppendRelayFrame(make([]byte, 0, wire.RelayHeaderSize+len(msg)), wire.RelayData, sid, msg)) {
			client.end(wire.CloseSlowConsumer, "host is not reading")
			return
		}
	}
}

// keepAlive pings until ctx ends. A missed pong cancels the connection.
func keepAlive(ctx context.Context, ws *websocket.Conn, cancel context.CancelFunc) {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
			err := ws.Ping(pctx)
			pcancel()
			if err != nil {
				cancel()
				return
			}
		}
	}
}

func writeControl(ctx context.Context, ws *websocket.Conn, msg wire.Control) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	return ws.Write(ctx, websocket.MessageText, data)
}
