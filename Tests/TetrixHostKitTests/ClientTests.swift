import CryptoKit
import Foundation
import Testing
@testable import TetrixHostKit

private let device = DeviceInfo(name: "Test laptop", app: "Tests", appVersion: "1")

/// A client wired to a `TestHost` through in-memory sockets.
private struct Rig {
	let host: TestHost
	let client: HostClient
	let opener: MemoryOpener
	let serving: Task<[UInt32], Never>

	init(_ configure: (inout TestHost) -> Void = { _ in }, known: Bool = true, wrongHostKey: Bool = false) {
		let deviceKey = Curve25519.KeyAgreement.PrivateKey()
		var host = TestHost()
		if known { host.knownDevices = [deviceKey.publicKey.rawRepresentation] }
		configure(&host)
		let (clientEnd, hostEnd) = MemorySocket.pair()
		var paired = host.paired(deviceKey: deviceKey)
		if wrongHostKey {
			paired = PairedHost(
				hostID: paired.hostID, hostName: paired.hostName, relay: paired.relay,
				hostStaticKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
				deviceID: paired.deviceID, deviceStaticKey: paired.deviceStaticKey
			)
		}
		opener = MemoryOpener([clientEnd])
		client = HostClient(host: paired, device: device, opener: opener)
		self.host = host
		let served = host
		serving = Task { await served.serve(hostEnd) }
	}
}

@Suite("Client")
struct ClientTests {
	@Test("A request crosses and its answer comes back")
	func roundTrip() async throws {
		let rig = Rig { host in
			host.respond = { head, body in
				TestHost.Reply(headers: ["x-path": head.path, "x-method": head.method], chunks: [body])
			}
		}
		let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
		let response = try await rig.client.send(.json("/v1/echo", body: big))
		var body = Data()
		for try await chunk in response.body { body.append(chunk) }
		#expect(response.status == 200)
		#expect(response.headers["x-path"] == "/v1/echo")
		#expect(response.headers["x-method"] == "POST")
		// 200,000 bytes cross as seven frames and arrive whole and in order.
		#expect(body == big)
		#expect(rig.opener.opened.first?.absoluteString == "ws://relay.test/v1/connect/aaaabbbbccccdddd")
	}

	@Test("Many requests share one connection")
	func concurrent() async throws {
		let rig = Rig { host in
			host.respond = { _, body in TestHost.Reply(chunks: [body]) }
		}
		try await withThrowingTaskGroup(of: Void.self) { group in
			for i in 0..<12 {
				group.addTask {
					let sent = Data("request \(i)".utf8)
					let got = try await rig.client.data(for: .json("/v1/echo", body: sent))
					#expect(got == sent)
				}
			}
			try await group.waitForAll()
		}
		#expect(rig.opener.opened.count == 1)
	}

	@Test("An event stream arrives as lines")
	func lines() async throws {
		let rig = Rig { host in
			host.respond = { _, _ in
				// The chunk boundaries fall mid-line and mid-character.
				let text = Data("data: one\r\n\ndata: caf\u{E9}\n\ndata: [DONE]\n".utf8)
				return TestHost.Reply(chunks: [text.prefix(7), text.dropFirst(7).prefix(15), text.dropFirst(22)].map { Data($0) })
			}
		}
		var got: [String] = []
		for try await line in rig.client.lines(for: HostRequest(path: "/v1/stream")) { got.append(line) }
		#expect(got == ["data: one", "", "data: caf\u{E9}", "", "data: [DONE]"])
	}

