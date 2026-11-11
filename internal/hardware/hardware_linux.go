//go:build linux

package hardware

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

func probe(info *Info) {
	info.Kind = "server"
	if data, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == "model name" {
				info.Chip = strings.TrimSpace(v)
				break
			}
		}
	}
	info.MemoryBytes = meminfo()["MemTotal"]
	if data, err := os.ReadFile("/sys/devices/virtual/dmi/id/product_name"); err == nil {
		info.Model = strings.TrimSpace(string(data))
	}
	if data, err := os.ReadFile("/sys/class/dmi/id/chassis_type"); err == nil {
		// SMBIOS chassis types 8 to 10 and 14 are portable machines.
		switch strings.TrimSpace(string(data)) {
		case "8", "9", "10", "14":
			info.Kind = "laptop"
		case "3", "4", "5", "6", "7", "13", "35":
			info.Kind = "desktop"
		}
	}
	if f, err := os.Open("/etc/os-release"); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if v, ok := strings.CutPrefix(sc.Text(), "PRETTY_NAME="); ok {
				info.OS = strings.Trim(v, `"`)
			}
		}
	}
	info.DiskBytes, info.DiskFreeBytes = disk()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader,nounits").Output()
	if err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			name, mem, ok := strings.Cut(line, ",")
			if !ok {
				continue
			}
			mib, _ := strconv.ParseUint(strings.TrimSpace(mem), 10, 64)
			info.GPUs = append(info.GPUs, GPU{Name: strings.TrimSpace(name), MemoryBytes: mib << 20})
		}
	}
}

func disk() (total, free uint64) {
	var st unix.Statfs_t
	if unix.Statfs("/", &st) == nil {
		return st.Blocks * uint64(st.Bsize), st.Bavail * uint64(st.Bsize)
	}
	return 0, 0
}

// DiskFree returns the free space now.
func DiskFree() uint64 {
	_, free := disk()
	return free
}

// meminfo reads /proc/meminfo into bytes.
func meminfo() map[string]uint64 {
	out := map[string]uint64{}
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		fields := strings.Fields(v)
		if len(fields) == 0 {
			continue
		}
		n, _ := strconv.ParseUint(fields[0], 10, 64)
		out[k] = n << 10
	}
	return out
}

var (
	cpuMu             sync.Mutex
	lastBusy, lastAll uint64
)

func sample(l *Load) {
	mem := meminfo()
	if mem["MemTotal"] > mem["MemAvailable"] {
		l.MemoryUsedBytes = mem["MemTotal"] - mem["MemAvailable"]
	}
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return
	}
	line, _, _ := strings.Cut(string(data), "\n")
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return
	}
	var all, idle uint64
	for i, f := range fields[1:] {
		n, _ := strconv.ParseUint(f, 10, 64)
		all += n
		if i == 3 || i == 4 {
			idle += n
		}
	}
	busy := all - idle
	cpuMu.Lock()
	defer cpuMu.Unlock()
	if lastAll != 0 && all > lastAll {
		l.CPUPercent = 100 * float64(busy-lastBusy) / float64(all-lastAll)
	}
	lastBusy, lastAll = busy, all
}
