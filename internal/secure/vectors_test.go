package secure

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"testing"

	"github.com/flynn/noise"

	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/pairing"
)

// The Swift package checks its own Noise code against this file. The Go
// test below checks that the file still matches what the Go code produces,
// so neither side can drift without a test failing.
//
// To regenerate the file after a deliberate protocol change, run:
//
//	go test ./internal/secure -run TestVectors -update
const vectorsPath = "../../Tests/TetrixHostKitTests/Fixtures/noise-vectors.json"

var update = flag.Bool("update", false, "rewrite the vectors file")

type message struct {
	// From is "initiator" or "responder".
	From       string `json:"from"`
	Payload    string `json:"payload"`
	Ciphertext string `json:"ciphertext"`
}

type vector struct {
	Name               string    `json:"name"`
	Protocol           string    `json:"protocol"`
	HostID             string    `json:"hostId"`
	Prologue           string    `json:"prologue"`
	PSK                string    `json:"psk,omitempty"`
	PairingSecret      string    `json:"pairingSecret,omitempty"`
	PairingHint        string    `json:"pairingHint,omitempty"`
	InitiatorStatic    string    `json:"initiatorStatic"`
	InitiatorEphemeral string    `json:"initiatorEphemeral"`
	ResponderStatic    string    `json:"responderStatic"`
	ResponderEphemeral string    `json:"responderEphemeral"`
	ResponderPublic    string    `json:"responderPublic"`
	Handshake          []message `json:"handshake"`
	HandshakeHash      string    `json:"handshakeHash"`
	Transport          []message `json:"transport"`
}

// key returns 32 bytes that differ per label, so every key in a vector is
// distinct and none is random.
func key(label byte) []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = label + byte(i)
	}
	return k
}

func build(t *testing.T) []vector {
	t.Helper()
	const hostID = "aaaabbbbccccdddd"
	initStatic, _ := identity.StaticFromPrivate(key(0x10))
	respStatic, _ := identity.StaticFromPrivate(key(0x40))
	secret := key(0x70)[:pairing.SecretSize]
	hint := pairing.HintFor(secret)

	run := func(name, protocol string, start func(initiator bool, random []byte) *noise.HandshakeState, payloads [][]byte) vector {
		initEph, respEph := key(0xA0), key(0xD0)
		init := start(true, initEph)
		resp := start(false, respEph)
		v := vector{
			Name: name, Protocol: protocol, HostID: hostID,
			InitiatorStatic:    hex.EncodeToString(initStatic.Private),
			InitiatorEphemeral: hex.EncodeToString(initEph),
			ResponderStatic:    hex.EncodeToString(respStatic.Private),
			ResponderEphemeral: hex.EncodeToString(respEph),
			ResponderPublic:    hex.EncodeToString(respStatic.Public),
		}
		var initSend, initRecv, respSend, respRecv *noise.CipherState
		for i, payload := range payloads {
			writer, reader, from := init, resp, "initiator"
			if i%2 == 1 {
				writer, reader, from = resp, init, "responder"
			}
			msg, w0, w1, err := writer.WriteMessage(nil, payload)
			if err != nil {
				t.Fatalf("%s: write %d: %v", name, i, err)
			}
			got, r0, r1, err := reader.ReadMessage(nil, msg)
			if err != nil {
				t.Fatalf("%s: read %d: %v", name, i, err)
			}
			if !bytes.Equal(got, payload) {
				t.Fatalf("%s: payload %d did not survive", name, i)
			}
			v.Handshake = append(v.Handshake, message{From: from, Payload: hex.EncodeToString(payload), Ciphertext: hex.EncodeToString(msg)})
			if w0 != nil {
				// Noise returns the initiator's sending state first.
				if from == "initiator" {
					initSend, initRecv, respRecv, respSend = w0, w1, r0, r1
				} else {
					respRecv, respSend, initSend, initRecv = w0, w1, r0, r1
				}
			}
		}
		if initSend == nil {
			t.Fatalf("%s: the handshake did not finish", name)
		}
		v.HandshakeHash = hex.EncodeToString(init.ChannelBinding())

		initiator := NewChannelForTest(initSend, initRecv)
		responder := NewChannelForTest(respSend, respRecv)
		for i, text := range []string{"first from the app", "first from the host", "second from the app", ""} {
			from, sender, receiver := "initiator", initiator, responder
			if i%2 == 1 {
				from, sender, receiver = "responder", responder, initiator
			}
			var sealed []byte
			sender.Seal([]byte(text), func(b []byte) error { sealed = b; return nil })
			if opened, err := receiver.Open(sealed); err != nil || string(opened) != text {
				t.Fatalf("%s: transport %d did not open", name, i)
			}
			v.Transport = append(v.Transport, message{From: from, Payload: hex.EncodeToString([]byte(text)), Ciphertext: hex.EncodeToString(sealed)})
		}
		return v
	}

	pair := run("pair", "Noise_XXpsk0_25519_ChaChaPoly_SHA256", func(initiator bool, random []byte) *noise.HandshakeState {
		static := respStatic
		if initiator {
			static = initStatic
		}
		hs, err := NewPair(Options{Static: static, HostID: hostID, Initiator: initiator, Random: bytes.NewReader(random)}, pairing.PSK(secret))
		if err != nil {
			t.Fatal(err)
		}
		return hs
	}, [][]byte{nil, []byte(`{"hostId":"aaaabbbbccccdddd","name":"Vector host","version":"1"}`), []byte(`{"name":"Vector device","app":"Cue"}`)})
	pair.Prologue = hex.EncodeToString([]byte("tetrix-host/pair/1\x00" + hostID))
	pair.PSK = hex.EncodeToString(pairing.PSK(secret))
	pair.PairingSecret = hex.EncodeToString(secret)
	pair.PairingHint = hex.EncodeToString(hint[:])

	session := run("session", "Noise_IK_25519_ChaChaPoly_SHA256", func(initiator bool, random []byte) *noise.HandshakeState {
		var hs *noise.HandshakeState
		var err error
		if initiator {
			hs, err = NewSession(Options{Static: initStatic, HostID: hostID, Initiator: true, Random: bytes.NewReader(random)}, respStatic.Public)
		} else {
			hs, err = NewSession(Options{Static: respStatic, HostID: hostID, Random: bytes.NewReader(random)}, nil)
		}
		if err != nil {
			t.Fatal(err)
		}
		return hs
	}, [][]byte{[]byte(`{"app":"Cue"}`), []byte(`{"hostId":"aaaabbbbccccdddd","name":"Vector host","version":"1"}`)})
	session.Prologue = hex.EncodeToString([]byte("tetrix-host/session/1\x00" + hostID))

	return []vector{pair, session}
}

