import CryptoKit
import Foundation
import os

/// Finds the host on this machine, and runs it as a child when asked.
final class LiveHostSupervisor: HostSupervisor, @unchecked Sendable {
	private let environment: HostEnvironment
	private let session: URLSession
	private let log = Logger(subsystem: "Tech.Tetrix.Host", category: "supervisor")

	/// Guards `child`. A lock and not an actor, because the app must be able
	/// to stop the child from `applicationWillTerminate`, which cannot wait.
	private let lock = NSLock()
	private var child: Process?

	private static let healthTimeout: TimeInterval = 1
	private static let startAttempts = 100
	private static let startPoll: Duration = .milliseconds(100)
	private static let stopAttempts = 50
	private static let stopPoll: Duration = .milliseconds(100)

	init(environment: HostEnvironment = .current) {
		self.environment = environment
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = false
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		session = URLSession(configuration: configuration)
	}

	var ownsHost: Bool {
		lock.withLock { child?.isRunning ?? false }
	}

	func connect() async -> (any HostService)? {
		guard let file = DaemonFile.read(from: environment.daemonFile) else { return nil }
		guard let token = try? String(contentsOf: environment.adminTokenFile, encoding: .utf8) else { return nil }
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		// The token is sent only to a listener that has shown it already
		// holds it.
		guard await holdsToken(file.address, token: trimmed) else { return nil }
		return LiveHostService(address: file.address, token: trimmed, session: session)
	}

	func start() async throws {
		if await connect() != nil { return }
		guard let binary = environment.locateBinary() else {
			throw HostError(message: "The host program is missing. Install tetrix-host, then start again.", code: "no_binary")
		}

		let process = Process()
		process.executableURL = binary
		process.arguments = ["serve"]
		// The child inherits the app's environment, so TETRIX_HOST_HOME
		// passes through when it is set.
		process.environment = environment.variables
		process.standardInput = FileHandle.nullDevice
		let output = logHandle() ?? FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = output
		do {
			try process.run()
		} catch {
			throw HostError(message: "The host program could not start.", code: "launch_failed")
		}
		lock.withLock { child = process }
		log.info("Started the host, process \(process.processIdentifier, privacy: .public)")

		for _ in 0..<Self.startAttempts {
			if await connect() != nil { return }
			if !process.isRunning {
				lock.withLock { child = nil }
				throw HostError(message: "The host stopped as soon as it started. The log is at \(environment.logFile.path).", code: "exited")
			}
			try await Task.sleep(for: Self.startPoll)
		}
		throw HostError(message: "The host started but did not answer in time.", code: "start_timeout")
	}

	func stop() async {
		guard let process = lock.withLock({ child }) else { return }
		process.terminate()
		for _ in 0..<Self.stopAttempts where process.isRunning {
			try? await Task.sleep(for: Self.stopPoll)
		}
		if process.isRunning {
			// The host ignored the request to stop. End it.
			kill(process.processIdentifier, SIGKILL)
		}
		lock.withLock { child = nil }
		log.info("Stopped the host")
	}

	/// Stops the child without waiting. The app calls this as it quits, so a
	/// host it started does not outlive it.
	func stopNow() {
		let process = lock.withLock { () -> Process? in
			defer { child = nil }
			return child
		}
		if let process, process.isRunning { process.terminate() }
	}

	/// Asks whatever listens at the address to show that it holds the admin
	/// token, without sending the token.
	///
	/// `daemon.json` can outlive the host that wrote it, and another program
	/// could then be listening on the port it names. The host answers a
	/// random challenge with an HMAC under the token. A stand-in cannot.
	/// `docs/reference/admin-api.md` specifies the check.
	private func holdsToken(_ address: String, token: String) async -> Bool {
		guard let url = URL(string: "http://\(address)/healthz") else { return false }
		let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
		var request = URLRequest(url: url)
		request.timeoutInterval = Self.healthTimeout
		request.setValue(nonce.base64EncodedString(), forHTTPHeaderField: "X-Host-Challenge")
		guard let (data, response) = try? await session.data(for: request),
		      (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
		return Self.proofIsValid(in: data, nonce: nonce, token: token)
	}

	/// Checks the `proof` field of a health answer. The comparison takes the
	/// same time whatever the proof is.
	static func proofIsValid(in answer: Data, nonce: Data, token: String) -> Bool {
		struct Health: Decodable { var proof: String? }
		guard let text = (try? JSONDecoder().decode(Health.self, from: answer))?.proof,
		      let proof = Data(base64Encoded: text) else { return false }
		var message = Data("tetrix-host/local-proof/1\0".utf8)
		message.append(nonce)
		return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: Data(token.utf8)))
	}

	/// Opens the host's log for appending, the same file the background
	/// service writes.
	private func logHandle() -> FileHandle? {
		let manager = FileManager.default
		let directory = environment.dataDirectory
		try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let path = environment.logFile.path
		if !manager.fileExists(atPath: path) {
			manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
		}
		guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
		_ = try? handle.seekToEnd()
		return handle
	}
}
