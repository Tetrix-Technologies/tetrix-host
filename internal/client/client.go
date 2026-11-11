// Package client is the Go form of the client side of the protocol. The
// tests use it, and so does the CLI's own check of the tunnel. Apps use the
// Swift package TetrixHostKit, which speaks the same bytes.
package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/flynn/noise"

	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
	"github.com/Tetrix-Technologies/tetrix-host/internal/secure"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// ErrDeviceNotPaired means the host itself said, inside the handshake, that
// it has no pairing for this device's key.
var ErrDeviceNotPaired = errors.New("the host no longer has this device paired")

// Pairing is what a client keeps after it pairs. Static holds the client's
// private key, so store it like a password.
type Pairing struct {
	HostID     string      `json:"hostId"`
	HostName   string      `json:"hostName"`
	Relay      string      `json:"relay"`
	HostStatic []byte      `json:"hostStatic"`
	DeviceID   string      `json:"deviceId"`
	Static     noise.DHKey `json:"static"`
}

func dial(ctx context.Context, relay, hostID string) (*websocket.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, strings.TrimRight(relay, "/")+"/v1/connect/"+hostID, &websocket.DialOptions{
		Subprotocols: []string{wire.Subprotocol},
	})
	if err != nil {
		return nil, fmt.Errorf("cannot reach the relay: %w", err)
	}
	ws.SetReadLimit(wire.MaxClientMessage)
	return ws, nil
}

func read(ctx context.Context, ws *websocket.Conn) ([]byte, error) {
	for {
		typ, msg, err := ws.Read(ctx)
		if err != nil {
			if code := websocket.CloseStatus(err); code >= 4000 {
				var ce websocket.CloseError
				errors.As(err, &ce)
				return nil, &wire.CloseError{Code: int(code), Reason: ce.Reason}
			}
			return nil, err
		}
		if typ == websocket.MessageBinary {
			return msg, nil
		}
	}
}

// Pair spends a pairing code and returns the pairing to store.
func Pair(ctx context.Context, code string, hello wire.ClientHello) (*Pairing, error) {
	offer, err := pairing.Parse(code)
	if err != nil {
		return nil, err
	}
	static, err := noise.DH25519.GenerateKeypair(nil)
	if err != nil {
		return nil, err
	}
	ws, err := dial(ctx, offer.Relay, offer.HostID)
	if err != nil {
		return nil, err
	}
	defer ws.CloseNow()

	hs, err := secure.NewPair(secure.Options{Static: static, HostID: offer.HostID, Initiator: true}, pairing.PSK(offer.Secret))
	if err != nil {
		return nil, err
	}
	m1, _, _, err := hs.WriteMessage(nil, nil)
	if err != nil {
		return nil, err
	}
	hint := pairing.HintFor(offer.Secret)
	first := append([]byte{wire.HelloPair}, hint[:]...)
	if err := ws.Write(ctx, websocket.MessageBinary, append(first, m1...)); err != nil {
		return nil, err
	}
	m2, err := read(ctx, ws)
	if err != nil {
		return nil, err
	}
	hostHelloBytes, _, _, err := hs.ReadMessage(nil, m2)
	if err != nil {
		return nil, errors.New("the host did not prove it holds this pairing code")
	}
	var hostHello wire.HostHello
	json.Unmarshal(hostHelloBytes, &hostHello)
	if hostHello.HostID != offer.HostID {
		return nil, errors.New("the host answered with a different ID")
	}
	helloBytes, _ := json.Marshal(hello)
	m3, cs0, cs1, err := hs.WriteMessage(nil, helloBytes)
	if err != nil {
		return nil, err
	}
	if err := ws.Write(ctx, websocket.MessageBinary, m3); err != nil {
		return nil, err
	}
	channel := secure.NewChannel(cs0, cs1, true)
	sealed, err := read(ctx, ws)
	if err != nil {
		return nil, err
	}
	plain, err := channel.Open(sealed)
	if err != nil {
		return nil, err
	}
	kind, _, payload, err := wire.ParseTunnelFrame(plain)
	if err != nil || kind != wire.FramePaired {
		return nil, errors.New("the host did not confirm the pairing")
	}
	var result wire.PairResult
	if err := json.Unmarshal(payload, &result); err != nil {
		return nil, err
	}
	if !result.OK {
		return nil, errors.New(result.Error)
	}
	ws.Close(websocket.StatusNormalClosure, "")
	return &Pairing{
		HostID:     offer.HostID,
		HostName:   result.HostName,
		Relay:      offer.Relay,
		HostStatic: hs.PeerStatic(),
		DeviceID:   result.DeviceID,
		Static:     static,
	}, nil
}

