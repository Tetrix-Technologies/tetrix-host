// Package hardware reports what machine a host runs on and how busy it is.
package hardware

import (
	"runtime"
	"time"
)

// GPU is one graphics card with its own memory.
type GPU struct {
	Name        string `json:"name"`
	MemoryBytes uint64 `json:"memoryBytes,omitempty"`
}

// Info describes the machine. It does not change while the host runs,
// except for the free disk space.
type Info struct {
	// Model is the name a person knows the machine by, such as "Mac mini".
	Model string `json:"model"`
	// Kind is laptop, desktop, or server. The app picks an icon from it.
	Kind          string `json:"kind"`
	Chip          string `json:"chip"`
	Cores         int    `json:"cores"`
	MemoryBytes   uint64 `json:"memoryBytes"`
	DiskBytes     uint64 `json:"diskBytes"`
	DiskFreeBytes uint64 `json:"diskFreeBytes"`
	OS            string `json:"os"`
	Arch          string `json:"arch"`
	GPUs          []GPU  `json:"gpus,omitempty"`
}

// Load is one sample of how busy the machine is.
type Load struct {
	MemoryUsedBytes uint64    `json:"memoryUsedBytes"`
	CPUPercent      float64   `json:"cpuPercent"`
	At              time.Time `json:"at"`
}

// Probe describes this machine. A field the platform cannot supply stays
// empty.
func Probe() Info {
	info := Info{Cores: runtime.NumCPU(), Arch: runtime.GOARCH, OS: runtime.GOOS, Kind: "desktop"}
	probe(&info)
	if info.Model == "" {
		info.Model = "This machine"
	}
	return info
}

// Sample measures the current load.
func Sample() Load {
	l := Load{At: time.Now().UTC()}
	sample(&l)
	return l
}
