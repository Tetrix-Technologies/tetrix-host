import Foundation
import Observation
import os

/// The one place that knows the state of the host.
///
/// It keeps the latest status document, applies each event to it, and
/// reconnects when the host goes away. Views read it and call its actions.
@MainActor
@Observable
final class HostStore {
	enum Phase: Equatable, Sendable {
		/// The app has not looked for a host yet.
		case connecting
		case stopped
		case starting
		case running
		case stopping
	}

	/// Where a pairing stands while the pairing sheet is open.
	enum PairingFlow: Equatable, Sendable {
		case idle
		case preparing
		case offered(PairingOffer)
		case paired(Device)
		case failed(String)
	}

	/// A path that just carried a request. The board lights it for a moment.
	struct RequestGlow: Equatable, Sendable {
		var deviceID: String?
		var role: Role?
		var until: Date
	}

	private(set) var phase: Phase = .connecting
	private(set) var status: HostStatus?
	/// Downloads the app knows of, by `engine/name`. A finished download
	/// stays until the app dismisses it, so a person can read how it ended.
	private(set) var pulls: [String: PullProgress] = [:]
	private(set) var pairing: PairingFlow = .idle
	private(set) var glows: [RequestGlow] = []
	/// True while a host the app started is running. Only then can it stop it.
	private(set) var ownsHost = false
	/// A short message about the last thing that failed.
	private(set) var notice: String?

	/// Speaks a change of state to a person who uses VoiceOver. A test
	/// passes its own, to hear what the store says.
	@ObservationIgnored private let announce: @MainActor (String) -> Void
	/// True once the store has said the host went away, until it says the
	/// host is back.
	@ObservationIgnored private var saidHostIsGone = false
	@ObservationIgnored private var expiry: Task<Void, Never>?

	@ObservationIgnored private let supervisor: any HostSupervisor
	@ObservationIgnored private var service: (any HostService)?
	@ObservationIgnored private let log = Logger(subsystem: "Tech.Tetrix.Host", category: "store")

	@ObservationIgnored private var refreshTask: Task<Void, Never>?
	@ObservationIgnored private var refreshPending = false
	@ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
	@ObservationIgnored private var sleeper: Task<Void, Never>?
	@ObservationIgnored private let clock = ContinuousClock()

	/// The shortest time between two status fetches.
	static let refreshInterval: Duration = .milliseconds(150)
	/// How often the app looks for a host while none answers.
	static let stoppedPoll: Duration = .milliseconds(1_500)
	static let recentLimit = 40
	/// How long an action waits for a connection that is on its way.
	static let serviceWaitAttempts = 30
	static let serviceWaitPoll: Duration = .milliseconds(100)

	init(supervisor: any HostSupervisor, announce: @escaping @MainActor (String) -> Void = Announcer.post) {
		self.supervisor = supervisor
		self.announce = announce
	}

	#if DEBUG
	/// A store that shows a fixed state, for snapshots and previews.
	init(supervisor: any HostSupervisor, phase: Phase, status: HostStatus?) {
		self.supervisor = supervisor
		announce = { _ in }
		self.phase = phase
		self.status = status
		ownsHost = supervisor.ownsHost
		if let status {
			pulls = Dictionary(uniqueKeysWithValues: status.pulls.map { ($0.id, $0) })
		}
	}

	func setPairingForSnapshot(_ flow: PairingFlow) { pairing = flow }
	func setPullForSnapshot(_ progress: PullProgress) { pulls[progress.id] = progress }
	#endif

	// MARK: Connection

