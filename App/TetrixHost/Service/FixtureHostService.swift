#if DEBUG
import Foundation
import os

/// A host that lives in memory. Tests drive the store with it, and the
/// snapshot mode draws the window from it.
final class FixtureHostService: HostService, Sendable {
	private struct State: Sendable {
		var status: HostStatus
		var listeners: [UUID: AsyncThrowingStream<HostEvent, Error>.Continuation] = [:]
		var statusFetches = 0
		var calls: [String] = []
		var failure: HostError?
		var answer = ChatDelta(content: "A host on your own machine keeps your words on your own machine.", reasoning: "")
		/// The speed the host reports after a chat. Nil leaves the number
		/// as it was, as the host does after an answer too short to measure.
		var answerSpeed: Double? = 57.5
	}

	private let state: OSAllocatedUnfairLock<State>

	init(status: HostStatus = .fixture()) {
		state = OSAllocatedUnfairLock(initialState: State(status: status))
	}

	// MARK: Test hooks

	/// How many times a client fetched the status document.
	var statusFetches: Int { state.withLock { $0.statusFetches } }
	/// The name of each call a client made, in order.
	var calls: [String] { state.withLock { $0.calls } }
	var listenerCount: Int { state.withLock { $0.listeners.count } }
	var currentStatus: HostStatus { state.withLock { $0.status } }

	/// Makes every later call fail with this error. Nil clears it.
	func fail(with error: HostError?) {
		state.withLock { $0.failure = error }
	}

	func setAnswer(_ answer: ChatDelta, speed: Double? = 57.5) {
		state.withLock {
			$0.answer = answer
			$0.answerSpeed = speed
		}
	}

	/// Changes the status without telling the listeners.
	func edit(_ change: @Sendable (inout HostStatus) -> Void) {
		state.withLock { change(&$0.status) }
	}

	/// Changes the status and sends `changed`, as the host does.
	func mutate(_ change: @Sendable (inout HostStatus) -> Void) {
		edit(change)
		emit(.changed)
	}

	func emit(_ event: HostEvent) {
		let listeners = state.withLock { Array($0.listeners.values) }
		for listener in listeners { listener.yield(event) }
	}

	/// Ends every open event stream, as a dropped connection does.
	func dropStreams() {
		let listeners = state.withLock { state -> [AsyncThrowingStream<HostEvent, Error>.Continuation] in
			defer { state.listeners.removeAll() }
			return Array(state.listeners.values)
		}
		for listener in listeners { listener.finish(throwing: URLError(.networkConnectionLost)) }
	}

	// MARK: HostService

	func status() async throws -> HostStatus {
		try state.withLock { state in
			if let failure = state.failure { throw failure }
			state.statusFetches += 1
			return state.status
		}
	}

	func events() -> AsyncThrowingStream<HostEvent, Error> {
		let id = UUID()
		return AsyncThrowingStream { continuation in
			state.withLock { $0.listeners[id] = continuation }
			continuation.onTermination = { [state] _ in
				state.withLock { _ = $0.listeners.removeValue(forKey: id) }
			}
		}
	}

	func startPairing() async throws -> PairingOffer {
		let offer = try record("startPairing") { status -> PairingOffer in
			var offer = PairingOffer()
			offer.code = "AEBY-IKII-H6DH-P4HT-7HNG-3B6D"
			offer.link = "tetrix-host://pair/\(offer.code)?relay=wss%3A%2F%2Frelay.tetrix.tech"
			offer.expiresAt = (status.load.at ?? .now).addingTimeInterval(600)
			status.pairing = offer
			return offer
		}
		emit(.changed)
		return offer
	}

	func cancelPairing() async throws {
		try record("cancelPairing") { $0.pairing = nil }
		emit(.changed)
	}

	func renameDevice(id: String, name: String) async throws {
		try record("renameDevice \(id) \(name)") { status in
			guard let index = status.devices.firstIndex(where: { $0.id == id }) else {
				throw HostError(message: "No such device, or the name is empty.", code: "not_found", status: 404)
			}
			status.devices[index].name = name
		}
		emit(.changed)
	}

	func removeDevice(id: String) async throws {
		try record("removeDevice \(id)") { status in
			guard status.devices.contains(where: { $0.id == id }) else {
				throw HostError(message: "No such device.", code: "not_found", status: 404)
			}
			status.devices.removeAll { $0.id == id }
		}
		emit(.changed)
	}

