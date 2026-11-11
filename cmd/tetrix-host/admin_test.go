package main

import (
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Tetrix-Technologies/tetrix-host/internal/host"
)

// The CLI must not hand the admin token to a program that merely listens
// where daemon.json says the host is.
func TestTokenGoesOnlyToTheRealHost(t *testing.T) {
	const token = "hadm_test"
	address := func(srv *httptest.Server) string { return strings.TrimPrefix(srv.URL, "http://") }

	real := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		nonce, _ := base64.StdEncoding.DecodeString(r.Header.Get(host.ChallengeHeader))
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "proof": host.LocalProof(token, nonce)})
	}))
	defer real.Close()
	if got := proves(address(real), token); got != proofGood {
		t.Fatalf("the real host was not recognised: %d", got)
	}

	sawToken := false
	standIns := map[string]http.HandlerFunc{
		"answers health with no proof": func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"ok":true}`))
		},
		"makes up a proof": func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"ok":true,"proof":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}`))
		},
		"holds another host's token": func(w http.ResponseWriter, r *http.Request) {
			nonce, _ := base64.StdEncoding.DecodeString(r.Header.Get(host.ChallengeHeader))
			json.NewEncoder(w).Encode(map[string]any{"ok": true, "proof": host.LocalProof("hadm_other", nonce)})
		},
		"is not a host at all": func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "<html>some other app</html>", http.StatusNotFound)
		},
	}
	for name, handler := range standIns {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.Contains(r.Header.Get("Authorization"), token) {
				sawToken = true
			}
			handler(w, r)
		}))
		if got := proves(address(srv), token); got != proofWrong {
			t.Errorf("a listener that %s got result %d, want proofWrong", name, got)
		}
		srv.Close()
	}
	if sawToken {
		t.Fatal("a stand-in listener was sent the token")
	}

	// Nothing listening at all is a host that is not running.
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	free := ln.Addr().String()
	ln.Close()
	if got := proves(free, token); got != proofNone {
		t.Fatalf("a closed port gave result %d, want proofNone", got)
	}
}
