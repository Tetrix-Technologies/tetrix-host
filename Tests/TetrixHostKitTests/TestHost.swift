import CryptoKit
import Foundation
@testable import TetrixHostKit

/// One end of an in-memory socket. What one end sends, the other receives.
final class MemorySocket: HostSocket, @unchecked Sendable {
	private let inbox: AsyncThrowingStream<Data, any Error>
	private let inboxContinuation: AsyncThrowingStream<Data, any Error>.Continuation
	private let lock = NSLock()
	private var peer: MemorySocket?

	private init() {
		(inbox, inboxContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
	}

	static func pair() -> (MemorySocket, MemorySocket) {
		let a = MemorySocket(), b = MemorySocket()
		a.peer = b
		b.peer = a
		return (a, b)
	}

	private var other: MemorySocket? {
		lock.withLock { peer }
	}

	func send(_ message: Data) async throws {
		guard let other else { throw HostSocketClosed(code: 1006) }
		other.inboxContinuation.yield(message)
	}

	func receive() async throws -> Data {
		var iterator = inbox.makeAsyncIterator()
		guard let message = try await iterator.next() else { throw HostSocketClosed(code: 1000) }
		return message
	}

	func close() {
		closePeer(code: 1000)
		inboxContinuation.finish()
	}

	/// Ends the other end's `receive` with a close code, as a relay does.
	func closePeer(code: Int) {
		let other = lock.withLock { () -> MemorySocket? in
			defer { peer = nil }
			return peer
		}
		other?.inboxContinuation.finish(throwing: HostSocketClosed(code: code))
	}
}

/// Hands out one prepared socket per `open`.
final class MemoryOpener: HostSocketOpener, @unchecked Sendable {
	private let lock = NSLock()
	private var sockets: [MemorySocket]
	private var urls: [URL] = []

	init(_ sockets: [MemorySocket]) { self.sockets = sockets }

	var opened: [URL] { lock.withLock { urls } }

	func open(_ url: URL) async throws -> any HostSocket {
		let socket = lock.withLock { () -> MemorySocket? in
			urls.append(url)
			return sockets.isEmpty ? nil : sockets.removeFirst()
		}
		guard let socket else { throw URLError(.cannotConnectToHost) }
		return socket
	}
}

/// A host written in Swift, for tests of the client's own logic. It runs the
/// responder side of both handshakes and answers requests from a closure.
/// The live test covers the real host.
struct TestHost: Sendable {
	struct Reply: Sendable {
		var status = 200
		var headers: [String: String] = [:]
		var chunks: [Data] = []
		/// Ends the stream with a reset instead of an end frame.
		var reset: String?
		/// Never ends the stream. A test uses it to check cancellation.
		var hang = false
	}

	let key = Curve25519.KeyAgreement.PrivateKey()
	let hostID = "aaaabbbbccccdddd"
	var name = "Test host"
	var knownDevices: [Data] = []
	var pairingSecret: Data?
	var respond: @Sendable (RequestHead, Data) -> Reply = { _, _ in Reply() }

	var hello: Data {
		try! JSONEncoder().encode(HostHello(hostId: hostID, name: name, version: "test"))
	}

	func paired(deviceKey: Curve25519.KeyAgreement.PrivateKey) -> PairedHost {
		PairedHost(
			hostID: hostID,
			hostName: name,
			relay: URL(string: "ws://relay.test")!,
			hostStaticKey: key.publicKey.rawRepresentation,
			deviceID: "d_test",
			deviceStaticKey: deviceKey.rawRepresentation
		)
	}

	/// Serves one connection until the client leaves. Returns the resets the
	/// client sent, so a test can check that a cancel reached the host.
	@discardableResult
	func serve(_ socket: MemorySocket) async -> [UInt32] {
		do {
			let first = try await socket.receive()
			switch first.first {
			case Wire.helloSession: return try await session(socket, Data(first.dropFirst()))
			case Wire.helloPair: try await pair(socket, Data(first.dropFirst()))
			default: socket.closePeer(code: Wire.Close.badRequest)
			}
		} catch {}
		return []
	}

