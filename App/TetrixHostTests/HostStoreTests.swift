import Foundation
import Testing
@testable import TetrixHost

/// Drives a store against a host that lives in memory.
@MainActor
private final class Harness {
	/// What the store said for VoiceOver, in order.
	final class Heard {
		var lines: [String] = []
	}

	let service: FixtureHostService
	let supervisor: FixtureHostSupervisor
	let store: HostStore
	let heard = Heard()
	private var loop: Task<Void, Never>?

	init(running: Bool = true, status: HostStatus = .fixture()) {
		service = FixtureHostService(status: status)
		supervisor = FixtureHostSupervisor(service: service, running: running)
		let heard = heard
		store = HostStore(supervisor: supervisor) { heard.lines.append($0) }
	}

	var said: [String] { heard.lines }

	func start() {
		let store = store
		loop = Task { await store.run() }
	}

	func stop() {
		loop?.cancel()
	}

	/// Waits until a condition holds, or fails the test after two seconds.
	func wait(for what: String, _ condition: () -> Bool) async {
		for _ in 0..<200 {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(10))
		}
		Issue.record("Timed out waiting for \(what)")
	}

	func connect() async {
		start()
		await wait(for: "the first status") { store.phase == .running && service.listenerCount == 1 }
	}
}

@Suite("Host store")
@MainActor
struct HostStoreTests {
	@Test("The store connects, fetches the status, and listens for events")
	func connects() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		#expect(harness.store.phase == .running)
		#expect(harness.store.status?.devices.count == 2)
		#expect(harness.service.statusFetches == 1)
	}

	@Test("With no host the store reads as stopped")
	func stopped() async {
		let harness = Harness(running: false)
		harness.start()
		defer { harness.stop() }
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }

		#expect(harness.store.status == nil)
		#expect(!harness.store.canStop)
	}

	@Test("Start brings the host up, and stop takes down a host the app started")
	func startAndStop() async {
		let harness = Harness(running: false)
		harness.start()
		defer { harness.stop() }
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }

		await harness.store.start()
		await harness.wait(for: "the running phase") { harness.store.phase == .running }
		#expect(harness.store.ownsHost)
		#expect(harness.store.canStop)

		await harness.store.stop()
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }
		#expect(harness.store.status == nil)
	}

	@Test("A host the app did not start cannot be stopped from the app")
	func cannotStopBackgroundHost() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		#expect(!harness.store.ownsHost)
		#expect(!harness.store.canStop)
		await harness.store.stop()
		#expect(harness.store.phase == .running)
	}

	@Test("A changed event refetches the status")
	func changedRefetches() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		harness.service.mutate { $0.host.name = "Attic" }
		await harness.wait(for: "the new name") { harness.store.status?.host.name == "Attic" }
		#expect(harness.service.statusFetches == 2)
	}

	@Test("A burst of changed events costs at most two fetches")
	func coalescesBursts() async throws {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		let before = harness.service.statusFetches

		harness.service.edit { $0.host.name = "Cellar" }
		for _ in 0..<25 { harness.service.emit(.changed) }
		try await Task.sleep(for: .milliseconds(450))

		// One fetch answers the burst. A second follows only if part of the
		// burst arrived while the first was on its way.
		let fetches = harness.service.statusFetches - before
		#expect(fetches >= 1)
		#expect(fetches <= 2)
		#expect(harness.store.status?.host.name == "Cellar")
	}

	@Test("A stream of changed events costs at most one fetch per 150 ms")
	func limitsFetchRate() async throws {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		let before = harness.service.statusFetches

		// Thirty events over about 450 ms.
		let clock = ContinuousClock()
		let started = clock.now
		for index in 0..<30 {
			harness.service.edit { $0.stats.requests = Int64(index) }
			harness.service.emit(.changed)
			try await Task.sleep(for: .milliseconds(15))
		}
		try await Task.sleep(for: .milliseconds(300))
		let elapsed = clock.now - started

		let fetches = harness.service.statusFetches - before
		let allowed = Int(elapsed / HostStore.refreshInterval) + 1
		#expect(fetches >= 2)
		#expect(fetches <= allowed)
		#expect(fetches < 30)
		// The last fetch came after the last change.
		#expect(harness.store.status?.stats.requests == 29)
	}

	@Test("A load event updates the live rows without a fetch")
	func appliesLoad() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		let before = harness.service.statusFetches

		var load = Load()
		load.memoryUsedBytes = 9_000_000_000
		load.cpuPercent = 71.5
		harness.service.emit(.load(load))
		await harness.wait(for: "the load") { harness.store.status?.load.cpuPercent == 71.5 }
		#expect(harness.store.status?.load.memoryUsedBytes == 9_000_000_000)
		#expect(harness.service.statusFetches == before)
	}

	@Test("Pull events drive the download, and a cancelled one goes away")
	func appliesPull() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		var pull = PullProgress()
		pull.engine = "ollama"
		pull.name = "qwen3:14b"
		pull.status = "Downloading"
		pull.completed = 25
		pull.total = 100
		harness.service.emit(.pull(pull))
		await harness.wait(for: "the download") { harness.store.activePulls.count == 1 }
		#expect(harness.store.pullFraction == 0.25)

		pull.completed = 100
		pull.status = "Done"
		pull.done = true
		harness.service.emit(.pull(pull))
		await harness.wait(for: "the download to end") { harness.store.activePulls.isEmpty }
		#expect(harness.store.pullFraction == nil)
		// A finished download stays until dismissed, so the sheet can say how it ended.
		#expect(harness.store.shownPulls.count == 1)
		harness.store.dismissFinishedDownloads()
		#expect(harness.store.shownPulls.isEmpty)

		pull.done = false
		pull.status = "Downloading"
		harness.service.emit(.pull(pull))
		await harness.wait(for: "the second download") { harness.store.activePulls.count == 1 }
		pull.done = true
		pull.status = "Cancelled"
		pull.error = "cancelled"
		harness.service.emit(.pull(pull))
		await harness.wait(for: "the cancel") { harness.store.shownPulls.isEmpty }
	}

	@Test("A request event joins the recent list and lights its path")
	func appliesRequest() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		let count = harness.store.status?.stats.recent.count ?? 0

		var record = RequestRecord()
		record.id = "r999"
		record.at = .now
		record.deviceId = Fixture.phoneID
		record.source = "tunnel"
		record.role = .quick
		record.status = 200
		record.tokensOut = 12
		harness.service.emit(.request(record))
		await harness.wait(for: "the request") { harness.store.status?.stats.recent.first?.id == "r999" }

		#expect(harness.store.status?.stats.recent.count == count + 1)
		#expect(harness.store.glows.count == 1)
		#expect(harness.store.glows.first?.deviceID == Fixture.phoneID)
		#expect(harness.store.glows.first?.role == .quick)

		// The same record twice is one row.
		harness.service.emit(.request(record))
		await harness.wait(for: "the second glow") { harness.store.glows.count == 2 }
		#expect(harness.store.status?.stats.recent.count == count + 1)
	}

	@Test("A paired event adds the device and finishes the pairing")
	func appliesPaired() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.beginPairing()
		guard case .offered(let offer) = harness.store.pairing else {
			Issue.record("Expected an offer")
			return
		}
		#expect(offer.link.hasPrefix("tetrix-host://pair/"))

		var device = Device()
		device.id = "d_new"
		device.name = "Kitchen iPad"
		device.app = "Cue"
		// The host saves the device, then sends the event.
		harness.service.edit { [device] in $0.devices.append(device) }
		harness.service.emit(.paired(device))
		await harness.wait(for: "the pairing") { harness.store.pairing == .paired(device) }
		#expect(harness.store.status?.devices.contains { $0.id == "d_new" } == true)

		// The code was used, so closing the sheet cancels nothing.
		await harness.store.endPairing()
		#expect(harness.store.pairing == .idle)
		#expect(!harness.service.calls.contains("cancelPairing"))
	}

	@Test("Closing the sheet before a device pairs cancels the code")
	func cancelsOpenCode() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.beginPairing()
		await harness.store.endPairing()
		#expect(harness.service.calls == ["startPairing", "cancelPairing"])
		#expect(harness.service.currentStatus.pairing == nil)
	}

	@Test("An action taken while the app is still connecting waits for the host")
	func actionWaitsForConnection() async {
		let harness = Harness()
		harness.start()
		defer { harness.stop() }

		// No wait for the first status: the sheet can open this early.
		await harness.store.beginPairing()
		guard case .offered = harness.store.pairing else {
			Issue.record("Expected an offer, got \(harness.store.pairing)")
			return
		}
		await harness.store.endPairing()
	}

	@Test("An action taken while the host is stopped fails at once")
	func actionFailsWhenStopped() async {
		let harness = Harness(running: false)
		harness.start()
		defer { harness.stop() }
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }

		let clock = ContinuousClock()
		let started = clock.now
		await harness.store.beginPairing()
		#expect(harness.store.pairing == .failed("The host is not running."))
		#expect(clock.now - started < .milliseconds(500))
		await harness.store.endPairing()
	}

	@Test("The store reconnects when the event stream drops")
	func reconnects() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		harness.service.edit { $0.host.name = "Back again" }
		harness.service.dropStreams()
		await harness.wait(for: "the reconnect") { harness.store.status?.host.name == "Back again" && harness.service.listenerCount == 1 }
		#expect(harness.store.phase == .running)
		#expect(harness.supervisor.connects >= 2)
	}

	@Test("The store follows a host that goes away and comes back")
	func followsRestart() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		harness.supervisor.setRunning(false)
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }
		#expect(harness.store.status == nil)

		harness.supervisor.setRunning(true)
		await harness.wait(for: "the return") { harness.store.phase == .running }
		#expect(harness.store.status != nil)
	}

	@Test("Backoff doubles up to its ceiling and resets")
	func backoff() {
		var backoff = Backoff()
		#expect(backoff.next() == .milliseconds(250))
		#expect(backoff.next() == .milliseconds(500))
		#expect(backoff.next() == .seconds(1))
		#expect(backoff.next() == .seconds(2))
		#expect(backoff.next() == .seconds(4))
		#expect(backoff.next() == .seconds(5))
		#expect(backoff.next() == .seconds(5))
		backoff.reset()
		#expect(backoff.next() == .milliseconds(250))
	}

	@Test("Role actions send what the host expects")
	func roleActions() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.setModel(Fixture.quickModelID, for: .deep)
		await harness.store.setSingle(true)
		#expect(harness.service.calls == ["setRoles \(Fixture.quickModelID) -", "setRoles - "])
		await harness.wait(for: "one model for everything") { harness.store.status?.roles.single == true }

		// Turning it off gives quick work the smallest other model.
		await harness.store.setSingle(false)
		#expect(harness.service.calls.last == "setRoles - \(Fixture.deepModelID)")
	}

	@Test("A failed action leaves a notice a person can read")
	func failureNotice() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.renameDevice(id: "d_missing", to: "Nobody")
		#expect(harness.store.notice == "No such device, or the name is empty.")

		await harness.store.renameDevice(id: Fixture.phoneID, to: "  Pocket  ")
		#expect(harness.store.notice == nil)
		await harness.wait(for: "the rename") { harness.store.status?.device(id: Fixture.phoneID)?.name == "Pocket" }
	}

	@Test("Unpairing removes the device")
	func unpair() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.unpair(deviceID: Fixture.phoneID)
		await harness.wait(for: "the device to go") { harness.store.status?.devices.count == 1 }
		#expect(harness.store.status?.device(id: Fixture.phoneID) == nil)
	}

	@Test("A setting that the host takes reports that it saved, and one that changes nothing does not")
	func savesReport() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		#expect(await harness.store.renameHost("Attic"))
		#expect(await harness.store.renameHost("Studio") == false)
		#expect(await harness.store.renameHost("   ") == false)
		#expect(await harness.store.setRelay("wss://relay.example.com"))
		#expect(await harness.store.renameDevice(id: Fixture.phoneID, to: "Pocket"))
		#expect(await harness.store.renameDevice(id: "d_missing", to: "Nobody") == false)
		#expect(harness.service.calls == ["updateSettings", "updateSettings", "renameDevice \(Fixture.phoneID) Pocket", "renameDevice d_missing Nobody"])
	}

	@Test("A notice is spoken when it appears, and goes when dismissed")
	func noticeIsAnnounced() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		await harness.store.renameDevice(id: "d_missing", to: "Nobody")
		#expect(harness.store.notice == "No such device, or the name is empty.")
		#expect(harness.said == ["No such device, or the name is empty."])
		harness.store.dismissNotice()
		#expect(harness.store.notice == nil)

		// One model for everything cannot turn off with one model installed.
		harness.service.edit { status in
			status.engines[0].models.removeLast()
			status.roles.quick = ""
			status.roles.single = true
		}
		harness.service.emit(.changed)
		await harness.wait(for: "the one model") { harness.store.status?.models.count == 1 }
		await harness.store.setSingle(false)
		#expect(harness.said.last == "Download a second model to give quick work its own.")
	}

	@Test("VoiceOver hears a device pair, by name")
	func pairingIsAnnounced() async {
		let harness = Harness()
		// A code that is good for ten minutes from now.
		harness.service.edit { $0.load.at = .now }
		await harness.connect()
		defer { harness.stop() }

		await harness.store.beginPairing()
		var device = Device()
		device.id = "d_new"
		device.name = "Kitchen iPad"
		device.app = "Cue"
		harness.service.emit(.paired(device))
		await harness.wait(for: "the pairing") { harness.store.pairing == .paired(device) }
		#expect(harness.said == ["Paired with Cue on Kitchen iPad."])
		await harness.store.endPairing()
	}

	@Test("VoiceOver hears a pairing code expire, and a pairing fail")
	func pairingEndsAreAnnounced() async {
		let harness = Harness()
		// A code with a fifth of a second left.
		harness.service.edit { $0.load.at = Date.now.addingTimeInterval(0.2 - 600) }
		await harness.connect()
		defer { harness.stop() }

		await harness.store.beginPairing()
		await harness.wait(for: "the expiry") { harness.said.contains("The pairing code expired.") }
		await harness.store.endPairing()

		// A code closed before it runs out says nothing.
		harness.service.edit { $0.load.at = Date.now.addingTimeInterval(0.2 - 600) }
		await harness.store.beginPairing()
		await harness.store.endPairing()
		try? await Task.sleep(for: .milliseconds(400))
		#expect(harness.said.filter { $0 == "The pairing code expired." }.count == 1)

		harness.service.fail(with: HostError(message: "The tunnel is off.", code: "tunnel_off", status: 409))
		await harness.store.beginPairing()
		#expect(harness.store.pairing == .failed("The tunnel is off."))
		#expect(harness.said.last == "The tunnel is off.")
		await harness.store.endPairing()
	}

	@Test("VoiceOver hears a download finish or fail, with the model's name, once")
	func downloadsAreAnnounced() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		var pull = PullProgress()
		pull.engine = "ollama"
		pull.name = "qwen3:14b"
		pull.status = "Downloading"
		pull.total = 100
		harness.service.emit(.pull(pull))
		pull.completed = 100
		pull.done = true
		harness.service.emit(.pull(pull))
		// The host may send the last event twice.
		harness.service.emit(.pull(pull))
		await harness.wait(for: "the download to end") { harness.store.shownPulls.first?.done == true }
		#expect(harness.said == ["Downloaded qwen3:14b."])

		var failed = PullProgress()
		failed.engine = "ollama"
		failed.name = "gemma3:27b"
		failed.done = true
		failed.error = "The disk is full."
		harness.service.emit(.pull(failed))
		await harness.wait(for: "the failure") { harness.store.shownPulls.count == 2 }
		#expect(harness.said.last == "The download of gemma3:27b failed. The disk is full.")

		// A download a person stopped says nothing.
		var stopped = PullProgress()
		stopped.engine = "ollama"
		stopped.name = "qwen3:32b"
		stopped.done = true
		stopped.error = "cancelled"
		harness.service.emit(.pull(stopped))
		harness.service.mutate { $0.host.name = "Marker" }
		await harness.wait(for: "the marker") { harness.store.status?.host.name == "Marker" }
		#expect(harness.said.count == 2)
	}

	@Test("VoiceOver hears the connection drop and return")
	func connectionIsAnnounced() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		// Finding the host at launch is not news.
		#expect(harness.said.isEmpty)

		harness.service.dropStreams()
		await harness.wait(for: "the return") { harness.said.count == 2 }
		#expect(harness.said == ["The connection to the host dropped.", "The host is connected again."])

		// A host that goes away is said once, however long it stays away.
		harness.supervisor.setRunning(false)
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }
		harness.supervisor.setRunning(true)
		await harness.wait(for: "the second return") { harness.store.phase == .running }
		#expect(harness.said == [
			"The connection to the host dropped.", "The host is connected again.",
			"The connection to the host dropped.", "The host is connected again.",
		])
	}

	@Test("VoiceOver hears a host start and stop when a person asks for it")
	func startAndStopAreAnnounced() async {
		let harness = Harness(running: false)
		harness.start()
		defer { harness.stop() }
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }
		#expect(harness.said.isEmpty)

		await harness.store.start()
		await harness.wait(for: "the running phase") { harness.store.phase == .running }
		#expect(harness.said == ["The host started."])

		await harness.store.stop()
		await harness.wait(for: "the stopped phase") { harness.store.phase == .stopped }
		#expect(harness.said == ["The host started.", "The host stopped."])
		#expect(harness.store.showsStop == false)
		#expect(harness.store.canToggleRunning)
	}

	@Test("VoiceOver hears a chat answer finish or fail")
	func chatIsAnnounced() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }

		var said: [String] = []
		let chat = ChatSession { said.append($0) }
		chat.draft = "Is it private?"
		chat.send(using: harness.store)
		await harness.wait(for: "the answer") { !chat.isStreaming }
		#expect(said == ["The answer is finished."])

		harness.service.fail(with: HostError(message: "This host has no model assigned yet.", code: "no_model_assigned", status: 503))
		chat.draft = "Hello"
		chat.send(using: harness.store)
		await harness.wait(for: "the failure") { !chat.isStreaming }
		#expect(said.last == "The answer failed. This host has no model assigned yet.")
	}

	@Test("A chat streams into the conversation, with its reasoning kept apart")
	func chat() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		harness.service.setAnswer(ChatDelta(content: "It stays here.", reasoning: "Keep it short."))

		let chat = ChatSession()
		chat.role = .quick
		chat.draft = "Where does my prompt go?"
		#expect(chat.canSend)
		chat.send(using: harness.store)
		await harness.wait(for: "the answer") { !chat.isStreaming }

		#expect(chat.messages.count == 2)
		#expect(chat.messages[0].speaker == .person)
		#expect(chat.messages[1].text.trimmingCharacters(in: .whitespaces) == "It stays here.")
		#expect(chat.messages[1].reasoning == "Keep it short.")
		#expect(!chat.messages[1].reasoningExpanded)
		#expect(chat.messages[1].state == .done)
		#expect(chat.messages[1].speed == 57.5)
		#expect(harness.service.calls.contains("chat quick"))
		#expect(chat.draft.isEmpty)
	}

	@Test("An answer too short to measure shows no speed, not an older answer's")
	func chatSpeedUnknown() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		harness.service.setAnswer(ChatDelta(content: "Yes."), speed: nil)

		let chat = ChatSession()
		chat.draft = "Is it private?"
		chat.send(using: harness.store)
		await harness.wait(for: "the answer") { !chat.isStreaming }
		#expect(chat.messages.last?.state == .done)
		#expect(chat.messages.last?.speed == 0)
	}

	@Test("A chat that fails shows the host's words")
	func chatFailure() async {
		let harness = Harness()
		await harness.connect()
		defer { harness.stop() }
		harness.service.fail(with: HostError(message: "This host has no model assigned yet.", code: "no_model_assigned", status: 503))

		let chat = ChatSession()
		chat.draft = "Hello"
		chat.send(using: harness.store)
		await harness.wait(for: "the failure") { !chat.isStreaming }
		#expect(chat.messages.last?.state == .failed("This host has no model assigned yet."))
	}
}