// Session is an open, sealed connection to a host.
type Session struct {
	Host wire.HostHello

	ws      *websocket.Conn
	channel *secure.Channel
	cancel  context.CancelFunc

	mu      sync.Mutex
	next    uint32
	streams map[uint32]*stream
	pongs   chan struct{}
	err     error
	done    chan struct{}
}

type stream struct {
	head chan wire.ResponseHead
	body *io.PipeWriter
	once sync.Once
}

func (st *stream) fail(err error) {
	st.once.Do(func() { close(st.head) })
	st.body.CloseWithError(err)
}

// Connect opens a session with a paired host.
func Connect(ctx context.Context, p *Pairing, hello wire.ClientHello) (*Session, error) {
	ws, err := dial(ctx, p.Relay, p.HostID)
	if err != nil {
		return nil, err
	}
	hs, err := secure.NewSession(secure.Options{Static: p.Static, HostID: p.HostID, Initiator: true}, p.HostStatic)
	if err != nil {
		ws.CloseNow()
		return nil, err
	}
	helloBytes, _ := json.Marshal(hello)
	m1, _, _, err := hs.WriteMessage(nil, helloBytes)
	if err != nil {
		ws.CloseNow()
		return nil, err
	}
	hctx, hcancel := context.WithTimeout(ctx, 15*time.Second)
	defer hcancel()
	if err := ws.Write(hctx, websocket.MessageBinary, append([]byte{wire.HelloSession}, m1...)); err != nil {
		ws.CloseNow()
		return nil, err
	}
	m2, err := read(hctx, ws)
	if err != nil {
		ws.CloseNow()
		return nil, err
	}
	hostHelloBytes, cs0, cs1, err := hs.ReadMessage(nil, m2)
	if err != nil {
		ws.CloseNow()
		return nil, errors.New("the host did not prove its identity")
	}
	var hostHello wire.HostHello
	json.Unmarshal(hostHelloBytes, &hostHello)
	if hostHello.Refused != "" {
		ws.CloseNow()
		if hostHello.Refused == wire.RefusedUnknownDevice {
			return nil, ErrDeviceNotPaired
		}
		return nil, fmt.Errorf("the host refused the session: %s", wire.CleanText(hostHello.Refused, 64))
	}
	s := &Session{
		Host:    hostHello,
		ws:      ws,
		channel: secure.NewChannel(cs0, cs1, true),
		streams: map[uint32]*stream{},
		pongs:   make(chan struct{}, 1),
		done:    make(chan struct{}),
	}
	rctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	go s.readLoop(rctx)

	// The first sealed message proves to the host that this is a live
	// session and not a replay. The pong proves the same to the client.
	if err := s.Ping(hctx); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *Session) send(kind byte, id uint32, payload []byte) error {
	frame := wire.AppendTunnelFrame(make([]byte, 0, wire.TunnelHeaderSize+len(payload)), kind, id, payload)
	return s.channel.Seal(frame, func(sealed []byte) error {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		return s.ws.Write(ctx, websocket.MessageBinary, sealed)
	})
}