	private func pair(_ socket: MemorySocket, _ message: Data) async throws {
		guard let secret = pairingSecret else {
			socket.closePeer(code: Wire.Close.pairingFailed)
			return
		}
		let psk = Data(SHA256.hash(data: Data(Wire.pairPSKContext.utf8) + secret))
		var handshake = try HandshakeState(
			pattern: .xxpsk0, initiator: false,
			prologue: Data((Wire.pairPrologue + hostID).utf8), staticKey: key, psk: psk
		)
		do {
			_ = try handshake.readMessage(Data(message.dropFirst(Wire.hintSize)))
		} catch {
			socket.closePeer(code: Wire.Close.pairingFailed)
			return
		}
		try await socket.send(try handshake.writeMessage(payload: hello).message)
		let third = try handshake.readMessage(try await socket.receive())
		var send = try requireTransport(third.transport).1
		let result = PairResult(ok: true, deviceId: "d_paired", hostId: hostID, hostName: name)
		let frame = Wire.frame(.paired, stream: 0, payload: try JSONEncoder().encode(result))
		try await socket.send(try send.encrypt(ad: Data(), plaintext: frame))
	}

	private func session(_ socket: MemorySocket, _ message: Data) async throws -> [UInt32] {
		var handshake = try HandshakeState(
			pattern: .ik, initiator: false,
			prologue: Data((Wire.sessionPrologue + hostID).utf8), staticKey: key
		)
		do {
			_ = try handshake.readMessage(message)
		} catch {
			socket.closePeer(code: Wire.Close.unauthorized)
			return []
		}
		guard let device = handshake.remoteStatic, knownDevices.contains(device) else {
			// The real host says so inside the handshake, then closes.
			var refusal = HostHello(hostId: hostID, name: "", version: "")
			refusal.refused = HostHello.refusedUnknownDevice
			try await socket.send(try handshake.writeMessage(payload: try JSONEncoder().encode(refusal)).message)
			socket.closePeer(code: Wire.Close.unknownDevice)
			return []
		}
		let second = try handshake.writeMessage(payload: hello)
		try await socket.send(second.message)
		var (receive, send) = try requireTransport(second.transport)

		var heads: [UInt32: RequestHead] = [:]
		var bodies: [UInt32: Data] = [:]
		var resets: [UInt32] = []
		func emit(_ kind: Wire.Frame, _ id: UInt32, _ payload: Data = Data()) async throws {
			try await socket.send(try send.encrypt(ad: Data(), plaintext: Wire.frame(kind, stream: id, payload: payload)))
		}
		while let sealed = try? await socket.receive() {
			let frame = try Wire.parse(try receive.decrypt(ad: Data(), ciphertext: sealed))
			let id = frame.stream
			switch frame.kind {
			case .ping:
				try await emit(.pong, id, frame.payload)
			case .request:
				heads[id] = try JSONDecoder().decode(RequestHead.self, from: frame.payload)
				bodies[id] = Data()
			case .body:
				bodies[id]?.append(frame.payload)
			case .reset:
				resets.append(id)
			case .end:
				guard let head = heads.removeValue(forKey: id) else { continue }
				let reply = respond(head, bodies.removeValue(forKey: id) ?? Data())
				try await emit(.response, id, try JSONEncoder().encode(ResponseHead(status: reply.status, headers: reply.headers)))
				for chunk in reply.chunks {
					// Cut a body the way the real host does.
					var rest = chunk
					repeat {
						try await emit(.body, id, Data(rest.prefix(Wire.bodyChunk)))
						rest = Data(rest.dropFirst(Wire.bodyChunk))
					} while !rest.isEmpty
				}
				if let code = reply.reset {
					try await emit(.reset, id, try JSONEncoder().encode(ResetBody(code: code, message: "The host stopped.")))
				} else if !reply.hang {
					try await emit(.end, id)
				}
			default:
				break
			}
		}
		return resets
	}
}

struct MissingTransport: Error {}

func requireTransport(_ transport: (CipherState, CipherState)?) throws -> (CipherState, CipherState) {
	guard let transport else { throw MissingTransport() }
	return transport
}
