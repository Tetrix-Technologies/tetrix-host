import Foundation
import Testing
@testable import TetrixHost

@Suite("Status document")
struct StatusDecodingTests {
	/// A status document as a running host wrote it, with one device added.
	static let live = """
	{
	  "product": "Tetrix Host",
	  "version": "0.1.0-dev",
	  "host": {
	    "id": "aoccscb7qz37b47z",
	    "name": "Noahs-Mac-mini-4",
	    "startedAt": "2026-11-11T02:36:05.176158Z",
	    "address": "127.0.0.1:4790",
	    "endpoint": "http://127.0.0.1:4790/v1"
	  },
	  "hardware": {
	    "model": "Mac mini", "kind": "desktop", "chip": "Apple M4", "cores": 10,
	    "memoryBytes": 17179869184, "diskBytes": 245107195904, "diskFreeBytes": 13504737280,
	    "os": "macOS 27.2", "arch": "arm64"
	  },
	  "load": { "memoryUsedBytes": 12459261952, "cpuPercent": 8.639999999999999, "at": "2026-11-11T02:37:14.112268Z" },
	  "tunnel": { "enabled": true, "state": "connected", "relay": "ws://127.0.0.1:8787", "since": "2026-11-11T02:36:05.257455Z" },
	  "engines": [
	    {
	      "id": "ollama", "kind": "ollama", "baseURL": "http://127.0.0.1:11434", "state": "ready", "version": "0.40.13",
	      "models": [
	        { "id": "ollama/gemma3:270m", "engine": "ollama", "name": "gemma3:270m", "sizeBytes": 291554930,
	          "family": "gemma3", "parameters": "268.10M", "quantization": "Q8_0", "contextLength": 32768, "loaded": true },
	        { "id": "ollama/qwen3:0.6b", "engine": "ollama", "name": "qwen3:0.6b", "sizeBytes": 522653767,
	          "family": "qwen3", "parameters": "751.63M", "quantization": "Q4_K_M", "contextLength": 40960,
	          "capabilities": ["tools", "thinking"], "loaded": false }
	      ]
	    }
	  ],
	  "roles": { "deep": "ollama/qwen3:0.6b", "quick": "ollama/gemma3:270m", "single": false },
	  "devices": [
	    { "id": "d_abc", "name": "Noah's MacBook Pro", "app": "Cue", "appVersion": "2.4.0", "platform": "macOS",
	      "publicKey": "a2V5", "pairedAt": "2026-11-10T01:00:00Z", "lastSeenAt": "2026-11-11T02:30:00Z",
	      "online": true, "requests": 3, "tokensIn": 40, "tokensOut": 90 }
	  ],
	  "stats": {
	    "requests": 1, "tokensIn": 16, "tokensOut": 3, "active": 0, "tokensPerSecond": 0,
	    "recent": [
	      { "id": "r1", "at": "2026-11-11T02:36:07.22409Z", "source": "local", "role": "quick",
	        "model": "ollama/gemma3:270m", "status": 200, "durationMs": 313, "tokensIn": 16, "tokensOut": 3, "stream": false }
	    ]
	  },
	  "pairing": {
	    "code": "AEBY-IKII",
	    "link": "tetrix-host://pair/AEBY-IKII?relay=ws%3A%2F%2F127.0.0.1%3A8787",
	    "expiresAt": "2026-11-11T02:46:07.557254Z"
	  },
	  "pulls": []
	}
	"""

	private func decode(_ json: String) throws -> HostStatus {
		try HostTime.decoder().decode(HostStatus.self, from: Data(json.utf8))
	}

