//go:build !darwin && !linux

package hardware

func probe(*Info) {}

func sample(*Load) {}

// DiskFree is not measured on this platform.
func DiskFree() uint64 { return 0 }
