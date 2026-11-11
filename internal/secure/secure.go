// Package secure builds the two Noise handshakes and the sealed channel
// that follows them. It adds no cryptography of its own. The Noise
// implementation is github.com/flynn/noise.
//
// A pairing uses Noise_XXpsk0_25519_ChaChaPoly_SHA256. The pre-shared key is
// the one-time secret in the pairing code, so neither side accepts the other
// without it. Both sides learn the other's static key.
//
// A session uses Noise_IK_25519_ChaChaPoly_SHA256. The client already holds
// the host's static key from the pairing. The host accepts the client only
// if the client's static key belongs to a paired device.
package secure

import (
	"crypto/rand"
	"errors"
	"io"
	"sync"

	"github.com/flynn/noise"

	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// Suite is the one cipher suite this protocol uses.
var Suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)

// PSKSize is the length of a pairing secret once it is stretched to the
// 32 bytes Noise requires.
const PSKSize = 32

// Options carries the choices both handshakes share.
type Options struct {
	Static    noise.DHKey
	HostID    string
	Initiator bool
	// Random overrides the source of ephemeral keys. Tests set it.
	Random io.Reader
}

func (o Options) random() io.Reader {
	if o.Random != nil {
		return o.Random
	}
	return rand.Reader
}

// NewPair starts a pairing handshake. psk is 32 bytes.
func NewPair(o Options, psk []byte) (*noise.HandshakeState, error) {
	if len(psk) != PSKSize {
		return nil, errors.New("secure: a pairing key is 32 bytes")
	}
	return noise.NewHandshakeState(noise.Config{
		CipherSuite:           Suite,
		Random:                o.random(),
		Pattern:               noise.HandshakeXX,
		Initiator:             o.Initiator,
		Prologue:              []byte(wire.PairPrologue + o.HostID),
		PresharedKey:          psk,
		PresharedKeyPlacement: 0,
		StaticKeypair:         o.Static,
	})
}

// NewSession starts a session handshake. An initiator passes the host's
// static public key. A responder passes nil.
func NewSession(o Options, hostStatic []byte) (*noise.HandshakeState, error) {
	if o.Initiator && len(hostStatic) != 32 {
		return nil, errors.New("secure: a client needs the host's static key")
	}
	cfg := noise.Config{
		CipherSuite:   Suite,
		Random:        o.random(),
		Pattern:       noise.HandshakeIK,
		Initiator:     o.Initiator,
		Prologue:      []byte(wire.SessionPrologue + o.HostID),
		StaticKeypair: o.Static,
	}
	if o.Initiator {
		cfg.PeerStatic = hostStatic
	}
	return noise.NewHandshakeState(cfg)
}

// Channel seals and opens messages after a handshake. Seal is safe to call
// from many goroutines. Open is for one reader.
type Channel struct {
	sendMu sync.Mutex
	send   *noise.CipherState
	recv   *noise.CipherState
}

// NewChannel orders the two cipher states a finished handshake returns.
// Noise gives the initiator's sending state first.
func NewChannel(first, second *noise.CipherState, initiator bool) *Channel {
	if initiator {
		return &Channel{send: first, recv: second}
	}
	return &Channel{send: second, recv: first}
}

// Seal encrypts one message and passes it to write while it holds the send
// lock, so messages reach the socket in nonce order.
func (c *Channel) Seal(plaintext []byte, write func([]byte) error) error {
	if len(plaintext) > wire.MaxNoiseMessage-wire.TagSize {
		return errors.New("secure: message too large")
	}
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	sealed, err := c.send.Encrypt(make([]byte, 0, len(plaintext)+wire.TagSize), nil, plaintext)
	if err != nil {
		return err
	}
	return write(sealed)
}

// Open decrypts one message.
func (c *Channel) Open(sealed []byte) ([]byte, error) {
	if len(sealed) > wire.MaxNoiseMessage {
		return nil, errors.New("secure: message too large")
	}
	return c.recv.Decrypt(make([]byte, 0, len(sealed)), nil, sealed)
}

// NewChannelForTest builds a channel from a send state and a receive state.
// Only tests need it. Production code gets its channel from NewChannel.
func NewChannelForTest(send, recv *noise.CipherState) *Channel {
	return &Channel{send: send, recv: recv}
}
