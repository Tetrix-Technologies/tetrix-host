import CryptoKit
import Foundation
import Testing
@testable import TetrixHost

@Suite("Formatting")
@MainActor
struct FormattingTests {
	private let now = Fixture.now

	@Test("Memory counts in powers of 1024")
	func memory() {
		#expect(Format.memory(17_179_869_184) == "16 GB")
		#expect(Format.memory(12_459_261_952) == "11.6 GB")
		#expect(Format.memory(8 << 20) == "8 MB")
		#expect(Format.memory(0) == "0 bytes")
	}

	@Test("Storage counts in powers of 1000")
	func storage() {
		#expect(Format.storage(245_107_195_904) == "245.1 GB")
		#expect(Format.storage(5_225_000_000) == "5.2 GB")
		#expect(Format.storage(522_653_767) == "523 MB")
		#expect(Format.storage(2_000_000_000_000) == "2 TB")
	}

	@Test("Download progress reads as in the sheet")
	func progress() {
		#expect(Format.progress(completed: 7_400_000_000, total: 11_400_000_000) == "7.4 GB of 11.4 GB")
		#expect(Format.progress(completed: 0, total: 0) == "")
		#expect(Format.progress(completed: 3_000_000, total: 0) == "3 MB")
		#expect(Format.percent(0.649) == "65 percent")
		#expect(Format.percentShort(0.274) == "27%")
		#expect(Format.percent(4) == "100 percent")
	}

	@Test("A window that is cut shows both figures")
	func window() {
		#expect(Format.window(supported: 40_960, inUse: nil) == "40,960 tokens")
		#expect(Format.window(supported: 40_960, inUse: 40_960) == "40,960 tokens")
		// The smaller figure is the one that limits a request.
		#expect(Format.window(supported: 40_960, inUse: 4_096) == "4,096 of 40,960 tokens")
		#expect(Format.window(supported: nil, inUse: 4_096) == "4,096 tokens")
		#expect(Format.window(supported: nil, inUse: nil) == "Unknown")

		var model = Model()
		model.contextLength = 40_960
		#expect(!model.windowIsCut(asked: 32_768))
		// The model server ignored the window the host asked for.
		model.contextInUse = 4_096
		#expect(model.windowIsCut(asked: 32_768))
		// The host asked for 32,768 and got it. Supporting more is not a fault.
		model.contextInUse = 32_768
		#expect(!model.windowIsCut(asked: 32_768))
		// The host never asks for more than the model has.
		model.contextInUse = 40_960
		#expect(!model.windowIsCut(asked: 65_536))
		// With the window left to the model server, anything under the
		// model's own limit is a cut.
		model.contextInUse = 4_096
		#expect(model.windowIsCut(asked: 0))

		var roles = Roles()
		roles.window.deep = 32_768
		roles.window.quick = 8_192
		roles.single = false
		#expect(roles.askedWindow(for: .deep) == 32_768)
		#expect(roles.askedWindow(for: .quick) == 8_192)
		roles.single = true
		#expect(roles.askedWindow(for: .quick) == 32_768)
		#expect(roles.askedWindow(for: .all) == 32_768)
	}

	@Test("Counts are grouped, and one token is singular")
	func counts() {
		#expect(Format.count(104_870) == "104,870")
		#expect(Format.tokens(1) == "1 token")
		#expect(Format.tokens(40_960) == "40,960 tokens")
		#expect(Format.context(nil) == "")
	}

	@Test("Speed reads in tokens a second")
	func speed() {
		#expect(Format.speed(42.3) == "42 tokens a second")
		#expect(Format.speed(6.25) == "6.3 tokens a second" || Format.speed(6.25) == "6.2 tokens a second")
		#expect(Format.speed(0) == "")
	}

	@Test("Uptime keeps the two largest units")
	func uptime() {
		#expect(Format.uptime(from: now.addingTimeInterval(-20), to: now) == "Less than a minute")
		#expect(Format.uptime(from: now.addingTimeInterval(-60), to: now) == "1 minute")
		#expect(Format.uptime(from: now.addingTimeInterval(-(2 * 3_600 + 14 * 60)), to: now) == "2 hours 14 minutes")
		#expect(Format.uptime(from: now.addingTimeInterval(-3_600), to: now) == "1 hour")
		#expect(Format.uptime(from: now.addingTimeInterval(-(3 * 86_400 + 3_600)), to: now) == "3 days 1 hour")
		#expect(Format.uptime(from: nil, to: now) == "")
	}