	@Test("A full document decodes")
	func fullDocument() throws {
		let status = try decode(Self.live)
		#expect(status.product == "Tetrix Host")
		#expect(status.host.address == "127.0.0.1:4790")
		#expect(status.hardware.memoryBytes == 17_179_869_184)
		#expect(status.hardware.symbolName == "macmini")
		#expect(status.tunnel.state == .connected)
		#expect(status.tunnel.relayHost == "127.0.0.1:8787")
		#expect(status.engines.first?.isReady == true)
		#expect(status.models.count == 2)
		#expect(status.model(for: .deep)?.name == "qwen3:0.6b")
		#expect(status.model(for: .quick)?.name == "gemma3:270m")
		#expect(status.model(for: .deep)?.capabilities == ["tools", "thinking"])
		#expect(status.model(for: .quick)?.capabilities == [])
		#expect(status.devices.first?.online == true)
		#expect(status.stats.recent.first?.role == .quick)
		#expect(status.stats.recent.first?.deviceId == nil)
		#expect(status.pairing?.code == "AEBY-IKII")
		#expect(!status.noEngineAnswers)
	}

	@Test("Times with a fraction of a second decode to the microsecond")
	func fractionalTimes() throws {
		let status = try decode(Self.live)
		let started = try #require(status.host.startedAt)
		let whole = try Date("2026-11-11T02:36:05Z", strategy: .iso8601)
		#expect(abs(started.timeIntervalSince(whole) - 0.176158) < 0.0001)
		#expect(HostTime.parse("2026-11-11T02:36:05Z") == whole)
		#expect(HostTime.parse("2026-11-11T12:36:05.5+10:00") == whole.addingTimeInterval(0.5))
		#expect(HostTime.parse("not a time") == nil)
	}

