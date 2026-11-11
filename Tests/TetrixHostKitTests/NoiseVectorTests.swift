import CryptoKit
import Foundation
import Testing
@testable import TetrixHostKit

/// The vectors come from the Go implementation the host runs. See
/// `internal/secure/vectors_test.go`, which writes the file and also fails
/// if the file drifts from the Go code.
struct VectorFile: Decodable {
	struct Message: Decodable {
		var from: String
		var payload: String
		var ciphertext: String
	}

	struct Vector: Decodable {
		var name: String
		var `protocol`: String
		var hostId: String
		var prologue: String
		var psk: String?
		var pairingSecret: String?
		var pairingHint: String?
		var initiatorStatic: String
		var initiatorEphemeral: String
		var responderStatic: String
		var responderEphemeral: String
		var responderPublic: String
		var handshake: [Message]
		var handshakeHash: String
		var transport: [Message]
	}

	var vectors: [Vector]

	static func load() throws -> VectorFile {
		let url = try #require(Bundle.module.url(forResource: "noise-vectors", withExtension: "json", subdirectory: "Fixtures"))
		return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
	}

	func named(_ name: String) throws -> Vector {
		try #require(vectors.first { $0.name == name })
	}
}

extension Data {
	init(hex: String) {
		self.init()
		var index = hex.startIndex
		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			append(UInt8(hex[index..<next], radix: 16)!)
			index = next
		}
	}

	var hex: String { map { String(format: "%02x", $0) }.joined() }
}

@Suite("Noise matches the Go implementation")
struct NoiseVectorTests {
	private func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
		try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: hex))
	}

	private func states(for vector: VectorFile.Vector) throws -> (initiator: HandshakeState, responder: HandshakeState) {
		let pattern: HandshakeState.Pattern = vector.name == "pair" ? .xxpsk0 : .ik
		let psk = vector.psk.map { Data(hex: $0) }
		let initiator = try HandshakeState(
			pattern: pattern,
			initiator: true,
			prologue: Data(hex: vector.prologue),
			staticKey: key(vector.initiatorStatic),
			remoteStatic: pattern.responderStaticKnown ? Data(hex: vector.responderPublic) : nil,
			psk: psk,
			ephemeral: key(vector.initiatorEphemeral)
		)
		let responder = try HandshakeState(
			pattern: pattern,
			initiator: false,
			prologue: Data(hex: vector.prologue),
			staticKey: key(vector.responderStatic),
			psk: psk,
			ephemeral: key(vector.responderEphemeral)
		)
		return (initiator, responder)
	}

	@Test("Every handshake and transport byte is the same", arguments: ["pair", "session"])
	func bytesMatch(name: String) throws {
		let vector = try VectorFile.load().named(name)
		var (initiator, responder) = try states(for: vector)
		var initiatorKeys: (CipherState, CipherState)?
		var responderKeys: (CipherState, CipherState)?

		for message in vector.handshake {
			let payload = Data(hex: message.payload)
			if message.from == "initiator" {
				let written = try initiator.writeMessage(payload: payload)
				#expect(written.message.hex == message.ciphertext)
				let read = try responder.readMessage(Data(hex: message.ciphertext))
				#expect(read.payload == payload)
				initiatorKeys = written.transport ?? initiatorKeys
				responderKeys = read.transport ?? responderKeys
			} else {
				let written = try responder.writeMessage(payload: payload)
				#expect(written.message.hex == message.ciphertext)
				let read = try initiator.readMessage(Data(hex: message.ciphertext))
				#expect(read.payload == payload)
				responderKeys = written.transport ?? responderKeys
				initiatorKeys = read.transport ?? initiatorKeys
			}
		}
		#expect(initiator.handshakeHash.hex == vector.handshakeHash)
		#expect(responder.handshakeHash.hex == vector.handshakeHash)

		// The first key of the pair seals what the initiator sends.
		var (initiatorSend, initiatorReceive) = try #require(initiatorKeys)
		var (responderReceive, responderSend) = try #require(responderKeys)
		for message in vector.transport {
			let payload = Data(hex: message.payload)
			if message.from == "initiator" {
				#expect(try initiatorSend.encrypt(ad: Data(), plaintext: payload).hex == message.ciphertext)
				#expect(try responderReceive.decrypt(ad: Data(), ciphertext: Data(hex: message.ciphertext)) == payload)
			} else {
				#expect(try responderSend.encrypt(ad: Data(), plaintext: payload).hex == message.ciphertext)
				#expect(try initiatorReceive.decrypt(ad: Data(), ciphertext: Data(hex: message.ciphertext)) == payload)
			}
		}
	}

	@Test("The responder's static key is what the initiator learns")
	func pairingLearnsTheHostKey() throws {
		let vector = try VectorFile.load().named("pair")
		var (initiator, _) = try states(for: vector)
		_ = try initiator.writeMessage()
		_ = try initiator.readMessage(Data(hex: vector.handshake[1].ciphertext))
		#expect(initiator.remoteStatic?.hex == vector.responderPublic)
	}

	@Test("A changed byte fails to open")
	func tamperingIsCaught() throws {
		let vector = try VectorFile.load().named("session")
		var (initiator, _) = try states(for: vector)
		_ = try initiator.writeMessage(payload: Data(hex: vector.handshake[0].payload))
		var reply = Data(hex: vector.handshake[1].ciphertext)
		reply[reply.count - 1] ^= 0x01
		#expect(throws: NoiseError.authenticationFailed) {
			_ = try initiator.readMessage(reply)
		}
	}

	@Test("The wrong pairing key fails at the first message")
	func wrongPairingKey() throws {
		let vector = try VectorFile.load().named("pair")
		var responder = try HandshakeState(
			pattern: .xxpsk0,
			initiator: false,
			prologue: Data(hex: vector.prologue),
			staticKey: key(vector.responderStatic),
			psk: Data(repeating: 9, count: 32)
		)
		#expect(throws: NoiseError.authenticationFailed) {
			_ = try responder.readMessage(Data(hex: vector.handshake[0].ciphertext))
		}
	}

	@Test("A session sealed to another host's key fails")
	func wrongHostKey() throws {
		let vector = try VectorFile.load().named("session")
		var initiator = try HandshakeState(
			pattern: .ik,
			initiator: true,
			prologue: Data(hex: vector.prologue),
			staticKey: key(vector.initiatorStatic),
			remoteStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
		)
		let first = try initiator.writeMessage()
		var responder = try HandshakeState(
			pattern: .ik,
			initiator: false,
			prologue: Data(hex: vector.prologue),
			staticKey: key(vector.responderStatic)
		)
		#expect(throws: NoiseError.authenticationFailed) {
			_ = try responder.readMessage(first.message)
		}
	}

	@Test("The pairing code yields the hint and key the host expects")
	func offerDerivations() throws {
		let vector = try VectorFile.load().named("pair")
		let secret = Data(hex: try #require(vector.pairingSecret))
		let hostRaw = try #require(Base32.decode(vector.hostId.uppercased()))
		let code = Base32.encode(Data([1]) + hostRaw + secret)
		let offer = try PairingOffer(code)
		#expect(offer.hostID == vector.hostId)
		#expect(offer.hint.hex == vector.pairingHint)
		#expect(offer.psk.hex == vector.psk)
		#expect(Data((Wire.pairPrologue + offer.hostID).utf8).hex == vector.prologue)
	}
}
