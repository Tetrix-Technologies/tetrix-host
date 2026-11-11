//go:build darwin

package hardware

import (
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

func probe(info *Info) {
	if v, err := unix.Sysctl("machdep.cpu.brand_string"); err == nil {
		info.Chip = v
	}
	if v, err := unix.SysctlUint64("hw.memsize"); err == nil {
		info.MemoryBytes = v
	}
	if v, err := unix.Sysctl("kern.osproductversion"); err == nil {
		info.OS = "macOS " + v
	}
	modelID, _ := unix.Sysctl("hw.model")
	info.Model = modelID
	if strings.Contains(modelID, "Book") {
		info.Kind = "laptop"
	}

	// system_profiler knows the marketing name. It can take a moment, so
	// give it a short deadline and keep the model ID if it misses.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "/usr/sbin/system_profiler", "SPHardwareDataType", "-json").Output(); err == nil {
		var data struct {
			Hardware []struct {
				MachineName string `json:"machine_name"`
				ChipType    string `json:"chip_type"`
			} `json:"SPHardwareDataType"`
		}
		if json.Unmarshal(out, &data) == nil && len(data.Hardware) > 0 {
			if n := data.Hardware[0].MachineName; n != "" {
				info.Model = n
				if strings.Contains(n, "Book") {
					info.Kind = "laptop"
				}
			}
			if c := data.Hardware[0].ChipType; c != "" {
				info.Chip = c
			}
		}
	}
	info.DiskBytes, info.DiskFreeBytes = disk()
}

// disk reads the data volume, which is where models are stored and where
// APFS reports the space a person can use.
func disk() (total, free uint64) {
	var st unix.Statfs_t
	for _, path := range []string{"/System/Volumes/Data", "/"} {
		if unix.Statfs(path, &st) == nil {
			return st.Blocks * uint64(st.Bsize), st.Bavail * uint64(st.Bsize)
		}
	}
	return 0, 0
}

// DiskFree returns the free space now.
func DiskFree() uint64 {
	_, free := disk()
	return free
}

var vmLine = regexp.MustCompile(`^(.+?):\s+(\d+)\.`)

func sample(l *Load) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Used memory is what Activity Monitor calls app, wired, and compressed.
	if out, err := exec.CommandContext(ctx, "/usr/bin/vm_stat").Output(); err == nil {
		pageSize := uint64(unix.Getpagesize())
		var pages uint64
		for _, line := range strings.Split(string(out), "\n") {
			m := vmLine.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			n, _ := strconv.ParseUint(m[2], 10, 64)
			switch m[1] {
			case "Pages active", "Pages wired down", "Pages occupied by compressor":
				pages += n
			}
		}
		l.MemoryUsedBytes = pages * pageSize
	}

	// ps reports each process as a share of one core. Divide the sum by the
	// core count for a share of the whole machine.
	if out, err := exec.CommandContext(ctx, "/bin/ps", "-A", "-o", "%cpu=").Output(); err == nil {
		var sum float64
		for _, f := range strings.Fields(string(out)) {
			v, _ := strconv.ParseFloat(f, 64)
			sum += v
		}
		cores, _ := unix.SysctlUint32("hw.ncpu")
		if cores > 0 {
			l.CPUPercent = min(100, sum/float64(cores))
		}
	}
}