	@Test("A device is connected, or was seen some time ago")
	func deviceState() {
		var device = Device()
		device.online = true
		#expect(Format.deviceState(device, now: now) == "Connected")
		device.online = false
		#expect(Format.deviceState(device, now: now) == "Not seen yet")
		device.lastSeenAt = now.addingTimeInterval(-3 * 3_600 - 240)
		#expect(Format.deviceState(device, now: now) == "Seen 3 h ago")
		device.lastSeenAt = now.addingTimeInterval(-60)
		#expect(Format.deviceState(device, now: now) == "Seen 1 min ago")
		device.lastSeenAt = now.addingTimeInterval(-10)
		#expect(Format.deviceState(device, now: now) == "Seen just now")
		device.lastSeenAt = now.addingTimeInterval(-2 * 86_400)
		#expect(Format.deviceState(device, now: now) == "Seen 2 days ago")
	}

	@Test("Relative times are short on screen and in whole words for VoiceOver")
	func relativeTimes() {
		func ago(_ seconds: TimeInterval) -> String { Format.ago(now.addingTimeInterval(-seconds), now: now) }
		func spoken(_ seconds: TimeInterval) -> String { Format.agoSpoken(now.addingTimeInterval(-seconds), now: now) }
		#expect(ago(59) == "just now")
		#expect(ago(60) == "1 min ago")
		#expect(ago(25 * 60) == "25 min ago")
		#expect(ago(59 * 60 + 59) == "59 min ago")
		#expect(ago(3_600) == "1 h ago")
		#expect(ago(3 * 3_600 + 240) == "3 h ago")
		#expect(ago(86_400) == "1 day ago")
		#expect(ago(9 * 86_400) == "9 days ago")
		// A time in the future, from a clock that runs ahead, reads as now.
		#expect(ago(-30) == "just now")

		#expect(spoken(25 * 60) == "25 minutes ago")
		#expect(spoken(3_600) == "1 hour ago")
		#expect(spoken(3 * 3_600) == "3 hours ago")
		#expect(spoken(2 * 86_400) == "2 days ago")
	}

	@Test("While the tunnel is off every device reads Unreachable")
	func unreachable() {
		var device = Device()
		device.online = true
		device.lastSeenAt = now.addingTimeInterval(-60)
		#expect(Format.deviceState(device, now: now, tunnelOff: true) == "Unreachable")
		device.online = false
		#expect(Format.deviceState(device, now: now, tunnelOff: true) == "Unreachable")
		#expect(Format.deviceState(device, now: now, tunnelOff: false, spoken: true) == "Seen 1 minute ago")
		// The dot is filled only for a device that is connected and reachable.
		device.online = true
		#expect(DeviceCard.tone(for: device, tunnelOff: false) == .healthy)
		#expect(DeviceCard.tone(for: device, tunnelOff: true) == .off)
	}

	@Test("A device's app reads with its version")
	func app() {
		var device = Device()
		#expect(Format.app(device) == "Device")
		device.app = "Cue"
		#expect(Format.app(device) == "Cue")
		device.appVersion = "2.4.0"
		#expect(Format.app(device) == "Cue 2.4.0")
	}

	@Test("A relay address is a WebSocket URL, and a bad one says why")
	func relayAddress() {
		#expect(Format.relayProblem("wss://relay.tetrix.tech") == nil)
		#expect(Format.relayProblem("ws://127.0.0.1:8787") == nil)
		#expect(Format.relayProblem("  WSS://Relay.example.com/path  ") == nil)
		#expect(Format.relayProblem("https://relay.tetrix.tech") == "A relay address starts with wss:// or ws://.")
		#expect(Format.relayProblem("relay.tetrix.tech") == "A relay address starts with wss:// or ws://.")
		#expect(Format.relayProblem("") == "A relay address starts with wss:// or ws://.")
		#expect(Format.relayProblem("wss://") == "The relay address names no server.")
		#expect(SettingField.nameProblem("") == "A name cannot be empty.")
		#expect(SettingField.nameProblem("Attic") == nil)
	}

