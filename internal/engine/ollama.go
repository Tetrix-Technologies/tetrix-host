package engine

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"

	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

// ollama fronts an Ollama server. Ollama downloads models, loads them on
// demand, and unloads them when idle, so the host leaves all of that to it.
type ollama struct {
	cfg    config.EngineConfig
	client *http.Client

	mu sync.Mutex
	// shown caches /api/show answers by model digest. A digest names one
	// exact model file, so its details never change.
	shown map[string]shown
	// variants holds the names of window variants known to exist.
	variants map[string]bool
}

// A window variant is a model that differs from its base only in the size
// of its context window. Its name is the base's name and this suffix, such
// as "qwen3:8b-th32768". The host makes variants and hides them: a person
// sees and assigns the base model.
var variantSuffix = regexp.MustCompile(`-th(\d+)$`)

// baseOf returns the base model's name for a variant, and the name itself
// for anything else.
func baseOf(name string) string {
	return variantSuffix.ReplaceAllString(name, "")
}

func (o *ollama) WithWindow(ctx context.Context, name string, tokens int) (string, error) {
	variant := fmt.Sprintf("%s-th%d", name, tokens)
	o.mu.Lock()
	known := o.variants[variant]
	o.mu.Unlock()
	if known {
		return variant, nil
	}
	// Ask before making it. Another host on this machine, or an earlier run
	// of this one, may have made it already.
	if err := o.call(ctx, "POST", "/api/show", map[string]string{"model": variant}, nil); err != nil {
		create := map[string]any{
			"model":      variant,
			"from":       name,
			"parameters": map[string]any{"num_ctx": tokens},
			"stream":     false,
		}
		if err := o.call(ctx, "POST", "/api/create", create, nil); err != nil {
			return "", fmt.Errorf("could not give %s a window of %d tokens: %w", name, tokens, err)
		}
	}
	o.mu.Lock()
	o.variants[variant] = true
	o.mu.Unlock()
	return variant, nil
}

type shown struct {
	capabilities  []string
	contextLength int
}

func (o *ollama) Config() config.EngineConfig { return o.cfg }

func (o *ollama) Upstream(path string) string { return o.cfg.BaseURL + path }

func (o *ollama) Authorize(req *http.Request) {
	if o.cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+o.cfg.APIKey)
	}
}

func (o *ollama) call(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		data, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, o.cfg.BaseURL+path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	o.Authorize(req)
	resp, err := o.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return ollamaError(resp)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(out)
}

func ollamaError(resp *http.Response) error {
	var e struct {
		Error string `json:"error"`
	}
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if json.Unmarshal(data, &e) == nil && e.Error != "" {
		return errors.New(e.Error)
	}
	return fmt.Errorf("the engine answered %d", resp.StatusCode)
}

func (o *ollama) Probe(ctx context.Context) (string, error) {
	var v struct {
		Version string `json:"version"`
	}
	if err := o.call(ctx, "GET", "/api/version", nil, &v); err != nil {
		return "", err
	}
	return v.Version, nil
}

func (o *ollama) Models(ctx context.Context) ([]Model, error) {
	var tags struct {
		Models []struct {
			Name    string `json:"name"`
			Size    int64  `json:"size"`
			Digest  string `json:"digest"`
			Details struct {
				Family            string `json:"family"`
				ParameterSize     string `json:"parameter_size"`
				QuantizationLevel string `json:"quantization_level"`
			} `json:"details"`
		} `json:"models"`
	}
	if err := o.call(ctx, "GET", "/api/tags", nil, &tags); err != nil {
		return nil, err
	}
	var running struct {
		Models []struct {
			Name          string `json:"name"`
			ContextLength int    `json:"context_length"`
		} `json:"models"`
	}
	o.call(ctx, "GET", "/api/ps", nil, &running)
	// A base model counts as loaded when one of its window variants is,
	// and the window in use is that variant's.
	loaded := map[string]bool{}
	inUse := map[string]int{}
	for _, m := range running.Models {
		base := baseOf(m.Name)
		loaded[base] = true
		if m.ContextLength > inUse[base] {
			inUse[base] = m.ContextLength
		}
	}

	models := make([]Model, 0, len(tags.Models))
	for _, t := range tags.Models {
		if variantSuffix.MatchString(t.Name) {
			// A window variant is the host's own bookkeeping.
			o.mu.Lock()
			o.variants[t.Name] = true
			o.mu.Unlock()
			continue
		}
		m := Model{
			ID:           o.cfg.ID + "/" + t.Name,
			Engine:       o.cfg.ID,
			Name:         t.Name,
			SizeBytes:    t.Size,
			Family:       t.Details.Family,
			Parameters:   t.Details.ParameterSize,
			Quantization: t.Details.QuantizationLevel,
			Loaded:       loaded[t.Name],
			ContextInUse: inUse[t.Name],
		}
		detail := o.show(ctx, t.Name, t.Digest)
		m.Capabilities = detail.capabilities
		m.ContextLength = detail.contextLength
		models = append(models, m)
	}
	return models, nil
}

