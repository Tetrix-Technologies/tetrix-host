// Package config reads and writes a host's files. They live in one
// directory, and every file that holds a secret has mode 0600.
package config

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
	"github.com/Tetrix-Technologies/tetrix-host/internal/identity"
	"github.com/Tetrix-Technologies/tetrix-host/internal/wire"
)

// Dir is the directory that holds a host's files. TETRIX_HOST_HOME overrides
// the default, which a test or a second host on one machine needs.
func Dir() (string, error) {
	if d := os.Getenv(brand.EnvHome); d != "" {
		return d, nil
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	name := brand.Name
	if runtime.GOOS == "linux" {
		name = brand.CLI
	}
	return filepath.Join(base, name), nil
}

// Paths names each file in the directory.
type Paths struct{ Dir string }

func (p Paths) Config() string     { return filepath.Join(p.Dir, "config.json") }
func (p Paths) Identity() string   { return filepath.Join(p.Dir, "identity.json") }
func (p Paths) Devices() string    { return filepath.Join(p.Dir, "devices.json") }
func (p Paths) AdminToken() string { return filepath.Join(p.Dir, "admin.token") }
func (p Paths) APIKey() string     { return filepath.Join(p.Dir, "api.key") }
func (p Paths) Daemon() string     { return filepath.Join(p.Dir, "daemon.json") }
func (p Paths) Log() string        { return filepath.Join(p.Dir, "host.log") }

// Roles maps the two kinds of work to a model. Deep takes work that needs
// thought. Quick takes short, simple work. When Quick is empty, Deep serves
// both, which is how one model is used for everything.
type Roles struct {
	Deep  string `json:"deep"`
	Quick string `json:"quick"`
}

// Resolve returns the model for a role name. It reports false when the name
// is not a role.
func (r Roles) Resolve(role string) (string, bool) {
	switch role {
	case RoleDeep:
		return r.Deep, true
	case RoleQuick:
		if r.Quick != "" {
			return r.Quick, true
		}
		return r.Deep, true
	}
	return "", false
}

const (
	RoleDeep  = "deep"
	RoleQuick = "quick"
)

// Window is the context window, in tokens, the host gives the model for
// each kind of work. Zero means the default. A negative number means the
// host leaves the window to the engine.
type Window struct {
	Deep  int `json:"deep,omitempty"`
	Quick int `json:"quick,omitempty"`
}

// The default windows. Deep work carries tools and a long conversation,
// and a Tetrix app's request runs past 20,000 tokens. Quick work is short.
const (
	DefaultDeepWindow  = 32768
	DefaultQuickWindow = 8192
)

// For returns the window for a role, or zero when the engine decides.
func (w Window) For(role string) int {
	value, fallback := w.Deep, DefaultDeepWindow
	if role == RoleQuick {
		value, fallback = w.Quick, DefaultQuickWindow
	}
	switch {
	case value < 0:
		return 0
	case value == 0:
		return fallback
	}
	return value
}

// EngineConfig points at one model server on this machine or network.
type EngineConfig struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"` // ollama or openai
	BaseURL string `json:"baseURL"`
	APIKey  string `json:"apiKey,omitempty"`
}

// TunnelConfig says whether and where the host connects out.
type TunnelConfig struct {
	Enabled bool   `json:"enabled"`
	Relay   string `json:"relay"`
}

// Config is config.json.
type Config struct {
	Name    string         `json:"name"`
	Listen  string         `json:"listen"`
	Tunnel  TunnelConfig   `json:"tunnel"`
	Engines []EngineConfig `json:"engines"`
	Roles   Roles          `json:"roles"`
	Window  Window         `json:"window"`
}

// Default is the configuration of a new host.
func Default() Config {
	name, _ := os.Hostname()
	name = strings.TrimSuffix(name, ".local")
	if name == "" {
		name = "My " + brand.Name
	}
	return Config{
		Name:   name,
		Listen: brand.DefaultListen,
		Tunnel: TunnelConfig{Enabled: true, Relay: brand.DefaultRelay},
		Engines: []EngineConfig{
			{ID: "ollama", Kind: "ollama", BaseURL: "http://127.0.0.1:11434"},
		},
	}
}

// Store guards config.json.
type Store struct {
	path string
	mu   sync.RWMutex
	cfg  Config
}

// OpenStore loads config.json, or writes the default if the file is absent.
func OpenStore(path string) (*Store, error) {
	s := &Store{path: path, cfg: Default()}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, s.save()
	}
	if err != nil {
		return nil, err
	}
	cfg := Default()
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if cfg.Listen == "" {
		cfg.Listen = brand.DefaultListen
	}
	if cfg.Tunnel.Relay == "" {
		cfg.Tunnel.Relay = brand.DefaultRelay
	}
	s.cfg = cfg
	return s, nil
}

// Get returns a copy of the configuration.
func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	c := s.cfg
	c.Engines = append([]EngineConfig(nil), s.cfg.Engines...)
	return c
}

// Update changes the configuration and writes it.
func (s *Store) Update(fn func(*Config)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	fn(&s.cfg)
	return s.save()
}

func (s *Store) save() error {
	return writeJSON(s.path, s.cfg, 0o600)
}

// Device is one paired app on one machine.
type Device struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	App        string    `json:"app,omitempty"`
	AppVersion string    `json:"appVersion,omitempty"`
	Platform   string    `json:"platform,omitempty"`
	PublicKey  string    `json:"publicKey"`
	PairedAt   time.Time `json:"pairedAt"`
	LastSeenAt time.Time `json:"lastSeenAt,omitzero"`
}

