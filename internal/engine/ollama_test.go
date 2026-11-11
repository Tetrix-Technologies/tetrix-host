package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"
	"testing"

	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

// A stand-in for Ollama's own API, with the shapes Ollama 0.40 returns.
func fakeOllama(t *testing.T) *httptest.Server {
	return fakeOllamaCounting(t, nil)
}

// fakeOllamaCounting also keeps window variants the way Ollama does: a
// variant exists once it has been created, and creates is told of each one.
func fakeOllamaCounting(t *testing.T, creates *[]string) *httptest.Server {
	var mu sync.Mutex
	made := map[string]bool{}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/create", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model      string         `json:"model"`
			From       string         `json:"from"`
			Parameters map[string]any `json:"parameters"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		made[body.Model] = true
		if creates != nil {
			*creates = append(*creates, fmt.Sprintf("%s from %s with %v", body.Model, body.From, body.Parameters["num_ctx"]))
		}
		mu.Unlock()
		fmt.Fprint(w, `{"status":"success"}`)
	})
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"version":"0.40.13"}`) })
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"models":[
			{"name":"qwen3:8b","size":5200000000,"digest":"aaa","details":{"family":"qwen3","parameter_size":"8.2B","quantization_level":"Q4_K_M"}},
			{"name":"plain:1b","size":800000000,"digest":"bbb","details":{"family":"plain"}},
			{"name":"broken:1b","size":1,"digest":"ccc","details":{}}
		]}`)
	})
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"models":[{"name":"qwen3:8b","context_length":4096}]}`)
	})
	mux.HandleFunc("POST /api/show", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		variant := made[body.Model]
		mu.Unlock()
		switch {
		case variant:
			fmt.Fprint(w, `{"capabilities":["completion"]}`)
			return
		}
		switch body.Model {
		case "qwen3:8b":
			fmt.Fprint(w, `{"capabilities":["completion","tools","thinking"],"model_info":{"qwen3.context_length":40960}}`)
		case "plain:1b":
			fmt.Fprint(w, `{"capabilities":["completion"],"model_info":{"plain.context_length":8192}}`)
		default:
			http.Error(w, `{"error":"no such model"}`, http.StatusNotFound)
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestOllamaModels(t *testing.T) {
	srv := fakeOllama(t)
	e, err := New(config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: srv.URL + "/v1/"}, http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	if got := e.Upstream("/v1/chat/completions"); got != srv.URL+"/v1/chat/completions" {
		t.Fatalf("a base URL that ends in /v1 was not trimmed: %s", got)
	}
	models, err := e.Models(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Model{}
	for _, m := range models {
		by[m.Name] = m
	}

	big := by["qwen3:8b"]
	if big.ID != "ollama/qwen3:8b" || big.ContextLength != 40960 || !big.Loaded {
		t.Fatalf("unexpected model: %+v", big)
	}
	// The window in use is what limits a request, and here it is a tenth
	// of what the model supports.
	if big.ContextInUse != 4096 {
		t.Fatalf("the window in use is %d, want 4096", big.ContextInUse)
	}
	if !slices.Equal(big.Capabilities, []string{"tools", "thinking"}) {
		t.Fatalf("unexpected capabilities: %v", big.Capabilities)
	}

	// Known to have none is an empty list. Not known is nil.
	if plain := by["plain:1b"]; plain.Capabilities == nil || len(plain.Capabilities) != 0 || plain.Loaded || plain.ContextInUse != 0 {
		t.Fatalf("a model with no extra abilities should have an empty list: %+v", plain)
	}
	if broken := by["broken:1b"]; broken.Capabilities != nil {
		t.Fatalf("a model the engine cannot describe should have nil capabilities: %+v", broken)
	}
}

func TestWindowVariantIsMadeOnce(t *testing.T) {
	var creates []string
	srv := fakeOllamaCounting(t, &creates)
	e, _ := New(config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: srv.URL}, http.DefaultClient)
	windowed, ok := e.(Windowed)
	if !ok {
		t.Fatal("the Ollama engine should be able to set a window")
	}
	for i := 0; i < 3; i++ {
		name, err := windowed.WithWindow(context.Background(), "qwen3:8b", 32768)
		if err != nil || name != "qwen3:8b-th32768" {
			t.Fatalf("got %q, %v", name, err)
		}
	}
	if len(creates) != 1 || creates[0] != "qwen3:8b-th32768 from qwen3:8b with 32768" {
		t.Fatalf("want one create, got %v", creates)
	}
	// Another window is another variant.
	if name, _ := windowed.WithWindow(context.Background(), "qwen3:8b", 8192); name != "qwen3:8b-th8192" {
		t.Fatalf("got %q", name)
	}
	if len(creates) != 2 {
		t.Fatalf("want two creates, got %v", creates)
	}

	// A second engine object, such as the host after a restart, finds the
	// variant in place and does not make it again.
	again, _ := New(config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: srv.URL}, http.DefaultClient)
	if _, err := again.(Windowed).WithWindow(context.Background(), "qwen3:8b", 32768); err != nil {
		t.Fatal(err)
	}
	if len(creates) != 2 {
		t.Fatalf("an existing variant was made again: %v", creates)
	}

	// The kind of engine that manages its own models cannot set a window.
	other, _ := New(config.EngineConfig{ID: "x", Kind: "openai", BaseURL: srv.URL}, http.DefaultClient)
	if _, ok := other.(Windowed); ok {
		t.Fatal("an OpenAI-style engine claims it can set a window")
	}
}

func TestWindowVariantsAreHidden(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"models":[
			{"name":"qwen3:8b","size":5,"digest":"aaa","details":{}},
			{"name":"qwen3:8b-th32768","size":5,"digest":"abc","details":{}},
			{"name":"qwen3:8b-th8192","size":5,"digest":"abd","details":{}}
		]}`)
	})
	// The variant is what is loaded. The person sees the base model as
	// loaded, with the variant's window.
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"models":[{"name":"qwen3:8b-th32768","context_length":32768}]}`)
	})
	mux.HandleFunc("POST /api/show", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"capabilities":["completion","tools"],"model_info":{"qwen3.context_length":40960}}`)
	})
	var deleted []string
	mux.HandleFunc("DELETE /api/delete", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		deleted = append(deleted, body.Model)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e, _ := New(config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: srv.URL}, http.DefaultClient)
	models, err := e.Models(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 1 || models[0].Name != "qwen3:8b" {
		t.Fatalf("variants should not be listed: %+v", models)
	}
	if !models[0].Loaded || models[0].ContextInUse != 32768 {
		t.Fatalf("the base model should show its loaded variant's window: %+v", models[0])
	}

	// Deleting the model deletes its variants too.
	if err := e.Delete(context.Background(), "qwen3:8b"); err != nil {
		t.Fatal(err)
	}
	slices.Sort(deleted)
	if !slices.Equal(deleted, []string{"qwen3:8b", "qwen3:8b-th32768", "qwen3:8b-th8192"}) {
		t.Fatalf("deleted %v", deleted)
	}
}