	@Test("An error status becomes an error with the host's message")
	func rejection() async throws {
		let rig = Rig { host in
			host.respond = { _, _ in
				TestHost.Reply(status: 503, chunks: [Data(#"{"error":{"message":"No model is assigned.","code":"no_model_assigned"}}"#.utf8)])
			}
		}
		let expected = HostError.requestRejected(status: 503, code: "no_model_assigned", message: "No model is assigned.")
		await #expect(throws: expected) {
			_ = try await rig.client.data(for: HostRequest(path: "/v1/models"))
		}
		await #expect(throws: expected) {
			for try await _ in rig.client.lines(for: HostRequest(path: "/v1/models")) {}
		}
	}

	@Test("A reset from the host ends the body with an error")
	func hostReset() async throws {
		let rig = Rig { host in
			host.respond = { _, _ in TestHost.Reply(chunks: [Data("partial".utf8)], reset: "engine_gone") }
		}
		let response = try await rig.client.send(HostRequest(path: "/v1/stream"))
		await #expect(throws: HostError.requestEnded(code: "engine_gone", message: "The host stopped.")) {
			for try await _ in response.body {}
		}
	}

	@Test("Stopping a stream tells the host, and the connection stays usable")
	func cancellation() async throws {
		let rig = Rig { host in
			host.respond = { head, _ in
				head.path == "/v1/forever"
					? TestHost.Reply(chunks: [Data("first".utf8)], hang: true)
					: TestHost.Reply(chunks: [Data("ok".utf8)])
			}
		}
		let reading = Task {
			let response = try await rig.client.send(HostRequest(path: "/v1/forever"))
			for try await _ in response.body {}
		}
		try await Task.sleep(for: .milliseconds(100))
		reading.cancel()
		_ = await reading.result

		#expect(try await rig.client.data(for: HostRequest(path: "/v1/next")) == Data("ok".utf8))
		await rig.client.disconnect()
		#expect(await rig.serving.value == [1])
	}

	@Test("A host that unpaired the device is reported as such")
	func unknownDevice() async {
		let rig = Rig(known: false)
		await #expect(throws: HostError.deviceNotPaired) { try await rig.client.connect() }
	}

	@Test("A close code alone never says that the device is unpaired")
	func relayCannotUnpair() async {
		// A relay sends 4403 without the host's sealed refusal. The client
		// must not report the device as unpaired, or an app that drops the
		// pairing on that error would let the relay unpair it.
		let deviceKey = Curve25519.KeyAgreement.PrivateKey()
		let host = TestHost()
		let (clientEnd, relayEnd) = MemorySocket.pair()
		let client = HostClient(host: host.paired(deviceKey: deviceKey), device: device, opener: MemoryOpener([clientEnd]))
		Task {
			_ = try? await relayEnd.receive()
			relayEnd.closePeer(code: Wire.Close.unknownDevice)
		}
		await #expect(throws: HostError.connectionLost) { try await client.connect() }
	}

