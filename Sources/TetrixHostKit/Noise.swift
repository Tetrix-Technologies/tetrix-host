import CryptoKit
import Foundation

// The Noise Protocol Framework, revision 34, for the two handshakes this
// protocol uses: Noise_XXpsk0_25519_ChaChaPoly_SHA256 to pair, and
// Noise_IK_25519_ChaChaPoly_SHA256 for a session. CryptoKit supplies every
// primitive. This file only arranges them the way the Noise specification
// says to.
//
// `Tests/TetrixHostKitTests/NoiseVectorTests.swift` checks each byte this
// file produces against vectors made by the Go implementation the host uses,
// github.com/flynn/noise.

enum NoiseError: Error {
	/// A message did not authenticate. The peer holds a different key, or the
	/// message was changed on the way.
	case authenticationFailed
	case malformedMessage
	case missingKey
	case handshakeComplete
}

/// One direction of a sealed channel.
struct CipherState: Sendable {
	private var key: SymmetricKey?
	private var nonce: UInt64 = 0

	init(key: SymmetricKey? = nil) { self.key = key }

	var hasKey: Bool { key != nil }

	/// The 96-bit nonce Noise defines for ChaChaPoly: four zero bytes, then
	/// the counter in little-endian order.
	private static func nonceValue(_ n: UInt64) -> ChaChaPoly.Nonce {
		var bytes = Data(count: 4)
		withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
		// 12 bytes always make a nonce.
		return try! ChaChaPoly.Nonce(data: bytes)
	}

	mutating func encrypt(ad: Data, plaintext: some DataProtocol) throws -> Data {
		guard let key else { return Data(plaintext) }
		let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonceValue(nonce), authenticating: ad)
		nonce += 1
		return box.ciphertext + box.tag
	}

	mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
		guard let key else { return Data(ciphertext) }
		let bytes = Data(ciphertext)
		guard bytes.count >= Wire.tagSize else { throw NoiseError.malformedMessage }
		let split = bytes.count - Wire.tagSize
		do {
			let box = try ChaChaPoly.SealedBox(
				nonce: Self.nonceValue(nonce),
				ciphertext: bytes[..<split],
				tag: bytes[split...]
			)
			let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
			// A failed open leaves the nonce where it was, as Noise requires.
			nonce += 1
			return plaintext
		} catch {
			throw NoiseError.authenticationFailed
		}
	}
}

/// The handshake's running hash and chaining key.
struct SymmetricState: Sendable {
	private(set) var chainingKey: Data
	private(set) var hash: Data
	private var cipher = CipherState()

	init(protocolName: String) {
		let name = Data(protocolName.utf8)
		// A name of 32 bytes or fewer is padded with zeros. A longer one is
		// hashed.
		hash = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
		chainingKey = hash
	}

	var hasKey: Bool { cipher.hasKey }

	mutating func mixHash(_ data: Data) {
		hash = Data(SHA256.hash(data: hash + data))
	}

	mutating func mixKey(_ material: Data) {
		let out = Self.hkdf(chainingKey, material, outputs: 2)
		chainingKey = out[0]
		cipher = CipherState(key: SymmetricKey(data: out[1]))
	}

	mutating func mixKeyAndHash(_ material: Data) {
		let out = Self.hkdf(chainingKey, material, outputs: 3)
		chainingKey = out[0]
		mixHash(out[1])
		cipher = CipherState(key: SymmetricKey(data: out[2]))
	}

	mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
		let ciphertext = try cipher.encrypt(ad: hash, plaintext: plaintext)
		mixHash(ciphertext)
		return ciphertext
	}

	mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
		let plaintext = try cipher.decrypt(ad: hash, ciphertext: ciphertext)
		mixHash(ciphertext)
		return plaintext
	}

	/// The two transport keys. The first seals what the initiator sends.
	func split() -> (CipherState, CipherState) {
		let out = Self.hkdf(chainingKey, Data(), outputs: 2)
		return (CipherState(key: SymmetricKey(data: out[0])), CipherState(key: SymmetricKey(data: out[1])))
	}

	/// Noise's HKDF, which is HMAC-based and fixed to two or three outputs.
	static func hkdf(_ chainingKey: Data, _ material: Data, outputs: Int) -> [Data] {
		func mac(_ key: Data, _ data: Data) -> Data {
			Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
		}
		let temp = mac(chainingKey, material)
		var out = [mac(temp, Data([0x01]))]
		for i in 2...max(2, outputs) {
			out.append(mac(temp, out[out.count - 1] + Data([UInt8(i)])))
		}
		return out
	}
}

/// A Noise handshake for the two patterns this protocol uses.
struct HandshakeState: Sendable {
	typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey

	enum Token: Sendable { case e, s, ee, es, se, ss, psk }

	struct Pattern: Sendable {
		var name: String
		/// True when the initiator knows the responder's static key before
		/// the first message.
		var responderStaticKnown: Bool
		/// Message patterns in order. The initiator writes the first.
		var messages: [[Token]]

