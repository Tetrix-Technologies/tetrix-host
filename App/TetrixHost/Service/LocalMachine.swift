import Foundation

/// What the app can say about this machine on its own, while no host runs.
enum LocalMachine {
	static func hardware(process: ProcessInfo = .processInfo) -> Hardware {
		var hardware = Hardware()
		let identifier = sysctl("hw.model") ?? ""
		hardware.kind = identifier.contains("Book") ? "laptop" : "desktop"
		hardware.model = Host.current().localizedName ?? "This Mac"
		hardware.chip = sysctl("machdep.cpu.brand_string") ?? ""
		hardware.cores = process.activeProcessorCount
		hardware.memoryBytes = Int64(clamping: process.physicalMemory)
		let version = process.operatingSystemVersion
		hardware.os = "macOS \(version.majorVersion).\(version.minorVersion)"

		let volume = URL(fileURLWithPath: "/System/Volumes/Data")
		if let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]) {
			hardware.diskFreeBytes = Int64(values.volumeAvailableCapacity ?? 0)
			hardware.diskBytes = Int64(values.volumeTotalCapacity ?? 0)
		}
		return hardware
	}

	private static func sysctl(_ name: String) -> String? {
		var size = 0
		guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
		var buffer = [UInt8](repeating: 0, count: size)
		guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
		let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
		return text.isEmpty ? nil : text
	}
}
