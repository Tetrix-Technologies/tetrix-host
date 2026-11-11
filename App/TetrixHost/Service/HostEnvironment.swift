import Foundation

/// Where the host keeps its files and where its program lives.
///
/// The values come in through the initializer, so a test can describe a
/// machine without touching the real one.
struct HostEnvironment: Sendable {
	static let homeVariable = "TETRIX_HOST_HOME"
	static let binaryVariable = "TETRIX_HOST_BINARY"
	static let binaryName = "tetrix-host"
	static let productName = "Tetrix Host"

	var variables: [String: String]
	var applicationSupport: URL
	var bundleURL: URL?

	static var current: HostEnvironment {
		HostEnvironment(
			variables: ProcessInfo.processInfo.environment,
			applicationSupport: URL.applicationSupportDirectory,
			bundleURL: Bundle.main.bundleURL
		)
	}

	/// The host's data directory. It holds `daemon.json` and `admin.token`.
	var dataDirectory: URL {
		if let home = variables[Self.homeVariable], !home.isEmpty {
			return URL(fileURLWithPath: home, isDirectory: true)
		}
		return applicationSupport.appending(path: Self.productName, directoryHint: .isDirectory)
	}

	var daemonFile: URL { dataDirectory.appending(path: "daemon.json") }
	var adminTokenFile: URL { dataDirectory.appending(path: "admin.token") }
	var logFile: URL { dataDirectory.appending(path: "host.log") }

	/// The places the host program may be, in the order the app looks.
	var binaryCandidates: [URL] {
		var candidates: [URL] = []
		if let named = variables[Self.binaryVariable], !named.isEmpty {
			candidates.append(URL(fileURLWithPath: named))
		}
		if let bundleURL {
			candidates.append(bundleURL.appending(path: "Contents/Helpers/\(Self.binaryName)"))
		}
		candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(Self.binaryName)"))
		candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(Self.binaryName)"))
		return candidates
	}

	/// The first candidate that can run.
	func locateBinary(isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> URL? {
		binaryCandidates.first(where: isExecutable)
	}
}

/// What a running host writes to `daemon.json`.
struct DaemonFile: Decodable, Equatable, Sendable {
	var pid = 0
	var address = ""
	var version: String?
	var startedAt: Date?

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		pid = c.value(.pid, or: 0)
		address = c.value(.address, or: "")
		version = c.optional(.version)
		startedAt = c.optional(.startedAt)
	}

	private enum CodingKeys: String, CodingKey {
		case pid, address, version, startedAt
	}

	static func read(from url: URL) -> DaemonFile? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		guard let file = try? HostTime.decoder().decode(DaemonFile.self, from: data), !file.address.isEmpty else { return nil }
		return file
	}
}