	@Test("Durations and countdowns")
	func durations() {
		#expect(Format.duration(milliseconds: 313) == "313 ms")
		#expect(Format.duration(milliseconds: 12_480) == "12.5 s")
		#expect(Format.duration(milliseconds: 125_000) == "2 min 5 s")
		#expect(Format.countdown(to: now.addingTimeInterval(581), now: now) == "9:41")
		#expect(Format.countdown(to: now.addingTimeInterval(-5), now: now) == "0:00")
	}

	@Test("Capabilities read in plain words")
	func capabilities() {
		#expect(Format.capabilities(["tools", "thinking"]) == "Use tools, reason")
		#expect(Format.capabilities(["vision"]) == "See images")
		#expect(Format.capabilities(["tools", "vision", "thinking"]) == "Use tools, see images, reason")
		#expect(Format.capabilities([]) == "Chat")
		#expect(Format.capabilities(["telepathy"]) == "Chat")
	}

	@Test("The tunnel's state in one word")
	func tunnelState() {
		var tunnel = Tunnel()
		#expect(Format.tunnelState(tunnel) == "Off")
		tunnel.enabled = true
		tunnel.state = .connected
		#expect(Format.tunnelState(tunnel) == "Connected")
		tunnel.state = .connecting
		#expect(Format.tunnelState(tunnel) == "Connecting")
		tunnel.state = .offline
		#expect(Format.tunnelState(tunnel) == "Offline")
	}

	@Test("A model's name comes out of its ID")
	func modelName() {
		#expect(Format.modelName(fromID: "ollama/qwen3:8b") == "qwen3:8b")
		#expect(Format.modelName(fromID: "lm/org/model") == "org/model")
		#expect(Format.modelName(fromID: "plain") == "plain")
	}

	@Test("Each card reads as one sentence")
	func summaries() {
		let status = HostStatus.fixture()
		#expect(CardSummary.machine(name: status.host.name, status.hardware, load: status.load) == "This machine, Studio, Mac mini, Apple M4, 16 GB memory, 212.6 GB free, 10.8 GB of memory in use, processor at 27 percent.")
		// A stopped host has no name of its own and no live reading.
		#expect(CardSummary.machine(status.hardware, load: nil) == "This machine, Mac mini, Apple M4, 16 GB memory, 212.6 GB free.")
		#expect(CardSummary.machine(name: "Studio", status.hardware, load: nil, problem: .machine(engines: [])) == "This machine, Studio, Mac mini, Apple M4, 16 GB memory, 212.6 GB free, no model server.")
		#expect(CardSummary.device(status.devices[0], now: now, tunnelOff: true) == "Cue on Noah's MacBook Pro, macOS, 128 requests. Unreachable. The tunnel is off.")
		#expect(CardSummary.device(status.devices[0], now: now) == "Cue on Noah's MacBook Pro, macOS, connected, 128 requests.")
		#expect(CardSummary.device(status.devices[1], now: now) == "Cue on Noah's iPhone, iOS, seen 3 hours ago, 14 requests.")
		#expect(CardSummary.tunnel(status.tunnel) == "Tunnel, relay relay.tetrix.tech, connected.")
		#expect(CardSummary.model(slot: .deep, modelID: Fixture.deepModelID, model: status.model(for: .deep)) == "Deep work, model qwen3:8b, 5.2 GB, context of 40,960 tokens, can use tools, reason, in memory.")
		#expect(CardSummary.model(slot: .all, modelID: "ollama/gone:1b", model: nil) == "All work, model gone:1b, not available.")
	}
}

@Suite("What a card and the toolbar show")
@MainActor
struct PresentationTests {
	private let status = HostStatus.fixture()

	@Test("The machine card takes the host's name, and the computer's own name while the host is stopped")
	func machineTitle() {
		#expect(MachineCard.title(name: "Studio", hardware: status.hardware) == "Studio")
		#expect(MachineCard.title(name: nil, hardware: status.hardware) == "Mac mini")
		#expect(MachineCard.title(name: "", hardware: status.hardware) == "Mac mini")
		#expect(MachineCard.title(name: nil, hardware: Hardware()) == "This machine")
	}

