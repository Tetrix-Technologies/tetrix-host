// Package engine talks to the model servers a host fronts. An engine is a
// program that already runs models and speaks the OpenAI HTTP dialect, such
// as Ollama, llama.cpp's llama-server, LM Studio, or vLLM. The host adds
// pairing, the tunnel, and roles on top. It does not run models itself.
package engine

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

// Model is one model an engine can serve.
type Model struct {
	// ID is the engine's ID, a slash, and the engine's own name for the model.
	ID           string `json:"id"`
	Engine       string `json:"engine"`
	Name         string `json:"name"`
	SizeBytes    int64  `json:"sizeBytes,omitempty"`
	Family       string `json:"family,omitempty"`
	Parameters   string `json:"parameters,omitempty"`
	Quantization string `json:"quantization,omitempty"`
	// ContextLength is the largest window the model supports.
	ContextLength int `json:"contextLength,omitempty"`
	// ContextInUse is the window the engine gave the model when it loaded
	// it. It can be far smaller than ContextLength, and an engine cuts a
	// longer request to fit without an error. Zero when not loaded or
	// not reported.
	ContextInUse int `json:"contextInUse,omitempty"`
	// Capabilities is what the model can do beyond chat. Nil means the
	// engine does not say. An empty list means it says there are none.
	Capabilities []string `json:"capabilities,omitempty"`
	// Loaded is true while the model sits in memory.
	Loaded bool `json:"loaded"`
}

// Progress reports a download.
type Progress struct {
	Engine    string `json:"engine"`
	Name      string `json:"name"`
	Status    string `json:"status"`
	Completed int64  `json:"completed"`
	Total     int64  `json:"total"`
	Done      bool   `json:"done"`
	Error     string `json:"error,omitempty"`
}

// ErrUnsupported means an engine cannot do what was asked.
var ErrUnsupported = errors.New("this engine does not support that")

// Engine is one model server.
type Engine interface {
	Config() config.EngineConfig
	// Probe returns the engine's version, or an error if it does not answer.
	Probe(ctx context.Context) (string, error)
	Models(ctx context.Context) ([]Model, error)
	// Pull downloads a model and calls report as the download advances.
	Pull(ctx context.Context, name string, report func(Progress)) error
	Delete(ctx context.Context, name string) error
	// Upstream returns the engine's URL for an OpenAI path such as
	// /v1/chat/completions.
	Upstream(path string) string
	// Authorize adds the engine's credentials to a request.
	Authorize(req *http.Request)
}

// Windowed is an engine that can run a model with a context window the
// host chooses. Without it, an engine uses its own default, which for
// Ollama is 4,096 tokens: far less than most models support, and an engine
// cuts a longer request to fit without an error.
type Windowed interface {
	// WithWindow returns the engine's name for the model running with a
	// window of this many tokens. The engine makes that variant if it does
	// not exist yet, which takes no extra disk space.
	WithWindow(ctx context.Context, name string, tokens int) (string, error)
}

// New builds an engine from its configuration.
func New(cfg config.EngineConfig, client *http.Client) (Engine, error) {
	cfg.BaseURL = strings.TrimSuffix(strings.TrimRight(cfg.BaseURL, "/"), "/v1")
	if cfg.ID == "" || strings.Contains(cfg.ID, "/") {
		return nil, errors.New("engine: an ID is required and cannot contain a slash")
	}
	if !strings.HasPrefix(cfg.BaseURL, "http://") && !strings.HasPrefix(cfg.BaseURL, "https://") {
		return nil, errors.New("engine: the address must start with http:// or https://")
	}
	switch cfg.Kind {
	case "ollama":
		return &ollama{cfg: cfg, client: client, shown: map[string]shown{}, variants: map[string]bool{}}, nil
	case "openai":
		return &openAI{cfg: cfg, client: client}, nil
	}
	return nil, errors.New("engine: kind must be ollama or openai")
}

// Status is an engine and what it holds, as last seen.
type Status struct {
	ID      string  `json:"id"`
	Kind    string  `json:"kind"`
	BaseURL string  `json:"baseURL"`
	State   string  `json:"state"` // ready or unreachable
	Version string  `json:"version,omitempty"`
	Error   string  `json:"error,omitempty"`
	Models  []Model `json:"models"`
}