	@Test("A time that was never set reads as absent")
	func zeroTime() throws {
		#expect(HostTime.parse("0001-01-01T00:00:00Z") == nil)
		let status = try decode(#"{"devices":[{"id":"d_1","name":"Phone","lastSeenAt":"0001-01-01T00:00:00Z"}]}"#)
		#expect(status.devices.first?.lastSeenAt == nil)
		#expect(status.devices.first?.name == "Phone")
	}

	@Test("An empty document decodes to an empty host")
	func emptyDocument() throws {
		let status = try decode("{}")
		#expect(status.engines.isEmpty)
		#expect(status.devices.isEmpty)
		#expect(status.pairing == nil)
		#expect(status.roles.single)
		#expect(status.tunnel.state == .disabled)
		#expect(status.noEngineAnswers)
	}

	@Test("Lists that the host writes as null decode as empty")
	func nullLists() throws {
		let status = try decode("""
		{"engines":[{"id":"ollama","kind":"ollama","state":"unreachable","error":"refused","models":null}],
		 "devices":null,"pulls":null,"pairing":null,"stats":{"recent":null},"hardware":{"gpus":null}}
		""")
		#expect(status.engines.first?.models.isEmpty == true)
		#expect(status.engines.first?.error == "refused")
		#expect(status.devices.isEmpty)
		#expect(status.pulls.isEmpty)
		#expect(status.stats.recent.isEmpty)
		#expect(status.noEngineAnswers)
	}

	@Test("A device with only its required fields decodes")
	func sparseDevice() throws {
		let status = try decode(#"{"devices":[{"id":"d_1","name":"Phone","publicKey":"a2V5","pairedAt":"2026-11-10T01:00:00Z"}]}"#)
		let device = try #require(status.devices.first)
		#expect(device.app == nil)
		#expect(device.appName == "Device")
		#expect(device.platform == nil)
		#expect(!device.online)
		#expect(device.requests == 0)
	}

	@Test("A model with no size, context, or capabilities decodes")
	func sparseModel() throws {
		let status = try decode(#"{"engines":[{"id":"lm","kind":"openai","state":"ready","models":[{"id":"lm/phi","engine":"lm","name":"phi","loaded":false}]}]}"#)
		let model = try #require(status.models.first)
		#expect(model.sizeBytes == nil)
		#expect(model.contextLength == nil)
		#expect(model.capabilities.isEmpty)
		#expect(status.engines.first?.managesDownloads == false)
	}

	@Test("Unknown fields and unknown states do not break decoding")
	func forwardCompatible() throws {
		let status = try decode("""
		{"future":{"x":1},"tunnel":{"enabled":true,"state":"sleeping","relay":"wss://relay.tetrix.tech"},
		 "stats":{"recent":[{"id":"r9","role":"vast","status":200}]}}
		""")
		#expect(status.tunnel.state == .offline)
		#expect(status.tunnel.relayHost == "relay.tetrix.tech")
		#expect(status.stats.recent.first?.role == nil)
	}

	@Test("One model for everything is read from the roles when the flag is absent")
	func singleFallback() throws {
		#expect(try decode(#"{"roles":{"deep":"a/x","quick":""}}"#).roles.single)
		#expect(try decode(#"{"roles":{"deep":"a/x","quick":"a/x"}}"#).roles.single)
		#expect(try !decode(#"{"roles":{"deep":"a/x","quick":"a/y"}}"#).roles.single)
		#expect(try decode(#"{"roles":{"deep":"a/x","quick":"","single":true}}"#).roles.modelID(for: .quick) == "a/x")
	}

	@Test("The symbol follows the kind of machine")
	func symbols() {
		var hardware = Hardware()
		hardware.kind = "laptop"
		#expect(hardware.symbolName == "laptopcomputer")
		hardware.kind = "desktop"
		#expect(hardware.symbolName == "macmini")
		hardware.kind = "server"
		#expect(hardware.symbolName == "server.rack")
	}

	@Test("The fixture has what the snapshots need")
	func fixture() {
		let status = HostStatus.fixture()
		#expect(status.devices.count == 2)
		#expect(status.devices.filter(\.online).count == 1)
		#expect(!status.roles.single)
		#expect(status.model(for: .deep) != nil)
		#expect(status.model(for: .quick) != nil)
		#expect(status.tunnel.state == .connected)
		#expect(!status.stats.recent.isEmpty)
	}

	@Test("A pull knows its share and how it ended")
	func pulls() throws {
		let decoder = HostTime.decoder()
		let running = try decoder.decode(PullProgress.self, from: Data(#"{"engine":"ollama","name":"qwen3:8b","status":"Downloading","completed":50,"total":200,"done":false}"#.utf8))
		#expect(running.id == "ollama/qwen3:8b")
		#expect(running.fraction == 0.25)
		#expect(!running.failed)

		let unknown = try decoder.decode(PullProgress.self, from: Data(#"{"engine":"ollama","name":"qwen3:8b","status":"Starting"}"#.utf8))
		#expect(unknown.fraction == nil)

		let cancelled = try decoder.decode(PullProgress.self, from: Data(#"{"engine":"ollama","name":"x","status":"Cancelled","done":true,"error":"cancelled"}"#.utf8))
		#expect(cancelled.cancelled)
		#expect(!cancelled.failed)

		let failed = try decoder.decode(PullProgress.self, from: Data(#"{"engine":"ollama","name":"x","status":"Failed","done":true,"error":"no such model"}"#.utf8))
		#expect(failed.failed)
	}
}

@Suite("Event stream")
struct EventStreamTests {
	@Test("The parser splits a stream into events and skips comments")
	func parser() {
		var parser = ServerSentEventParser()
		let text = ": connected\n\nevent: changed\ndata: {\"type\":\"changed\"}\n\n: beat\n\nevent: load\ndata: {\"a\":1}\n\n"
		let events = parser.feed(text.utf8)
		#expect(events == [
			ServerSentEvent(event: "changed", data: "{\"type\":\"changed\"}"),
			ServerSentEvent(event: "load", data: "{\"a\":1}"),
		])
	}

	@Test("An event split across reads arrives once, whole")
	func partialReads() {
		var parser = ServerSentEventParser()
		#expect(parser.feed("event: lo".utf8).isEmpty)
		#expect(parser.feed("ad\ndata: {\"x\"".utf8).isEmpty)
		#expect(parser.feed(":2}\n".utf8).isEmpty)
		#expect(parser.feed("\n".utf8) == [ServerSentEvent(event: "load", data: "{\"x\":2}")])
	}

	@Test("An event with no name is a message, and data lines join")
	func defaults() {
		var parser = ServerSentEventParser()
		#expect(parser.feed("data: one\ndata: two\n\n".utf8) == [ServerSentEvent(event: "message", data: "one\ntwo")])
		#expect(parser.feed("data:[DONE]\r\n\r\n".utf8) == [ServerSentEvent(event: "message", data: "[DONE]")])
	}

	@Test("Each kind of event decodes")
	func decodeEvents() {
		#expect(HostEvent.decode(ServerSentEvent(event: "changed", data: #"{"type":"changed","at":"2026-11-11T02:31:07Z"}"#)) == .changed)

		let load = HostEvent.decode(ServerSentEvent(event: "load", data: #"{"type":"load","at":"2026-11-11T02:31:10Z","data":{"memoryUsedBytes":13059981312,"cpuPercent":27.4,"at":"2026-11-11T02:31:10Z"}}"#))
		guard case .load(let sample) = load else {
			Issue.record("Expected a load event")
			return
		}
		#expect(sample.memoryUsedBytes == 13_059_981_312)
		#expect(sample.cpuPercent == 27.4)

		let pull = HostEvent.decode(ServerSentEvent(event: "pull", data: #"{"type":"pull","data":{"engine":"ollama","name":"qwen3:8b","status":"Downloading","completed":5,"total":10,"done":false}}"#))
		guard case .pull(let progress) = pull else {
			Issue.record("Expected a pull event")
			return
		}
		#expect(progress.fraction == 0.5)

		let request = HostEvent.decode(ServerSentEvent(event: "request", data: #"{"type":"request","data":{"id":"r2","at":"2026-11-11T02:36:07Z","deviceId":"d_abc","source":"tunnel","role":"deep","status":200,"durationMs":900,"tokensOut":12}}"#))
		guard case .request(let record) = request else {
			Issue.record("Expected a request event")
			return
		}
		#expect(record.deviceId == "d_abc")
		#expect(record.role == .deep)

		let paired = HostEvent.decode(ServerSentEvent(event: "paired", data: #"{"type":"paired","data":{"id":"d_new","name":"Noah's iPhone","app":"Cue","platform":"iOS","publicKey":"a2V5","pairedAt":"2026-11-11T02:40:00Z"}}"#))
		guard case .paired(let device) = paired else {
			Issue.record("Expected a paired event")
			return
		}
		#expect(device.name == "Noah's iPhone")
		#expect(device.requests == 0)
	}

	@Test("An unknown event is skipped")
	func unknownEvent() {
		#expect(HostEvent.decode(ServerSentEvent(event: "weather", data: "{}")) == nil)
		#expect(HostEvent.decode(ServerSentEvent(event: "load", data: "not json")) == nil)
	}

	@Test("A chat chunk gives its text and its reasoning")
	func chatChunks() {
		#expect(ChatChunk.delta(from: #"{"choices":[{"delta":{"content":"Hello"}}]}"#) == ChatDelta(content: "Hello"))
		#expect(ChatChunk.delta(from: #"{"choices":[{"delta":{"content":"","reasoning":"Think"}}]}"#) == ChatDelta(reasoning: "Think"))
		#expect(ChatChunk.delta(from: #"{"choices":[{"delta":{"reasoning_content":"Hmm"}}]}"#) == ChatDelta(reasoning: "Hmm"))
		#expect(ChatChunk.delta(from: #"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":9}}"#) == nil)
		#expect(ChatChunk.delta(from: #"{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
		#expect(ChatChunk.delta(from: "[DONE]") == nil)
	}
}
