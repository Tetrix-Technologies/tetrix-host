import CryptoKit
import Foundation

/// What a pairing code or link says: which host, on which relay, and the
/// one-time secret that proves the app was shown the code.
public struct PairingOffer: Sendable, Equatable {
	/// The host's name on its relay.
	public let hostID: String
	/// The relay to reach the host through.
	public let relay: URL
	let secret: Data

	/// Reads a code such as `AEBY-IKII-...` or a link such as
	/// `tetrix-host://pair/AEBY-IKII-...?relay=wss://relay.example.com`.
	///
	/// A bare code names no relay, so it means the default one.
	public init(_ text: String) throws {
		var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
		var relay = Wire.defaultRelay
		if code.contains("://") {
			guard let parts = URLComponents(string: code), parts.host == "pair" else {
				throw HostError.invalidPairingCode
			}
			if let value = parts.queryItems?.first(where: { $0.name == "relay" })?.value {
				guard let url = URL(string: value), let scheme = url.scheme, ["wss", "ws"].contains(scheme) else {
					throw HostError.invalidPairingCode
				}
				relay = url
			}
			code = String(parts.path.drop(while: { $0 == "/" }))
		}
		let letters = code.uppercased().filter { $0 != "-" && $0 != " " }
		// A version byte, a 10-byte host ID, and a 16-byte secret.
		guard let raw = Base32.decode(letters), raw.count == 27, raw[0] == 1 else {
			throw HostError.invalidPairingCode
		}
		hostID = Base32.encode(raw[1..<11]).lowercased()
		secret = Data(raw[11...])
		self.relay = relay
	}

	/// Whether text looks like a pairing code or link. Use it to decide
	/// whether to offer "Pair" for something on the pasteboard.
	public static func isValid(_ text: String) -> Bool {
		(try? PairingOffer(text)) != nil
	}

	/// The 4 bytes that tell the host which code this is, without revealing
	/// the secret.
	var hint: Data {
		Data(SHA256.hash(data: Data(Wire.pairHintContext.utf8) + secret).prefix(Wire.hintSize))
	}

	/// The secret stretched to the 32 bytes Noise requires.
	var psk: Data {
		Data(SHA256.hash(data: Data(Wire.pairPSKContext.utf8) + secret))
	}
}

/// RFC 4648 base32 without padding.
enum Base32 {
	private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

	static func encode(_ data: some DataProtocol) -> String {
		var out = [UInt8]()
		var buffer: UInt32 = 0
		var bits = 0
		for byte in data {
			buffer = buffer << 8 | UInt32(byte)
			bits += 8
			while bits >= 5 {
				bits -= 5
				out.append(alphabet[Int(buffer >> UInt32(bits)) & 31])
			}
		}
		if bits > 0 {
			out.append(alphabet[Int(buffer << UInt32(5 - bits)) & 31])
		}
		return String(decoding: out, as: UTF8.self)
	}

	static func decode(_ text: String) -> Data? {
		var out = Data()
		var buffer: UInt32 = 0
		var bits = 0
		for character in text.utf8 {
			guard let value = alphabet.firstIndex(of: character) else { return nil }
			buffer = buffer << 5 | UInt32(value)
			bits += 5
			if bits >= 8 {
				bits -= 8
				out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
			}
		}
		// Leftover bits must be zero padding.
		guard bits < 5, buffer & (1 << UInt32(bits) - 1) == 0 else { return nil }
		return out
	}
}