	func setRoles(deep: String?, quick: String?) async throws {
		try record("setRoles \(deep ?? "-") \(quick ?? "-")") { status in
			if let deep { status.roles.deep = deep }
			if let quick { status.roles.quick = quick }
			if status.roles.quick == status.roles.deep { status.roles.quick = "" }
			status.roles.single = status.roles.quick.isEmpty
		}
		emit(.changed)
	}

	func updateSettings(_ change: SettingsChange) async throws {
		try record("updateSettings") { status in
			if let name = change.name { status.host.name = name }
			if let relay = change.tunnel?.relay { status.tunnel.relay = relay }
			if let enabled = change.tunnel?.enabled {
				status.tunnel.enabled = enabled
				status.tunnel.state = enabled ? .connected : .disabled
			}
		}
		emit(.changed)
	}

	func pullModel(name: String, engine: String?) async throws {
		let progress = try record("pullModel \(name)") { status -> PullProgress in
			var progress = PullProgress()
			progress.engine = engine ?? status.engines.first?.id ?? "ollama"
			progress.name = name
			progress.status = "Starting"
			status.pulls.append(progress)
			return progress
		}
		emit(.pull(progress))
	}

	func cancelPull(engine: String, name: String) async throws {
		let progress = try record("cancelPull \(name)") { status -> PullProgress in
			status.pulls.removeAll { $0.engine == engine && $0.name == name }
			var progress = PullProgress()
			progress.engine = engine
			progress.name = name
			progress.status = "Cancelled"
			progress.done = true
			progress.error = "cancelled"
			return progress
		}
		emit(.pull(progress))
		emit(.changed)
	}

	func deleteModel(id: String) async throws {
		try record("deleteModel \(id)") { status in
			for index in status.engines.indices {
				status.engines[index].models.removeAll { $0.id == id }
			}
			if status.roles.quick == id { status.roles.quick = "" }
			if status.roles.deep == id {
				status.roles.deep = status.roles.quick
				status.roles.quick = ""
			}
			status.roles.single = status.roles.quick.isEmpty
		}
		emit(.changed)
	}

	func chat(role: Role, messages: [ChatTurn]) -> AsyncThrowingStream<ChatDelta, Error> {
		let (answer, failure) = state.withLock { state in
			state.calls.append("chat \(role.rawValue)")
			if state.failure == nil {
				state.status.stats.requests += 1
				if let speed = state.answerSpeed { state.status.stats.tokensPerSecond = speed }
			}
			return (state.answer, state.failure)
		}
		return AsyncThrowingStream { continuation in
			if let failure {
				continuation.finish(throwing: failure)
				return
			}
			if !answer.reasoning.isEmpty { continuation.yield(ChatDelta(reasoning: answer.reasoning)) }
			for word in answer.content.split(separator: " ", omittingEmptySubsequences: false) {
				continuation.yield(ChatDelta(content: String(word) + " "))
			}
			continuation.finish()
		}
	}

	private func record<Result: Sendable>(_ call: String, _ change: @Sendable (inout HostStatus) throws -> Result) throws -> Result {
		try state.withLock { state in
			state.calls.append(call)
			if let failure = state.failure { throw failure }
			return try change(&state.status)
		}
	}
}

/// A supervisor with no program behind it. `running` decides whether a host
/// answers.
final class FixtureHostSupervisor: HostSupervisor, Sendable {
	private struct State: Sendable {
		var running: Bool
		var owns = false
		var connects = 0
	}

	let service: FixtureHostService
	private let state: OSAllocatedUnfairLock<State>

	/// `owns` says the app started the host, which lets the app stop it.
	init(service: FixtureHostService = FixtureHostService(), running: Bool = true, owns: Bool = false) {
		self.service = service
		state = OSAllocatedUnfairLock(initialState: State(running: running, owns: owns))
	}

	var ownsHost: Bool { state.withLock { $0.owns } }
	var connects: Int { state.withLock { $0.connects } }

	func setRunning(_ running: Bool) {
		state.withLock { $0.running = running }
		if !running { service.dropStreams() }
	}

	func connect() async -> (any HostService)? {
		state.withLock { state in
			state.connects += 1
			return state.running ? service : nil
		}
	}

	func start() async throws {
		state.withLock {
			$0.running = true
			$0.owns = true
		}
	}

	func stop() async {
		state.withLock {
			$0.running = false
			$0.owns = false
		}
		service.dropStreams()
	}
}
#endif
