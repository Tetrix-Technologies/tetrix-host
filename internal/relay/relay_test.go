package relay

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// start returns the address of a relay to test. It is the Go relay, unless
// TETRIX_HOST_TEST_RELAY names another one, such as the Cloudflare Worker
// in deploy/cloudflare running under "wrangler dev". The same tests then
// hold both relays to the same behavior. A test that sets relay options is
// skipped for an external relay, which takes none.
func start(t *testing.T, opts Options) string {
	t.Helper()
	if external := os.Getenv("TETRIX_HOST_TEST_RELAY"); external != "" {
		if opts != (Options{}) {
			t.Skip("this test sets relay options, and an external relay takes none")
		}
		return strings.TrimRight(external, "/")
	}
	srv := httptest.NewServer(New(opts).Handler())
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http")
}

// hostURL is the address a host with this key dials.
func hostURL(relay string, key ed25519.PrivateKey) string {
	return relay + "/v1/host?id=" + identity.HostID(key.Public().(ed25519.PublicKey))
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{wire.Subprotocol}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ws.CloseNow() })
	return ws
}

func readControl(t *testing.T, ws *websocket.Conn) wire.Control {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := ws.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var msg wire.Control
	json.Unmarshal(data, &msg)
	return msg
}

// register answers the relay's challenge. alter can break the reply.
func register(t *testing.T, ws *websocket.Conn, key ed25519.PrivateKey, alter func(*wire.Control)) wire.Control {
	t.Helper()
	challenge := readControl(t, ws)
	nonce, _ := base64.StdEncoding.DecodeString(challenge.Nonce)
	if challenge.Type != "challenge" || len(nonce) != 32 {
		t.Fatalf("unexpected challenge: %+v", challenge)
	}
	pub := key.Public().(ed25519.PublicKey)
	reply := wire.Control{
		Type:      "register",
		HostID:    identity.HostID(pub),
		PublicKey: base64.StdEncoding.EncodeToString(pub),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, wire.RegisterMessage(nonce))),
	}
	if alter != nil {
		alter(&reply)
	}
	data, _ := json.Marshal(reply)
	ws.Write(context.Background(), websocket.MessageText, data)
	return readControl(t, ws)
}

func newKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func closeCode(t *testing.T, ws *websocket.Conn) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err := ws.Read(ctx); err != nil {
			return int(websocket.CloseStatus(err))
		}
	}
}

func TestRegistrationNeedsTheKey(t *testing.T) {
	url := start(t, Options{})
	key, other := newKey(t), newKey(t)

	if got := register(t, dial(t, hostURL(url, key)), key, nil); got.Type != "registered" {
		t.Fatalf("an honest host was refused: %+v", got)
	}

	for name, alter := range map[string]func(*wire.Control){
		// A host cannot claim an ID that belongs to another key.
		"another host's ID": func(c *wire.Control) {
			c.HostID = identity.HostID(other.Public().(ed25519.PublicKey))
		},
		// A host cannot present another host's public key without its
		// private key.
		"another host's key": func(c *wire.Control) {
			pub := other.Public().(ed25519.PublicKey)
			c.PublicKey = base64.StdEncoding.EncodeToString(pub)
			c.HostID = identity.HostID(pub)
		},
		"a signature over other bytes": func(c *wire.Control) {
			c.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(key, []byte("something else")))
		},
		"no signature": func(c *wire.Control) { c.Signature = "" },
	} {
		ws := dial(t, hostURL(url, key))
		if got := register(t, ws, key, alter); got.Type != "error" {
			t.Errorf("%s: the relay answered %+v, want an error", name, got)
		}
		if code := closeCode(t, ws); code != wire.CloseUnauthorized {
			t.Errorf("%s: closed with %d, want %d", name, code, wire.CloseUnauthorized)
		}
	}
}

func TestAHostCannotSitInAnotherHostsPlace(t *testing.T) {
	url := start(t, Options{})
	mine, theirs := newKey(t), newKey(t)
	// A valid proof for my own key, sent to the address of another host.
	ws := dial(t, hostURL(url, theirs))
	if got := register(t, ws, mine, nil); got.Type != "error" {
		t.Fatalf("a host registered at another host's address: %+v", got)
	}
	if code := closeCode(t, ws); code != wire.CloseUnauthorized {
		t.Fatalf("closed with %d, want %d", code, wire.CloseUnauthorized)
	}
	// Their place is still empty, so their clients are told it is offline.
	theirID := identity.HostID(theirs.Public().(ed25519.PublicKey))
	if code := closeCode(t, dial(t, url+"/v1/connect/"+theirID)); code != wire.CloseHostOffline {
		t.Fatalf("a client of the other host closed with %d, want %d", code, wire.CloseHostOffline)
	}
}