	@Test("Letting go of the client ends a body that is still being read")
	func droppedClientEndsTheBody() async throws {
		let deviceKey = Curve25519.KeyAgreement.PrivateKey()
		var host = TestHost()
		host.knownDevices = [deviceKey.publicKey.rawRepresentation]
		host.respond = { _, _ in TestHost.Reply(chunks: [Data("first".utf8)], hang: true) }
		let (clientEnd, hostEnd) = MemorySocket.pair()
		let served = host
		Task { await served.serve(hostEnd) }

		func body() async throws -> AsyncThrowingStream<Data, any Error> {
			let connection = try await HostConnection.connect(
				to: served.paired(deviceKey: deviceKey), device: device, opener: MemoryOpener([clientEnd])
			)
			return try await connection.send(HostRequest(path: "/v1/forever")).body
		}
		let stream = try await body()
		await #expect(throws: HostError.connectionLost) {
			try await withDeadline(.seconds(5)) {
				for try await _ in stream {}
			}
		}
	}

	@Test("A far side without the host's key is refused")
	func impostor() async {
		let rig = Rig(wrongHostKey: true)
		await #expect(throws: HostError.hostNotVerified) { try await rig.client.connect() }
	}

	@Test("A dropped connection fails requests in flight, and the next request reconnects")
	func reconnect() async throws {
		let deviceKey = Curve25519.KeyAgreement.PrivateKey()
		var host = TestHost()
		host.knownDevices = [deviceKey.publicKey.rawRepresentation]
		host.respond = { head, _ in
			head.path == "/v1/forever" ? TestHost.Reply(hang: true) : TestHost.Reply(chunks: [Data("ok".utf8)])
		}
		let (firstClient, firstHost) = MemorySocket.pair()
		let (secondClient, secondHost) = MemorySocket.pair()
		let opener = MemoryOpener([firstClient, secondClient])
		let client = HostClient(host: host.paired(deviceKey: deviceKey), device: device, opener: opener)
		let served = host
		Task { await served.serve(firstHost) }
		Task { await served.serve(secondHost) }

		let response = try await client.send(HostRequest(path: "/v1/forever"))
		firstHost.closePeer(code: 1006)
		await #expect(throws: HostError.connectionLost) {
			for try await _ in response.body {}
		}
		#expect(try await client.data(for: HostRequest(path: "/v1/next")) == Data("ok".utf8))
		#expect(opener.opened.count == 2)
	}

	@Test("Pairing returns the host's key and a new device key")
	func pairing() async throws {
		var host = TestHost()
		let secret = Data((0..<16).map { UInt8($0) })
		host.pairingSecret = secret
		let hostRaw = try #require(Base32.decode(host.hostID.uppercased()))
		let code = Base32.encode(Data([1]) + hostRaw + secret)
		let link = "tetrix-host://pair/\(code)?relay=ws%3A%2F%2Frelay.test"

		let (clientEnd, hostEnd) = MemorySocket.pair()
		let served = host
		Task { await served.serve(hostEnd) }
		let paired = try await HostPairing.pair(code: link, device: device, opener: MemoryOpener([clientEnd]))
		#expect(paired.hostID == host.hostID)
		#expect(paired.hostName == "Test host")
		#expect(paired.relay.absoluteString == "ws://relay.test")
		#expect(paired.hostStaticKey == host.key.publicKey.rawRepresentation)
		#expect(paired.deviceID == "d_paired")
		#expect(paired.deviceStaticKey.count == 32)
	}

	@Test("A code the host does not hold is refused")
	func pairingWithWrongCode() async throws {
		var host = TestHost()
		host.pairingSecret = Data(repeating: 1, count: 16)
		let hostRaw = try #require(Base32.decode(host.hostID.uppercased()))
		let code = Base32.encode(Data([1]) + hostRaw + Data(repeating: 2, count: 16))
		let (clientEnd, hostEnd) = MemorySocket.pair()
		let served = host
		Task { await served.serve(hostEnd) }
		await #expect(throws: HostError.pairingRefused) {
			_ = try await HostPairing.pair(code: code, device: device, opener: MemoryOpener([clientEnd]))
		}
	}
}

@Suite("Parsing")
struct ParsingTests {
	@Test("A code and a link name the same host")
	func offer() throws {
		let raw = Data([1]) + Data(repeating: 0xAB, count: 10) + Data(repeating: 0xCD, count: 16)
		let plain = Base32.encode(raw)
		let grouped = stride(from: 0, to: plain.count, by: 4).map { offset -> String in
			let start = plain.index(plain.startIndex, offsetBy: offset)
			return String(plain[start..<(plain.index(start, offsetBy: 4, limitedBy: plain.endIndex) ?? plain.endIndex)])
		}.joined(separator: "-")

		let bare = try PairingOffer(" \(grouped.lowercased()) \n")
		#expect(bare.relay == Wire.defaultRelay)
		#expect(bare.secret == Data(repeating: 0xCD, count: 16))
		#expect(bare.hostID.count == 16)

		let link = try PairingOffer("tetrix-host://pair/\(grouped)?relay=wss%3A%2F%2Frelay.example.com")
		#expect(link.hostID == bare.hostID)
		#expect(link.relay.absoluteString == "wss://relay.example.com")
		#expect(PairingOffer.isValid(grouped))
	}

