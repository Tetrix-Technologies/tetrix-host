import Foundation

/// The two kinds of work a host serves. An app names a role, and the
/// host's owner decides which model answers it.
public enum HostRole: String, Sendable, Codable, CaseIterable {
	/// Work that needs thought. The host's larger model takes it.
	case deep
	/// Short, simple work. The host's smaller model takes it. A host with
	/// one model uses that model for both roles.
	case quick
}

/// What a host can do, from `GET /v1/host`.
public struct HostInfo: Codable, Sendable, Equatable {
	public struct Role: Codable, Sendable, Equatable {
		/// The model assigned to the role. Empty when none is.
		public var model: String
		/// Whether that model is installed and its engine answers.
		public var available: Bool
		/// The largest context window the model supports, in tokens. Nil
		/// when unknown.
		public var contextLength: Int?
		/// The window the host's engine is running the model with now. It
		/// can be far smaller than `contextLength`, and an engine cuts a
		/// longer request to fit without an error. Nil when the model is
		/// not loaded or the engine does not say.
		public var contextInUse: Int?
		/// What the model can do beyond chat, such as `tools` or `vision`.
		/// Nil when the host's engine does not say, which is different
		/// from an empty list.
		public var capabilities: [String]?

		/// Whether the model has a capability: true, false, or nil when
		/// the host cannot tell.
		public func can(_ capability: String) -> Bool? {
			capabilities.map { $0.contains(capability) }
		}

		/// The window a request must fit: the one in use when known, and
		/// the model's own limit otherwise.
		public var usableContext: Int? { contextInUse ?? contextLength }
	}

	public var id: String
	public var name: String
	public var version: String
	/// True when one model serves both roles.
	public var single: Bool
	public var roles: [String: Role]

	public subscript(role: HostRole) -> Role? { roles[role.rawValue] }
}

/// A paired host, ready for requests.
///
/// `HostClient` opens a connection on the first request and keeps it. If
/// the connection drops, the next request opens a new one.
///
/// ```swift
/// let client = HostClient(host: paired, device: device)
/// for try await line in client.lines(for: .json("/v1/chat/completions", body: body)) {
///     // Each line is one line of the host's event stream.
/// }
/// ```
public actor HostClient {
	public nonisolated let host: PairedHost
	private let device: DeviceInfo
	private let opener: any HostSocketOpener
	private var connection: HostConnection?
	private var opening: Task<HostConnection, any Error>?

	public init(host: PairedHost, device: DeviceInfo, opener: any HostSocketOpener = URLSessionSocketOpener()) {
		self.host = host
		self.device = device
		self.opener = opener
	}

	/// The open connection, or a new one.
	private func connected() async throws -> HostConnection {
		if let connection, await connection.isOpen { return connection }
		connection = nil
		if let opening { return try await opening.value }
		let host = host, device = device, opener = opener
		let task = Task { try await HostConnection.connect(to: host, device: device, opener: opener) }
		opening = task
		defer { opening = nil }
		let fresh = try await task.value
		connection = fresh
		return fresh
	}

	/// Sends a request and returns the host's answer with a streaming body.
	public func send(_ request: HostRequest) async throws -> HostResponse {
		try await connected().send(request)
	}

	/// Sends a request and returns the whole body. A status outside 200 to
	/// 299 throws `HostError.requestRejected`.
	///
	/// - Parameter timeout: The longest the whole call may take. When it
	///   passes, the call throws `HostError.timedOut` and the host is told
	///   to stop. Nil waits as long as the host takes.
	public func data(for request: HostRequest, timeout: Duration? = nil) async throws -> Data {
		guard let timeout else { return try await collect(request) }
		return try await withDeadline(timeout) { try await self.collect(request) }
	}

	private func collect(_ request: HostRequest) async throws -> Data {
		let response = try await send(request)
		var body = Data()
		for try await chunk in response.body { body.append(chunk) }
		guard (200..<300).contains(response.status) else {
			throw Self.rejection(status: response.status, body: body)
		}
		return body
	}

	/// Sends a request and returns the body one line at a time. This is the
	/// form an event-stream parser wants.
	///
	/// A status outside 200 to 299 ends the stream with
	/// `HostError.requestRejected`. Stop iterating to cancel the request.
	///
	/// - Parameter timeout: The longest to wait for the host to start its
	///   answer. A model can take a while to load, so allow for that. Once
	///   the answer starts, no deadline applies. Nil waits without limit.
	public nonisolated func lines(for request: HostRequest, timeout: Duration? = nil) -> AsyncThrowingStream<String, any Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let response: HostResponse
					if let timeout {
						response = try await withDeadline(timeout) { try await self.send(request) }
					} else {
						response = try await self.send(request)
					}
					guard (200..<300).contains(response.status) else {
						var body = Data()
						for try await chunk in response.body where body.count < 64 * 1024 { body.append(chunk) }
						throw Self.rejection(status: response.status, body: body)
					}
					var splitter = LineSplitter()
					for try await chunk in response.body {
						for line in splitter.append(chunk) { continuation.yield(line) }
					}
					if let last = splitter.finish() { continuation.yield(last) }
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Asks the host what it can do. Call it after connecting to learn, for
	/// example, whether the deep model can use tools.
	public func info() async throws -> HostInfo {
		try JSONDecoder().decode(HostInfo.self, from: try await data(for: HostRequest(path: "/v1/host")))
	}

	/// Opens the connection now instead of on the first request. Throws if
	/// the host cannot be reached, which makes it a way to check a pairing.
	public func connect() async throws {
		_ = try await connected()
	}

	/// Closes the connection. The next request opens a new one.
	public func disconnect() async {
		await connection?.close()
		connection = nil
	}

	/// Ends this device's pairing on the host, so the host's owner does not
	/// keep a dead entry in the device list. Remove the pairing from your
	/// own store afterward, whether or not this call succeeds: if the host
	/// is offline, the owner can still unpair the device there.
	public func unpair() async throws {
		_ = try await data(for: HostRequest(method: "DELETE", path: "/v1/device"), timeout: .seconds(20))
		await disconnect()
	}

	private static func rejection(status: Int, body: Data) -> HostError {
		struct Envelope: Decodable {
			struct Detail: Decodable {
				var message: String?
				var code: String?
			}
			var error: Detail
		}
		if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
			return .requestRejected(
				status: status,
				code: envelope.error.code ?? "",
				message: envelope.error.message ?? "The host answered \(status)."
			)
		}
		return .requestRejected(status: status, code: "", message: "The host answered \(status).")
	}
}

/// Cuts a byte stream into lines. A line can span two chunks, and so can
/// one character.
struct LineSplitter {
	private var pending = Data()

	mutating func append(_ chunk: Data) -> [String] {
		pending.append(chunk)
		var lines: [String] = []
		while let newline = pending.firstIndex(of: 0x0A) {
			var line = pending[pending.startIndex..<newline]
			if line.last == 0x0D { line = line.dropLast() }
			lines.append(String(decoding: line, as: UTF8.self))
			pending = Data(pending[pending.index(after: newline)...])
		}
		return lines
	}

	mutating func finish() -> String? {
		guard !pending.isEmpty else { return nil }
		defer { pending = Data() }
		return String(decoding: pending, as: UTF8.self)
	}
}
