#if DEBUG
import Foundation

/// Canned data for tests and snapshots.
enum Fixture {
	/// The moment every fixture time is measured from: 11 November 2026,
	/// 2:30 pm in Brisbane.
	static let now = Date(timeIntervalSince1970: 1_794_371_400)

	static let deepModelID = "ollama/qwen3:8b"
	static let quickModelID = "ollama/gemma3:4b"
	static let laptopID = "d_7f3k2m9x"
	static let phoneID = "d_q81zc4vw"
}

extension HostStatus {
	/// A busy, healthy host: two paired devices, both roles assigned, a
	/// connected tunnel, and some recent requests.
	static func fixture(now: Date = Fixture.now) -> HostStatus {
		var status = HostStatus()
		status.product = "Tetrix Host"
		status.version = "0.1.0"

		status.host.id = "aoccscb7qz37b47z"
		status.host.name = "Studio"
		status.host.startedAt = now.addingTimeInterval(-(2 * 3_600 + 14 * 60))
		status.host.address = "127.0.0.1:4784"
		status.host.endpoint = "http://127.0.0.1:4784/v1"

		status.hardware.model = "Mac mini"
		status.hardware.kind = "desktop"
		status.hardware.chip = "Apple M4"
		status.hardware.cores = 10
		status.hardware.memoryBytes = 16 << 30
		status.hardware.diskBytes = 494_384_795_648
		status.hardware.diskFreeBytes = 212_600_000_000
		status.hardware.os = "macOS 26.1"
		status.hardware.arch = "arm64"

		status.load.memoryUsedBytes = 11_600_000_000
		status.load.cpuPercent = 27.4
		status.load.at = now

		status.tunnel.enabled = true
		status.tunnel.state = .connected
		status.tunnel.relay = "wss://relay.tetrix.tech"
		status.tunnel.since = now.addingTimeInterval(-(2 * 3_600 + 13 * 60))

		var deep = Model()
		deep.id = Fixture.deepModelID
		deep.engine = "ollama"
		deep.name = "qwen3:8b"
		deep.sizeBytes = 5_225_000_000
		deep.family = "qwen3"
		deep.parameters = "8.2B"
		deep.quantization = "Q4_K_M"
		deep.contextLength = 40_960
		deep.capabilities = ["tools", "thinking"]
		deep.loaded = true

		var quick = Model()
		quick.id = Fixture.quickModelID
		quick.engine = "ollama"
		quick.name = "gemma3:4b"
		quick.sizeBytes = 3_338_000_000
		quick.family = "gemma3"
		quick.parameters = "4.3B"
		quick.quantization = "Q4_K_M"
		quick.contextLength = 131_072
		quick.capabilities = ["vision"]
		quick.loaded = false

		var engine = Engine()
		engine.id = "ollama"
		engine.kind = "ollama"
		engine.baseURL = "http://127.0.0.1:11434"
		engine.state = "ready"
		engine.version = "0.12.6"
		engine.models = [deep, quick]
		status.engines = [engine]

		status.roles.deep = deep.id
		status.roles.quick = quick.id
		status.roles.single = false

		var laptop = Device()
		laptop.id = Fixture.laptopID
		laptop.name = "Noah's MacBook Pro"
		laptop.app = "Cue"
		laptop.appVersion = "2.4.0"
		laptop.platform = "macOS"
		laptop.publicKey = "q1b0J8mYd2sVwq3xk0c1t7pZr5n9a4eHf6uLgTiBoXs="
		laptop.pairedAt = now.addingTimeInterval(-6 * 86_400)
		laptop.lastSeenAt = now.addingTimeInterval(-40)
		laptop.online = true
		laptop.requests = 128
		laptop.tokensIn = 96_410
		laptop.tokensOut = 41_872

		var phone = Device()
		phone.id = Fixture.phoneID
		phone.name = "Noah's iPhone"
		phone.app = "Cue"
		phone.appVersion = "2.4.0"
		phone.platform = "iOS"
		phone.publicKey = "Zk4nW0c8sT1yLr6vPq2mXe9aHd3uJb7gFi5oKtCwNxE="
		phone.pairedAt = now.addingTimeInterval(-3 * 86_400)
		phone.lastSeenAt = now.addingTimeInterval(-3 * 3_600 - 240)
		phone.online = false
		phone.requests = 14
		phone.tokensIn = 6_120
		phone.tokensOut = 2_904
		status.devices = [laptop, phone]

		status.stats.requests = 147
		status.stats.tokensIn = 104_870
		status.stats.tokensOut = 45_611
		status.stats.active = 0
		status.stats.tokensPerSecond = 42.3
		status.stats.recent = [
			record("r147", secondsAgo: 42, device: laptop.id, role: .deep, model: deep.id, tokensOut: 512, durationMs: 12_480, now: now),
			record("r146", secondsAgo: 75, device: laptop.id, role: .quick, model: quick.id, tokensOut: 38, durationMs: 640, now: now),
			record("r145", secondsAgo: 190, device: nil, role: .quick, model: quick.id, tokensOut: 21, durationMs: 410, now: now),
			record("r144", secondsAgo: 420, device: laptop.id, role: .deep, model: deep.id, tokensOut: 884, durationMs: 21_300, now: now),
			record("r143", secondsAgo: 1_260, device: laptop.id, role: .quick, model: quick.id, tokensOut: 64, durationMs: 980, now: now),
			record("r142", secondsAgo: 11_040, device: phone.id, role: .deep, model: deep.id, tokensOut: 301, durationMs: 7_900, now: now),
			record("r141", secondsAgo: 11_100, device: phone.id, role: .quick, model: quick.id, tokensOut: 17, durationMs: 380, now: now),
		]
		return status
	}

	private static func record(
		_ id: String,
		secondsAgo: TimeInterval,
		device: String?,
		role: Role,
		model: String,
		tokensOut: Int,
		durationMs: Int64,
		now: Date
	) -> RequestRecord {
		var record = RequestRecord()
		record.id = id
		record.at = now.addingTimeInterval(-secondsAgo)
		record.deviceId = device
		record.source = device == nil ? "local" : "tunnel"
		record.role = role
		record.model = model
		record.status = 200
		record.durationMs = durationMs
		record.tokensIn = tokensOut * 2
		record.tokensOut = tokensOut
		record.stream = true
		return record
	}
}
#endif