		/// Both sides prove a shared secret and learn each other's static key.
		static let xxpsk0 = Pattern(
			name: "XXpsk0",
			responderStaticKnown: false,
			messages: [[.psk, .e], [.e, .ee, .s, .es], [.s, .se]]
		)
		/// The initiator already holds the responder's static key.
		static let ik = Pattern(
			name: "IK",
			responderStaticKnown: true,
			messages: [[.e, .es, .s, .ss], [.e, .ee, .se]]
		)
	}

	private var symmetric: SymmetricState
	private let initiator: Bool
	private let staticKey: PrivateKey
	private var ephemeral: PrivateKey?
	private let fixedEphemeral: PrivateKey?
	private(set) var remoteStatic: Data?
	private var remoteEphemeral: Data?
	private let psk: Data?
	private var remaining: [[Token]]
	private var myTurn: Bool

	/// - Parameters:
	///   - remoteStatic: The responder's static public key. An IK initiator
	///     must pass it.
	///   - psk: The 32-byte pre-shared key. A psk pattern must pass it.
	///   - ephemeral: A fixed ephemeral key. Only tests pass it.
	init(
		pattern: Pattern,
		initiator: Bool,
		prologue: Data,
		staticKey: PrivateKey,
		remoteStatic: Data? = nil,
		psk: Data? = nil,
		ephemeral: PrivateKey? = nil
	) throws {
		symmetric = SymmetricState(protocolName: "Noise_\(pattern.name)_25519_ChaChaPoly_SHA256")
		self.initiator = initiator
		self.staticKey = staticKey
		self.remoteStatic = remoteStatic.map { Data($0) }
		self.psk = psk
		fixedEphemeral = ephemeral
		remaining = pattern.messages
		myTurn = initiator
		if pattern.messages.joined().contains(.psk), psk?.count != 32 { throw NoiseError.missingKey }

		symmetric.mixHash(prologue)
		if pattern.responderStaticKnown {
			// The pre-message: both sides hash the responder's static key.
			if initiator {
				guard let remote = self.remoteStatic, remote.count == 32 else { throw NoiseError.missingKey }
				symmetric.mixHash(remote)
			} else {
				symmetric.mixHash(staticKey.publicKey.rawRepresentation)
			}
		}
	}

	/// The value that names this handshake. Both sides hold the same one.
	var handshakeHash: Data { symmetric.hash }

	private func dh(_ key: PrivateKey?, _ remote: Data?) throws -> Data {
		guard let key, let remote else { throw NoiseError.missingKey }
		let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
		return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
	}

	/// Applies a token that mixes a key, which works the same on both sides
	/// of a message.
	private mutating func mix(_ token: Token) throws {
		switch token {
		case .ee: symmetric.mixKey(try dh(ephemeral, remoteEphemeral))
		case .es: symmetric.mixKey(try initiator ? dh(ephemeral, remoteStatic) : dh(staticKey, remoteEphemeral))
		case .se: symmetric.mixKey(try initiator ? dh(staticKey, remoteEphemeral) : dh(ephemeral, remoteStatic))
		case .ss: symmetric.mixKey(try dh(staticKey, remoteStatic))
		case .psk:
			guard let psk else { throw NoiseError.missingKey }
			symmetric.mixKeyAndHash(psk)
		case .e, .s: break
		}
	}

	/// Writes the next handshake message. `transport` is set on the last one.
	mutating func writeMessage(payload: Data = Data()) throws -> (message: Data, transport: (CipherState, CipherState)?) {
		guard myTurn, !remaining.isEmpty else { throw NoiseError.handshakeComplete }
		var out = Data()
		for token in remaining.removeFirst() {
			switch token {
			case .e:
				let key = fixedEphemeral ?? PrivateKey()
				ephemeral = key
				let pub = key.publicKey.rawRepresentation
				out.append(pub)
				symmetric.mixHash(pub)
				// In a psk handshake the ephemeral key also feeds the chain.
				if psk != nil { symmetric.mixKey(pub) }
			case .s:
				out.append(try symmetric.encryptAndHash(staticKey.publicKey.rawRepresentation))
			default:
				try mix(token)
			}
		}
		out.append(try symmetric.encryptAndHash(payload))
		myTurn = false
		return (out, remaining.isEmpty ? symmetric.split() : nil)
	}

	/// Reads the peer's next handshake message. `transport` is set on the
	/// last one.
	mutating func readMessage(_ message: Data) throws -> (payload: Data, transport: (CipherState, CipherState)?) {
		guard !myTurn, !remaining.isEmpty else { throw NoiseError.handshakeComplete }
		var rest = Data(message)
		func take(_ n: Int) throws -> Data {
			guard rest.count >= n else { throw NoiseError.malformedMessage }
			let head = Data(rest.prefix(n))
			rest = Data(rest.dropFirst(n))
			return head
		}
		for token in remaining.removeFirst() {
			switch token {
			case .e:
				let pub = try take(32)
				remoteEphemeral = pub
				symmetric.mixHash(pub)
				if psk != nil { symmetric.mixKey(pub) }
			case .s:
				let sealed = try take(symmetric.hasKey ? 32 + Wire.tagSize : 32)
				remoteStatic = try symmetric.decryptAndHash(sealed)
			default:
				try mix(token)
			}
		}
		let payload = try symmetric.decryptAndHash(rest)
		myTurn = true
		return (payload, remaining.isEmpty ? symmetric.split() : nil)
	}
}
