// Package identity holds a host's two long-term keys. The Ed25519 key signs
// the relay's challenge, and the host ID is a hash of its public half. The
// X25519 key is the host's Noise static key, which a client pins when it
// pairs.
package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/flynn/noise"

	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// HostIDBytes is the length of a host ID before encoding.
const HostIDBytes = 10

var idEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// Identity is a host's key material.
type Identity struct {
	Signing ed25519.PrivateKey
	Static  noise.DHKey
}

type stored struct {
	Version       int    `json:"version"`
	SigningSeed   string `json:"signingSeed"`
	StaticPrivate string `json:"staticPrivate"`
}

// Generate makes a new identity.
func Generate() (*Identity, error) {
	_, signing, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	static, err := noise.DH25519.GenerateKeypair(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Identity{Signing: signing, Static: static}, nil
}

// LoadOrCreate reads the identity at path. If the file does not exist,
// LoadOrCreate makes an identity and writes it with mode 0600.
func LoadOrCreate(path string) (*Identity, bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		id, err := Generate()
		if err != nil {
			return nil, false, err
		}
		if err := id.Save(path); err != nil {
			return nil, false, err
		}
		return id, true, nil
	}
	if err != nil {
		return nil, false, err
	}
	var s stored
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, false, fmt.Errorf("identity: %s is not valid: %w", path, err)
	}
	seed, err := base64.StdEncoding.DecodeString(s.SigningSeed)
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, false, fmt.Errorf("identity: %s has a bad signing key", path)
	}
	priv, err := base64.StdEncoding.DecodeString(s.StaticPrivate)
	if err != nil || len(priv) != 32 {
		return nil, false, fmt.Errorf("identity: %s has a bad static key", path)
	}
	static, err := StaticFromPrivate(priv)
	if err != nil {
		return nil, false, err
	}
	return &Identity{Signing: ed25519.NewKeyFromSeed(seed), Static: static}, false, nil
}

// Save writes the identity to path with mode 0600.
func (id *Identity) Save(path string) error {
	data, err := json.MarshalIndent(stored{
		Version:       1,
		SigningSeed:   base64.StdEncoding.EncodeToString(id.Signing.Seed()),
		StaticPrivate: base64.StdEncoding.EncodeToString(id.Static.Private),
	}, "", "\t")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// SigningPublic is the public half of the signing key.
func (id *Identity) SigningPublic() ed25519.PublicKey {
	return id.Signing.Public().(ed25519.PublicKey)
}

// HostID is the host's routing name on a relay.
func (id *Identity) HostID() string { return HostID(id.SigningPublic()) }

// HostID derives a host ID from a signing public key: the first 10 bytes of
// SHA-256 over a context string and the key, in lower-case base32.
func HostID(pub ed25519.PublicKey) string {
	return EncodeHostID(HostIDRaw(pub))
}

// HostIDRaw is the host ID before encoding.
func HostIDRaw(pub ed25519.PublicKey) []byte {
	h := sha256.New()
	h.Write([]byte(wire.HostIDContext))
	h.Write(pub)
	return h.Sum(nil)[:HostIDBytes]
}

// EncodeHostID turns 10 raw bytes into the 16-character form.
func EncodeHostID(raw []byte) string {
	return strings.ToLower(idEncoding.EncodeToString(raw))
}

// DecodeHostID is the inverse of EncodeHostID.
func DecodeHostID(s string) ([]byte, error) {
	raw, err := idEncoding.DecodeString(strings.ToUpper(s))
	if err != nil || len(raw) != HostIDBytes {
		return nil, errors.New("identity: not a host ID")
	}
	return raw, nil
}

// ValidHostID reports whether s has the form of a host ID.
func ValidHostID(s string) bool {
	if len(s) != 16 || s != strings.ToLower(s) {
		return false
	}
	_, err := DecodeHostID(s)
	return err == nil
}

// DeviceID derives a paired device's ID from its static public key.
func DeviceID(staticPublic []byte) string {
	h := sha256.New()
	h.Write([]byte(wire.DeviceIDContext))
	h.Write(staticPublic)
	return "d_" + strings.ToLower(idEncoding.EncodeToString(h.Sum(nil)[:8]))
}

// StaticFromPrivate rebuilds an X25519 key pair from its private half.
func StaticFromPrivate(priv []byte) (noise.DHKey, error) {
	if len(priv) != 32 {
		return noise.DHKey{}, errors.New("identity: a static key is 32 bytes")
	}
	// GenerateKeypair reads exactly 32 bytes and uses them as the private
	// key, so a reader over priv yields the matching pair.
	return noise.DH25519.GenerateKeypair(&fixedReader{b: priv})
}

type fixedReader struct{ b []byte }

func (r *fixedReader) Read(p []byte) (int, error) {
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}
