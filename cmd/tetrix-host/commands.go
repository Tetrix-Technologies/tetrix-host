package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"golang.org/x/term"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/engine"
	"github.com/Tetrix-Technologies/tetrix-host/internal/events"
	"github.com/Tetrix-Technologies/tetrix-host/internal/host"
	"github.com/Tetrix-Technologies/tetrix-host/internal/qrterm"
)

func status(ctx context.Context) (*admin, host.Status, error) {
	var st host.Status
	a, err := connect()
	if err != nil {
		return nil, st, err
	}
	return a, st, a.call(ctx, "GET", "/admin/v1/status", nil, &st)
}

func cmdStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "print the whole status document as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	_, st, err := status(context.Background())
	if err != nil {
		return err
	}
	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(st)
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(w, "Host\t%s\t(%s)\n", st.Host.Name, st.Host.ID)
	fmt.Fprintf(w, "Machine\t%s, %s, %s memory\n", st.Hardware.Model, st.Hardware.Chip, gigabytes(int64(st.Hardware.MemoryBytes)))
	fmt.Fprintf(w, "Running\t%s\ton %s\n", since(st.Host.StartedAt), st.Host.Address)
	fmt.Fprintf(w, "Tunnel\t%s\n", tunnelLine(st))
	fmt.Fprintf(w, "Deep work\t%s\n", orNone(st.Roles.Deep))
	if st.Roles.Single {
		fmt.Fprintf(w, "Quick work\tsame model\n")
	} else {
		fmt.Fprintf(w, "Quick work\t%s\n", orNone(st.Roles.Quick))
	}
	online := 0
	for _, d := range st.Devices {
		if d.Online {
			online++
		}
	}
	fmt.Fprintf(w, "Devices\t%d paired, %d connected\n", len(st.Devices), online)
	fmt.Fprintf(w, "Served\t%d requests, %d tokens out\n", st.Stats.Requests, st.Stats.TokensOut)
	w.Flush()
	for _, e := range st.Engines {
		if e.State != "ready" {
			fmt.Printf("\nThe %s engine is not answering at %s.\n", e.ID, e.BaseURL)
		}
	}
	if st.Roles.Deep == "" {
		fmt.Printf("\nNo model is assigned. Download one with \"%s models pull <name>\".\n", brand.CLI)
	}
	return nil
}