// Devices guards devices.json.
type Devices struct {
	path string
	mu   sync.RWMutex
	list []Device
}

// OpenDevices loads devices.json. An absent file is an empty list.
func OpenDevices(path string) (*Devices, error) {
	d := &Devices{path: path}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return d, nil
	}
	if err != nil {
		return nil, err
	}
	return d, json.Unmarshal(data, &d.list)
}

// List returns the devices, oldest pairing first.
func (d *Devices) List() []Device {
	d.mu.RLock()
	defer d.mu.RUnlock()
	out := append([]Device(nil), d.list...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].PairedAt.Before(out[j].PairedAt) })
	return out
}

// ByStaticKey finds the device that owns a Noise static key.
func (d *Devices) ByStaticKey(pub []byte) (Device, bool) {
	key := base64.StdEncoding.EncodeToString(pub)
	d.mu.RLock()
	defer d.mu.RUnlock()
	for _, dev := range d.list {
		if dev.PublicKey == key {
			return dev, true
		}
	}
	return Device{}, false
}

// Enroll adds a device, or refreshes its details if its key is already
// known. A second pairing of one key never makes a second device.
func (d *Devices) Enroll(pub []byte, hello wire.ClientHello) (Device, error) {
	if len(pub) != 32 {
		return Device{}, errors.New("config: a device key is 32 bytes")
	}
	key := base64.StdEncoding.EncodeToString(pub)
	name := clean(hello.Name, 64)
	if name == "" {
		name = "Unnamed device"
	}
	now := time.Now().UTC()
	d.mu.Lock()
	defer d.mu.Unlock()
	for i := range d.list {
		if d.list[i].PublicKey == key {
			d.list[i].Name = name
			d.list[i].App = clean(hello.App, 32)
			d.list[i].AppVersion = clean(hello.AppVersion, 32)
			d.list[i].Platform = clean(hello.Platform, 32)
			d.list[i].LastSeenAt = now
			return d.list[i], d.save()
		}
	}
	dev := Device{
		ID:         identity.DeviceID(pub),
		Name:       name,
		App:        clean(hello.App, 32),
		AppVersion: clean(hello.AppVersion, 32),
		Platform:   clean(hello.Platform, 32),
		PublicKey:  key,
		PairedAt:   now,
		LastSeenAt: now,
	}
	d.list = append(d.list, dev)
	return dev, d.save()
}

// Touch records that a device connected, and what it says about itself.
func (d *Devices) Touch(id string, hello wire.ClientHello) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for i := range d.list {
		if d.list[i].ID == id {
			d.list[i].LastSeenAt = time.Now().UTC()
			if v := clean(hello.AppVersion, 32); v != "" {
				d.list[i].AppVersion = v
			}
			d.save()
			return
		}
	}
}

// Rename changes a device's name. It reports false if no device has the ID
// or the name is empty.
func (d *Devices) Rename(id, name string) (bool, error) {
	name = clean(name, 64)
	if name == "" {
		return false, nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	for i := range d.list {
		if d.list[i].ID == id {
			d.list[i].Name = name
			return true, d.save()
		}
	}
	return false, nil
}

// Remove unpairs a device. Its key stops working at once. An error means
// the device is gone from memory but the file was not written, so the
// device would come back when the host restarts.
func (d *Devices) Remove(id string) (bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for i := range d.list {
		if d.list[i].ID == id {
			d.list = append(d.list[:i], d.list[i+1:]...)
			return true, d.save()
		}
	}
	return false, nil
}

// Known reports whether a device with this ID is still paired.
func (d *Devices) Known(id string) bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	for _, dev := range d.list {
		if dev.ID == id {
			return true
		}
	}
	return false
}

func (d *Devices) save() error {
	if d.path == "" {
		return nil
	}
	list := d.list
	if list == nil {
		list = []Device{}
	}
	return writeJSON(d.path, list, 0o600)
}

// clean makes a string a device supplied safe to store and print.
func clean(s string, max int) string { return wire.CleanText(s, max) }

// LoadOrCreateSecret reads a token file, or writes a new random token with
// the given prefix if the file is absent.
func LoadOrCreateSecret(path, prefix string) (string, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		if s := strings.TrimSpace(string(data)); s != "" {
			return s, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := prefix + hex.EncodeToString(raw)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	return token, os.WriteFile(path, []byte(token+"\n"), 0o600)
}

// Daemon is daemon.json, which a running host writes so the CLI and the app
// can find it.
type Daemon struct {
	PID       int       `json:"pid"`
	Address   string    `json:"address"`
	Version   string    `json:"version"`
	StartedAt time.Time `json:"startedAt"`
}

// WriteDaemon records a running host.
func WriteDaemon(path string, d Daemon) error { return writeJSON(path, d, 0o600) }

// RemoveDaemon deletes daemon.json if it still names this process. A host
// that is stopping can outlive the start of its replacement by a moment,
// and it must not delete the file the new host has just written.
func RemoveDaemon(path string, pid int) {
	if d, err := ReadDaemon(path); err == nil && d.PID != pid {
		return
	}
	os.Remove(path)
}

// ReadDaemon reads daemon.json.
func ReadDaemon(path string) (Daemon, error) {
	var d Daemon
	data, err := os.ReadFile(path)
	if err != nil {
		return d, err
	}
	return d, json.Unmarshal(data, &d)
}

func writeJSON(path string, v any, mode os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "\t")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