	/// Looks for the host, follows its event stream, and reconnects when the
	/// stream drops. Runs until its task is cancelled.
	func run() async {
		var backoff = Backoff()
		while !Task.isCancelled {
			guard let service = await supervisor.connect() else {
				self.service = nil
				ownsHost = supervisor.ownsHost
				if phase != .starting {
					if phase != .stopped { log.info("No host answers") }
					if phase == .running || phase == .stopping, !saidHostIsGone {
						announce("The host stopped.")
						saidHostIsGone = true
					}
					phase = .stopped
					clearLiveState()
				}
				await pause(Self.stoppedPoll)
				continue
			}

			self.service = service
			ownsHost = supervisor.ownsHost
			do {
				// Open the stream before the fetch, so no change falls
				// between the two.
				let events = service.events()
				try await fetchStatus(from: service)
				if phase != .running { log.info("Connected to the host at \(self.status?.host.address ?? "", privacy: .public)") }
				if phase == .starting {
					announce("The host started.")
				} else if saidHostIsGone {
					announce("The host is connected again.")
				}
				saidHostIsGone = false
				phase = .running
				backoff.reset()
				for try await event in events {
					apply(event)
				}
			} catch {
				log.info("The event stream dropped: \(String(describing: error), privacy: .public)")
			}
			self.service = nil
			if Task.isCancelled { break }
			// A stream that drops while the host should be running is news.
			// A stop the person asked for is not.
			if phase == .running, !saidHostIsGone {
				announce("The connection to the host dropped.")
				saidHostIsGone = true
			}
			await pause(backoff.next())
		}
	}

	/// Starts the host as a child of the app.
	func start() async {
		guard phase == .stopped || phase == .connecting else { return }
		phase = .starting
		notice = nil
		do {
			try await supervisor.start()
			ownsHost = supervisor.ownsHost
			wake()
		} catch {
			phase = .stopped
			report(HostError.message(for: error))
		}
	}

	/// Stops a host the app started.
	func stop() async {
		guard phase == .running, supervisor.ownsHost else { return }
		phase = .stopping
		await supervisor.stop()
		ownsHost = supervisor.ownsHost
		wake()
	}

	/// True when the app can stop the host.
	var canStop: Bool { phase == .running && ownsHost }

	/// True while the one start-or-stop control reads "Stop host".
	var showsStop: Bool { phase == .running || phase == .stopping }

	/// True when that control can act: the host is stopped, or it runs and
	/// the app started it.
	var canToggleRunning: Bool { phase == .stopped || canStop }

	/// Starts a stopped host, or stops a running one.
	func toggleRunning() async {
		if showsStop { await stop() } else { await start() }
	}

	// MARK: Events

	/// Applies one event from the stream.
	func apply(_ event: HostEvent) {
		switch event {
		case .changed:
			scheduleRefresh()
		case .load(let load):
			status?.load = load
		case .pull(let progress):
			apply(progress)
		case .request(let record):
			apply(record)
		case .paired(let device):
			if status?.devices.contains(where: { $0.id == device.id }) == false {
				status?.devices.append(device)
			}
			switch pairing {
			case .offered, .preparing:
				pairing = .paired(device)
				expiry?.cancel()
			default: break
			}
			announce("Paired with \(device.appName) on \(device.name).")
		}
	}

	private func apply(_ progress: PullProgress) {
		let alreadyEnded = pulls[progress.id]?.done ?? false
		if progress.cancelled {
			pulls[progress.id] = nil
		} else {
			pulls[progress.id] = progress
		}
		guard progress.done, !progress.cancelled, !alreadyEnded else { return }
		if progress.failed {
			announce("The download of \(progress.name) failed. \(progress.error ?? "")".trimmingCharacters(in: .whitespaces))
		} else {
			announce("Downloaded \(progress.name).")
		}
	}

