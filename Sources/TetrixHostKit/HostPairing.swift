import CryptoKit
import Foundation

/// Pairs this device with a host.
public enum HostPairing {
	/// Spends a pairing code and returns the pairing to store.
	///
	/// The handshake is Noise XXpsk0. The pre-shared key comes from the
	/// one-time secret in the code, so each side accepts the other only if
	/// both were given the same code. The relay passes the handshake and
	/// cannot join it, because it never sees the code.
	///
	/// - Parameters:
	///   - code: A pairing code or link, as the host shows it.
	///   - device: How this device appears in the host's device list.
	public static func pair(
		code: String,
		device: DeviceInfo,
		opener: any HostSocketOpener = URLSessionSocketOpener(),
		timeout: Duration = .seconds(30)
	) async throws -> PairedHost {
		let offer = try PairingOffer(code)
		let socket: any HostSocket
		do {
			socket = try await opener.open(offer.relay.appending(path: "v1/connect/\(offer.hostID)"))
		} catch {
			throw HostError.from(error)
		}
		defer { socket.close() }
		do {
			return try await withDeadline(timeout, onExpire: { socket.close() }) {
				// A new key for each pairing. It never leaves this device.
				let key = Curve25519.KeyAgreement.PrivateKey()
				var handshake = try HandshakeState(
					pattern: .xxpsk0,
					initiator: true,
					prologue: Data((Wire.pairPrologue + offer.hostID).utf8),
					staticKey: key,
					psk: offer.psk
				)
				let first = try handshake.writeMessage()
				try await socket.send(Data([Wire.helloPair]) + offer.hint + first.message)

				// The host's answer opens only if the host holds the code.
				let second = try handshake.readMessage(try await socket.receive())
				let hello = try JSONDecoder().decode(HostHello.self, from: second.payload)
				guard hello.hostId == offer.hostID else {
					throw HostError.hostNotVerified
				}

				let third = try handshake.writeMessage(payload: JSONEncoder().encode(device.hello))
				try await socket.send(third.message)
				guard var transport = third.transport, let hostKey = handshake.remoteStatic else {
					throw HostError.protocolViolation("The handshake did not finish.")
				}

				let sealed = try await socket.receive()
				let frame = try Wire.parse(try transport.1.decrypt(ad: Data(), ciphertext: sealed))
				guard frame.kind == .paired else {
					throw HostError.protocolViolation("The host did not confirm the pairing.")
				}
				let result = try JSONDecoder().decode(PairResult.self, from: frame.payload)
				guard result.ok, let deviceID = result.deviceId else {
					throw HostError.pairingRefused
				}
				return PairedHost(
					hostID: offer.hostID,
					hostName: result.hostName ?? hello.name,
					relay: offer.relay,
					hostStaticKey: hostKey,
					deviceID: deviceID,
					deviceStaticKey: key.rawRepresentation
				)
			}
		} catch let error as NoiseError {
			// The host's message did not open, so the far side does not hold
			// this code.
			_ = error
			throw HostError.pairingRefused
		} catch {
			throw HostError.from(error)
		}
	}
}
