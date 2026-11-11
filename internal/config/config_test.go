package config

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

func TestRolesResolve(t *testing.T) {
	both := Roles{Deep: "a/big", Quick: "a/small"}
	one := Roles{Deep: "a/big"}
	for _, tc := range []struct {
		roles Roles
		role  string
		want  string
		ok    bool
	}{
		{both, RoleDeep, "a/big", true},
		{both, RoleQuick, "a/small", true},
		{one, RoleQuick, "a/big", true},
		{Roles{}, RoleDeep, "", true},
		{both, "a/big", "", false},
		{both, "", "", false},
	} {
		got, ok := tc.roles.Resolve(tc.role)
		if got != tc.want || ok != tc.ok {
			t.Errorf("%+v resolve %q = %q, %v; want %q, %v", tc.roles, tc.role, got, ok, tc.want, tc.ok)
		}
	}
}

func TestEnrollIsIdempotentPerKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devices.json")
	d, err := OpenDevices(path)
	if err != nil {
		t.Fatal(err)
	}
	key := bytes.Repeat([]byte{7}, 32)
	first, err := d.Enroll(key, wire.ClientHello{Name: "Laptop", App: "Cue"})
	if err != nil {
		t.Fatal(err)
	}
	second, err := d.Enroll(key, wire.ClientHello{Name: "Laptop renamed", App: "Cue"})
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID || len(d.List()) != 1 || d.List()[0].Name != "Laptop renamed" {
		t.Fatalf("a second pairing of one key should update one device, got %+v", d.List())
	}
	if _, err := d.Enroll([]byte("short"), wire.ClientHello{}); err == nil {
		t.Fatal("a short key was enrolled")
	}

	// The list survives a restart, and the file is private.
	reopened, err := OpenDevices(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := reopened.ByStaticKey(key); !ok || got.ID != first.ID {
		t.Fatal("the device was not found after reopening")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("devices.json has mode %o, want 600", info.Mode().Perm())
	}

	if removed, err := reopened.Remove(first.ID); !removed || err != nil {
		t.Fatalf("remove failed: %v, %v", removed, err)
	}
	if removed, _ := reopened.Remove(first.ID); removed {
		t.Fatal("a device was removed twice")
	}
	if reopened.Known(first.ID) {
		t.Fatal("a removed device is still known by ID")
	}
	if _, ok := reopened.ByStaticKey(key); ok {
		t.Fatal("a removed device is still known")
	}
}

func TestDeviceNamesAreCleaned(t *testing.T) {
	d, _ := OpenDevices("")
	dev, _ := d.Enroll(bytes.Repeat([]byte{1}, 32), wire.ClientHello{
		// An escape sequence that would clear a terminal, and a newline
		// that would forge a log line.
		Name: "  Lap\x1b[2Jtop\nINFO fake  ",
		App:  "Cue\x00",
	})
	if dev.Name != "Lap[2JtopINFO fake" || dev.App != "Cue" {
		t.Fatalf("control characters survived: %q, %q", dev.Name, dev.App)
	}
	long, _ := d.Enroll(bytes.Repeat([]byte{2}, 32), wire.ClientHello{Name: string(bytes.Repeat([]byte("x"), 500))})
	if len(long.Name) > 64 {
		t.Fatalf("a name of %d bytes was kept", len(long.Name))
	}
	blank, _ := d.Enroll(bytes.Repeat([]byte{3}, 32), wire.ClientHello{Name: " \t "})
	if blank.Name == "" {
		t.Fatal("a device with no name should get a placeholder")
	}
}

func TestSecretsAreStableAndPrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "admin.token")
	first, err := LoadOrCreateSecret(path, "hadm_")
	if err != nil {
		t.Fatal(err)
	}
	second, _ := LoadOrCreateSecret(path, "hadm_")
	if first != second || len(first) != len("hadm_")+48 {
		t.Fatalf("the token changed or has the wrong length: %q, %q", first, second)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("the token file has mode %o, want 600", info.Mode().Perm())
	}
}

func TestStoreKeepsWhatItIsGiven(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	s, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Get(); len(got.Engines) != 1 || got.Engines[0].Kind != "ollama" || !got.Tunnel.Enabled {
		t.Fatalf("unexpected defaults: %+v", got)
	}
	s.Update(func(c *Config) { c.Roles = Roles{Deep: "ollama/x"}; c.Name = "Studio" })
	again, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.Get(); got.Roles.Deep != "ollama/x" || got.Name != "Studio" {
		t.Fatalf("the change did not survive a reopen: %+v", got)
	}
}

func TestAStoppingHostLeavesItsSuccessorsFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.json")
	// The new host has already written the file when the old one exits.
	if err := WriteDaemon(path, Daemon{PID: 222, Address: "127.0.0.1:4784"}); err != nil {
		t.Fatal(err)
	}
	RemoveDaemon(path, 111)
	if d, err := ReadDaemon(path); err != nil || d.PID != 222 {
		t.Fatalf("the old host deleted the new host's file: %+v, %v", d, err)
	}
	// A host removes its own file.
	RemoveDaemon(path, 222)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("a host left its own file behind")
	}
	// Removing a file that is not there is not an error.
	RemoveDaemon(path, 222)
}

func TestWindowDefaults(t *testing.T) {
	for _, tc := range []struct {
		window Window
		role   string
		want   int
	}{
		{Window{}, RoleDeep, DefaultDeepWindow},
		{Window{}, RoleQuick, DefaultQuickWindow},
		{Window{Deep: 16384}, RoleDeep, 16384},
		{Window{Deep: 16384}, RoleQuick, DefaultQuickWindow},
		// A negative number leaves the window to the engine.
		{Window{Deep: -1}, RoleDeep, 0},
		{Window{Quick: -1}, RoleQuick, 0},
	} {
		if got := tc.window.For(tc.role); got != tc.want {
			t.Errorf("%+v for %s = %d, want %d", tc.window, tc.role, got, tc.want)
		}
	}
}
