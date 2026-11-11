import CryptoKit
import Foundation
import Testing
@testable import TetrixHostKit

/// Runs the Swift client against a real host through a real relay. This is
/// the test that proves the two implementations of the protocol agree on
/// the network, not only on vectors.
///
/// `scripts/interop.sh` starts a relay and a host, makes a pairing link, and
/// runs this suite with the link in `TETRIX_HOST_PAIR_LINK`. Without that
/// variable the suite is skipped.
@Suite("Against a running host", .enabled(if: ProcessInfo.processInfo.environment["TETRIX_HOST_PAIR_LINK"] != nil))
struct LiveHostTests {
	private let device = DeviceInfo(name: "Swift interop test", app: "TetrixHostKit", appVersion: TetrixHostKit.version)

	@Test("Pair, connect, and use both roles", .timeLimit(.minutes(3)))
	func endToEnd() async throws {
		let link = try #require(ProcessInfo.processInfo.environment["TETRIX_HOST_PAIR_LINK"])
		let offer = try PairingOffer(link)

		let paired = try await HostPairing.pair(code: link, device: device)
		#expect(paired.hostID == offer.hostID)
		#expect(paired.hostStaticKey.count == 32)
		#expect(paired.deviceID.hasPrefix("d_"))

		// A code works once.
		await #expect(throws: HostError.pairingRefused) {
			_ = try await HostPairing.pair(code: link, device: device)
		}

		let client = HostClient(host: paired, device: device)
		let info = try await client.info()
		#expect(info.id == paired.hostID)
		#expect(info[.deep]?.available == true)

		// A deadline that passes ends the call and leaves the client usable.
		await #expect(throws: HostError.timedOut) {
			_ = try await client.data(for: HostRequest(path: "/v1/host"), timeout: .zero)
		}
		#expect(try await client.info().id == paired.hostID)

		// A streamed answer from each role, at the same time, on one connection.
		async let deep = collect(client.chat([.user("Reply with the single word: ready")], role: .deep, maxTokens: 400))
		async let quick = collect(client.chat([.user("Reply with the single word: ready")], role: .quick, maxTokens: 32))
		let (deepAnswer, quickAnswer) = try await (deep, quick)
		#expect(!(deepAnswer.text + deepAnswer.reasoning).isEmpty)
		#expect(!quickAnswer.text.isEmpty)
		#expect(deepAnswer.usage?.completionTokens ?? 0 > 0)
		#expect(quickAnswer.finished)

		// A plain JSON answer.
		let body = try JSONSerialization.data(withJSONObject: [
			"model": "quick",
			"messages": [["role": "user", "content": "Reply with the single word: ready"]],
			"max_tokens": 16,
		])
		let plain: Data = try await client.data(for: .json("/v1/chat/completions", body: body))
		#expect(String(decoding: plain, as: UTF8.self).contains("\"choices\""))

		// The host's own error reaches the app as written.
		let bad = try JSONSerialization.data(withJSONObject: ["model": "ollama/no-such-model", "messages": []])
		do {
			_ = try await client.data(for: .json("/v1/chat/completions", body: bad))
			Issue.record("An unknown model was accepted.")
		} catch let HostError.requestRejected(status, code, _) {
			#expect(status == 404)
			#expect(code == "model_not_found")
		}

		// A paired device cannot reach the admin routes.
		await #expect(throws: HostError.requestRejected(status: 404, code: "", message: "The host answered 404.")) {
			_ = try await client.data(for: HostRequest(path: "/admin/v1/status"))
		}

		// Stopping a stream leaves the connection usable.
		var seen = 0
		for try await _ in client.chat([.user("Count from 1 to 200, one number per line.")], role: .quick) {
			seen += 1
			if seen == 3 { break }
		}
		#expect(try await client.info().id == paired.hostID)
		await client.disconnect()

		// A second device pairs and then unpairs itself. The host forgets
		// it, and says so in the sealed handshake the next time it tries.
		if let second = try Self.newPairingLink() {
			let leaving = try await HostPairing.pair(code: second, device: device)
			let leavingClient = HostClient(host: leaving, device: device)
			try await leavingClient.unpair()
			var refused = false
			for _ in 0..<40 where !refused {
				do {
					_ = try await HostConnection.connect(to: leaving, device: device)
				} catch HostError.deviceNotPaired {
					refused = true
				}
				try await Task.sleep(for: .milliseconds(50))
			}
			#expect(refused, "The host still accepts a device that unpaired itself.")
		}

		// The relay cannot stand in for the host: a client that pinned
		// another key refuses the session.
		let wrongHost = PairedHost(
			hostID: paired.hostID, hostName: paired.hostName, relay: paired.relay,
			hostStaticKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
			deviceID: paired.deviceID, deviceStaticKey: paired.deviceStaticKey
		)
		await #expect(throws: HostError.hostNotVerified) {
			_ = try await HostConnection.connect(to: wrongHost, device: device)
		}

		// A key the host never paired with is turned away.
		let stranger = PairedHost(
			hostID: paired.hostID, hostName: paired.hostName, relay: paired.relay,
			hostStaticKey: paired.hostStaticKey,
			deviceID: "d_stranger", deviceStaticKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
		)
		await #expect(throws: HostError.deviceNotPaired) {
			_ = try await HostConnection.connect(to: stranger, device: device)
		}

		// A host ID nobody registered is offline.
		let nobody = PairedHost(
			hostID: "aaaaaaaaaaaaaaaa", hostName: "", relay: paired.relay,
			hostStaticKey: paired.hostStaticKey, deviceID: "", deviceStaticKey: paired.deviceStaticKey
		)
		await #expect(throws: HostError.hostOffline) {
			_ = try await HostConnection.connect(to: nobody, device: device)
		}
	}

	/// Asks the host under test for another pairing link. A host holds one
	/// open code at a time, so this runs only after the first is spent.
	/// `scripts/interop.sh` names the host's binary. Without it, the part
	/// of the test that needs a second device is skipped.
	private static func newPairingLink() throws -> String? {
		guard let binary = ProcessInfo.processInfo.environment["TETRIX_HOST_INTEROP_BINARY"] else { return nil }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: binary)
		process.arguments = ["pair", "--json"]
		let output = Pipe()
		process.standardOutput = output
		try process.run()
		process.waitUntilExit()
		struct Offer: Decodable { var link: String }
		let data = output.fileHandleForReading.readDataToEndOfFile()
		return try JSONDecoder().decode(Offer.self, from: data).link
	}

	private struct Answer {
		var text = ""
		var reasoning = ""
		var usage: ChatUsage?
		var finished = false
	}

	private func collect(_ stream: AsyncThrowingStream<ChatDelta, any Error>) async throws -> Answer {
		var answer = Answer()
		for try await delta in stream {
			answer.text += delta.content ?? ""
			answer.reasoning += delta.reasoning ?? ""
			answer.usage = delta.usage ?? answer.usage
			if delta.finishReason != nil { answer.finished = true }
		}
		return answer
	}
}