func TestAChallengeCannotBeReplayed(t *testing.T) {
	url := start(t, Options{})
	key := newKey(t)

	// Record a valid reply on one connection.
	first := dial(t, hostURL(url, key))
	challenge := readControl(t, first)
	nonce, _ := base64.StdEncoding.DecodeString(challenge.Nonce)
	pub := key.Public().(ed25519.PublicKey)
	recorded, _ := json.Marshal(wire.Control{
		Type: "register", HostID: identity.HostID(pub),
		PublicKey: base64.StdEncoding.EncodeToString(pub),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, wire.RegisterMessage(nonce))),
	})

	// The same bytes on a new connection answer a different challenge.
	second := dial(t, hostURL(url, key))
	readControl(t, second)
	second.Write(context.Background(), websocket.MessageText, recorded)
	if got := readControl(t, second); got.Type != "error" {
		t.Fatalf("a replayed registration was accepted: %+v", got)
	}
}

func TestClientsOfUnknownHostsAreTurnedAway(t *testing.T) {
	url := start(t, Options{})
	if code := closeCode(t, dial(t, url+"/v1/connect/aaaaaaaaaaaaaaaa")); code != wire.CloseHostOffline {
		t.Errorf("an unregistered host ID closed with %d, want %d", code, wire.CloseHostOffline)
	}
	for _, bad := range []string{"short", "AAAAAAAAAAAAAAAA", "aaaaaaaaaaaaaaa1", "aaaaaaaaaaaaaaaaa"} {
		if code := closeCode(t, dial(t, url+"/v1/connect/"+bad)); code != wire.CloseBadRequest {
			t.Errorf("the host ID %q closed with %d, want %d", bad, code, wire.CloseBadRequest)
		}
	}
}

func TestMessagesPassUnchangedAndSessionsAreSeparate(t *testing.T) {
	url := start(t, Options{})
	key := newKey(t)
	host := dial(t, hostURL(url, key))
	register(t, host, key, nil)
	hostID := identity.HostID(key.Public().(ed25519.PublicKey))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	readFrame := func() (byte, uint64, []byte) {
		_, msg, err := host.Read(ctx)
		if err != nil {
			t.Fatalf("host read: %v", err)
		}
		kind, sid, payload, err := wire.ParseRelayFrame(msg)
		if err != nil {
			t.Fatal(err)
		}
		return kind, sid, payload
	}

	a := dial(t, url+"/v1/connect/"+hostID)
	kind, sidA, _ := readFrame()
	if kind != wire.RelayOpen {
		t.Fatalf("want an open frame, got %d", kind)
	}
	b := dial(t, url+"/v1/connect/"+hostID)
	_, sidB, _ := readFrame()
	if sidA == sidB {
		t.Fatal("two clients share a session ID")
	}

	a.Write(ctx, websocket.MessageBinary, []byte("from a"))
	if kind, sid, payload := readFrame(); kind != wire.RelayData || sid != sidA || string(payload) != "from a" {
		t.Fatalf("got frame %d for session %d: %q", kind, sid, payload)
	}

	// What the host sends to one session reaches that client only.
	host.Write(ctx, websocket.MessageBinary, wire.AppendRelayFrame(nil, wire.RelayData, sidB, []byte("to b")))
	if _, msg, err := b.Read(ctx); err != nil || string(msg) != "to b" {
		t.Fatalf("b read %q, %v", msg, err)
	}

	// The host can close one client with a code, and the other stays.
	host.Write(ctx, websocket.MessageBinary, wire.AppendRelayFrame(nil, wire.RelayClose, sidA, wire.AppendClose(nil, wire.CloseUnknownDevice, "unknown device")))
	if code := closeCode(t, a); code != wire.CloseUnknownDevice {
		t.Fatalf("a closed with %d, want %d", code, wire.CloseUnknownDevice)
	}
	host.Write(ctx, websocket.MessageBinary, wire.AppendRelayFrame(nil, wire.RelayData, sidB, []byte("still here")))
	if _, msg, err := b.Read(ctx); err != nil || string(msg) != "still here" {
		t.Fatalf("b read %q, %v", msg, err)
	}

	// When a client leaves, the host is told.
	b.Close(websocket.StatusNormalClosure, "")
	if kind, sid, _ := readFrame(); kind != wire.RelayClose || sid != sidB {
		t.Fatalf("want a close for session %d, got frame %d for %d", sidB, kind, sid)
	}
}

