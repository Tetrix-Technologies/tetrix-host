import Foundation
import Testing
@testable import TetrixHost

/// Tests that talk to a real host. They are skipped unless the environment
/// names one, so the ordinary test run needs no host and no network.
///
/// To run them against a host that is already up:
///
///     TEST_RUNNER_TETRIX_HOST_LIVE_HOME=<data directory> xcodebuild ... test
///
/// To also start and stop a host of the test's own:
///
///     TEST_RUNNER_TETRIX_HOST_LIVE_BINARY=<path to tetrix-host> xcodebuild ... test
private enum Live {
	static let home = ProcessInfo.processInfo.environment["TETRIX_HOST_LIVE_HOME"]
	static let binary = ProcessInfo.processInfo.environment["TETRIX_HOST_LIVE_BINARY"]

	static func environment(home: String, binary: String? = nil) -> HostEnvironment {
		var variables = [HostEnvironment.homeVariable: home]
		if let binary { variables[HostEnvironment.binaryVariable] = binary }
		return HostEnvironment(variables: variables, applicationSupport: URL.applicationSupportDirectory, bundleURL: nil)
	}
}

@Suite("Live host", .enabled(if: Live.home != nil), .timeLimit(.minutes(2)))
struct LiveHostTests {
	private func service() async throws -> any HostService {
		let supervisor = LiveHostSupervisor(environment: Live.environment(home: Live.home ?? ""))
		return try #require(await supervisor.connect(), "No host answers in TETRIX_HOST_LIVE_HOME")
	}

	@Test("The app finds the host and reads its status")
	func status() async throws {
		let status = try await service().status()
		#expect(status.product == "Tetrix Host")
		#expect(!status.host.id.isEmpty)
		#expect(!status.host.address.isEmpty)
		#expect(status.host.startedAt != nil)
		#expect(status.hardware.memoryBytes > 0)
		#expect(!status.hardware.model.isEmpty)
		#expect(status.load.at != nil)
		#expect(!status.engines.isEmpty)
	}

	@Test("The event stream delivers a load sample")
	func events() async throws {
		var sample: Load?
		for try await event in try await service().events() {
			if case .load(let load) = event {
				sample = load
				break
			}
		}
		#expect((sample?.memoryUsedBytes ?? 0) > 0)
	}

	@Test("A chat streams an answer from the model behind quick work")
	func chat() async throws {
		let service = try await service()
		let status = try await service.status()
		try #require(status.model(for: .quick) != nil, "The host has no model for quick work")

		var answer = ""
		var reasoning = ""
		for try await delta in service.chat(role: .quick, messages: [ChatTurn(role: .user, content: "Say hello in three words.")]) {
			answer += delta.content
			reasoning += delta.reasoning
		}
		#expect(!(answer + reasoning).isEmpty)

		// The host counted the request.
		let after = try await service.status()
		#expect(after.stats.requests > status.stats.requests)
	}

	@Test("A wrong key is refused with words a person can read")
	func wrongKey() async throws {
		let status = try await service().status()
		let stranger = LiveHostService(address: status.host.address, token: "not-the-key", session: .shared)
		await #expect(throws: HostError.self) {
			_ = try await stranger.status()
		}
	}

	@Test("A pairing code opens and closes")
	func pairing() async throws {
		let service = try await service()
		// Leave an open code alone. Someone may be about to use it.
		guard try await service.status().pairing == nil else { return }

		let offer = try await service.startPairing()
		#expect(offer.link.hasPrefix("tetrix-host://pair/"))
		#expect(offer.expiresAt.map { $0 > .now } == true)
		#expect(try await service.status().pairing?.code == offer.code)

		try await service.cancelPairing()
		#expect(try await service.status().pairing == nil)
	}
}

@Suite("Live supervisor", .enabled(if: Live.binary != nil), .timeLimit(.minutes(2)))
struct LiveSupervisorTests {
	@Test("The app starts a host of its own, finds it, and stops it")
	func startAndStop() async throws {
		let home = FileManager.default.temporaryDirectory.appending(path: "TetrixHostTests-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }

		// A host with its tunnel off, on a port of its own, so the test
		// reaches no relay and no other host.
		let port = Int.random(in: 49_200...60_000)
		let config = #"{"name":"Test host","listen":"127.0.0.1:\#(port)","tunnel":{"enabled":false,"relay":"ws://127.0.0.1:9"},"engines":[]}"#
		try Data(config.utf8).write(to: home.appending(path: "config.json"))

		let supervisor = LiveHostSupervisor(environment: Live.environment(home: home.path, binary: Live.binary))
		#expect(await supervisor.connect() == nil)
		#expect(!supervisor.ownsHost)

		try await supervisor.start()
		#expect(supervisor.ownsHost)
		let service = try #require(await supervisor.connect())
		let status = try await service.status()
		#expect(status.host.name == "Test host")
		#expect(status.host.address == "127.0.0.1:\(port)")
		#expect(status.tunnel.enabled == false)
		#expect(status.noEngineAnswers)
		#expect(FileManager.default.fileExists(atPath: home.appending(path: "host.log").path))

		await supervisor.stop()
		#expect(!supervisor.ownsHost)
		#expect(await supervisor.connect() == nil)
	}

	@Test("Starting with no program to run fails with words a person can read")
	func missingBinary() async throws {
		let home = FileManager.default.temporaryDirectory.appending(path: "TetrixHostTests-\(UUID().uuidString)", directoryHint: .isDirectory)
		defer { try? FileManager.default.removeItem(at: home) }
		let environment = HostEnvironment(
			variables: [HostEnvironment.homeVariable: home.path, HostEnvironment.binaryVariable: "/nonexistent/tetrix-host"],
			applicationSupport: home,
			bundleURL: home
		)
		// The two fixed install places may hold a real program, so this
		// only checks the case where they do not.
		guard environment.locateBinary() == nil else { return }
		await #expect(throws: HostError.self) {
			try await LiveHostSupervisor(environment: environment).start()
		}
	}
}
