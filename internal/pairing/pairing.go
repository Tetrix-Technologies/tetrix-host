// Package pairing makes and checks pairing tickets. A ticket is a one-time
// secret the host shows as a code, a link, and a QR image. A client that
// holds the secret can complete the pairing handshake. Nothing else can,
// including the relay, which never sees the code.
package pairing

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

const (
	// SecretSize is the length of a ticket's secret.
	SecretSize = 16
	// DefaultTTL is how long a ticket stays valid.
	DefaultTTL = 10 * time.Minute
	// MaxFailures is how many bad attempts a ticket survives.
	MaxFailures = 5
	codeVersion = 1
	codeSize    = 1 + identity.HostIDBytes + SecretSize
)

var codeEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// Hint identifies a ticket to the host without revealing its secret.
type Hint [wire.HintSize]byte

// HintFor derives the hint a client sends ahead of the handshake.
func HintFor(secret []byte) Hint {
	h := sha256.New()
	h.Write([]byte(wire.PairHintContext))
	h.Write(secret)
	var out Hint
	copy(out[:], h.Sum(nil))
	return out
}

// PSK stretches a ticket's secret to the 32 bytes Noise requires. The
// secret is random, so one hash with a context string is enough.
func PSK(secret []byte) []byte {
	h := sha256.New()
	h.Write([]byte("tetrix-host/pair-psk/1\x00"))
	h.Write(secret)
	return h.Sum(nil)
}

// Ticket is one outstanding offer to pair.
type Ticket struct {
	ID        string
	Secret    []byte
	CreatedAt time.Time
	ExpiresAt time.Time
	failures  int
}

// Code is the ticket as text: a version byte, the host ID, and the secret,
// in base32, in groups of four.
func Code(hostID string, secret []byte) (string, error) {
	raw, err := identity.DecodeHostID(hostID)
	if err != nil {
		return "", err
	}
	if len(secret) != SecretSize {
		return "", errors.New("pairing: bad secret length")
	}
	buf := make([]byte, 0, codeSize)
	buf = append(buf, codeVersion)
	buf = append(buf, raw...)
	buf = append(buf, secret...)
	return group(codeEncoding.EncodeToString(buf)), nil
}

func group(s string) string {
	var b strings.Builder
	for i, r := range s {
		if i > 0 && i%4 == 0 {
			b.WriteByte('-')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// Link wraps a code in a URL an app can open. The relay is included only
// when it is not the default, which keeps the common link short.
func Link(code, relay string) string {
	u := brand.Scheme + "://pair/" + code
	if relay != "" && relay != brand.DefaultRelay {
		u += "?relay=" + url.QueryEscape(relay)
	}
	return u
}

// Offer is what a client learns from a code or a link.
type Offer struct {
	HostID string
	Secret []byte
	Relay  string
}

// Parse reads a code or a link.
func Parse(s string) (*Offer, error) {
	s = strings.TrimSpace(s)
	relay := brand.DefaultRelay
	if i := strings.Index(s, "://"); i >= 0 {
		u, err := url.Parse(s)
		if err != nil || u.Host != "pair" {
			return nil, errors.New("pairing: not a pairing link")
		}
		if r := u.Query().Get("relay"); r != "" {
			relay = r
		}
		s = strings.TrimPrefix(u.Path, "/")
	}
	s = strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(s))
	raw, err := codeEncoding.DecodeString(s)
	if err != nil || len(raw) != codeSize || raw[0] != codeVersion {
		return nil, errors.New("pairing: not a pairing code")
	}
	return &Offer{
		HostID: identity.EncodeHostID(raw[1 : 1+identity.HostIDBytes]),
		Secret: raw[1+identity.HostIDBytes:],
		Relay:  relay,
	}, nil
}

// Manager holds the tickets a host has open. A host has at most one at a
// time, because a second code on screen only confuses the person pairing.
type Manager struct {
	mu      sync.Mutex
	tickets map[Hint]*Ticket
	ttl     time.Duration
	now     func() time.Time
}

// NewManager returns a manager whose tickets live for ttl.
func NewManager(ttl time.Duration) *Manager {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	return &Manager{tickets: map[Hint]*Ticket{}, ttl: ttl, now: time.Now}
}

// Create voids any open ticket and returns a new one.
func (m *Manager) Create() (*Ticket, error) {
	secret := make([]byte, SecretSize)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	hint := HintFor(secret)
	now := m.now()
	t := &Ticket{
		ID:        hex.EncodeToString(hint[:]),
		Secret:    secret,
		CreatedAt: now,
		ExpiresAt: now.Add(m.ttl),
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.tickets = map[Hint]*Ticket{hint: t}
	return t, nil
}

// Lookup returns the open ticket with this hint.
func (m *Manager) Lookup(hint Hint) (*Ticket, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tickets[hint]
	if !ok {
		return nil, false
	}
	if !m.now().Before(t.ExpiresAt) {
		delete(m.tickets, hint)
		return nil, false
	}
	return t, true
}

// Fail records a bad attempt. After MaxFailures the ticket is void.
func (m *Manager) Fail(t *Ticket) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t.failures++
	if t.failures >= MaxFailures {
		delete(m.tickets, HintFor(t.Secret))
	}
}

// Claim spends a ticket. It reports false if the ticket is already gone.
func (m *Manager) Claim(t *Ticket) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	hint := HintFor(t.Secret)
	if _, ok := m.tickets[hint]; !ok {
		return false
	}
	delete(m.tickets, hint)
	return true
}

// Cancel voids every open ticket.
func (m *Manager) Cancel() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.tickets = map[Hint]*Ticket{}
}

// Active returns the open ticket, if there is one.
func (m *Manager) Active() *Ticket {
	m.mu.Lock()
	defer m.mu.Unlock()
	for hint, t := range m.tickets {
		if !m.now().Before(t.ExpiresAt) {
			delete(m.tickets, hint)
			continue
		}
		return t
	}
	return nil
}
