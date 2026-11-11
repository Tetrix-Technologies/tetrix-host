package pairing

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
)

const hostID = "aoccscb7qz37b47z"

func TestCodeRoundTrip(t *testing.T) {
	secret := bytes.Repeat([]byte{0xC3}, SecretSize)
	code, err := Code(hostID, secret)
	if err != nil {
		t.Fatal(err)
	}
	if len(code) != 44+10 || strings.Count(code, "-") != 10 {
		t.Fatalf("a code should be 44 characters in 11 groups, got %q", code)
	}

	for name, text := range map[string]string{
		"code":             code,
		"lower case":       strings.ToLower(code),
		"spaces":           " " + strings.ReplaceAll(code, "-", " ") + "\n",
		"link":             Link(code, brand.DefaultRelay),
		"link, own relay":  Link(code, "wss://relay.example.com"),
		"link, local test": Link(code, "ws://127.0.0.1:8787"),
	} {
		offer, err := Parse(text)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if offer.HostID != hostID || !bytes.Equal(offer.Secret, secret) {
			t.Errorf("%s: parsed the wrong host or secret", name)
		}
	}

	// The default relay is left out of a link, and a bare code means it.
	if link := Link(code, brand.DefaultRelay); strings.Contains(link, "relay=") {
		t.Errorf("the default relay should not appear in %q", link)
	}
	if offer, _ := Parse(Link(code, "wss://relay.example.com")); offer.Relay != "wss://relay.example.com" {
		t.Errorf("the relay did not survive the link, got %q", offer.Relay)
	}
	if offer, _ := Parse(code); offer.Relay != brand.DefaultRelay {
		t.Errorf("a bare code should mean the default relay, got %q", offer.Relay)
	}
}

func TestParseRefusesNonsense(t *testing.T) {
	for _, text := range []string{"", "hello", "AAAA-BBBB", "https://example.com/x", brand.Scheme + "://pair/AAAA"} {
		if _, err := Parse(text); err == nil {
			t.Errorf("%q parsed as a pairing code", text)
		}
	}
}

func TestTicketWorksOnce(t *testing.T) {
	m := NewManager(time.Minute)
	ticket, err := m.Create()
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := m.Lookup(HintFor(ticket.Secret)); !ok || got != ticket {
		t.Fatal("an open ticket was not found by its hint")
	}
	if !m.Claim(ticket) {
		t.Fatal("the first claim failed")
	}
	if m.Claim(ticket) {
		t.Fatal("a ticket was claimed twice")
	}
	if _, ok := m.Lookup(HintFor(ticket.Secret)); ok {
		t.Fatal("a spent ticket is still open")
	}
}

func TestTicketExpires(t *testing.T) {
	m := NewManager(10 * time.Minute)
	now := time.Now()
	m.now = func() time.Time { return now }
	ticket, _ := m.Create()

	now = now.Add(9*time.Minute + 59*time.Second)
	if _, ok := m.Lookup(HintFor(ticket.Secret)); !ok {
		t.Fatal("a ticket expired early")
	}
	now = now.Add(time.Second)
	if _, ok := m.Lookup(HintFor(ticket.Secret)); ok {
		t.Fatal("a ticket outlived its ten minutes")
	}
	if m.Active() != nil {
		t.Fatal("an expired ticket is still reported as active")
	}
}

func TestTicketIsVoidAfterFiveFailures(t *testing.T) {
	m := NewManager(time.Minute)
	ticket, _ := m.Create()
	for i := 0; i < MaxFailures-1; i++ {
		m.Fail(ticket)
	}
	if _, ok := m.Lookup(HintFor(ticket.Secret)); !ok {
		t.Fatal("a ticket was voided before its last allowed failure")
	}
	m.Fail(ticket)
	if _, ok := m.Lookup(HintFor(ticket.Secret)); ok {
		t.Fatal("a ticket survived five failures")
	}
	if m.Claim(ticket) {
		t.Fatal("a voided ticket was claimed")
	}
}

func TestNewTicketVoidsTheOld(t *testing.T) {
	m := NewManager(time.Minute)
	first, _ := m.Create()
	second, _ := m.Create()
	if _, ok := m.Lookup(HintFor(first.Secret)); ok {
		t.Fatal("the first ticket is still open after a second was made")
	}
	if got := m.Active(); got != second {
		t.Fatal("the second ticket is not the active one")
	}
	m.Cancel()
	if m.Active() != nil {
		t.Fatal("a cancelled ticket is still active")
	}
}

func TestSecretsDiffer(t *testing.T) {
	m := NewManager(time.Minute)
	a, _ := m.Create()
	b, _ := m.Create()
	if bytes.Equal(a.Secret, b.Secret) {
		t.Fatal("two tickets share a secret")
	}
	// The pre-shared key and the hint come from one secret and must not be
	// the same bytes, or the hint would leak part of the key.
	hint := HintFor(a.Secret)
	if bytes.HasPrefix(PSK(a.Secret), hint[:]) {
		t.Fatal("the hint is a prefix of the pre-shared key")
	}
}
