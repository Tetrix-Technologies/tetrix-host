package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/events"
	"github.com/Tetrix-Technologies/tetrix-host/internal/host"
)

// admin calls the running host's admin API.
type admin struct {
	base  string
	token string
	http  *http.Client
}

var errNotRunning = errors.New("the host is not running. Start it with \"" + brand.CLI + " serve\", or in the background with \"" + brand.CLI + " service install\"")

// connect finds the running host from daemon.json.
func connect() (*admin, error) {
	p, err := paths()
	if err != nil {
		return nil, err
	}
	d, err := config.ReadDaemon(p.Daemon())
	if err != nil {
		return nil, errNotRunning
	}
	raw, err := os.ReadFile(p.AdminToken())
	if err != nil {
		return nil, fmt.Errorf("cannot read the admin token: %w", err)
	}
	token := strings.TrimSpace(string(raw))
	switch proves(d.Address, token) {
	case proofNone:
		return nil, errNotRunning
	case proofWrong:
		return nil, fmt.Errorf("something is listening at %s, but it is not this host, so the admin token was not sent. If the host is not running, delete %s", d.Address, p.Daemon())
	}
	return &admin{base: "http://" + d.Address, token: token, http: &http.Client{}}, nil
}

const (
	proofNone = iota
	proofWrong
	proofGood
)

// proves asks whatever listens at address to show that it holds the admin
// token. daemon.json can outlive the host that wrote it, and the port it
// names could then belong to another program. Nothing gets the token until
// it passes this check.
func proves(address, token string) int {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return proofNone
	}
	req, err := http.NewRequest("GET", "http://"+address+"/healthz", nil)
	if err != nil {
		return proofNone
	}
	req.Header.Set(host.ChallengeHeader, base64.StdEncoding.EncodeToString(nonce))
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return proofNone
	}
	defer resp.Body.Close()
	var answer struct {
		Proof string `json:"proof"`
	}
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&answer) != nil {
		return proofWrong
	}
	if !hmac.Equal([]byte(answer.Proof), []byte(host.LocalProof(token, nonce))) {
		return proofWrong
	}
	return proofGood
}

type apiError struct {
	Error struct {
		Message string `json:"message"`
		Code    string `json:"code"`
	} `json:"error"`
}

func (a *admin) request(ctx context.Context, method, path string, in any) (*http.Response, error) {
	var body io.Reader
	if in != nil {
		data, err := json.Marshal(in)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(data)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.base+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.token)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return nil, errNotRunning
	}
	if resp.StatusCode >= 300 {
		defer resp.Body.Close()
		var e apiError
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		if json.Unmarshal(data, &e) == nil && e.Error.Message != "" {
			return nil, errors.New(e.Error.Message)
		}
		return nil, fmt.Errorf("the host answered %d", resp.StatusCode)
	}
	return resp, nil
}

// call sends a request and decodes the JSON answer into out, if out is set.
func (a *admin) call(ctx context.Context, method, path string, in, out any) error {
	resp, err := a.request(ctx, method, path, in)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// watch calls fn for each event until fn returns false or ctx ends.
func (a *admin) watch(ctx context.Context, fn func(events.Event, json.RawMessage) bool) error {
	resp, err := a.request(ctx, "GET", "/admin/v1/events", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	for scanner.Scan() {
		data, ok := strings.CutPrefix(scanner.Text(), "data: ")
		if !ok {
			continue
		}
		var raw struct {
			events.Event
			Data json.RawMessage `json:"data"`
		}
		if json.Unmarshal([]byte(data), &raw) != nil {
			continue
		}
		if !fn(raw.Event, raw.Data) {
			return nil
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return scanner.Err()
}
