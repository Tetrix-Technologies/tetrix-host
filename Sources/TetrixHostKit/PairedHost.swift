import CryptoKit
import Foundation

/// What an app keeps after it pairs with a host.
///
/// `deviceStaticKey` is this device's private key. Anyone who holds it can
/// use the host as this device, so store a `PairedHost` in the Keychain.
/// `PairedHostStore` does that.
public struct PairedHost: Codable, Sendable, Equatable, Identifiable {
	public var id: String { hostID }

	/// The host's name on its relay.
	public let hostID: String
	/// The name the host's owner gave it. Show this to the person.
	public var hostName: String
	/// The relay the host connects to.
	public let relay: URL
	/// The host's static public key. Every session checks the host against
	/// it, which is what stops a relay from standing in for the host.
	public let hostStaticKey: Data
	/// This device's ID on the host.
	public let deviceID: String
	/// This device's private key, 32 bytes.
	public let deviceStaticKey: Data

	public init(hostID: String, hostName: String, relay: URL, hostStaticKey: Data, deviceID: String, deviceStaticKey: Data) {
		self.hostID = hostID
		self.hostName = hostName
		self.relay = relay
		self.hostStaticKey = hostStaticKey
		self.deviceID = deviceID
		self.deviceStaticKey = deviceStaticKey
	}

	/// The relay address a client dials to reach this host.
	var connectURL: URL {
		relay.appending(path: "v1/connect/\(hostID)")
	}
}

/// How a device describes itself to a host. The host's owner sees these
/// values in the list of paired devices.
public struct DeviceInfo: Sendable, Equatable {
	/// The device's name, for example "Noah's MacBook Pro".
	public var name: String
	/// The app's name, for example "Cue".
	public var app: String
	public var appVersion: String
	/// The platform's name, for example "macOS".
	public var platform: String

	public init(name: String, app: String, appVersion: String = "", platform: String = DeviceInfo.currentPlatform) {
		self.name = name
		self.app = app
		self.appVersion = appVersion
		self.platform = platform
	}

	public static var currentPlatform: String {
		#if os(macOS)
		"macOS"
		#elseif os(iOS)
		"iOS"
		#elseif os(visionOS)
		"visionOS"
		#else
		"Unknown"
		#endif
	}

	var hello: ClientHello {
		ClientHello(name: name, app: app, appVersion: appVersion, platform: platform, sdk: "TetrixHostKit/\(TetrixHostKit.version)")
	}
}

/// The package's version, sent to the host in each handshake.
public enum TetrixHostKit {
	public static let version = "0.1.0"
}

/// Why a call to a host failed. Each case's description is written for a
/// person and is safe to show.
public enum HostError: Error, Sendable, Equatable {
	/// The text is not a pairing code or link.
	case invalidPairingCode
	/// The host refused the code. It is wrong, used, or expired.
	case pairingRefused
	/// The host is not connected to its relay.
	case hostOffline
	/// The host's owner unpaired this device. The host says this inside the
	/// sealed handshake, so a relay cannot fake it. It is safe to remove the
	/// pairing when you see this.
	case deviceNotPaired
	/// The far side did not prove that it holds the host's key. Nothing was
	/// sent to it. A relay or a network fault can cause this, so do not
	/// remove a pairing because of it. If it persists, the host's identity
	/// changed, and the person must pair again.
	case hostNotVerified
	/// The relay did not answer.
	case relayUnreachable
	/// The host has too many connections open.
	case hostBusy
	/// The connection dropped. A new call opens a new one.
	case connectionLost
	case timedOut
	/// The host answered a request with an error status.
	case requestRejected(status: Int, code: String, message: String)
	/// The host ended one request early.
	case requestEnded(code: String, message: String)
	case protocolViolation(String)
}

extension HostError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidPairingCode: "That is not a pairing code."
		case .pairingRefused: "The host did not accept that code. Codes work once and expire after 10 minutes."
		case .hostOffline: "The host is offline."
		case .deviceNotPaired: "This device is no longer paired with the host."
		case .hostNotVerified: "The host could not prove its identity."
		case .relayUnreachable: "The relay is not answering. Check the network connection."
		case .hostBusy: "The host is busy. Try again in a moment."
		case .connectionLost: "The connection to the host dropped."
		case .timedOut: "The host took too long to answer."
		case .requestRejected(_, _, let message): message
		case .requestEnded(_, let message): message.isEmpty ? "The host ended the request." : message
		case .protocolViolation(let detail): "The host sent something unexpected. \(detail)"
		}
	}
}

extension HostError {
	/// Turns any error from the socket or the handshake into a `HostError`.
	static func from(_ error: any Error) -> HostError {
		if let error = error as? HostError { return error }
		if let closed = error as? HostSocketClosed {
			switch closed.code {
			// A close code is not sealed, so a relay can send any of these.
			// None of them may lead an app to drop a pairing. The host's
			// own refusal of an unpaired device arrives in the handshake.
			case Wire.Close.hostOffline: return .hostOffline
			case Wire.Close.unknownDevice: return .connectionLost
			case Wire.Close.unauthorized: return .hostNotVerified
			case Wire.Close.pairingFailed: return .pairingRefused
			case Wire.Close.tooManySessions, Wire.Close.slowConsumer: return .hostBusy
			default: return .connectionLost
			}
		}
		if error is NoiseError { return .hostNotVerified }
		if error is CancellationError { return .connectionLost }
		if let url = error as? URLError {
			switch url.code {
			case .timedOut: return .timedOut
			case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
			     .badServerResponse, .appTransportSecurityRequiresSecureConnection:
				return .relayUnreachable
			default: return .connectionLost
			}
		}
		return .connectionLost
	}
}