// Registry holds a host's engines and a short-lived view of their models.
type Registry struct {
	client *http.Client

	mu        sync.Mutex
	engines   []Engine
	statuses  []Status
	checkedAt time.Time
	refresh   sync.Mutex
}

// NewRegistry returns a registry that calls engines with client.
func NewRegistry(client *http.Client) *Registry {
	return &Registry{client: client}
}

// Set replaces the engines. A bad entry is skipped and returned as an error.
func (r *Registry) Set(cfgs []config.EngineConfig) error {
	var engines []Engine
	var errs []error
	for _, cfg := range cfgs {
		e, err := New(cfg, r.client)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		engines = append(engines, e)
	}
	r.mu.Lock()
	r.engines = engines
	r.checkedAt = time.Time{}
	r.mu.Unlock()
	return errors.Join(errs...)
}

// Engine returns the engine with this ID.
func (r *Registry) Engine(id string) (Engine, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.engines {
		if e.Config().ID == id {
			return e, true
		}
	}
	return nil, false
}

// Invalidate makes the next Snapshot ask the engines again.
func (r *Registry) Invalidate() {
	r.mu.Lock()
	r.checkedAt = time.Time{}
	r.mu.Unlock()
}

// Snapshot returns every engine's status. It asks the engines again when
// the last answer is older than maxAge.
func (r *Registry) Snapshot(ctx context.Context, maxAge time.Duration) []Status {
	r.mu.Lock()
	fresh := !r.checkedAt.IsZero() && time.Since(r.checkedAt) < maxAge
	cached := r.statuses
	engines := append([]Engine(nil), r.engines...)
	r.mu.Unlock()
	if fresh {
		return cached
	}

	// One refresh at a time. A caller that waited takes the result.
	r.refresh.Lock()
	defer r.refresh.Unlock()
	r.mu.Lock()
	if !r.checkedAt.IsZero() && time.Since(r.checkedAt) < maxAge {
		cached = r.statuses
		r.mu.Unlock()
		return cached
	}
	r.mu.Unlock()

	// The answer is cached for every caller, so one caller's cancelled
	// request must not make it say that no engine answers.
	ctx = context.WithoutCancel(ctx)
	statuses := make([]Status, len(engines))
	var wg sync.WaitGroup
	for i, e := range engines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cfg := e.Config()
			st := Status{ID: cfg.ID, Kind: cfg.Kind, BaseURL: cfg.BaseURL, Models: []Model{}}
			pctx, cancel := context.WithTimeout(ctx, 4*time.Second)
			defer cancel()
			version, err := e.Probe(pctx)
			if err != nil {
				st.State = "unreachable"
				st.Error = "Not answering at " + cfg.BaseURL
				statuses[i] = st
				return
			}
			st.State = "ready"
			st.Version = version
			models, err := e.Models(pctx)
			if err != nil {
				st.Error = err.Error()
			}
			sort.Slice(models, func(a, b int) bool { return models[a].Name < models[b].Name })
			if models != nil {
				st.Models = models
			}
			statuses[i] = st
		}()
	}
	wg.Wait()

	r.mu.Lock()
	r.statuses = statuses
	r.checkedAt = time.Now()
	r.mu.Unlock()
	return statuses
}

// Find returns the engine and model for a model ID.
func (r *Registry) Find(ctx context.Context, modelID string) (Engine, Model, bool) {
	engineID, _, ok := strings.Cut(modelID, "/")
	if !ok {
		return nil, Model{}, false
	}
	e, ok := r.Engine(engineID)
	if !ok {
		return nil, Model{}, false
	}
	for _, st := range r.Snapshot(ctx, 15*time.Second) {
		if st.ID != engineID {
			continue
		}
		for _, m := range st.Models {
			if m.ID == modelID {
				return e, m, true
			}
		}
	}
	return nil, Model{}, false
}

// All returns every model on every engine that answers.
func (r *Registry) All(ctx context.Context) []Model {
	var out []Model
	for _, st := range r.Snapshot(ctx, 15*time.Second) {
		out = append(out, st.Models...)
	}
	return out
}