func TestVectors(t *testing.T) {
	data, err := json.MarshalIndent(map[string]any{"vectors": build(t)}, "", "\t")
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, '\n')
	if *update {
		if err := os.WriteFile(vectorsPath, data, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatalf("%v. Run the test with -update to write the file", err)
	}
	if !bytes.Equal(want, data) {
		t.Fatal("the vectors file does not match the Go implementation. If the protocol changed on purpose, run the test with -update and run the Swift tests")
	}
}

// TestWrongKeysFail checks the properties the design rests on: a handshake
// with the wrong pairing key, or against the wrong host key, does not
// complete.
func TestWrongKeysFail(t *testing.T) {
	const hostID = "aaaabbbbccccdddd"
	client, _ := identity.StaticFromPrivate(key(1))
	host, _ := identity.StaticFromPrivate(key(2))
	other, _ := identity.StaticFromPrivate(key(3))

	init, _ := NewPair(Options{Static: client, HostID: hostID, Initiator: true}, pairing.PSK(key(4)[:16]))
	resp, _ := NewPair(Options{Static: host, HostID: hostID}, pairing.PSK(key(5)[:16]))
	m1, _, _, _ := init.WriteMessage(nil, nil)
	if _, _, _, err := resp.ReadMessage(nil, m1); err == nil {
		t.Fatal("a host accepted a pairing message made with another code")
	}

	init, _ = NewSession(Options{Static: client, HostID: hostID, Initiator: true}, other.Public)
	resp, _ = NewSession(Options{Static: host, HostID: hostID}, nil)
	m1, _, _, _ = init.WriteMessage(nil, nil)
	if _, _, _, err := resp.ReadMessage(nil, m1); err == nil {
		t.Fatal("a host accepted a session message sealed to another host's key")
	}

	// The host ID is bound into the handshake, so a message for one host
	// means nothing to another that somehow shares its key.
	init, _ = NewSession(Options{Static: client, HostID: hostID, Initiator: true}, host.Public)
	resp, _ = NewSession(Options{Static: host, HostID: "zzzzbbbbccccdddd"}, nil)
	m1, _, _, _ = init.WriteMessage(nil, nil)
	if _, _, _, err := resp.ReadMessage(nil, m1); err == nil {
		t.Fatal("a session message for one host ID opened under another")
	}
}

// TestTamperedMessageFails checks that a sealed message with one changed
// bit does not open, and that a message cannot be opened twice.
func TestTamperedMessageFails(t *testing.T) {
	const hostID = "aaaabbbbccccdddd"
	client, _ := identity.StaticFromPrivate(key(1))
	host, _ := identity.StaticFromPrivate(key(2))
	init, _ := NewSession(Options{Static: client, HostID: hostID, Initiator: true}, host.Public)
	resp, _ := NewSession(Options{Static: host, HostID: hostID}, nil)
	m1, _, _, _ := init.WriteMessage(nil, nil)
	if _, _, _, err := resp.ReadMessage(nil, m1); err != nil {
		t.Fatal(err)
	}
	m2, r0, r1, _ := resp.WriteMessage(nil, nil)
	_, i0, i1, err := init.ReadMessage(nil, m2)
	if err != nil {
		t.Fatal(err)
	}
	app := NewChannel(i0, i1, true)
	hostSide := NewChannel(r0, r1, false)

	var sealed []byte
	app.Seal([]byte("a prompt"), func(b []byte) error { sealed = b; return nil })
	changed := append([]byte(nil), sealed...)
	changed[0] ^= 0x01
	if _, err := hostSide.Open(changed); err == nil {
		t.Fatal("a changed message opened")
	}
	if got, err := hostSide.Open(sealed); err != nil || string(got) != "a prompt" {
		t.Fatalf("the true message did not open after a forged one was refused: %v", err)
	}
	if _, err := hostSide.Open(sealed); err == nil {
		t.Fatal("a replayed message opened")
	}
}
