package host

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/client"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/relay"
	"github.com/Tetrix-Technologies/tetrix-host/internal/stats"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// fakeEngine speaks enough of the OpenAI dialect to stand in for a model
// server. It records the model each request named.
type fakeEngine struct {
	*httptest.Server
	mu   sync.Mutex
	seen []string
}

func newFakeEngine(t *testing.T) *fakeEngine {
	f := &fakeEngine{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":[{"id":"big"},{"id":"small"},{"id":"dies"}]}`)
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model  string `json:"model"`
			Stream bool   `json:"stream"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.seen = append(f.seen, body.Model)
		f.mu.Unlock()
		if body.Model == "dies" {
			// Send part of an answer, then drop the connection, as an
			// engine does when it crashes or runs out of memory.
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Content-Length", "500")
			w.Write([]byte(`{"choices":[{"message":{"content":"half an ans`))
			w.(http.Flusher).Flush()
			conn, _, _ := w.(http.Hijacker).Hijack()
			conn.Close()
			return
		}
		if !body.Stream {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"model":%q,"choices":[{"message":{"role":"assistant","content":"hello"}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}`, body.Model)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, word := range []string{"one", "two", "three"} {
			fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q}}]}\n\n", word)
			w.(http.Flusher).Flush()
		}
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3}}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	})
	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func (f *fakeEngine) last() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.seen) == 0 {
		return ""
	}
	return f.seen[len(f.seen)-1]
}

type rig struct {
	t      *testing.T
	host   *Host
	engine *fakeEngine
	relay  string
	base   string
}

func newRig(t *testing.T, roles config.Roles) *rig {
	t.Helper()
	relaySrv := httptest.NewServer(relay.New(relay.Options{}).Handler())
	t.Cleanup(relaySrv.Close)
	eng := newFakeEngine(t)

	dir := t.TempDir()
	paths := config.Paths{Dir: dir}
	cfg := config.Config{
		Name:    "Test host",
		Listen:  "127.0.0.1:0",
		Tunnel:  config.TunnelConfig{Enabled: true, Relay: "ws" + strings.TrimPrefix(relaySrv.URL, "http")},
		Engines: []config.EngineConfig{{ID: "fake", Kind: "openai", BaseURL: eng.URL}},
		Roles:   roles,
	}
	data, _ := json.Marshal(cfg)
	if err := os.WriteFile(paths.Config(), data, 0o600); err != nil {
		t.Fatal(err)
	}
	h, err := Open(paths, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := h.Run(ctx); err != nil {
			t.Errorf("run: %v", err)
		}
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	r := &rig{t: t, host: h, engine: eng, relay: cfg.Tunnel.Relay}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if h.Address() != "" {
			r.base = "http://" + h.Address()
			if st := r.status(); st.Tunnel.State == "connected" {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("the host did not come up")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return r
}

func (r *rig) do(method, path, token string, body any) *http.Response {
	r.t.Helper()
	var reader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		reader = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, r.base+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	return resp
}

func (r *rig) status() Status {
	resp := r.do("GET", "/admin/v1/status", r.host.adminToken, nil)
	defer resp.Body.Close()
	var st Status
	json.NewDecoder(resp.Body).Decode(&st)
	return st
}

// pair makes a code through the admin API and spends it through the relay.
func (r *rig) pair(name string) (*client.Pairing, *client.Session) {
	r.t.Helper()
	resp := r.do("POST", "/admin/v1/pairing", r.host.adminToken, nil)
	var offer PairingStatus
	json.NewDecoder(resp.Body).Decode(&offer)
	resp.Body.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := client.Pair(ctx, offer.Link, wire.ClientHello{Name: name, App: "Cue", Platform: "macOS"})
	if err != nil {
		r.t.Fatalf("pair: %v", err)
	}
	s, err := client.Connect(ctx, p, wire.ClientHello{App: "Cue"})
	if err != nil {
		r.t.Fatalf("connect: %v", err)
	}
	r.t.Cleanup(s.Close)
	return p, s
}

func chat(t *testing.T, s *client.Session, model string, stream bool) (int, string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"model": model, "stream": stream,
		"messages": []map[string]string{{"role": "user", "content": "hi"}},
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	resp, err := s.Do(ctx, "POST", "/v1/chat/completions", map[string]string{"content-type": "application/json"}, body)
	if err != nil {
		t.Fatalf("chat: %v", err)
	}
	out, _ := io.ReadAll(resp.Body)
	return resp.Status, string(out)
}

func TestRolesRouteToModels(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big", Quick: "fake/small"})
	_, s := r.pair("Laptop")

	for model, want := range map[string]string{
		"deep":         "big",
		"quick":        "small",
		"tetrix/quick": "small",
		"":             "big",
		"fake/small":   "small",
	} {
		status, body := chat(t, s, model, false)
		if status != 200 {
			t.Fatalf("model %q: status %d: %s", model, status, body)
		}
		if got := r.engine.last(); got != want {
			t.Errorf("model %q reached %q, want %q", model, got, want)
		}
	}
	if status, _ := chat(t, s, "fake/missing", false); status != 404 {
		t.Errorf("an unknown model answered %d, want 404", status)
	}
}

func TestOneModelServesBothRoles(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	_, s := r.pair("Laptop")
	if status, body := chat(t, s, "quick", false); status != 200 {
		t.Fatalf("status %d: %s", status, body)
	}
	if got := r.engine.last(); got != "big" {
		t.Fatalf("quick work reached %q, want the deep model", got)
	}
	if !r.status().Roles.Single {
		t.Fatal("status should report one model for everything")
	}
}

func TestStreamThroughTunnelIsCounted(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big", Quick: "fake/small"})
	p, s := r.pair("Laptop")

	status, body := chat(t, s, "deep", true)
	if status != 200 {
		t.Fatalf("status %d: %s", status, body)
	}
	var words []string
	sc := bufio.NewScanner(strings.NewReader(body))
	for sc.Scan() {
		data, ok := strings.CutPrefix(sc.Text(), "data: ")
		if !ok || data == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		json.Unmarshal([]byte(data), &chunk)
		if len(chunk.Choices) > 0 {
			words = append(words, chunk.Choices[0].Delta.Content)
		}
	}
	if strings.Join(words, " ") != "one two three" {
		t.Fatalf("stream arrived as %q", words)
	}
	if !strings.HasSuffix(strings.TrimSpace(body), "data: [DONE]") {
		t.Fatal("the stream did not end with [DONE]")
	}

	st := r.status()
	if st.Stats.Requests != 1 || st.Stats.TokensIn != 11 || st.Stats.TokensOut != 3 {
		t.Fatalf("unexpected totals: %+v", st.Stats.Totals)
	}
	if len(st.Devices) != 1 || st.Devices[0].ID != p.DeviceID || !st.Devices[0].Online || st.Devices[0].Requests != 1 {
		t.Fatalf("unexpected device: %+v", st.Devices)
	}
	rec := st.Stats.Recent[0]
	if rec.DeviceID != p.DeviceID || rec.Role != "deep" || rec.Model != "fake/big" || rec.Source != "tunnel" {
		t.Fatalf("unexpected record: %+v", rec)
	}
}

func TestLocalKeys(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	check := func(method, path, token string, want int) {
		t.Helper()
		resp := r.do(method, path, token, nil)
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Errorf("%s %s answered %d, want %d", method, path, resp.StatusCode, want)
		}
	}
	check("GET", "/v1/models", "", 401)
	check("GET", "/admin/v1/status", "", 401)
	check("GET", "/v1/models", "wrong", 401)
	// The API key opens the model routes and nothing else.
	check("GET", "/v1/models", r.host.apiKey, 200)
	check("GET", "/admin/v1/status", r.host.apiKey, 401)
	check("POST", "/admin/v1/pairing", r.host.apiKey, 401)
	check("GET", "/v1/models", r.host.adminToken, 200)
	check("GET", "/admin/v1/status", r.host.adminToken, 200)
}

func TestDeviceCannotReachAdmin(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	_, s := r.pair("Laptop")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, path := range []string{"/admin/v1/status", "/admin/v1/pairing", "/healthz"} {
		resp, err := s.Do(ctx, "GET", path, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.Status != 404 {
			t.Errorf("a device reached %s with status %d, want 404", path, resp.Status)
		}
	}
}

func TestUnpairEndsTheSession(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	p, s := r.pair("Laptop")
	if status, _ := chat(t, s, "deep", false); status != 200 {
		t.Fatalf("status %d before unpairing", status)
	}
	resp := r.do("DELETE", "/admin/v1/devices/"+p.DeviceID, r.host.adminToken, nil)
	resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("unpair answered %d", resp.StatusCode)
	}

	// The open session dies, and the key cannot open another.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, err := s.Do(ctx, "GET", "/v1/host", nil, nil); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the session stayed open after the device was unpaired")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := client.Connect(ctx, p, wire.ClientHello{}); err == nil {
		t.Fatal("an unpaired device opened a new session")
	}
	if n := len(r.status().Devices); n != 0 {
		t.Fatalf("%d devices remain", n)
	}
}

func TestHostInfo(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big", Quick: "fake/small"})
	_, s := r.pair("Laptop")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := s.Do(ctx, "GET", "/v1/host", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	var info struct {
		Name   string              `json:"name"`
		Single bool                `json:"single"`
		Roles  map[string]RoleInfo `json:"roles"`
	}
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info.Name != "Test host" || info.Single {
		t.Fatalf("unexpected info: %+v", info)
	}
	if info.Roles["deep"].Model != "fake/big" || info.Roles["quick"].Model != "fake/small" || !info.Roles["deep"].Available {
		t.Fatalf("unexpected roles: %+v", info.Roles)
	}
}

// do sends a raw body through the tunnel and returns the status and body.
func tunnelPost(t *testing.T, s *client.Session, path string, body []byte) (int, string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	resp, err := s.Do(ctx, "POST", path, map[string]string{"content-type": "application/json"}, body)
	if err != nil {
		return 0, "", err
	}
	out, err := io.ReadAll(resp.Body)
	return resp.Status, string(out), err
}

func TestOddBodiesAreRefusedNotFatal(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	_, s := r.pair("Laptop")
	// Each of these is valid JSON that is not an object. "null" once
	// crashed the host, because it decodes into a nil map without an error.
	for _, body := range []string{"null", "[]", `"text"`, "42", "", "{"} {
		status, _, err := tunnelPost(t, s, "/v1/chat/completions", []byte(body))
		if err != nil || status != 400 {
			t.Errorf("body %q answered %d, %v; want 400", body, status, err)
		}
	}
	if status, _ := chat(t, s, "deep", false); status != 200 {
		t.Fatalf("the host stopped serving after odd bodies: %d", status)
	}
}

func TestEngineThatDiesMidAnswer(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	_, s := r.pair("Laptop")
	body, _ := json.Marshal(map[string]any{"model": "fake/dies", "messages": []any{}})
	status, got, err := tunnelPost(t, s, "/v1/chat/completions", body)
	if err == nil {
		t.Fatalf("half an answer arrived as a whole one: status %d, %q", status, got)
	}
	if !strings.Contains(err.Error(), "upstream_failed") {
		t.Fatalf("want an upstream_failed reset, got %v", err)
	}
	// The failure is recorded as one, and the host carries on.
	if rec := r.status().Stats.Recent[0]; rec.Status != 502 {
		t.Fatalf("the failed request was recorded with status %d", rec.Status)
	}
	if status, _ := chat(t, s, "deep", false); status != 200 {
		t.Fatalf("the host stopped serving after an engine failure: %d", status)
	}

	// Over loopback the same failure drops the connection.
	req, _ := http.NewRequest("POST", r.base+"/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+r.host.apiKey)
	resp, err := http.DefaultClient.Do(req)
	if err == nil {
		_, err = io.ReadAll(resp.Body)
		resp.Body.Close()
	}
	if err == nil {
		t.Fatal("a local client read half an answer with no error")
	}
}

func TestCancelledRequestDoesNotHideTheEngines(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	// Make the next lookup ask the engines again, with a context that is
	// already cancelled, as a request that was reset in flight has.
	r.host.engines.Invalidate()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, ok := r.host.engines.Find(ctx, "fake/big"); !ok {
		t.Fatal("a cancelled caller made the model look missing")
	}
	// The next caller sees the engine too.
	if st := r.status(); len(st.Engines) != 1 || st.Engines[0].State != "ready" {
		t.Fatalf("the engine looks down after a cancelled lookup: %+v", st.Engines)
	}
}

func TestHealthProvesTheToken(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	ask := func(nonce string) map[string]any {
		req, _ := http.NewRequest("GET", r.base+"/healthz", nil)
		if nonce != "" {
			req.Header.Set(ChallengeHeader, nonce)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	nonce := bytes.Repeat([]byte{0x5A}, 32)
	got := ask(base64.StdEncoding.EncodeToString(nonce))
	if got["proof"] != LocalProof(r.host.adminToken, nonce) {
		t.Fatalf("the proof does not match: %v", got["proof"])
	}
	if got["proof"] == LocalProof("some other token", nonce) {
		t.Fatal("the proof does not depend on the token")
	}
	// No challenge, or one too short to be a nonce, gets no proof.
	for _, bad := range []string{"", "AAAA", "not base64!"} {
		if _, has := ask(bad)["proof"]; has {
			t.Errorf("a proof was given for the challenge %q", bad)
		}
	}
}

// fakeOllama serves the parts of Ollama's API that downloads use. A pull
// stalls until its request is cancelled.
func fakeOllama(t *testing.T, cancelled chan<- struct{}) *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"version":"0.0.0"}`) })
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"models":[]}`) })
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"models":[]}`) })
	mux.HandleFunc("POST /api/pull", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, `{"status":"pulling manifest"}`)
		fmt.Fprintln(w, `{"status":"pulling abc","digest":"abc","total":1000,"completed":250}`)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		cancelled <- struct{}{}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestPullCancelFindsTheDefaultEngine(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	cancelled := make(chan struct{}, 1)
	ollama := fakeOllama(t, cancelled)
	resp := r.do("POST", "/admin/v1/engines", r.host.adminToken, config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: ollama.URL})
	resp.Body.Close()

	// Neither call names an engine, which is what the CLI sends.
	resp = r.do("POST", "/admin/v1/models/pull", r.host.adminToken, map[string]string{"name": "some-model"})
	resp.Body.Close()
	if resp.StatusCode != 202 {
		t.Fatalf("pull answered %d", resp.StatusCode)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		if st := r.status(); len(st.Pulls) == 1 && st.Pulls[0].Total == 1000 {
			if st.Pulls[0].Engine != "ollama" || st.Pulls[0].Completed != 250 {
				t.Fatalf("unexpected progress: %+v", st.Pulls[0])
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the download never showed progress: %+v", r.status().Pulls)
		}
		time.Sleep(20 * time.Millisecond)
	}

	resp = r.do("DELETE", "/admin/v1/models/pull?name=some-model", r.host.adminToken, nil)
	resp.Body.Close()
	if resp.StatusCode != 204 {
		t.Fatalf("cancel answered %d, want 204", resp.StatusCode)
	}
	select {
	case <-cancelled:
	case <-time.After(3 * time.Second):
		t.Fatal("the cancel did not reach the engine")
	}
	for len(r.status().Pulls) != 0 {
		if time.Now().After(deadline.Add(3 * time.Second)) {
			t.Fatal("the download is still listed after it was cancelled")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestRunningRequestsAreListed(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	p, _ := r.pair("Laptop")
	if got := r.status().Stats; got.Active != 0 || len(got.Running) != 0 {
		t.Fatalf("an idle host reports work: %+v", got)
	}
	r.host.stats.Begin(stats.Running{ID: "x1", At: time.Now(), DeviceID: p.DeviceID, Source: "tunnel", Role: "deep", Model: "fake/big"})
	got := r.status().Stats
	if got.Active != 1 || len(got.Running) != 1 || got.Running[0].DeviceID != p.DeviceID || got.Running[0].Role != "deep" {
		t.Fatalf("unexpected running list: %+v", got.Running)
	}
	r.host.stats.End(stats.Record{ID: "x1", DeviceID: p.DeviceID}, 0)
	if got := r.status().Stats; got.Active != 0 || len(got.Running) != 0 {
		t.Fatalf("a finished request is still listed: %+v", got.Running)
	}
}

func TestRenameAnswersByCause(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	p, _ := r.pair("Laptop")
	for _, tc := range []struct {
		id, name string
		want     int
	}{
		{p.DeviceID, "  ", 400},
		{"d_nobody", "Desk", 404},
		{p.DeviceID, "Desk", 204},
	} {
		resp := r.do("PATCH", "/admin/v1/devices/"+tc.id, r.host.adminToken, map[string]string{"name": tc.name})
		resp.Body.Close()
		if resp.StatusCode != tc.want {
			t.Errorf("rename %q to %q answered %d, want %d", tc.id, tc.name, resp.StatusCode, tc.want)
		}
	}
	if got := r.status().Devices[0].Name; got != "Desk" {
		t.Fatalf("the device is called %q", got)
	}
}

func TestDeviceCanUnpairItself(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	p, s := r.pair("Laptop")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := s.Do(ctx, "DELETE", "/v1/device", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.Status != 204 {
		t.Fatalf("unpair answered %d", resp.Status)
	}
	if n := len(r.status().Devices); n != 0 {
		t.Fatalf("%d devices remain after a device unpaired itself", n)
	}
	// The key no longer opens a session, and the host says so itself.
	deadline := time.Now().Add(3 * time.Second)
	for {
		_, err := client.Connect(ctx, p, wire.ClientHello{})
		if errors.Is(err, client.ErrDeviceNotPaired) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("want ErrDeviceNotPaired, got %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// A local program is not a device and has nothing to unpair.
	local := r.do("DELETE", "/v1/device", r.host.apiKey, nil)
	local.Body.Close()
	if local.StatusCode != 400 {
		t.Fatalf("a local unpair answered %d, want 400", local.StatusCode)
	}
}

func TestHostInfoSaysWhenCapabilitiesAreUnknown(t *testing.T) {
	// The fake engine is of the kind that does not report capabilities.
	r := newRig(t, config.Roles{Deep: "fake/big"})
	_, s := r.pair("Laptop")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := s.Do(ctx, "GET", "/v1/host", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	var info struct {
		Roles map[string]struct {
			Capabilities *[]string `json:"capabilities"`
		} `json:"roles"`
	}
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info.Roles["deep"].Capabilities != nil {
		t.Fatalf("capabilities should be null when the engine does not report them, got %v", *info.Roles["deep"].Capabilities)
	}
	// With nothing known, a tool request goes to the engine to decide.
	body, _ := json.Marshal(map[string]any{"model": "deep", "messages": []any{}, "tools": []any{map[string]any{"type": "function"}}})
	if status, got, err := tunnelPost(t, s, "/v1/chat/completions", body); err != nil || status != 200 {
		t.Fatalf("a tool request to a model of unknown ability answered %d %q %v", status, got, err)
	}
}

// windowOllama is a stand-in for Ollama with two models. It records the
// model each chat request named, which shows the window the host chose.
func windowOllama(t *testing.T) (*httptest.Server, func() string) {
	var mu sync.Mutex
	var asked []string
	made := map[string]bool{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"version":"0.40.13"}`) })
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, `{"models":[]}`) })
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"models":[
			{"name":"large:8b","size":5000,"digest":"l","details":{}},
			{"name":"little:1b","size":800,"digest":"s","details":{}}
		]}`)
	})
	mux.HandleFunc("POST /api/show", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		exists := made[body.Model]
		mu.Unlock()
		switch {
		case body.Model == "large:8b":
			fmt.Fprint(w, `{"capabilities":["completion","tools"],"model_info":{"x.context_length":131072}}`)
		case body.Model == "little:1b":
			// A model whose own limit is below the default deep window.
			fmt.Fprint(w, `{"capabilities":["completion"],"model_info":{"x.context_length":4096}}`)
		case exists:
			fmt.Fprint(w, `{}`)
		default:
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		}
	})
	mux.HandleFunc("POST /api/create", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		made[body.Model] = true
		mu.Unlock()
		fmt.Fprint(w, `{"status":"success"}`)
	})
	mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Model string `json:"model"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		asked = append(asked, body.Model)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, func() string {
		mu.Lock()
		defer mu.Unlock()
		if len(asked) == 0 {
			return ""
		}
		return asked[len(asked)-1]
	}
}

func TestHostSetsTheWindow(t *testing.T) {
	r := newRig(t, config.Roles{Deep: "fake/big"})
	ollama, last := windowOllama(t)
	add := r.do("POST", "/admin/v1/engines", r.host.adminToken, config.EngineConfig{ID: "ollama", Kind: "ollama", BaseURL: ollama.URL})
	add.Body.Close()
	set := func(body any) {
		t.Helper()
		resp := r.do("PUT", "/admin/v1/"+map[bool]string{true: "roles", false: "settings"}[strings.Contains(fmt.Sprint(body), "ollama/")], r.host.adminToken, body)
		resp.Body.Close()
		if resp.StatusCode != 204 {
			t.Fatalf("setting %v answered %d", body, resp.StatusCode)
		}
	}
	ask := func(model string) string {
		t.Helper()
		resp := r.do("POST", "/v1/chat/completions", r.host.apiKey, map[string]any{"model": model, "messages": []any{}})
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("model %q answered %d", model, resp.StatusCode)
		}
		return last()
	}

	// Two models: each role gets its own default window.
	set(map[string]string{"deep": "ollama/large:8b", "quick": "ollama/little:1b"})
	if got := ask("deep"); got != "large:8b-th32768" {
		t.Errorf("deep work asked the engine for %q", got)
	}
	// The quick model supports 4,096 tokens, less than the quick default.
	// The host never asks for more than a model has.
	if got := ask("quick"); got != "little:1b-th4096" {
		t.Errorf("quick work asked the engine for %q", got)
	}

	// The app is told the window a request gets, before the model loads.
	resp := r.do("GET", "/v1/host", r.host.apiKey, nil)
	var info struct {
		Roles map[string]RoleInfo `json:"roles"`
	}
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info.Roles["deep"].ContextInUse != 32768 || info.Roles["deep"].ContextLength != 131072 || info.Roles["quick"].ContextInUse != 4096 {
		t.Errorf("unexpected windows: %+v", info.Roles)
	}

	// One model for everything runs with one window, so it loads once.
	set(map[string]string{"deep": "ollama/large:8b", "quick": ""})
	if got := ask("quick"); got != "large:8b-th32768" {
		t.Errorf("with one model, quick work asked the engine for %q", got)
	}

	// The owner can change the window, or leave it to the engine.
	set(map[string]any{"window": map[string]int{"deep": 65536}})
	if got := ask("deep"); got != "large:8b-th65536" {
		t.Errorf("after raising the window, deep work asked for %q", got)
	}
	if st := r.status(); st.Roles.Window.Deep != 65536 || st.Roles.Window.Quick != config.DefaultQuickWindow {
		t.Errorf("status reports the windows as %+v", st.Roles.Window)
	}
	set(map[string]any{"window": map[string]int{"deep": -1}})
	if got := ask("deep"); got != "large:8b" {
		t.Errorf("with the window left to the engine, deep work asked for %q", got)
	}
	bad := r.do("PUT", "/admin/v1/settings", r.host.adminToken, map[string]any{"window": map[string]int{"deep": 100}})
	bad.Body.Close()
	if bad.StatusCode != 400 {
		t.Errorf("a window of 100 tokens answered %d, want 400", bad.StatusCode)
	}

	// An engine that manages its own models is asked for the model as it is.
	set(map[string]any{"window": map[string]int{"deep": 0}})
	resp = r.do("POST", "/v1/chat/completions", r.host.apiKey, map[string]any{"model": "fake/big", "messages": []any{}})
	resp.Body.Close()
	if got := r.engine.last(); got != "big" {
		t.Errorf("the OpenAI-style engine was asked for %q", got)
	}
}
