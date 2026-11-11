// Package tunnel keeps a host's outbound connection to a relay. The host
// dials out, so it needs no open port, no static address, and no VPN. Each
// client the relay brings arrives as a Conn.
package tunnel

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// Conn is one client's connection as the host sees it. Messages arrive
// whole and in order.
type Conn interface {
	Recv(ctx context.Context) ([]byte, error)
	Send(msg []byte) error
	// Close ends the connection. The relay passes code and reason to the
	// client, so reason must not carry detail.
	Close(code int, reason string)
}

// State is where the tunnel stands.
type State string

const (
	StateDisabled   State = "disabled"
	StateConnecting State = "connecting"
	StateConnected  State = "connected"
	StateOffline    State = "offline"
)

// Status is a snapshot for the admin API.
type Status struct {
	State     State     `json:"state"`
	Relay     string    `json:"relay"`
	Since     time.Time `json:"since,omitzero"`
	LastError string    `json:"lastError,omitempty"`
}

// Tunnel dials a relay and reconnects when the connection drops.
type Tunnel struct {
	Relay    string
	Identity *identity.Identity
	// Serve handles one client. It runs on its own goroutine.
	Serve    func(ctx context.Context, c Conn)
	OnChange func(Status)
	Log      *slog.Logger
	// MaxSessions bounds the clients served at once. Zero means 128. The
	// bound is the host's own, because a relay cannot be relied on to
	// enforce one.
	MaxSessions int

	mu     sync.Mutex
	status Status
}

// Status returns the current state.
func (t *Tunnel) Status() Status {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.status.State == "" {
		return Status{State: StateOffline, Relay: t.Relay}
	}
	return t.status
}

func (t *Tunnel) set(state State, err error) {
	t.mu.Lock()
	t.status.Relay = t.Relay
	if t.status.State != state {
		t.status.State = state
		t.status.Since = time.Now().UTC()
	}
	if err != nil {
		t.status.LastError = err.Error()
	} else if state == StateConnected {
		t.status.LastError = ""
	}
	s := t.status
	t.mu.Unlock()
	if t.OnChange != nil {
		t.OnChange(s)
	}
}

