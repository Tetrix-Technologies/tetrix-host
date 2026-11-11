import Foundation

/// The admin API of a running host, over loopback HTTP.
struct LiveHostService: HostService {
	let address: String
	let token: String
	let session: URLSession

	/// Seconds a plain request may wait.
	private static let requestTimeout: TimeInterval = 15
	/// Seconds the event stream may stay silent. The host sends a comment
	/// every 15 seconds, so three missed beats mean the connection is dead.
	private static let streamIdleTimeout: TimeInterval = 45
	/// Seconds a chat may wait for the next piece. A large model can take a
	/// long time to load before its first word.
	private static let chatIdleTimeout: TimeInterval = 600
	private static let maxErrorBody = 64 << 10

	// MARK: HostService

	func status() async throws -> HostStatus {
		let data = try await send("GET", "/admin/v1/status")
		do {
			return try HostTime.decoder().decode(HostStatus.self, from: data)
		} catch {
			throw HostError(message: "The host sent a status this app cannot read.", code: "bad_status")
		}
	}

	func events() -> AsyncThrowingStream<HostEvent, Error> {
		var request = makeRequest("GET", "/admin/v1/events")
		request.timeoutInterval = Self.streamIdleTimeout
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		return stream(request) { message, continuation in
			if let event = HostEvent.decode(message) { continuation.yield(event) }
			return true
		}
	}

	func startPairing() async throws -> PairingOffer {
		let data = try await send("POST", "/admin/v1/pairing")
		do {
			return try HostTime.decoder().decode(PairingOffer.self, from: data)
		} catch {
			throw HostError(message: "The host sent a pairing code this app cannot read.", code: "bad_pairing")
		}
	}

	func cancelPairing() async throws {
		try await send("DELETE", "/admin/v1/pairing")
	}

	func renameDevice(id: String, name: String) async throws {
		try await send("PATCH", "/admin/v1/devices/\(Self.escape(id))", body: ["name": name])
	}

	func removeDevice(id: String) async throws {
		try await send("DELETE", "/admin/v1/devices/\(Self.escape(id))")
	}

	func setRoles(deep: String?, quick: String?) async throws {
		var body: [String: String] = [:]
		if let deep { body["deep"] = deep }
		if let quick { body["quick"] = quick }
		try await send("PUT", "/admin/v1/roles", body: body)
	}

	func updateSettings(_ change: SettingsChange) async throws {
		try await send("PUT", "/admin/v1/settings", body: change)
	}

	func pullModel(name: String, engine: String?) async throws {
		var body = ["name": name]
		if let engine { body["engine"] = engine }
		try await send("POST", "/admin/v1/models/pull", body: body)
	}

	func cancelPull(engine: String, name: String) async throws {
		try await send("DELETE", "/admin/v1/models/pull", query: [
			URLQueryItem(name: "engine", value: engine),
			URLQueryItem(name: "name", value: name),
		])
	}

	func deleteModel(id: String) async throws {
		try await send("DELETE", "/admin/v1/models", query: [URLQueryItem(name: "id", value: id)])
	}

	func chat(role: Role, messages: [ChatTurn]) -> AsyncThrowingStream<ChatDelta, Error> {
		var request = makeRequest("POST", "/v1/chat/completions")
		request.timeoutInterval = Self.chatIdleTimeout
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
		request.httpBody = try? JSONEncoder().encode(ChatBody(model: role.rawValue, messages: messages, stream: true))
		return stream(request) { message, continuation in
			guard message.data != "[DONE]" else { return false }
			if let delta = ChatChunk.delta(from: message.data) { continuation.yield(delta) }
			return true
		}
	}

	// MARK: Requests

	private func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
		var components = URLComponents(string: "http://\(address)") ?? URLComponents()
		components.percentEncodedPath = path
		if !query.isEmpty {
			components.queryItems = query
			// The host reads a plus sign in a query as a space.
			components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		}
		var request = URLRequest(url: components.url ?? URL(fileURLWithPath: "/"))
		request.httpMethod = method
		request.timeoutInterval = Self.requestTimeout
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		return request
	}

	@discardableResult
	private func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Data {
		try await perform(makeRequest(method, path, query: query))
	}

	@discardableResult
	private func send(_ method: String, _ path: String, body: some Encodable) async throws -> Data {
		var request = makeRequest(method, path)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(body)
		return try await perform(request)
	}

	private func perform(_ request: URLRequest) async throws -> Data {
		let (data, response) = try await session.data(for: request)
		try Self.check(response, body: data)
		return data
	}

	/// Opens a streaming request and hands each server-sent event to `take`.
	/// `take` returns false to end the stream.
	private func stream<Element: Sendable>(
		_ request: URLRequest,
		take: @escaping @Sendable (ServerSentEvent, AsyncThrowingStream<Element, Error>.Continuation) -> Bool
	) -> AsyncThrowingStream<Element, Error> {
		let session = session
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let (bytes, response) = try await session.bytes(for: request)
					if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
						var body = Data()
						for try await byte in bytes where body.count < Self.maxErrorBody {
							body.append(byte)
						}
						try Self.check(response, body: body)
					}
					var parser = ServerSentEventParser()
					for try await byte in bytes {
						guard let message = parser.feed(byte) else { continue }
						if !take(message, continuation) { break }
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private static func check(_ response: URLResponse, body: Data) throws {
		guard let http = response as? HTTPURLResponse else { return }
		guard http.statusCode >= 400 else { return }
		if let failure = try? JSONDecoder().decode(ErrorBody.self, from: body) {
			throw HostError(message: failure.error.message, code: failure.error.code ?? "host_error", status: http.statusCode)
		}
		if http.statusCode == 401 {
			throw HostError(message: "The host did not accept this app's key.", code: "unauthorized", status: 401)
		}
		throw HostError(message: "The host answered with an error.", code: "host_error", status: http.statusCode)
	}

	private static func escape(_ segment: String) -> String {
		var allowed = CharacterSet.urlPathAllowed
		allowed.remove(charactersIn: "/")
		return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
	}

	private struct ErrorBody: Decodable {
		struct Failure: Decodable {
			let message: String
			let code: String?
		}

		let error: Failure
	}

	private struct ChatBody: Encodable {
		let model: String
		let messages: [ChatTurn]
		let stream: Bool
	}
}

/// One chunk of a streamed chat answer, in the shape OpenAI clients read.
enum ChatChunk {
	private struct Body: Decodable {
		struct Choice: Decodable {
			struct Delta: Decodable {
				let content: String?
				let reasoning: String?
				let reasoning_content: String?
			}

			let delta: Delta?
		}

		let choices: [Choice]?
	}

	/// Reads the text out of one `data:` payload. Returns nil when the chunk
	/// carries no text, such as the closing usage chunk.
	static func delta(from payload: String) -> ChatDelta? {
		guard let body = try? JSONDecoder().decode(Body.self, from: Data(payload.utf8)) else { return nil }
		guard let delta = body.choices?.first?.delta else { return nil }
		let content = delta.content ?? ""
		let reasoning = delta.reasoning ?? delta.reasoning_content ?? ""
		guard !content.isEmpty || !reasoning.isEmpty else { return nil }
		return ChatDelta(content: content, reasoning: reasoning)
	}
}