	@Test("Text that is not a code is refused", arguments: [
		"", "hello", "AAAA-BBBB", "https://example.com/pair/AAAA",
		"tetrix-host://pair/AAAA?relay=https%3A%2F%2Fexample.com",
	])
	func notACode(text: String) {
		#expect(throws: HostError.invalidPairingCode) { _ = try PairingOffer(text) }
	}

	@Test("Base32 round trips")
	func base32() {
		for count in 0..<40 {
			let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
			#expect(Base32.decode(Base32.encode(data)) == data)
		}
		#expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
		#expect(Base32.decode("MZXW6YTBOI") == Data("foobar".utf8))
		#expect(Base32.decode("MZXW6YTBO1") == nil)
	}

	@Test("Host info tells unknown from none")
	func hostInfo() throws {
		let json = #"""
		{"id":"aaaabbbbccccdddd","name":"Studio","version":"1","single":false,"roles":{
		  "deep":{"model":"ollama/qwen3:8b","available":true,"contextLength":40960,"contextInUse":4096,"capabilities":["tools"]},
		  "quick":{"model":"other/x","available":true,"capabilities":null}}}
		"""#
		let info = try JSONDecoder().decode(HostInfo.self, from: Data(json.utf8))
		let deep = try #require(info[.deep])
		#expect(deep.can("tools") == true)
		#expect(deep.can("vision") == false)
		// The window in use is the one a request must fit.
		#expect(deep.usableContext == 4096)
		let quick = try #require(info[.quick])
		#expect(quick.capabilities == nil)
		#expect(quick.can("tools") == nil)
		#expect(quick.usableContext == nil)
	}

	@Test("Chat event lines decode")
	func chatDelta() {
		#expect(ChatDelta(eventLine: #"data: {"choices":[{"delta":{"content":"Hi"}}]}"#)?.content == "Hi")
		#expect(ChatDelta(eventLine: #"data: {"choices":[{"delta":{"reasoning":"Hm"}}]}"#)?.reasoning == "Hm")
		#expect(ChatDelta(eventLine: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)?.finishReason == "stop")
		let usage = ChatDelta(eventLine: #"data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3}}"#)?.usage
		#expect(usage == ChatUsage(promptTokens: 11, completionTokens: 3))
		#expect(ChatDelta(eventLine: "data: [DONE]") == nil)
		#expect(ChatDelta(eventLine: "") == nil)
		#expect(ChatDelta(eventLine: ": comment") == nil)
	}

	@Test("Frames round trip")
	func frames() throws {
		let frame = Wire.frame(.body, stream: 0x0102_0304, payload: Data("abc".utf8))
		#expect(frame.prefix(10).hex == "02010203040003616263")
		// Padding hides the payload's length within a 512-byte step.
		#expect(frame.count == 512)
		#expect(frame.dropFirst(10).allSatisfy { $0 == 0 })
		#expect(Wire.frame(.body, stream: 1, payload: Data(count: 505)).count == 512)
		#expect(Wire.frame(.body, stream: 1, payload: Data(count: 506)).count == 1024)
		#expect(Wire.frame(.body, stream: 1, payload: Data(count: Wire.bodyChunk)).count == 33280)
		// A slice with a non-zero start index parses the same.
		let parsed = try Wire.parse((Data([0xFF]) + frame).dropFirst())
		#expect(parsed.kind == .body)
		#expect(parsed.stream == 0x0102_0304)
		#expect(parsed.payload == Data("abc".utf8))
		#expect(throws: HostError.self) { _ = try Wire.parse(Data([1, 2])) }
		// A length field that points past the end is refused.
		#expect(throws: HostError.self) { _ = try Wire.parse(Data([2, 0, 0, 0, 1, 0, 9, 1, 2])) }
	}
}