func TestSessionLimit(t *testing.T) {
	url := start(t, Options{MaxSessionsPerHost: 2})
	key := newKey(t)
	host := dial(t, hostURL(url, key))
	register(t, host, key, nil)
	go func() {
		for {
			if _, _, err := host.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	connect := url + "/v1/connect/" + identity.HostID(key.Public().(ed25519.PublicKey))
	dial(t, connect)
	dial(t, connect)
	if code := closeCode(t, dial(t, connect)); code != wire.CloseTooManySessions {
		t.Fatalf("a third client closed with %d, want %d", code, wire.CloseTooManySessions)
	}
}

func TestSecondRegistrationReplacesTheFirst(t *testing.T) {
	url := start(t, Options{})
	key := newKey(t)
	first := dial(t, hostURL(url, key))
	register(t, first, key, nil)
	client := dial(t, url+"/v1/connect/"+identity.HostID(key.Public().(ed25519.PublicKey)))

	second := dial(t, hostURL(url, key))
	if got := register(t, second, key, nil); got.Type != "registered" {
		t.Fatalf("the second registration was refused: %+v", got)
	}
	if code := closeCode(t, first); code != wire.CloseReplaced {
		t.Errorf("the first connection closed with %d, want %d", code, wire.CloseReplaced)
	}
	// A client of the old connection is dropped, because its session keys
	// lived in that connection.
	if code := closeCode(t, client); code != wire.CloseHostOffline {
		t.Errorf("the old connection's client closed with %d, want %d", code, wire.CloseHostOffline)
	}
}

func TestHostLimit(t *testing.T) {
	url := start(t, Options{MaxHosts: 1})
	first, second := newKey(t), newKey(t)
	register(t, dial(t, hostURL(url, first)), first, nil)
	if got := register(t, dial(t, hostURL(url, second)), second, nil); got.Type != "error" || got.Code != "relay_full" {
		t.Fatalf("a second host got %+v, want relay_full", got)
	}
}

func TestOversizeClientMessageCannotCutTheHostOff(t *testing.T) {
	url := start(t, Options{})
	key := newKey(t)
	host := dial(t, hostURL(url, key))
	// The limit a real host sets on its relay connection.
	host.SetReadLimit(wire.MaxHostMessage)
	register(t, host, key, nil)
	hostID := identity.HostID(key.Public().(ed25519.PublicKey))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	next := func() (byte, uint64, []byte) {
		t.Helper()
		_, msg, err := host.Read(ctx)
		if err != nil {
			t.Fatalf("the host's connection broke: %v", err)
		}
		kind, sid, payload, _ := wire.ParseRelayFrame(msg)
		return kind, sid, payload
	}

	// The largest message a client may send arrives whole.
	a := dial(t, url+"/v1/connect/"+hostID)
	next()
	biggest := make([]byte, wire.MaxClientMessage)
	if err := a.Write(ctx, websocket.MessageBinary, biggest); err != nil {
		t.Fatal(err)
	}
	if kind, _, payload := next(); kind != wire.RelayData || len(payload) != wire.MaxClientMessage {
		t.Fatalf("got frame %d with %d bytes", kind, len(payload))
	}

	// One byte more ends that client and nobody else.
	b := dial(t, url+"/v1/connect/"+hostID)
	_, sidB, _ := next()
	b.Write(ctx, websocket.MessageBinary, make([]byte, wire.MaxClientMessage+1))
	if kind, sid, _ := next(); kind != wire.RelayClose || sid != sidB {
		t.Fatalf("want the oversize client closed, got frame %d for session %d", kind, sid)
	}
	a.Write(ctx, websocket.MessageBinary, []byte("still here"))
	if kind, _, payload := next(); kind != wire.RelayData || string(payload) != "still here" {
		t.Fatalf("the host lost its other client: frame %d %q", kind, payload)
	}
}

func TestOneAddressCannotTakeTheHostsWholeBudget(t *testing.T) {
	url := start(t, Options{MaxSessionsPerHost: 10, MaxSessionsPerAddress: 2, TrustForwarded: true})
	key := newKey(t)
	host := dial(t, hostURL(url, key))
	register(t, host, key, nil)
	go func() {
		for {
			if _, _, err := host.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	connect := url + "/v1/connect/" + identity.HostID(key.Public().(ed25519.PublicKey))
	from := func(address string) *websocket.Conn {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		header := map[string][]string{"X-Forwarded-For": {address}}
		ws, _, err := websocket.Dial(ctx, connect, &websocket.DialOptions{Subprotocols: []string{wire.Subprotocol}, HTTPHeader: header})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ws.CloseNow() })
		return ws
	}

	from("203.0.113.9")
	from("203.0.113.9")
	if code := closeCode(t, from("203.0.113.9")); code != wire.CloseTooManySessions {
		t.Fatalf("a third connection from one address closed with %d, want %d", code, wire.CloseTooManySessions)
	}

	// Another address still gets in. So does another address in the same
	// IPv6 /64 as nobody else.
	other := from("198.51.100.4")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, _, err := other.Read(ctx); websocket.CloseStatus(err) == wire.CloseTooManySessions {
		t.Fatal("a second address was shut out by the first")
	}

	// An IPv6 subscriber is one address, whatever the low bits say.
	from("2001:db8:1:2::1")
	from("2001:db8:1:2:ffff::2")
	if code := closeCode(t, from("2001:db8:1:2:aaaa::3")); code != wire.CloseTooManySessions {
		t.Fatalf("three addresses in one /64 were counted apart, closed with %d", code)
	}
}