	private func apply(_ record: RequestRecord) {
		if var stats = status?.stats, !stats.recent.contains(where: { $0.id == record.id }) {
			stats.recent.insert(record, at: 0)
			if stats.recent.count > Self.recentLimit { stats.recent.removeLast(stats.recent.count - Self.recentLimit) }
			status?.stats = stats
		}
		let until = Date.now.addingTimeInterval(Motion.requestGlow)
		glows.append(RequestGlow(deviceID: record.deviceId, role: record.role, until: until))
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(Motion.requestGlow))
			self?.expireGlows()
		}
	}

	private func expireGlows() {
		let now = Date.now
		glows.removeAll { $0.until <= now }
	}

	/// Asks for a fresh status document. A burst of calls costs at most one
	/// fetch per `refreshInterval`.
	func scheduleRefresh() {
		guard refreshTask == nil else {
			refreshPending = true
			return
		}
		refreshTask = Task { [weak self] in
			guard let self else { return }
			repeat {
				if let last = self.lastRefresh {
					let wait = Self.refreshInterval - (self.clock.now - last)
					if wait > .zero { try? await self.clock.sleep(for: wait) }
				}
				if Task.isCancelled { break }
				// Clear the flag as the fetch starts. A change that arrived
				// during the wait is in this fetch. Only a change that
				// arrives after this line needs another.
				self.refreshPending = false
				self.lastRefresh = self.clock.now
				if let service = self.service {
					try? await self.fetchStatus(from: service)
				}
			} while self.refreshPending && !Task.isCancelled
			self.refreshTask = nil
		}
	}

	private func fetchStatus(from service: any HostService) async throws {
		let fresh = try await service.status()
		status = fresh
		// The status lists the downloads that run now. Drop a download the
		// app still shows as running when the host no longer does.
		let running = Set(fresh.pulls.map(\.id))
		for (id, pull) in pulls where !pull.done && !running.contains(id) {
			pulls[id] = nil
		}
		for pull in fresh.pulls {
			pulls[pull.id] = pull
		}
	}

	private func clearLiveState() {
		status = nil
		pulls.removeAll()
		glows.removeAll()
		if pairing != .idle { failPairing("The host stopped.") }
	}

	// MARK: Derived

	var activePulls: [PullProgress] {
		pulls.values.filter { !$0.done }.sorted { $0.id < $1.id }
	}

	var shownPulls: [PullProgress] {
		pulls.values.sorted { $0.id < $1.id }
	}

	/// The overall share downloaded across running downloads.
	var pullFraction: Double? {
		let active = activePulls
		guard !active.isEmpty else { return nil }
		let total = active.reduce(Int64(0)) { $0 + $1.total }
		guard total > 0 else { return 0 }
		return Double(active.reduce(Int64(0)) { $0 + $1.completed }) / Double(total)
	}

	// MARK: Actions

	func setModel(_ modelID: String, for role: Role) async {
		await perform { service in
			switch role {
			case .deep: try await service.setRoles(deep: modelID, quick: nil)
			case .quick: try await service.setRoles(deep: nil, quick: modelID)
			}
		}
	}

	/// Turns "One model for everything" on or off. Off gives quick work the
	/// smallest other model, since quick work is short and simple.
	func setSingle(_ single: Bool) async {
		guard let status else { return }
		if single {
			await perform { try await $0.setRoles(deep: nil, quick: "") }
			return
		}
		let others = status.models.filter { $0.id != status.roles.deep }
		guard let smallest = others.min(by: { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }) else {
			report("Download a second model to give quick work its own.")
			return
		}
		await perform { try await $0.setRoles(deep: nil, quick: smallest.id) }
	}

	/// Each of the three saves below returns true when the host took the
	/// change, so a field can say "Saved".
	@discardableResult
	func renameHost(_ name: String) async -> Bool {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != status?.host.name else { return false }
		return await perform { try await $0.updateSettings(SettingsChange(name: trimmed)) }
	}

	func setTunnelEnabled(_ enabled: Bool) async {
		await perform { try await $0.updateSettings(SettingsChange(tunnel: .init(enabled: enabled))) }
	}

	@discardableResult
	func setRelay(_ relay: String) async -> Bool {
		let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != status?.tunnel.relay else { return false }
		return await perform { try await $0.updateSettings(SettingsChange(tunnel: .init(relay: trimmed))) }
	}

	@discardableResult
	func renameDevice(id: String, to name: String) async -> Bool {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != status?.device(id: id)?.name else { return false }
		return await perform { try await $0.renameDevice(id: id, name: trimmed) }
	}

	func unpair(deviceID: String) async {
		await perform { try await $0.removeDevice(id: deviceID) }
	}

	func deleteModel(id: String) async {
		await perform { try await $0.deleteModel(id: id) }
	}

	@discardableResult
	func download(_ name: String) async -> Bool {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }
		return await perform { try await $0.pullModel(name: trimmed, engine: nil) }
	}

	func cancelDownload(_ pull: PullProgress) async {
		await perform { try await $0.cancelPull(engine: pull.engine, name: pull.name) }
	}

	/// Forgets the downloads that have ended.
	func dismissFinishedDownloads() {
		for (id, pull) in pulls where pull.done {
			pulls[id] = nil
		}
	}

	/// Asks the host for a pairing code.
	func beginPairing() async {
		expiry?.cancel()
		pairing = .preparing
		guard let service = await liveService() else {
			failPairing("The host is not running.")
			return
		}
		do {
			let offer = try await service.startPairing()
			// A device may pair in the moment the answer travels.
			if case .preparing = pairing {
				pairing = .offered(offer)
				announceExpiry(of: offer)
			}
		} catch {
			failPairing(HostError.message(for: error))
		}
	}

	/// Ends a pairing. An open code is cancelled, so it cannot be used later.
	func endPairing() async {
		let open: Bool
		switch pairing {
		case .offered, .preparing: open = true
		default: open = false
		}
		expiry?.cancel()
		pairing = .idle
		if open, let service {
			try? await service.cancelPairing()
		}
	}

	private func failPairing(_ reason: String) {
		expiry?.cancel()
		pairing = .failed(reason)
		announce(reason.isEmpty ? "The host could not make a pairing code." : reason)
	}

	/// Says so when an open code runs out. The sheet shows the same thing.
	private func announceExpiry(of offer: PairingOffer) {
		guard let expires = offer.expiresAt else { return }
		expiry = Task { [weak self] in
			let wait = expires.timeIntervalSinceNow
			if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
			guard !Task.isCancelled, let self, case .offered(let open) = self.pairing, open.code == offer.code else { return }
			self.announce("The pairing code expired.")
		}
	}

	/// Streams a chat answer from the model behind a role.
	func chat(role: Role, turns: [ChatTurn]) -> AsyncThrowingStream<ChatDelta, Error>? {
		service?.chat(role: role, messages: turns)
	}

	/// Fetches the status once a request has had time to be counted, and
	/// returns the speed of the last answer.
	func speedOfLastAnswer() async -> Double {
		try? await Task.sleep(for: Self.refreshInterval)
		if let service { try? await fetchStatus(from: service) }
		return status?.stats.tokensPerSecond ?? 0
	}

	/// The service, once the host answers. While the app is connecting or
	/// reconnecting, this waits a moment instead of failing at once.
	private func liveService() async -> (any HostService)? {
		for _ in 0..<Self.serviceWaitAttempts {
			if let service { return service }
			if phase == .stopped || phase == .stopping || Task.isCancelled { return nil }
			try? await Task.sleep(for: Self.serviceWaitPoll)
		}
		return service
	}

	@discardableResult
	private func perform(_ work: (any HostService) async throws -> Void) async -> Bool {
		guard let service = await liveService() else {
			report("The host is not running.")
			return false
		}
		do {
			try await work(service)
			notice = nil
			return true
		} catch {
			report(HostError.message(for: error))
			return false
		}
	}

	/// Shows a message about something that failed, and speaks it.
	private func report(_ message: String) {
		guard !message.isEmpty else { return }
		notice = message
		announce(message)
	}

	func dismissNotice() {
		notice = nil
	}

	// MARK: Waiting

	private func pause(_ duration: Duration) async {
		let task = Task<Void, Never> { try? await Task.sleep(for: duration) }
		sleeper = task
		await withTaskCancellationHandler {
			await task.value
		} onCancel: {
			task.cancel()
		}
		sleeper = nil
	}

	/// Cuts the current wait short, so the loop looks for the host now.
	private func wake() {
		sleeper?.cancel()
	}
}

/// Waits that grow each time the event stream drops, up to a ceiling.
struct Backoff: Sendable {
	static let first: Duration = .milliseconds(250)
	static let ceiling: Duration = .seconds(5)

	private var current = Backoff.first

	mutating func next() -> Duration {
		defer { current = min(current * 2, Self.ceiling) }
		return current
	}

	mutating func reset() {
		current = Self.first
	}
}