	@Test("A card names what is wrong with it: waiting or failed")
	func cardProblems() {
		var tunnel = status.tunnel
		#expect(CardProblem.tunnel(tunnel) == nil)
		tunnel.state = .connecting
		#expect(CardProblem.tunnel(tunnel) == CardProblem(level: .waiting, text: "Connecting"))
		tunnel.state = .offline
		#expect(CardProblem.tunnel(tunnel) == CardProblem(level: .failed, text: "Offline"))
		// A tunnel a person turned off is not a problem.
		tunnel.enabled = false
		#expect(CardProblem.tunnel(tunnel) == nil)

		#expect(CardProblem.machine(engines: status.engines) == nil)
		var silent = status.engines[0]
		silent.state = "unreachable"
		#expect(CardProblem.machine(engines: [silent]) == CardProblem(level: .waiting, text: "No model server"))
		#expect(CardProblem.machine(engines: []) == CardProblem(level: .waiting, text: "No model server"))
		#expect(CardProblem.machine(engines: [status.engines[0], silent]) == CardProblem(level: .waiting, text: "A server is down"))

		#expect(CardProblem.model(status.model(for: .deep)) == nil)
		#expect(CardProblem.model(nil) == CardProblem(level: .waiting, text: "Not available"))
		#expect(CardProblem.Level.waiting.color == Palette.harvest)
		#expect(CardProblem.Level.failed.color == Palette.rust)
	}

	@Test("The toolbar dot follows the health of the host")
	func health() {
		#expect(status.health == .healthy)
		#expect(status.healthSummary == "Running.")

		var connecting = status
		connecting.tunnel.state = .connecting
		#expect(connecting.health == .waiting)
		#expect(connecting.healthSummary == "The tunnel is connecting.")

		var offline = status
		offline.tunnel.state = .offline
		#expect(offline.health == .failed)
		#expect(offline.healthSummary == "The tunnel is offline.")

		var noServer = status
		noServer.engines[0].state = "unreachable"
		#expect(noServer.health == .waiting)
		#expect(noServer.healthSummary == "No model server is answering.")

		// A tunnel a person turned off is healthy: nothing is wrong.
		var off = status
		off.tunnel.enabled = false
		off.tunnel.state = .disabled
		#expect(off.health == .healthy)
		// Off and stale: the last state the tunnel had does not count.
		off.tunnel.state = .offline
		#expect(off.health == .healthy)

		// A failure outranks a wait, and the summary names both.
		var both = offline
		both.engines[0].state = "unreachable"
		#expect(both.health == .failed)
		#expect(both.healthSummary == "The tunnel is offline. No model server is answering.")
	}

	@Test("One model for everything reads as off while no model is assigned")
	func oneModelSwitch() {
		var roles = Roles()
		#expect(roles.single)
		#expect(!roles.usesOneModel)
		roles.deep = Fixture.deepModelID
		#expect(roles.usesOneModel)
		roles.quick = Fixture.quickModelID
		roles.single = false
		#expect(!roles.usesOneModel)
	}

	@Test("A load meter turns to the warning color at 90 percent")
	func meterFill() {
		#expect(MeterBar.fill(for: 0) == Palette.inkSoft)
		#expect(MeterBar.fill(for: 0.899) == Palette.inkSoft)
		#expect(MeterBar.fill(for: 0.9) == Palette.harvest)
		#expect(MeterBar.fill(for: 1) == Palette.harvest)
	}

	@Test("The open drawer takes its usual height, or 40 percent of a short window")
	func drawerHeight() {
		#expect(ChatDrawer.openHeight(inContent: 1_000) == Metrics.drawerHeight)
		#expect(ChatDrawer.openHeight(inContent: 750) == 300)
		#expect(ChatDrawer.openHeight(inContent: 608) == 243)
		#expect(ChatDrawer.openHeight(inContent: 0) == 0)
	}

	@Test("A download's status line shows only when it adds something")
	func downloadStatusLine() {
		var pull = PullProgress()
		pull.name = "qwen3:14b"
		pull.status = "Downloading"
		#expect(PullProgressView.statusLine(for: pull) == nil)
		pull.status = "Starting"
		#expect(PullProgressView.statusLine(for: pull) == "Starting")
		pull.status = "Verifying"
		#expect(PullProgressView.statusLine(for: pull) == "Checking the download")
		pull.status = "Finishing"
		#expect(PullProgressView.statusLine(for: pull) == "Finishing")
		pull.done = true
		#expect(PullProgressView.statusLine(for: pull) == "Downloaded. The model is ready to use.")
		pull.error = "The disk is full."
		#expect(PullProgressView.statusLine(for: pull) == "The disk is full.")
		#expect(Format.percentShort(1.0 / 3) == "33%")
	}