func tunnelLine(st host.Status) string {
	switch st.Tunnel.State {
	case "connected":
		return "connected to " + st.Tunnel.Relay
	case "connecting":
		return "connecting to " + st.Tunnel.Relay
	case "disabled":
		return "off"
	}
	if st.Tunnel.LastError != "" {
		return "offline: " + st.Tunnel.LastError
	}
	return "offline"
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func gigabytes(n int64) string {
	gb := float64(n) / (1 << 30)
	if gb >= 10 {
		return fmt.Sprintf("%.0f GB", gb)
	}
	return fmt.Sprintf("%.1f GB", gb)
}

func since(t time.Time) string {
	d := time.Since(t).Round(time.Second)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}

func cmdPair(args []string) error {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	noWait := fs.Bool("no-wait", false, "print the code and exit without waiting for the app")
	asJSON := fs.Bool("json", false, "print the code as JSON and exit, for a script")
	if err := fs.Parse(args); err != nil {
		return err
	}
	ctx, cancel := signalContext()
	defer cancel()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	if !st.Tunnel.Enabled {
		return fmt.Errorf("the tunnel is off, so an app cannot reach this host. Turn it on with \"%s tunnel on\"", brand.CLI)
	}
	var offer host.PairingStatus
	if err := a.call(ctx, "POST", "/admin/v1/pairing", nil, &offer); err != nil {
		return err
	}
	if *asJSON {
		return json.NewEncoder(os.Stdout).Encode(offer)
	}

	fmt.Printf("\nPair an app with %s\n\n", st.Host.Name)
	if term.IsTerminal(int(os.Stdout.Fd())) {
		qrterm.Write(os.Stdout, offer.Link)
		fmt.Println()
	}
	fmt.Printf("  Scan the code with the app, or paste this link into it:\n\n  %s\n\n", offer.Link)
	fmt.Printf("  The code works once and expires in %d minutes.\n", int(time.Until(offer.ExpiresAt).Round(time.Minute).Minutes()))
	if st.Tunnel.State != "connected" {
		fmt.Printf("\n  The tunnel is %s. Pairing will work when it connects.\n", tunnelLine(st))
	}
	if *noWait {
		return nil
	}
	fmt.Print("\n  Waiting for the app. Press Ctrl-C to cancel.\n")

	wctx, wcancel := context.WithDeadline(ctx, offer.ExpiresAt)
	defer wcancel()
	var paired *config.Device
	err = a.watch(wctx, func(e events.Event, data json.RawMessage) bool {
		if e.Type != events.Paired {
			return true
		}
		var d config.Device
		if json.Unmarshal(data, &d) == nil {
			paired = &d
		}
		return false
	})
	if paired != nil {
		app := paired.App
		if app == "" {
			app = "An app"
		}
		fmt.Printf("\n  Paired. %s on %s can now use this host.\n\n", app, paired.Name)
		return nil
	}
	// Nothing paired, so take the code off the table.
	a.call(context.Background(), "DELETE", "/admin/v1/pairing", nil, nil)
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(wctx.Err(), context.DeadlineExceeded) {
		return errors.New("the code expired before an app used it")
	}
	fmt.Println("\n  Cancelled. The code no longer works.")
	return nil
}

func cmdDevices(args []string) error {
	ctx := context.Background()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	find := func(ref string) (host.DeviceStatus, error) {
		var hit []host.DeviceStatus
		for _, d := range st.Devices {
			if d.ID == ref || strings.EqualFold(d.Name, ref) {
				hit = append(hit, d)
			}
		}
		switch len(hit) {
		case 1:
			return hit[0], nil
		case 0:
			return host.DeviceStatus{}, fmt.Errorf("no paired device is called %q", ref)
		}
		return host.DeviceStatus{}, fmt.Errorf("more than one device is called %q. Use the device's ID", ref)
	}
	if len(args) >= 2 && (args[0] == "rm" || args[0] == "remove") {
		d, err := find(strings.Join(args[1:], " "))
		if err != nil {
			return err
		}
		if err := a.call(ctx, "DELETE", "/admin/v1/devices/"+d.ID, nil, nil); err != nil {
			return err
		}
		fmt.Printf("Unpaired %s. It can no longer use this host.\n", d.Name)
		return nil
	}
	if len(args) >= 3 && args[0] == "rename" {
		d, err := find(args[1])
		if err != nil {
			return err
		}
		return a.call(ctx, "PATCH", "/admin/v1/devices/"+d.ID, map[string]string{"name": strings.Join(args[2:], " ")}, nil)
	}
	if len(args) > 0 {
		return fmt.Errorf("usage: %[1]s devices, %[1]s devices rm <device>, or %[1]s devices rename <device> <name>", brand.CLI)
	}
	if len(st.Devices) == 0 {
		fmt.Printf("No devices are paired. Run \"%s pair\" to pair one.\n", brand.CLI)
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tAPP\tSTATE\tREQUESTS\tLAST SEEN\tID")
	for _, d := range st.Devices {
		state := "away"
		if d.Online {
			state = "connected"
		}
		seen := "never"
		if !d.LastSeenAt.IsZero() {
			seen = since(d.LastSeenAt) + " ago"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\t%s\n", d.Name, strings.TrimSpace(d.App+" "+d.Platform), state, d.Requests, seen, d.ID)
	}
	return w.Flush()
}

func cmdModels(args []string) error {
	ctx, cancel := signalContext()
	defer cancel()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	if len(args) >= 2 && args[0] == "pull" {
		return pull(ctx, a, args[1])
	}
	if len(args) >= 2 && (args[0] == "rm" || args[0] == "remove") {
		id, err := modelID(st, args[1])
		if err != nil {
			return err
		}
		if err := a.call(ctx, "DELETE", "/admin/v1/models?id="+url.QueryEscape(id), nil, nil); err != nil {
			return err
		}
		fmt.Printf("Deleted %s.\n", id)
		return nil
	}
	if len(args) > 0 {
		return fmt.Errorf("usage: %[1]s models, %[1]s models pull <name>, or %[1]s models rm <model>", brand.CLI)
	}

	var models []engine.Model
	for _, e := range st.Engines {
		if e.State != "ready" {
			fmt.Printf("The %s engine is not answering at %s.\n", e.ID, e.BaseURL)
		}
		models = append(models, e.Models...)
	}
	if len(models) == 0 {
		fmt.Printf("No models are installed. Download one with \"%s models pull <name>\".\n", brand.CLI)
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "MODEL\tSIZE\tUSED FOR\tCAN\tWINDOW\tIN MEMORY")
	for _, m := range models {
		var roles []string
		if st.Roles.Deep == m.ID {
			roles = append(roles, "deep")
		}
		if st.Roles.Quick == m.ID || (st.Roles.Single && st.Roles.Deep == m.ID) {
			roles = append(roles, "quick")
		}
		loaded := ""
		if m.Loaded {
			loaded = "yes"
		}
		size := ""
		if m.SizeBytes > 0 {
			size = gigabytes(m.SizeBytes)
		}
		// The window in use is the one that limits a request. Show it
		// when the engine reports it, and the model's own limit otherwise.
		window := ""
		switch {
		case m.ContextInUse > 0 && m.ContextInUse < m.ContextLength:
			window = fmt.Sprintf("%d of %d", m.ContextInUse, m.ContextLength)
		case m.ContextLength > 0:
			window = fmt.Sprint(m.ContextLength)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\n", m.ID, size, strings.Join(roles, ", "), strings.Join(m.Capabilities, ", "), window, loaded)
	}
	return w.Flush()
}

// modelID accepts a full model ID or an engine's own name for a model.
func modelID(st host.Status, ref string) (string, error) {
	var hit []string
	for _, e := range st.Engines {
		for _, m := range e.Models {
			if m.ID == ref {
				return m.ID, nil
			}
			if m.Name == ref {
				hit = append(hit, m.ID)
			}
		}
	}
	switch len(hit) {
	case 1:
		return hit[0], nil
	case 0:
		return "", fmt.Errorf("no installed model is called %q. Run \"%s models\" for the list", ref, brand.CLI)
	}
	return "", fmt.Errorf("more than one engine has a model called %q. Use one of: %s", ref, strings.Join(hit, ", "))
}

func pull(ctx context.Context, a *admin, name string) error {
	if err := a.call(ctx, "POST", "/admin/v1/models/pull", map[string]string{"name": name}, nil); err != nil {
		return err
	}
	interactive := term.IsTerminal(int(os.Stdout.Fd()))
	var failure string
	done := false
	err := a.watch(ctx, func(e events.Event, data json.RawMessage) bool {
		if e.Type != events.Pull {
			return true
		}
		var p engine.Progress
		if json.Unmarshal(data, &p) != nil || p.Name != name {
			return true
		}
		if interactive && p.Total > 0 {
			fmt.Printf("\r  %s  %s of %s  %3.0f%%   ", p.Status, gigabytes(p.Completed), gigabytes(p.Total), 100*float64(p.Completed)/float64(p.Total))
		}
		if p.Done {
			done = true
			failure = p.Error
			return false
		}
		return true
	})
	if interactive {
		fmt.Println()
	}
	if !done {
		// Ctrl-C stops the download too. A partial download resumes later.
		a.call(context.Background(), "DELETE", "/admin/v1/models/pull?name="+url.QueryEscape(name), nil, nil)
		if err != nil && !errors.Is(err, context.Canceled) {
			return err
		}
		return errors.New("download cancelled")
	}
	if failure != "" {
		return errors.New(failure)
	}
	fmt.Printf("Downloaded %s.\n", name)
	return nil
}

func cmdUse(args []string) error {
	ctx := context.Background()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	usage := fmt.Errorf("usage: %[1]s use <model>, %[1]s use deep <model>, or %[1]s use quick <model>", brand.CLI)
	switch len(args) {
	case 1:
		id, err := modelID(st, args[0])
		if err != nil {
			return err
		}
		if err := a.call(ctx, "PUT", "/admin/v1/roles", map[string]string{"deep": id, "quick": ""}, nil); err != nil {
			return err
		}
		fmt.Printf("Using %s for everything.\n", id)
	case 2:
		role := args[0]
		if role != config.RoleDeep && role != config.RoleQuick {
			return usage
		}
		id, err := modelID(st, args[1])
		if err != nil {
			return err
		}
		if err := a.call(ctx, "PUT", "/admin/v1/roles", map[string]string{role: id}, nil); err != nil {
			return err
		}
		fmt.Printf("Using %s for %s work.\n", id, role)
	default:
		return usage
	}
	return nil
}

func cmdEngines(args []string) error {
	ctx := context.Background()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	if len(args) >= 1 && args[0] == "add" {
		fs := flag.NewFlagSet("engines add", flag.ContinueOnError)
		kind := fs.String("kind", "openai", "ollama, or openai for any server that speaks the OpenAI API")
		key := fs.String("key", "", "API key the engine needs, if any")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		if fs.NArg() != 2 {
			return fmt.Errorf("usage: %s engines add [--kind ollama|openai] [--key KEY] <id> <address>", brand.CLI)
		}
		cfg := config.EngineConfig{ID: fs.Arg(0), Kind: *kind, BaseURL: fs.Arg(1), APIKey: *key}
		if err := a.call(ctx, "POST", "/admin/v1/engines", cfg, nil); err != nil {
			return err
		}
		fmt.Printf("Added the %s engine at %s.\n", cfg.ID, cfg.BaseURL)
		return nil
	}
	if len(args) == 2 && (args[0] == "rm" || args[0] == "remove") {
		return a.call(ctx, "DELETE", "/admin/v1/engines/"+url.PathEscape(args[1]), nil, nil)
	}
	if len(args) > 0 {
		return fmt.Errorf("usage: %[1]s engines, %[1]s engines add <id> <address>, or %[1]s engines rm <id>", brand.CLI)
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tKIND\tADDRESS\tSTATE\tMODELS")
	for _, e := range st.Engines {
		state := e.State
		if e.Version != "" {
			state += " (" + e.Version + ")"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%d\n", e.ID, e.Kind, e.BaseURL, state, len(e.Models))
	}
	return w.Flush()
}

func cmdTunnel(args []string) error {
	ctx := context.Background()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	set := func(body map[string]any) error {
		return a.call(ctx, "PUT", "/admin/v1/settings", map[string]any{"tunnel": body}, nil)
	}
	switch {
	case len(args) == 0:
		fmt.Printf("Tunnel   %s\nRelay    %s\nHost ID  %s\n", tunnelLine(st), st.Tunnel.Relay, st.Host.ID)
		return nil
	case len(args) == 1 && args[0] == "on":
		return set(map[string]any{"enabled": true})
	case len(args) == 1 && args[0] == "off":
		if err := set(map[string]any{"enabled": false}); err != nil {
			return err
		}
		fmt.Println("The tunnel is off. Paired apps cannot reach this host until you turn it on.")
		return nil
	case len(args) == 2 && args[0] == "relay":
		relay := args[1]
		if relay == "default" {
			relay = brand.DefaultRelay
		}
		if err := set(map[string]any{"relay": relay}); err != nil {
			return err
		}
		fmt.Printf("Using the relay at %s.\n", relay)
		if len(st.Devices) > 0 {
			fmt.Println("Paired apps still look for this host on the old relay. Pair them again.")
		}
		return nil
	}
	return fmt.Errorf("usage: %[1]s tunnel, %[1]s tunnel on, %[1]s tunnel off, or %[1]s tunnel relay <address>", brand.CLI)
}

func cmdName(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: %s name <new name>", brand.CLI)
	}
	a, err := connect()
	if err != nil {
		return err
	}
	return a.call(context.Background(), "PUT", "/admin/v1/settings", map[string]string{"name": strings.Join(args, " ")}, nil)
}

func cmdKey(args []string) error {
	_, st, err := status(context.Background())
	if err != nil {
		return err
	}
	p, err := paths()
	if err != nil {
		return err
	}
	key, err := os.ReadFile(p.APIKey())
	if err != nil {
		return err
	}
	fmt.Printf("Programs on this machine can use the host as an OpenAI-style API.\n\n")
	fmt.Printf("  Base URL  %s\n  API key   %s\n  Models    deep, quick\n\n", st.Host.Endpoint, strings.TrimSpace(string(key)))
	fmt.Printf("The key opens the model routes only. It cannot pair a device or change a setting.\n")
	return nil
}

// cmdWindow shows or sets the context window the host gives the model for
// each kind of work.
func cmdWindow(args []string) error {
	ctx := context.Background()
	a, st, err := status(ctx)
	if err != nil {
		return err
	}
	usage := fmt.Errorf("usage: %[1]s window, %[1]s window deep <tokens>, %[1]s window quick <tokens>. In place of a number, \"default\" restores the default and \"engine\" leaves the window to the model server", brand.CLI)
	if len(args) == 0 {
		show := func(tokens int) string {
			if tokens == 0 {
				return "left to the model server"
			}
			return fmt.Sprintf("%d tokens", tokens)
		}
		fmt.Printf("Deep work   %s\nQuick work  %s\n", show(st.Roles.Window.Deep), show(st.Roles.Window.Quick))
		if st.Roles.Single {
			fmt.Println("\nOne model serves both, so it runs with the deep window.")
		}
		return nil
	}
	if len(args) != 2 || (args[0] != config.RoleDeep && args[0] != config.RoleQuick) {
		return usage
	}
	var tokens int
	switch args[1] {
	case "default":
		tokens = 0
	case "engine":
		tokens = -1
	default:
		n, err := strconv.Atoi(strings.ReplaceAll(args[1], ",", ""))
		if err != nil || n < 1024 {
			return usage
		}
		tokens = n
	}
	if err := a.call(ctx, "PUT", "/admin/v1/settings", map[string]any{"window": map[string]int{args[0]: tokens}}, nil); err != nil {
		return err
	}
	_, st, err = status(ctx)
	if err != nil {
		return err
	}
	set := st.Roles.Window.Deep
	if args[0] == config.RoleQuick {
		set = st.Roles.Window.Quick
	}
	if set == 0 {
		fmt.Printf("The model server now decides the window for %s work.\n", args[0])
	} else {
		fmt.Printf("The model for %s work now reads up to %d tokens at once. A larger window uses more memory.\n", args[0], set)
	}
	return nil
}
