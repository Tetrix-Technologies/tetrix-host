import Foundation

/// Everything the app asks of a running host.
///
/// `LiveHostService` speaks the admin API over loopback. `FixtureHostService`
/// answers from memory, for tests and for snapshots.
protocol HostService: Sendable {
	func status() async throws -> HostStatus
	/// The host's event stream. It ends, or throws, when the connection drops.
	func events() -> AsyncThrowingStream<HostEvent, Error>

	func startPairing() async throws -> PairingOffer
	func cancelPairing() async throws

	func renameDevice(id: String, name: String) async throws
	func removeDevice(id: String) async throws

	/// Assigns models to roles. A nil role keeps its model.
	func setRoles(deep: String?, quick: String?) async throws
	func updateSettings(_ change: SettingsChange) async throws

	func pullModel(name: String, engine: String?) async throws
	func cancelPull(engine: String, name: String) async throws
	func deleteModel(id: String) async throws

	/// Sends a conversation to the model behind a role and streams the answer.
	func chat(role: Role, messages: [ChatTurn]) -> AsyncThrowingStream<ChatDelta, Error>
}

/// Finds, starts, and stops the host program on this machine.
protocol HostSupervisor: Sendable {
	/// Returns a service for the live host, or nil when no host answers.
	func connect() async -> (any HostService)?
	/// Starts the host as a child of the app and waits until it answers.
	func start() async throws
	/// Stops the host, if the app started it.
	func stop() async
	/// True while a host the app started is running.
	var ownsHost: Bool { get }
}

/// A change to the host's settings. A nil field keeps its value.
struct SettingsChange: Encodable, Equatable, Sendable {
	var name: String?
	var tunnel: TunnelChange?

	struct TunnelChange: Encodable, Equatable, Sendable {
		var enabled: Bool?
		var relay: String?
	}
}

/// One turn of a conversation, as the model routes take it.
struct ChatTurn: Codable, Equatable, Sendable {
	enum Speaker: String, Codable, Sendable {
		case user, assistant
	}

	var role: Speaker
	var content: String
}

/// One piece of a streamed answer.
struct ChatDelta: Equatable, Sendable {
	var content = ""
	var reasoning = ""
}

/// A failure the host reported, or one the app met on the way to the host.
/// `message` is written for a person.
struct HostError: LocalizedError, Equatable, Sendable {
	var message: String
	var code = "host_error"
	var status = 0

	var errorDescription: String? { message }

	/// The words to show for any error.
	static func message(for error: Error) -> String {
		if let error = error as? HostError { return error.message }
		if error is CancellationError { return "" }
		if let error = error as? URLError {
			switch error.code {
			case .cancelled: return ""
			case .timedOut: return "The host took too long to answer."
			default: return "The host is not answering."
			}
		}
		return "Something went wrong. Try again."
	}
}
