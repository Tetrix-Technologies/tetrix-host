import Foundation

/// The bytes that cross the network. `docs/reference/protocol.md` is the
/// specification. This file is its Swift form, and `internal/wire/wire.go`
/// is its Go form. A change to one is a change to all three.
enum Wire {
	static let subprotocol = "tetrix-host.v1"
	static let defaultRelay = URL(string: "wss://relay.tetrix.tech")!

	static let maxNoiseMessage = 65535
	static let tagSize = 16
	static let tunnelHeaderSize = 7
	/// The largest payload that fits one sealed message.
	static let maxFramePayload = maxNoiseMessage - tagSize - tunnelHeaderSize
	/// The step a frame is padded to before it is sealed. A model streams
	/// its answer a token at a time. Without padding, the size of each
	/// sealed message would give away the length of each token to anyone
	/// who watches the connection, the relay included.
	static let padBlock = 512
	static let bodyChunk = 32 * 1024
	/// The largest message this client accepts from a relay. A relay passes
	/// bare Noise messages, so anything larger is not from a host.
	static let maxSocketMessage = maxNoiseMessage
	static let hintSize = 4

	// Domain-separation strings. Each one names a single use of a key or hash.
	static let pairPrologue = "tetrix-host/pair/1\0"
	static let sessionPrologue = "tetrix-host/session/1\0"
	static let pairHintContext = "tetrix-host/pair-hint/1\0"
	static let pairPSKContext = "tetrix-host/pair-psk/1\0"

	/// The first byte of a client's opening message.
	static let helloPair: UInt8 = 0x01
	static let helloSession: UInt8 = 0x02

	/// A tunnel frame's type. One frame travels in each sealed message.
	enum Frame: UInt8 {
		case request = 0x01
		case body = 0x02
		case end = 0x03
		case response = 0x04
		case reset = 0x05
		case ping = 0x06
		case pong = 0x07
		case paired = 0x10
	}

	/// WebSocket close codes the relay and the host use.
	enum Close {
		static let badRequest = 4400
		static let unauthorized = 4401
		static let unknownDevice = 4403
		static let hostOffline = 4404
		static let slowConsumer = 4408
		static let replaced = 4409
		static let pairingFailed = 4410
		static let tooManySessions = 4429
		static let hostError = 4500
	}

	/// Builds a frame: one type byte, a 4-byte big-endian stream ID, a 2-byte
	/// big-endian payload length, the payload, and zero bytes up to the next
	/// multiple of `padBlock`. The payload must fit one sealed message.
	static func frame(_ kind: Frame, stream: UInt32, payload: some DataProtocol = Data()) -> Data {
		precondition(payload.count <= maxFramePayload, "A frame payload must fit one sealed message.")
		let size = tunnelHeaderSize + payload.count
		let padded = min((size + padBlock - 1) / padBlock * padBlock, maxNoiseMessage - tagSize)
		var out = Data(capacity: padded)
		out.append(kind.rawValue)
		withUnsafeBytes(of: stream.bigEndian) { out.append(contentsOf: $0) }
		withUnsafeBytes(of: UInt16(payload.count).bigEndian) { out.append(contentsOf: $0) }
		out.append(contentsOf: payload)
		out.append(Data(count: padded - size))
		return out
	}

	/// Splits a frame and drops its padding. An unknown type is returned as
	/// nil so the caller can ignore it, which lets a newer host add frame
	/// types.
	static func parse(_ data: Data) throws -> (kind: Frame?, stream: UInt32, payload: Data) {
		let bytes = Data(data)
		guard bytes.count >= tunnelHeaderSize else {
			throw HostError.protocolViolation("A frame was too short.")
		}
		let stream = bytes[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
		let length = Int(bytes[5]) << 8 | Int(bytes[6])
		guard tunnelHeaderSize + length <= bytes.count else {
			throw HostError.protocolViolation("A frame was shorter than its length.")
		}
		return (Frame(rawValue: bytes[0]), stream, Data(bytes[7..<(7 + length)]))
	}
}

struct RequestHead: Codable {
	var method: String
	var path: String
	var headers: [String: String]?
}

struct ResponseHead: Codable {
	var status: Int
	var headers: [String: String]?
}

struct ResetBody: Codable {
	var code: String?
	var message: String?
}

struct ClientHello: Codable {
	var name: String?
	var app: String?
	var appVersion: String?
	var platform: String?
	var sdk: String?
}

struct PairResult: Codable {
	var ok: Bool
	var deviceId: String?
	var hostId: String?
	var hostName: String?
	var error: String?
}

/// What a host says about itself in its handshake.
public struct HostHello: Codable, Sendable, Equatable {
	public var hostId: String
	public var name: String
	public var version: String
	/// Set when the host will not serve this device. It arrives inside the
	/// handshake, so it is the host's own word.
	var refused: String?

	static let refusedUnknownDevice = "unknown_device"
}