	@Test("A request from a device that was unpaired says so")
	func recentSource() {
		var record = RequestRecord()
		#expect(RecentRow.source(of: record, deviceName: nil) == "This machine")
		record.deviceId = Fixture.phoneID
		#expect(RecentRow.source(of: record, deviceName: "Noah's iPhone") == "Noah's iPhone")
		#expect(RecentRow.source(of: record, deviceName: nil) == "Unpaired device")
	}

	@Test("A model picker lists the installed models, and what is chosen when that is none of them")
	func pickerOptions() {
		let models = status.models
		#expect(ModelPicker.options(models: models, selection: Fixture.deepModelID).map(\.title) == ["qwen3:8b", "gemma3:4b"])
		#expect(ModelPicker.options(models: models, selection: "").map(\.title) == ["None", "qwen3:8b", "gemma3:4b"])
		#expect(ModelPicker.options(models: models, selection: "ollama/gone:1b").first == MenuChoice.Option(id: "ollama/gone:1b", title: "gone:1b"))
	}
}

@Suite("Model suggestions")
struct ModelCatalogTests {
	@Test("A 16 GB machine is offered models that fit and one that does not")
	func sixteenGigabytes() {
		let suggestions = ModelCatalog.suggestions(memoryBytes: 16 << 30)
		#expect(suggestions.count <= ModelCatalog.limit)
		#expect(suggestions.contains { $0.fits && $0.entry.role == .deep })
		#expect(suggestions.contains { $0.fits && $0.entry.role == .quick })
		#expect(suggestions.filter { !$0.fits }.count == 1)
		#expect(suggestions.first { $0.entry.name == "qwen3:14b" }?.fits == true)
		#expect(suggestions.first { !$0.fits }?.entry.name == "gpt-oss:20b")
	}

	@Test("The download sheet starts on the first suggestion that fits")
	func firstChoice() {
		let suggestions = ModelCatalog.suggestions(memoryBytes: 16 << 30)
		#expect(ModelCatalog.firstChoice(in: suggestions) == "qwen3:14b")
		#expect(ModelCatalog.firstChoice(in: ModelCatalog.suggestions(memoryBytes: 16 << 30, installed: ["qwen3:14b"])) == "gemma3:12b")
		// A machine too small for any model gets no choice made for it.
		#expect(ModelCatalog.firstChoice(in: ModelCatalog.suggestions(memoryBytes: 1 << 30)) == nil)
		#expect(ModelCatalog.firstChoice(in: []) == nil)
	}

	@Test("An installed model is not suggested again")
	func skipsInstalled() {
		let suggestions = ModelCatalog.suggestions(memoryBytes: 16 << 30, installed: ["qwen3:14b"])
		#expect(!suggestions.contains { $0.entry.name == "qwen3:14b" })
	}

	@Test("A small machine still gets a suggestion")
	func smallMachine() {
		let suggestions = ModelCatalog.suggestions(memoryBytes: 4 << 30)
		#expect(suggestions.contains { $0.fits })
		#expect(suggestions.first?.fits == true)
	}

	@Test("A large machine fits the largest models")
	func largeMachine() {
		let suggestions = ModelCatalog.suggestions(memoryBytes: 128 << 30)
		#expect(suggestions.first?.entry.name == "gpt-oss:120b")
		#expect(suggestions.allSatisfy { $0.fits })
	}
}

@Suite("Host files")
struct HostEnvironmentTests {
	private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
	private let bundle = URL(fileURLWithPath: "/Applications/Tetrix Host.app", isDirectory: true)