// Ping checks that the host answers.
func (s *Session) Ping(ctx context.Context) error {
	if err := s.send(wire.FramePing, 0, []byte("ping")); err != nil {
		return err
	}
	select {
	case <-s.pongs:
		return nil
	case <-s.done:
		return s.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Session) readLoop(ctx context.Context) {
	var err error
	defer func() {
		s.mu.Lock()
		s.err = err
		streams := s.streams
		s.streams = map[uint32]*stream{}
		s.mu.Unlock()
		close(s.done)
		for _, st := range streams {
			st.fail(err)
		}
	}()
	for {
		var sealed, plain []byte
		if sealed, err = read(ctx, s.ws); err != nil {
			return
		}
		if plain, err = s.channel.Open(sealed); err != nil {
			return
		}
		kind, id, payload, perr := wire.ParseTunnelFrame(plain)
		if perr != nil {
			err = perr
			return
		}
		s.mu.Lock()
		st := s.streams[id]
		s.mu.Unlock()
		switch kind {
		case wire.FramePong:
			select {
			case s.pongs <- struct{}{}:
			default:
			}
		case wire.FramePing:
			s.send(wire.FramePong, id, payload)
		case wire.FrameResponse:
			if st != nil {
				var head wire.ResponseHead
				json.Unmarshal(payload, &head)
				select {
				case st.head <- head:
				default:
				}
			}
		case wire.FrameBody:
			if st != nil {
				st.body.Write(payload)
			}
		case wire.FrameEnd:
			if st != nil {
				st.body.Close()
				s.forget(id)
			}
		case wire.FrameReset:
			if st != nil {
				var reset wire.Reset
				json.Unmarshal(payload, &reset)
				st.fail(fmt.Errorf("the host ended the request: %s %s", reset.Code, reset.Message))
				s.forget(id)
			}
		}
	}
}

func (s *Session) forget(id uint32) {
	s.mu.Lock()
	delete(s.streams, id)
	s.mu.Unlock()
}

// Response is a host's answer to one request.
type Response struct {
	Status  int
	Headers map[string]string
	Body    io.ReadCloser
}

type bodyReader struct {
	*io.PipeReader
	cancel func()
}

func (b *bodyReader) Close() error {
	b.cancel()
	return b.PipeReader.Close()
}

// Do sends one request and returns once the host has answered with a
// status. The body streams.
func (s *Session) Do(ctx context.Context, method, path string, headers map[string]string, body []byte) (*Response, error) {
	pr, pw := io.Pipe()
	st := &stream{head: make(chan wire.ResponseHead, 1), body: pw}
	s.mu.Lock()
	if s.err != nil {
		s.mu.Unlock()
		return nil, s.err
	}
	s.next++
	id := s.next
	s.streams[id] = st
	s.mu.Unlock()

	head, _ := json.Marshal(wire.RequestHead{Method: method, Path: path, Headers: headers})
	if err := s.send(wire.FrameRequest, id, head); err != nil {
		s.forget(id)
		return nil, err
	}
	for len(body) > 0 {
		n := min(len(body), wire.BodyChunk)
		if err := s.send(wire.FrameBody, id, body[:n]); err != nil {
			s.forget(id)
			return nil, err
		}
		body = body[n:]
	}
	if err := s.send(wire.FrameEnd, id, nil); err != nil {
		s.forget(id)
		return nil, err
	}
	abandon := func() {
		s.mu.Lock()
		_, open := s.streams[id]
		delete(s.streams, id)
		s.mu.Unlock()
		if open {
			s.send(wire.FrameReset, id, nil)
		}
	}
	select {
	case h, ok := <-st.head:
		if !ok {
			_, err := pr.Read(nil)
			if err == nil {
				err = errors.New("the request failed")
			}
			return nil, err
		}
		return &Response{Status: h.Status, Headers: h.Headers, Body: &bodyReader{PipeReader: pr, cancel: abandon}}, nil
	case <-s.done:
		return nil, s.err
	case <-ctx.Done():
		abandon()
		return nil, ctx.Err()
	}
}

// Close ends the session.
func (s *Session) Close() {
	s.ws.Close(websocket.StatusNormalClosure, "")
	s.cancel()
}
