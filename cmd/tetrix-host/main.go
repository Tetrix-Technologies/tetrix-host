// Command tetrix-host runs and manages a host.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
	"github.com/Tetrix-Technologies/tetrix-host/internal/host"
	"github.com/Tetrix-Technologies/tetrix-host/internal/relay"
)

const usage = `%[1]s runs models on your own machine for the apps you pair with it.

Usage:
  %[2]s serve                   Run the host in this terminal
  %[2]s service install         Run the host in the background, from login
  %[2]s status                  Show what the host is doing

  %[2]s pair                    Show a code that pairs one app
  %[2]s devices                 List paired devices
  %[2]s devices rm <device>     Unpair a device

  %[2]s models                  List installed models
  %[2]s models pull <name>      Download a model
  %[2]s models rm <model>       Delete a model
  %[2]s use <model>             Use one model for everything
  %[2]s use deep <model>        Set the model for work that needs thought
  %[2]s use quick <model>       Set the model for short, simple work
  %[2]s window                  Show or set how much each model can read at once
  %[2]s chat [--quick] [text]   Talk to a model from the terminal

  %[2]s engines                 List the model servers this host fronts
  %[2]s tunnel                  Show the tunnel, turn it on or off, or set its relay
  %[2]s key                     Show the address and key for local programs
  %[2]s doctor                  Check every part and say what is wrong
  %[2]s relay serve             Run your own relay

Run "%[2]s <command> --help" for a command's options.
The host keeps its files in %[3]s.
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, brand.CLI+": "+err.Error())
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		printUsage()
		return nil
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "serve", "up":
		return cmdServe(rest)
	case "relay":
		return cmdRelay(rest)
	case "status":
		return cmdStatus(rest)
	case "pair":
		return cmdPair(rest)
	case "devices", "device":
		return cmdDevices(rest)
	case "models", "model":
		return cmdModels(rest)
	case "use":
		return cmdUse(rest)
	case "engines", "engine":
		return cmdEngines(rest)
	case "tunnel":
		return cmdTunnel(rest)
	case "window":
		return cmdWindow(rest)
	case "chat":
		return cmdChat(rest)
	case "key":
		return cmdKey(rest)
	case "doctor":
		return cmdDoctor(rest)
	case "service":
		return cmdService(rest)
	case "name":
		return cmdName(rest)
	case "dev":
		return cmdDev(rest)
	case "version", "--version", "-v":
		fmt.Println(brand.CLI, brand.Version)
		return nil
	case "help", "--help", "-h":
		printUsage()
		return nil
	}
	return fmt.Errorf("unknown command %q. Run %q for the list", cmd, brand.CLI+" help")
}

func printUsage() {
	dir, _ := config.Dir()
	fmt.Printf(usage, brand.Name, brand.CLI, dir)
}

func paths() (config.Paths, error) {
	dir, err := config.Dir()
	if err != nil {
		return config.Paths{}, err
	}
	return config.Paths{Dir: dir}, nil
}

// signalContext ends on Ctrl-C, a terminate signal, or a closed terminal.
// The hangup matters for "serve": a host that dies without cleaning up
// leaves daemon.json behind, pointing at a port anyone could then take.
func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
}

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := fs.String("listen", "", "address for the local API, for this run only (default "+brand.DefaultListen+")")
	quiet := fs.Bool("quiet", false, "log warnings and errors only")
	if err := fs.Parse(args); err != nil {
		return err
	}
	level := slog.LevelInfo
	if *quiet {
		level = slog.LevelWarn
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	p, err := paths()
	if err != nil {
		return err
	}
	if d, err := config.ReadDaemon(p.Daemon()); err == nil && alive(d) {
		return fmt.Errorf("a host is already running at %s (process %d)", d.Address, d.PID)
	}
	h, err := host.Open(p, log)
	if err != nil {
		return err
	}
	if *listen != "" {
		h.ListenOverride = *listen
	}
	ctx, cancel := signalContext()
	defer cancel()
	return h.Run(ctx)
}

// alive reports whether the host that daemon.json names still answers.
func alive(d config.Daemon) bool {
	client := &http.Client{Timeout: 800 * time.Millisecond}
	resp, err := client.Get("http://" + d.Address + "/healthz")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func cmdRelay(args []string) error {
	if len(args) == 0 || args[0] != "serve" {
		return errors.New(`to run a relay, use "` + brand.CLI + ` relay serve". To point a host at a relay, use "` + brand.CLI + ` tunnel relay <address>"`)
	}
	fs := flag.NewFlagSet("relay serve", flag.ContinueOnError)
	listen := fs.String("listen", ":8787", "address to listen on")
	maxHosts := fs.Int("max-hosts", 0, "most hosts to serve at once (0 for no limit)")
	behindProxy := fs.Bool("behind-proxy", false, "read each client's address from X-Forwarded-For. Set it only when your own reverse proxy is in front")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	r := relay.New(relay.Options{Logger: log, MaxHosts: *maxHosts, TrustForwarded: *behindProxy})
	server := &http.Server{Addr: *listen, Handler: r.Handler(), ReadHeaderTimeout: 10 * time.Second}
	ctx, cancel := signalContext()
	defer cancel()
	go func() {
		<-ctx.Done()
		shutdown, c := context.WithTimeout(context.Background(), 3*time.Second)
		defer c()
		server.Shutdown(shutdown)
	}()
	log.Info("relay listening", "address", *listen, "version", brand.Version)
	log.Info("put TLS in front of this port before you use it across the internet")
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
