import Foundation

/// A message socket to a relay. The package ships a `URLSession`
/// implementation. A test passes its own.
public protocol HostSocket: Sendable {
	/// Sends one binary message.
	func send(_ message: Data) async throws
	/// Waits for the next binary message. Throws `HostSocketClosed` when the
	/// far side ended the connection with a code.
	func receive() async throws -> Data
	func close()
}

/// The far side closed the socket with a WebSocket close code.
public struct HostSocketClosed: Error, Sendable, Equatable {
	public let code: Int
	public let reason: String

	public init(code: Int, reason: String = "") {
		self.code = code
		self.reason = reason
	}
}

/// Opens sockets. `HostClient` takes one so a test can swap the network out.
public protocol HostSocketOpener: Sendable {
	func open(_ url: URL) async throws -> any HostSocket
}

/// Opens WebSockets with `URLSession`.
public struct URLSessionSocketOpener: HostSocketOpener {
	public init() {}

	public func open(_ url: URL) async throws -> any HostSocket {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = false
		configuration.timeoutIntervalForRequest = 20
		let session = URLSession(configuration: configuration)
		let task = session.webSocketTask(with: url, protocols: [Wire.subprotocol])
		task.maximumMessageSize = Wire.maxSocketMessage
		task.resume()
		let socket = URLSessionSocket(session: session, task: task)
		socket.keepAlive(every: .seconds(25))
		return socket
	}
}

final class URLSessionSocket: HostSocket {
	private let session: URLSession
	private let task: URLSessionWebSocketTask

	init(session: URLSession, task: URLSessionWebSocketTask) {
		self.session = session
		self.task = task
	}

	/// Sends a WebSocket ping at a steady interval while the socket is open.
	///
	/// An app can hold a connection open for minutes between requests. A
	/// home router forgets a silent connection, and so do some networks in
	/// between. The ping is answered at the relay's edge and never reaches
	/// the host, so it costs the host nothing.
	func keepAlive(every interval: Duration) {
		let task = task
		Task.detached(priority: .utility) {
			while task.state == .running {
				try? await Task.sleep(for: interval)
				guard task.state == .running else { return }
				task.sendPing { _ in }
			}
		}
	}

	func send(_ message: Data) async throws {
		do {
			try await task.send(.data(message))
		} catch {
			throw closure() ?? error
		}
	}

	func receive() async throws -> Data {
		while true {
			do {
				if case .data(let data) = try await task.receive() { return data }
				// A text message has no meaning on this socket. Skip it.
			} catch {
				throw closure() ?? error
			}
		}
	}

	/// The close code the far side sent, if it sent one. The relay and the
	/// host report why they refuse a connection this way.
	private func closure() -> HostSocketClosed? {
		let code = task.closeCode.rawValue
		guard code >= 1000 else { return nil }
		let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
		return HostSocketClosed(code: code, reason: reason)
	}

	func close() {
		task.cancel(with: .normalClosure, reason: nil)
		session.finishTasksAndInvalidate()
	}
}