	@Test("The data directory is in Application Support unless the variable moves it")
	func dataDirectory() {
		let standard = HostEnvironment(variables: [:], applicationSupport: support, bundleURL: bundle)
		#expect(standard.dataDirectory.path == "/Users/someone/Library/Application Support/Tetrix Host")
		#expect(standard.daemonFile.lastPathComponent == "daemon.json")
		#expect(standard.adminTokenFile.lastPathComponent == "admin.token")

		let moved = HostEnvironment(variables: ["TETRIX_HOST_HOME": "/tmp/host"], applicationSupport: support, bundleURL: bundle)
		#expect(moved.dataDirectory.path == "/tmp/host")

		let empty = HostEnvironment(variables: ["TETRIX_HOST_HOME": ""], applicationSupport: support, bundleURL: bundle)
		#expect(empty.dataDirectory.path == standard.dataDirectory.path)
	}

	@Test("The app looks for the host program in a fixed order")
	func binaryOrder() {
		let environment = HostEnvironment(variables: ["TETRIX_HOST_BINARY": "/opt/custom/tetrix-host"], applicationSupport: support, bundleURL: bundle)
		#expect(environment.binaryCandidates.map(\.path) == [
			"/opt/custom/tetrix-host",
			"/Applications/Tetrix Host.app/Contents/Helpers/tetrix-host",
			"/usr/local/bin/tetrix-host",
			"/opt/homebrew/bin/tetrix-host",
		])
		#expect(environment.locateBinary { $0.path.hasPrefix("/usr/local") }?.path == "/usr/local/bin/tetrix-host")
		#expect(environment.locateBinary { _ in true }?.path == "/opt/custom/tetrix-host")
		#expect(environment.locateBinary { _ in false } == nil)

		let plain = HostEnvironment(variables: [:], applicationSupport: support, bundleURL: bundle)
		#expect(plain.binaryCandidates.first?.path == "/Applications/Tetrix Host.app/Contents/Helpers/tetrix-host")
	}

	@Test("daemon.json gives the address")
	func daemonFile() throws {
		let directory = FileManager.default.temporaryDirectory.appending(path: "TetrixHostTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let file = directory.appending(path: "daemon.json")
		#expect(DaemonFile.read(from: file) == nil)

		try Data(#"{"pid":4242,"address":"127.0.0.1:4784","version":"0.1.0","startedAt":"2026-11-11T02:28:55Z"}"#.utf8).write(to: file)
		let daemon = try #require(DaemonFile.read(from: file))
		#expect(daemon.pid == 4242)
		#expect(daemon.address == "127.0.0.1:4784")

		try Data("{}".utf8).write(to: file)
		#expect(DaemonFile.read(from: file) == nil)
	}
}

@Suite("Host check")
struct HostCheckTests {
	// HMAC-SHA256 under the token "hadm_test" over the context string and a
	// nonce of 32 bytes of 0x5A. `internal/host` computes the same value in
	// LocalProof, and its test uses the same nonce.
	private let nonce = Data(repeating: 0x5A, count: 32)
	private let token = "hadm_test"

	private func proof(token: String, nonce: Data) -> String {
		var message = Data("tetrix-host/local-proof/1\0".utf8)
		message.append(nonce)
		let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(token.utf8)))
		return Data(mac).base64EncodedString()
	}

	private func answer(_ proof: String?) -> Data {
		var body: [String: Any] = ["ok": true]
		if let proof { body["proof"] = proof }
		return try! JSONSerialization.data(withJSONObject: body)
	}

	@Test("The token goes only to a listener that already holds it")
	func proofs() {
		let good = answer(proof(token: token, nonce: nonce))
		#expect(LiveHostSupervisor.proofIsValid(in: good, nonce: nonce, token: token))

		// A listener with another token, an old answer, no proof, a made-up
		// proof, or no JSON at all gets nothing.
		#expect(!LiveHostSupervisor.proofIsValid(in: answer(proof(token: "hadm_other", nonce: nonce)), nonce: nonce, token: token))
		#expect(!LiveHostSupervisor.proofIsValid(in: good, nonce: Data(repeating: 0x5B, count: 32), token: token))
		#expect(!LiveHostSupervisor.proofIsValid(in: answer(nil), nonce: nonce, token: token))
		#expect(!LiveHostSupervisor.proofIsValid(in: answer("AAAA"), nonce: nonce, token: token))
		#expect(!LiveHostSupervisor.proofIsValid(in: Data("<html>".utf8), nonce: nonce, token: token))
	}
}