// show asks Ollama what a model can do. A failure leaves the fields empty.
func (o *ollama) show(ctx context.Context, name, digest string) shown {
	o.mu.Lock()
	cached, ok := o.shown[digest]
	o.mu.Unlock()
	if ok && digest != "" {
		return cached
	}
	var info struct {
		Capabilities []string       `json:"capabilities"`
		ModelInfo    map[string]any `json:"model_info"`
	}
	if err := o.call(ctx, "POST", "/api/show", map[string]string{"model": name}, &info); err != nil {
		return shown{}
	}
	// Not nil: Ollama answered, so an empty list means "none", not
	// "unknown".
	out := shown{capabilities: []string{}}
	for _, c := range info.Capabilities {
		// "completion" is true of every chat model, so it says nothing.
		if c != "completion" {
			out.capabilities = append(out.capabilities, c)
		}
	}
	for key, value := range info.ModelInfo {
		if strings.HasSuffix(key, ".context_length") {
			if n, ok := value.(float64); ok {
				out.contextLength = int(n)
			}
		}
	}
	if digest != "" {
		o.mu.Lock()
		o.shown[digest] = out
		o.mu.Unlock()
	}
	return out
}

func (o *ollama) Pull(ctx context.Context, name string, report func(Progress)) error {
	data, _ := json.Marshal(map[string]any{"model": name, "stream": true})
	req, err := http.NewRequestWithContext(ctx, "POST", o.cfg.BaseURL+"/api/pull", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	o.Authorize(req)
	resp, err := o.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return ollamaError(resp)
	}

	// Ollama reports each layer separately. Sum them so the caller sees one
	// figure for the whole model.
	type layer struct{ completed, total int64 }
	layers := map[string]layer{}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		var line struct {
			Status    string `json:"status"`
			Digest    string `json:"digest"`
			Total     int64  `json:"total"`
			Completed int64  `json:"completed"`
			Error     string `json:"error"`
		}
		if json.Unmarshal(scanner.Bytes(), &line) != nil {
			continue
		}
		if line.Error != "" {
			return errors.New(line.Error)
		}
		if line.Digest != "" {
			layers[line.Digest] = layer{line.Completed, line.Total}
		}
		p := Progress{Engine: o.cfg.ID, Name: name, Status: plainStatus(line.Status)}
		for _, l := range layers {
			p.Completed += l.completed
			p.Total += l.total
		}
		if line.Status == "success" {
			p.Done = true
			p.Completed = p.Total
		}
		report(p)
		if p.Done {
			return nil
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	return errors.New("the download ended before it finished")
}

// plainStatus turns Ollama's status lines into the three a person needs.
func plainStatus(s string) string {
	switch {
	case s == "success":
		return "Done"
	case strings.HasPrefix(s, "pulling manifest"):
		return "Starting"
	case strings.HasPrefix(s, "pulling"):
		return "Downloading"
	case strings.HasPrefix(s, "verifying"):
		return "Verifying"
	default:
		return "Finishing"
	}
}

func (o *ollama) Delete(ctx context.Context, name string) error {
	// The model's window variants go with it.
	var tags struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if o.call(ctx, "GET", "/api/tags", nil, &tags) == nil {
		for _, t := range tags.Models {
			if t.Name != name && baseOf(t.Name) == name {
				o.call(ctx, "DELETE", "/api/delete", map[string]string{"model": t.Name}, nil)
				o.mu.Lock()
				delete(o.variants, t.Name)
				o.mu.Unlock()
			}
		}
	}
	return o.call(ctx, "DELETE", "/api/delete", map[string]string{"model": name}, nil)
}
