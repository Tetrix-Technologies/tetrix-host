// Package stats counts what a host serves. The counts live in memory and
// start at zero each time the host starts. A record holds sizes and times.
// It never holds a prompt or an answer.
package stats

import (
	"sort"
	"sync"
	"time"
)

// Record is one finished request.
type Record struct {
	ID         string    `json:"id"`
	At         time.Time `json:"at"`
	DeviceID   string    `json:"deviceId,omitempty"`
	Source     string    `json:"source"` // tunnel or local
	Role       string    `json:"role,omitempty"`
	Model      string    `json:"model,omitempty"`
	Status     int       `json:"status"`
	DurationMs int64     `json:"durationMs"`
	TokensIn   int       `json:"tokensIn"`
	TokensOut  int       `json:"tokensOut"`
	Stream     bool      `json:"stream"`
}

// Running is one request in progress. A watcher uses it to show which
// device and which role are busy right now.
type Running struct {
	ID       string    `json:"id"`
	At       time.Time `json:"at"`
	DeviceID string    `json:"deviceId,omitempty"`
	Source   string    `json:"source"`
	Role     string    `json:"role,omitempty"`
	Model    string    `json:"model,omitempty"`
}

// Totals is a running sum.
type Totals struct {
	Requests  int64 `json:"requests"`
	TokensIn  int64 `json:"tokensIn"`
	TokensOut int64 `json:"tokensOut"`
}

// Snapshot is the stats block of the admin API.
type Snapshot struct {
	Totals
	Active          int       `json:"active"`
	Running         []Running `json:"running"`
	TokensPerSecond float64   `json:"tokensPerSecond"`
	Recent          []Record  `json:"recent"`
}

const keep = 40

// Stats is safe for concurrent use.
type Stats struct {
	mu        sync.Mutex
	total     Totals
	perDevice map[string]*Totals
	recent    []Record
	running   map[string]Running
	rate      float64
}

// New returns empty stats.
func New() *Stats {
	return &Stats{perDevice: map[string]*Totals{}, running: map[string]Running{}}
}

// Begin marks a request as running. End it with a record of the same ID.
func (s *Stats) Begin(r Running) {
	s.mu.Lock()
	s.running[r.ID] = r
	s.mu.Unlock()
}

// End records a finished request. generation is the time from the first
// byte of the answer to the last, which is what a token rate should use.
func (s *Stats) End(r Record, generation time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.running, r.ID)
	s.total.Requests++
	s.total.TokensIn += int64(r.TokensIn)
	s.total.TokensOut += int64(r.TokensOut)
	if r.DeviceID != "" {
		t := s.perDevice[r.DeviceID]
		if t == nil {
			t = &Totals{}
			s.perDevice[r.DeviceID] = t
		}
		t.Requests++
		t.TokensIn += int64(r.TokensIn)
		t.TokensOut += int64(r.TokensOut)
	}
	if r.TokensOut > 1 && generation > 50*time.Millisecond {
		s.rate = float64(r.TokensOut) / generation.Seconds()
	}
	s.recent = append(s.recent, r)
	if len(s.recent) > keep {
		s.recent = s.recent[len(s.recent)-keep:]
	}
}

// Snapshot returns the totals and the newest records first.
func (s *Stats) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	recent := make([]Record, len(s.recent))
	for i, r := range s.recent {
		recent[len(s.recent)-1-i] = r
	}
	running := make([]Running, 0, len(s.running))
	for _, r := range s.running {
		running = append(running, r)
	}
	sort.Slice(running, func(i, j int) bool {
		if !running[i].At.Equal(running[j].At) {
			return running[i].At.Before(running[j].At)
		}
		return running[i].ID < running[j].ID
	})
	return Snapshot{Totals: s.total, Active: len(running), Running: running, TokensPerSecond: s.rate, Recent: recent}
}

// Device returns one device's totals.
func (s *Stats) Device(id string) Totals {
	s.mu.Lock()
	defer s.mu.Unlock()
	if t := s.perDevice[id]; t != nil {
		return *t
	}
	return Totals{}
}
