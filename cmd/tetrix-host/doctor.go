package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/client"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/engine"
	"github.com/Tetrix-Technologies/tetrix-host/internal/host"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// cmdDoctor checks each part in the order a request passes through it, and
// stops explaining at the first part that is broken.
func cmdDoctor(args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	problems := 0
	ok := func(format string, v ...any) { fmt.Printf("  ok    "+format+"\n", v...) }
	bad := func(format string, v ...any) {
		problems++
		fmt.Printf("  FAIL  "+format+"\n", v...)
	}
	note := func(format string, v ...any) { fmt.Printf("  note  "+format+"\n", v...) }

	a, st, err := status(ctx)
	if err != nil {
		bad("%s", err)
		return fmt.Errorf("1 problem found")
	}
	ok("The host is running at %s.", st.Host.Address)

	models := map[string]engine.Model{}
	for _, e := range st.Engines {
		if e.State != "ready" {
			bad("The %s engine is not answering at %s. Start it, or remove it with \"%s engines rm %s\".", e.ID, e.BaseURL, brand.CLI, e.ID)
			continue
		}
		ok("The %s engine answers and has %d models.", e.ID, len(e.Models))
		for _, m := range e.Models {
			models[m.ID] = m
		}
	}
	if len(st.Engines) == 0 {
		bad("No engine is configured. Install Ollama, or add a server with \"%s engines add\".", brand.CLI)
	}

	checkRole := func(role, id string) {
		if id == "" {
			bad("No model is assigned to %s work. Download one with \"%s models pull <name>\".", role, brand.CLI)
			return
		}
		m, found := models[id]
		if !found {
			bad("The model for %s work, %s, is not installed.", role, id)
			return
		}
		ok("%s work uses %s.", strings.ToUpper(role[:1])+role[1:], id)
		if m.Engine != "" && len(m.Capabilities) > 0 && !slices.Contains(m.Capabilities, "tools") {
			note("%s cannot call tools. An app that acts on your behalf needs a model that can.", id)
		}
	}
	checkRole(config.RoleDeep, st.Roles.Deep)
	if !st.Roles.Single {
		checkRole(config.RoleQuick, st.Roles.Quick)
	}

	if st.Roles.Deep != "" && models[st.Roles.Deep].ID != "" {
		started := time.Now()
		resp, err := a.request(ctx, "POST", "/v1/chat/completions", map[string]any{
			"model":      config.RoleQuick,
			"messages":   []chatMessage{{Role: "user", Content: "Reply with the single word: ready"}},
			"max_tokens": 16,
		})
		if err != nil {
			bad("A test request failed: %s", err)
		} else {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			ok("A model answered a test request in %s.", time.Since(started).Round(10*time.Millisecond))
		}
		// The test loaded a model, so the engine now reports the window it
		// runs that model with.
		if _, after, err := status(ctx); err == nil {
			for _, e := range after.Engines {
				for _, m := range e.Models {
					if m.ContextInUse == 0 {
						continue
					}
					// What the host asked for, per role. One model for
					// both roles runs with the deep window.
					asked := 0
					switch {
					case m.ID == after.Roles.Deep:
						asked = after.Roles.Window.Deep
					case m.ID == after.Roles.Quick:
						asked = after.Roles.Window.Quick
					default:
						continue
					}
					if asked > 0 && m.ContextLength > 0 && asked > m.ContextLength {
						asked = m.ContextLength
					}
					switch {
					case asked > 0 && m.ContextInUse < asked:
						note("%s runs with a window of %d tokens, though this host asked for %d. A longer request is cut to fit with no error. Check the model server.", m.ID, m.ContextInUse, asked)
					case asked == 0 && m.ContextInUse < m.ContextLength:
						note("%s runs with a window of %d tokens, though it supports %d, because the window is left to the model server. A longer request is cut to fit with no error. Run \"%s window\" to set it.", m.ID, m.ContextInUse, m.ContextLength, brand.CLI)
					}
				}
			}
		}
	}

	switch {
	case !st.Tunnel.Enabled:
		note("The tunnel is off, so apps cannot reach this host. Turn it on with \"%s tunnel on\".", brand.CLI)
	case st.Tunnel.State != "connected":
		bad("The tunnel is not connected to %s. %s", st.Tunnel.Relay, st.Tunnel.LastError)
		checkRelay(ctx, st.Tunnel.Relay, ok, bad)
	default:
		ok("The tunnel is connected to %s.", st.Tunnel.Relay)
		roundTrip(ctx, a, st, ok, bad, note)
	}

	fmt.Println()
	if problems == 0 {
		fmt.Println("Everything works.")
		return nil
	}
	if problems == 1 {
		return fmt.Errorf("1 problem found")
	}
	return fmt.Errorf("%d problems found", problems)
}

// checkRelay asks the relay's health route over plain HTTPS, which tells a
// network fault apart from a relay that is down.
func checkRelay(ctx context.Context, relay string, ok, bad func(string, ...any)) {
	url := strings.Replace(strings.Replace(relay, "wss://", "https://", 1), "ws://", "http://", 1) + "/healthz"
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		bad("The relay does not answer at %s. Check the network and the relay address.", url)
		return
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		ok("The relay answers at %s, so the fault is between it and this host's key.", url)
	} else {
		bad("The relay answered %d at %s.", resp.StatusCode, url)
	}
}

// roundTrip pairs a throwaway device through the relay, sends one request
// through the sealed tunnel, and unpairs the device. It proves the whole
// path an app uses.
func roundTrip(ctx context.Context, a *admin, st host.Status, ok, bad, note func(string, ...any)) {
	if st.Pairing != nil {
		note("A pairing code is open, so the tunnel test was skipped. It would cancel the code.")
		return
	}
	var offer host.PairingStatus
	if err := a.call(ctx, "POST", "/admin/v1/pairing", nil, &offer); err != nil {
		bad("The host could not make a pairing code: %s", err)
		return
	}
	defer a.call(context.Background(), "DELETE", "/admin/v1/pairing", nil, nil)

	started := time.Now()
	p, err := client.Pair(ctx, offer.Link, wire.ClientHello{Name: "Doctor check", App: brand.CLI, Platform: "check"})
	if err != nil {
		bad("A test device could not pair through the relay: %s", err)
		return
	}
	defer a.call(context.Background(), "DELETE", "/admin/v1/devices/"+p.DeviceID, nil, nil)

	s, err := client.Connect(ctx, p, wire.ClientHello{App: brand.CLI})
	if err != nil {
		bad("A test device paired but could not open a session: %s", err)
		return
	}
	defer s.Close()
	resp, err := s.Do(ctx, "GET", "/v1/host", nil, nil)
	if err != nil {
		bad("A request through the tunnel failed: %s", err)
		return
	}
	var info struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info.ID != st.Host.ID {
		bad("A request through the tunnel reached the wrong host.")
		return
	}
	ok("A test device paired, sent a sealed request through the relay, and got an answer in %s.", time.Since(started).Round(time.Millisecond))
}