// Run keeps the tunnel up until ctx ends.
func (t *Tunnel) Run(ctx context.Context) {
	if t.Log == nil {
		t.Log = slog.Default()
	}
	backoff := time.Second
	for ctx.Err() == nil {
		t.set(StateConnecting, nil)
		started := time.Now()
		err := t.connect(ctx)
		if ctx.Err() != nil {
			break
		}
		t.set(StateOffline, err)
		t.Log.Warn("tunnel down", "relay", t.Relay, "error", err)
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		wait := backoff + time.Duration(rand.Int64N(int64(backoff/2)+1))
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
	t.set(StateOffline, nil)
}

func (t *Tunnel) connect(ctx context.Context) error {
	dialCtx, cancelDial := context.WithTimeout(ctx, 15*time.Second)
	// The ID in the address lets a relay send this connection to the right
	// place before the host has proved anything. The proof still follows:
	// the relay checks the ID against the key in the challenge.
	ws, _, err := websocket.Dial(dialCtx, strings.TrimRight(t.Relay, "/")+"/v1/host?id="+t.Identity.HostID(), &websocket.DialOptions{
		Subprotocols: []string{wire.Subprotocol},
	})
	cancelDial()
	if err != nil {
		t.Log.Debug("relay dial failed", "relay", t.Relay, "error", err)
		return fmt.Errorf("cannot reach the relay at %s", t.Relay)
	}
	defer ws.CloseNow()
	ws.SetReadLimit(wire.MaxHostMessage)

	if err := t.register(ctx, ws); err != nil {
		return err
	}
	t.set(StateConnected, nil)
	t.Log.Info("tunnel up", "relay", t.Relay, "host", t.Identity.HostID())

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	out := make(chan []byte, 256)
	writeErr := make(chan error, 1)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-out:
				wctx, wcancel := context.WithTimeout(ctx, 20*time.Second)
				err := ws.Write(wctx, websocket.MessageBinary, b)
				wcancel()
				if err != nil {
					writeErr <- err
					cancel()
					return
				}
			}
		}
	}()
	go func() {
		tick := time.NewTicker(25 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := ws.Ping(pctx)
				pcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()

	var mu sync.Mutex
	sessions := map[uint64]*relayConn{}
	defer func() {
		mu.Lock()
		for _, rc := range sessions {
			rc.end(&wire.CloseError{Code: wire.CloseHostOffline, Reason: "tunnel down"})
		}
		mu.Unlock()
	}()

	for {
		typ, msg, err := ws.Read(ctx)
		if err != nil {
			select {
			case werr := <-writeErr:
				return werr
			default:
			}
			if code := websocket.CloseStatus(err); code == wire.CloseReplaced {
				return errors.New("another copy of this host connected to the relay")
			}
			return err
		}
		if typ != websocket.MessageBinary {
			continue
		}
		kind, sid, payload, err := wire.ParseRelayFrame(msg)
		if err != nil {
			return err
		}
		switch kind {
		case wire.RelayOpen:
			limit := t.MaxSessions
			if limit <= 0 {
				limit = 128
			}
			mu.Lock()
			full := len(sessions) >= limit
			mu.Unlock()
			if full {
				refusal := wire.AppendRelayFrame(nil, wire.RelayClose, sid, wire.AppendClose(nil, wire.CloseTooManySessions, "host is busy"))
				select {
				case out <- refusal:
				case <-ctx.Done():
				}
				continue
			}
			rc := &relayConn{sid: sid, in: make(chan []byte, 512), done: make(chan struct{}), out: out, tunnelCtx: ctx}
			rc.forget = func() {
				mu.Lock()
				delete(sessions, sid)
				mu.Unlock()
			}
			mu.Lock()
			sessions[sid] = rc
			mu.Unlock()
			go func() {
				sctx, scancel := context.WithCancel(ctx)
				defer scancel()
				go func() {
					select {
					case <-rc.done:
						scancel()
					case <-sctx.Done():
					}
				}()
				t.Serve(sctx, rc)
				rc.Close(1000, "")
			}()
		case wire.RelayData:
			mu.Lock()
			rc := sessions[sid]
			mu.Unlock()
			if rc == nil {
				continue
			}
			select {
			case rc.in <- payload:
			default:
				rc.Close(wire.CloseSlowConsumer, "host is busy")
			}
		case wire.RelayClose:
			mu.Lock()
			rc := sessions[sid]
			delete(sessions, sid)
			mu.Unlock()
			if rc != nil {
				rc.end(&wire.CloseError{Code: 1000, Reason: "client closed"})
			}
		}
	}
}

func (t *Tunnel) register(ctx context.Context, ws *websocket.Conn) error {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	challenge, err := readControl(ctx, ws)
	if err != nil {
		return err
	}
	if challenge.Type != "challenge" {
		return errors.New("the relay did not send a challenge")
	}
	nonce, err := base64.StdEncoding.DecodeString(challenge.Nonce)
	if err != nil || len(nonce) < 16 {
		return errors.New("the relay sent a bad challenge")
	}
	reply, _ := json.Marshal(wire.Control{
		Type:      "register",
		HostID:    t.Identity.HostID(),
		PublicKey: base64.StdEncoding.EncodeToString(t.Identity.SigningPublic()),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(t.Identity.Signing, wire.RegisterMessage(nonce))),
	})
	if err := ws.Write(ctx, websocket.MessageText, reply); err != nil {
		return err
	}
	result, err := readControl(ctx, ws)
	if err != nil {
		return err
	}
	if result.Type != "registered" {
		// The relay wrote this text, so clean it before it reaches a
		// terminal or the status document.
		return fmt.Errorf("the relay refused this host: %s", wire.CleanText(result.Message, 120))
	}
	return nil
}

func readControl(ctx context.Context, ws *websocket.Conn) (wire.Control, error) {
	var msg wire.Control
	typ, data, err := ws.Read(ctx)
	if err != nil {
		return msg, err
	}
	if typ != websocket.MessageText {
		return msg, errors.New("expected a control message")
	}
	return msg, json.Unmarshal(data, &msg)
}

// relayConn is a Conn that rides the host's one relay socket.
type relayConn struct {
	sid       uint64
	in        chan []byte
	out       chan<- []byte
	tunnelCtx context.Context
	forget    func()

	once sync.Once
	done chan struct{}
	err  error
}

func (c *relayConn) end(err error) {
	c.once.Do(func() {
		c.err = err
		close(c.done)
	})
}

func (c *relayConn) Recv(ctx context.Context) ([]byte, error) {
	// Deliver what already arrived before reporting the end.
	select {
	case msg := <-c.in:
		return msg, nil
	default:
	}
	select {
	case msg := <-c.in:
		return msg, nil
	case <-c.done:
		return nil, c.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (c *relayConn) Send(msg []byte) error {
	frame := wire.AppendRelayFrame(make([]byte, 0, wire.RelayHeaderSize+len(msg)), wire.RelayData, c.sid, msg)
	select {
	case <-c.done:
		return c.err
	default:
	}
	select {
	case c.out <- frame:
		return nil
	case <-c.done:
		return c.err
	case <-c.tunnelCtx.Done():
		return errors.New("tunnel down")
	}
}

func (c *relayConn) Close(code int, reason string) {
	select {
	case <-c.done:
		return
	default:
	}
	var payload []byte
	if code != 1000 {
		payload = wire.AppendClose(nil, code, reason)
	}
	frame := wire.AppendRelayFrame(nil, wire.RelayClose, c.sid, payload)
	select {
	case c.out <- frame:
	case <-c.tunnelCtx.Done():
	}
	c.forget()
	c.end(&wire.CloseError{Code: code, Reason: reason})
}
