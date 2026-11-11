package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/config"
)

const launchLabel = brand.ServiceLabel

// cmdService installs the host as a background service of the signed-in
// user: a LaunchAgent on macOS and a systemd user unit on Linux. Neither
// needs root.
func cmdService(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: %s service install, uninstall, or status", brand.CLI)
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = servicePath(exe); err != nil {
		return err
	}
	p, err := paths()
	if err != nil {
		return err
	}
	switch runtime.GOOS {
	case "darwin":
		return launchd(args[0], exe, p)
	case "linux":
		return systemd(args[0], exe)
	}
	return fmt.Errorf("background service setup is not available on %s. Run \"%s serve\" under your own service manager", runtime.GOOS, brand.CLI)
}

// servicePath returns the path that a background service runs.
//
// A package manager such as Homebrew keeps each version in a directory of
// its own and points a link on the PATH at the current one. The service has
// to run the link. If it ran the file behind the link, it would stay on the
// old version after an upgrade, and stop when that version is deleted.
//
// So when the command on the PATH is a link to this program, the answer is
// the link. In every other case it is the program's own file.
func servicePath(exe string) (string, error) {
	file, err := filepath.EvalSymlinks(exe)
	if err != nil {
		return "", err
	}
	found, err := exec.LookPath(brand.CLI)
	if err != nil {
		return file, nil
	}
	link, err := filepath.Abs(found)
	if err != nil {
		return file, nil
	}
	if target, err := filepath.EvalSymlinks(link); err != nil || target != file {
		return file, nil
	}
	return link, nil
}

func launchd(action, exe string, p config.Paths) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	plist := filepath.Join(home, "Library", "LaunchAgents", launchLabel+".plist")
	domain := fmt.Sprintf("gui/%d", os.Getuid())
	switch action {
	case "install":
		if err := os.MkdirAll(p.Dir, 0o700); err != nil {
			return err
		}
		body := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>serve</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
</dict>
</plist>
`, launchLabel, xmlEscape(exe), xmlEscape(p.Log()), xmlEscape(p.Log()))
		if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(plist, []byte(body), 0o644); err != nil {
			return err
		}
		// Replace a copy that is already loaded.
		exec.Command("launchctl", "bootout", domain+"/"+launchLabel).Run()
		if out, err := exec.Command("launchctl", "bootstrap", domain, plist).CombinedOutput(); err != nil {
			return fmt.Errorf("launchctl could not load the service: %s", strings.TrimSpace(string(out)))
		}
		return waitUntilRunning(p, "The log is at "+p.Log()+".")
	case "uninstall":
		exec.Command("launchctl", "bootout", domain+"/"+launchLabel).Run()
		if err := os.Remove(plist); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		fmt.Println("The background service is removed. Paired devices and settings are kept.")
		return nil
	case "status":
		if _, err := os.Stat(plist); err != nil {
			fmt.Println("The background service is not installed.")
			return nil
		}
		return serviceStatus(p)
	}
	return fmt.Errorf("usage: %s service install, uninstall, or status", brand.CLI)
}

func systemd(action, exe string) error {
	p, err := paths()
	if err != nil {
		return err
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	unit := filepath.Join(dir, "systemd", "user", brand.CLI+".service")
	systemctl := func(args ...string) error {
		out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("systemctl %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
		}
		return nil
	}
	switch action {
	case "install":
		body := fmt.Sprintf(`[Unit]
Description=%s host
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%q serve
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
`, brand.Name, exe)
		if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(unit, []byte(body), 0o644); err != nil {
			return err
		}
		if err := systemctl("daemon-reload"); err != nil {
			return err
		}
		if err := systemctl("enable", "--now", brand.CLI+".service"); err != nil {
			return err
		}
		return waitUntilRunning(p, "Read the log with \"journalctl --user -u "+brand.CLI+"\". To keep the host up after you log out, run \"loginctl enable-linger\".")
	case "uninstall":
		systemctl("disable", "--now", brand.CLI+".service")
		if err := os.Remove(unit); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		systemctl("daemon-reload")
		fmt.Println("The background service is removed. Paired devices and settings are kept.")
		return nil
	case "status":
		if _, err := os.Stat(unit); err != nil {
			fmt.Println("The background service is not installed.")
			return nil
		}
		return serviceStatus(p)
	}
	return fmt.Errorf("usage: %s service install, uninstall, or status", brand.CLI)
}

func waitUntilRunning(p config.Paths, hint string) error {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if d, err := config.ReadDaemon(p.Daemon()); err == nil && alive(d) {
			fmt.Printf("The host is running in the background at %s. It starts again each time you log in.\n%s\n", d.Address, hint)
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("the service is installed but the host did not start. " + hint)
}

func serviceStatus(p config.Paths) error {
	if d, err := config.ReadDaemon(p.Daemon()); err == nil && alive(d) {
		fmt.Printf("The background service is installed and the host is running at %s.\n", d.Address)
		return nil
	}
	fmt.Println("The background service is installed but the host is not running.")
	return nil
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}
