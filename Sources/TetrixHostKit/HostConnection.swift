import CryptoKit
import Foundation

/// One request to a host. The path is one of the host's model routes, such
/// as `/v1/chat/completions`.
public struct HostRequest: Sendable, Equatable {
	public var method: String
	public var path: String
	/// Header names in lower case.
	public var headers: [String: String]
	public var body: Data?

	public init(method: String = "GET", path: String, headers: [String: String] = [:], body: Data? = nil) {
		self.method = method
		self.path = path
		self.headers = headers
		self.body = body
	}

	/// A `POST` with a JSON body.
	public static func json(_ path: String, body: Data) -> HostRequest {
		HostRequest(method: "POST", path: path, headers: ["content-type": "application/json"], body: body)
	}
}

/// A host's answer. The status and headers are complete. The body arrives
/// in pieces as the host produces it.
public struct HostResponse: Sendable {
	public let status: Int
	public let headers: [String: String]
	public let body: AsyncThrowingStream<Data, any Error>
}

/// One open, sealed connection to a host.
///
/// Most apps use `HostClient`, which opens a connection when it needs one
/// and replaces one that dropped. Use `HostConnection` directly to control
/// that yourself.
public actor HostConnection {
	/// What the host said about itself in the handshake.
	public nonisolated let host: HostHello

	private let socket: any HostSocket
	private var sendCipher: CipherState
	private var receiveCipher: CipherState
	private let outbox: AsyncStream<Data>.Continuation
	private let outgoing: AsyncStream<Data>

	private struct Stream: Sendable {
		var head: CheckedContinuation<ResponseHead, any Error>?
		var body: AsyncThrowingStream<Data, any Error>.Continuation
	}

	private var streams: [UInt32: Stream] = [:]
	private var nextStream: UInt32 = 0
	private var failure: HostError?
	private var pongWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
	private var tasks: [Task<Void, Never>] = []

	private init(socket: any HostSocket, send: CipherState, receive: CipherState, host: HostHello) {
		self.socket = socket
		sendCipher = send
		receiveCipher = receive
		self.host = host
		(outgoing, outbox) = AsyncStream<Data>.makeStream()
	}

	/// Opens a session with a paired host.
	///
	/// The handshake is Noise IK. The client seals its first message to the
	/// host's static key, so only the real host can answer, and the host
	/// accepts the client only if its key belongs to a paired device.
	public static func connect(
		to paired: PairedHost,
		device: DeviceInfo,
		opener: any HostSocketOpener = URLSessionSocketOpener(),
		timeout: Duration = .seconds(20)
	) async throws -> HostConnection {
		let socket: any HostSocket
		do {
			socket = try await opener.open(paired.connectURL)
		} catch {
			throw HostError.from(error)
		}
		do {
			return try await withDeadline(timeout, onExpire: { socket.close() }) {
				let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: paired.deviceStaticKey)
				var handshake = try HandshakeState(
					pattern: .ik,
					initiator: true,
					prologue: Data((Wire.sessionPrologue + paired.hostID).utf8),
					staticKey: key,
					remoteStatic: paired.hostStaticKey
				)
				let first = try handshake.writeMessage(payload: JSONEncoder().encode(device.hello))
				try await socket.send(Data([Wire.helloSession]) + first.message)
				let second = try handshake.readMessage(try await socket.receive())
				guard let transport = second.transport else {
					throw HostError.protocolViolation("The handshake did not finish.")
				}
				let hello = try JSONDecoder().decode(HostHello.self, from: second.payload)
				// A refusal here is sealed with keys only the real host can
				// derive. A close code from the socket could be the relay's.
				if let refused = hello.refused {
					throw refused == HostHello.refusedUnknownDevice
						? HostError.deviceNotPaired
						: HostError.protocolViolation("The host refused the session.")
				}
				let connection = HostConnection(socket: socket, send: transport.0, receive: transport.1, host: hello)
				await connection.start()
				// The first sealed message shows the host that this is a live
				// session and not a replay. The pong shows the client the same.
				try await connection.ping()
				return connection
			}
		} catch {
			socket.close()
			throw HostError.from(error)
		}
	}

	private func start() {
		let socket = socket
		let outgoing = outgoing
		// One task writes to the socket, so messages leave in the order
		// their nonces were used.
		tasks.append(Task { [weak self] in
			for await message in outgoing {
				do {
					try await socket.send(message)
				} catch {
					await self?.fail(HostError.from(error))
					return
				}
			}
		})
		tasks.append(Task { [weak self] in
			while !Task.isCancelled {
				do {
					let message = try await socket.receive()
					guard let self else { return }
					await self.receive(message)
				} catch {
					await self?.fail(HostError.from(error))
					return
				}
			}
		})
	}

	/// Whether the connection can still carry a request.
	public var isOpen: Bool { failure == nil }

	/// Sends a request. Returns when the host has answered with a status.
	///
	/// To cancel a request, cancel the task that awaits this call, or stop
	/// reading the response body. Either tells the host to stop its work.
	public func send(_ request: HostRequest) async throws -> HostResponse {
		if let failure { throw failure }
		nextStream &+= 1
		let id = nextStream
		let (body, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
		bodyContinuation.onTermination = { [weak self] reason in
			guard case .cancelled = reason else { return }
			Task { await self?.abandon(id) }
		}

		let head = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResponseHead, any Error>) in
				streams[id] = Stream(head: continuation, body: bodyContinuation)
				do {
					let head = RequestHead(method: request.method, path: request.path, headers: request.headers)
					try seal(.request, stream: id, payload: JSONEncoder().encode(head))
					var rest = request.body ?? Data()
					while !rest.isEmpty {
						let chunk = rest.prefix(Wire.bodyChunk)
						try seal(.body, stream: id, payload: chunk)
						rest = rest.dropFirst(chunk.count)
					}
					try seal(.end, stream: id)
				} catch {
					streams[id] = nil
					continuation.resume(throwing: HostError.from(error))
				}
			}
		} onCancel: {
			Task { await self.abandon(id) }
		}
		return HostResponse(status: head.status, headers: head.headers ?? [:], body: body)
	}

	/// Checks that the host answers.
	public func ping(timeout: Duration = .seconds(10)) async throws {
		if let failure { throw failure }
		let id = UUID()
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
			pongWaiters[id] = continuation
			do {
				try seal(.ping, stream: 0, payload: Data("ping".utf8))
			} catch {
				pongWaiters[id] = nil
				continuation.resume(throwing: HostError.from(error))
				return
			}
			// Weak, so that a pending timeout does not keep a connection
			// alive after its owner let it go.
			Task { [weak self] in
				try? await Task.sleep(for: timeout)
				await self?.expirePing(id)
			}
		}
	}

	private func expirePing(_ id: UUID) {
		pongWaiters.removeValue(forKey: id)?.resume(throwing: HostError.timedOut)
	}

	/// Closes the connection. Requests in flight fail with `connectionLost`.
	public func close() {
		fail(.connectionLost)
	}

	/// Seals a frame and queues it. No suspension point sits between the two
	/// steps, so the queue order always matches the nonce order.
	private func seal(_ kind: Wire.Frame, stream: UInt32, payload: some DataProtocol = Data()) throws {
		if let failure { throw failure }
		guard payload.count <= Wire.maxFramePayload else {
			throw HostError.protocolViolation("A request's headers are too large.")
		}
		let sealed = try sendCipher.encrypt(ad: Data(), plaintext: Wire.frame(kind, stream: stream, payload: payload))
		outbox.yield(sealed)
	}

	private func receive(_ sealed: Data) {
		guard failure == nil else { return }
		let frame: (kind: Wire.Frame?, stream: UInt32, payload: Data)
		do {
			frame = try Wire.parse(try receiveCipher.decrypt(ad: Data(), ciphertext: sealed))
		} catch {
			fail(.protocolViolation("A message from the host did not open."))
			return
		}
		let id = frame.stream
		switch frame.kind {
		case .pong:
			let waiters = pongWaiters
			pongWaiters = [:]
			for waiter in waiters.values { waiter.resume() }
		case .ping:
			try? seal(.pong, stream: id, payload: frame.payload)
		case .response:
			guard let continuation = streams[id]?.head else { return }
			streams[id]?.head = nil
			do {
				continuation.resume(returning: try JSONDecoder().decode(ResponseHead.self, from: frame.payload))
			} catch {
				streams[id]?.body.finish()
				streams[id] = nil
				continuation.resume(throwing: HostError.protocolViolation("A response head was not valid."))
			}
		case .body:
			streams[id]?.body.yield(frame.payload)
		case .end:
			end(id, with: nil)
		case .reset:
			let reset = try? JSONDecoder().decode(ResetBody.self, from: frame.payload)
			end(id, with: HostError.requestEnded(code: reset?.code ?? "reset", message: reset?.message ?? ""))
		case .request, .paired, nil:
			break
		}
	}

	private func end(_ id: UInt32, with error: HostError?) {
		guard let stream = streams.removeValue(forKey: id) else { return }
		stream.head?.resume(throwing: error ?? HostError.protocolViolation("The host ended a request without answering it."))
		stream.body.finish(throwing: error)
	}

	/// Gives up on one request and tells the host to stop work on it.
	private func abandon(_ id: UInt32) {
		guard let stream = streams.removeValue(forKey: id) else { return }
		stream.head?.resume(throwing: CancellationError())
		stream.body.finish(throwing: CancellationError())
		try? seal(.reset, stream: id)
	}

	private func fail(_ error: HostError) {
		guard failure == nil else { return }
		failure = error
		outbox.finish()
		socket.close()
		for task in tasks { task.cancel() }
		tasks = []
		let open = streams
		streams = [:]
		for stream in open.values {
			stream.head?.resume(throwing: error)
			stream.body.finish(throwing: error)
		}
		let waiters = pongWaiters
		pongWaiters = [:]
		for waiter in waiters.values { waiter.resume(throwing: error) }
	}

	deinit {
		outbox.finish()
		socket.close()
		for task in tasks { task.cancel() }
		// A caller can still be reading a body after it let the connection
		// go. End that read with an error, or it would wait forever.
		for stream in streams.values {
			stream.head?.resume(throwing: HostError.connectionLost)
			stream.body.finish(throwing: HostError.connectionLost)
		}
		for waiter in pongWaiters.values { waiter.resume(throwing: HostError.connectionLost) }
	}
}

/// Runs `work` and throws `HostError.timedOut` if it takes longer than
/// `timeout`. `onExpire` runs first, so it can close whatever `work` waits on.
func withDeadline<T: Sendable>(
	_ timeout: Duration,
	onExpire: @escaping @Sendable () -> Void = {},
	_ work: @escaping @Sendable () async throws -> T
) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask { try await work() }
		group.addTask {
			try await Task.sleep(for: timeout)
			onExpire()
			throw HostError.timedOut
		}
		defer { group.cancelAll() }
		guard let result = try await group.next() else { throw HostError.timedOut }
		return result
	}
}
