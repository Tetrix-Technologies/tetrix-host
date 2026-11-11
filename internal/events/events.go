// Package events carries news from the host to whoever watches it: the app
// and `tetrix-host pair`, over the admin API's event stream.
package events

import (
	"sync"
	"time"
)

// Event is one piece of news.
type Event struct {
	Type string    `json:"type"`
	At   time.Time `json:"at"`
	Data any       `json:"data,omitempty"`
}

// Event types.
const (
	// Changed means the status snapshot is out of date. Fetch it again.
	Changed = "changed"
	// Load carries a hardware.Load sample.
	Load = "load"
	// Pull carries an engine.Progress.
	Pull = "pull"
	// Request carries a stats.Record for a finished request.
	Request = "request"
	// Paired carries the config.Device that just paired.
	Paired = "paired"
)

// Hub fans events out to subscribers. A subscriber that falls behind loses
// events instead of slowing the host.
type Hub struct {
	mu   sync.Mutex
	subs map[chan Event]struct{}
}

// NewHub returns an empty hub.
func NewHub() *Hub { return &Hub{subs: map[chan Event]struct{}{}} }

// Publish sends an event to every subscriber.
func (h *Hub) Publish(typ string, data any) {
	e := Event{Type: typ, At: time.Now().UTC(), Data: data}
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- e:
		default:
		}
	}
}

// Subscribe returns a channel of events and a function that ends the
// subscription.
func (h *Hub) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 64)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs, ch)
		h.mu.Unlock()
	}
}

// Watchers is the number of subscribers.
func (h *Hub) Watchers() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}
