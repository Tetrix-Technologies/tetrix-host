package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/Tetrix-Technologies/tetrix-host/internal/brand"
)

// program writes an executable file named for the command in dir, and
// returns its path with every link in it followed.
func program(t *testing.T, dir string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, brand.CLI)
	if err := os.WriteFile(file, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(file)
	if err != nil {
		t.Fatal(err)
	}
	return real
}

func TestServicePath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("a background service is not set up on Windows")
	}
	root := t.TempDir()
	// The layout Homebrew makes: one directory per version, and a link on
	// the PATH to the current one.
	file := program(t, filepath.Join(root, "Cellar", brand.CLI, "0.1.0", "bin"))
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(bin, brand.CLI)
	if err := os.Symlink(filepath.Join("..", "Cellar", brand.CLI, "0.1.0", "bin", brand.CLI), link); err != nil {
		t.Fatal(err)
	}
	other := program(t, filepath.Join(root, "other"))

	tests := []struct {
		name string
		path string
		exe  string
		want string
	}{
		{"a link on the PATH to this program", bin, file, link},
		{"started through the link", bin, link, link},
		{"the program itself on the PATH", filepath.Dir(file), file, file},
		{"another copy on the PATH", filepath.Dir(other), file, file},
		{"nothing on the PATH", filepath.Join(root, "empty"), file, file},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("PATH", tt.path)
			got, err := servicePath(tt.exe)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("servicePath(%q) = %q, want %q", tt.exe, got, tt.want)
			}
		})
	}
}
