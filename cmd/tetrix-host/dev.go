package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"
)

// cmdDev holds tools for people who work on the host itself. The usage text
// does not list them.
func cmdDev(args []string) error {
	if len(args) == 0 || args[0] != "fake-engine" {
		return errors.New("usage: dev fake-engine [--listen ADDRESS]")
	}
	fs := flag.NewFlagSet("dev fake-engine", flag.ContinueOnError)
	listen := fs.String("listen", "127.0.0.1:0", "address to listen on")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	fmt.Printf("fake engine listening on http://%s with models big and small\n", ln.Addr())
	return http.Serve(ln, fakeEngine())
}

// fakeEngine speaks enough of the OpenAI dialect to stand in for a model
// server. Tests and demos use it on machines with no model installed. Its
// answer names the model that served it, which makes role routing visible.
func fakeEngine() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"list","data":[{"id":"big","object":"model"},{"id":"small","object":"model"}]}`)
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, `{"error":{"message":"bad request"}}`, http.StatusBadRequest)
			return
		}
		words := strings.Fields("This is the " + body.Model + " model on a fake engine. It answers every prompt with these words so that a test can check streaming without a real model.")
		if !body.Stream {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{
				"model": body.Model,
				"choices": []any{map[string]any{
					"index": 0, "finish_reason": "stop",
					"message": map[string]string{"role": "assistant", "content": strings.Join(words, " ")},
				}},
				"usage": map[string]int{"prompt_tokens": 8, "completion_tokens": len(words)},
			})
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		send := func(v any) {
			data, _ := json.Marshal(v)
			fmt.Fprintf(w, "data: %s\n\n", data)
			if flusher != nil {
				flusher.Flush()
			}
		}
		for i, word := range words {
			if i > 0 {
				word = " " + word
			}
			send(map[string]any{"model": body.Model, "choices": []any{map[string]any{"index": 0, "delta": map[string]string{"content": word}}}})
			select {
			case <-r.Context().Done():
				return
			case <-time.After(8 * time.Millisecond):
			}
		}
		send(map[string]any{"model": body.Model, "choices": []any{map[string]any{"index": 0, "delta": map[string]string{}, "finish_reason": "stop"}}})
		send(map[string]any{"model": body.Model, "choices": []any{}, "usage": map[string]int{"prompt_tokens": 8, "completion_tokens": len(words)}})
		fmt.Fprint(w, "data: [DONE]\n\n")
	})
	return mux
}
