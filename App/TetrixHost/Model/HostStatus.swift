import Foundation

/// The whole state of a host, as `GET /admin/v1/status` returns it.
///
/// Every type here decodes a document with fields missing. A host may run a
/// newer or an older version than the app, and Go writes an empty list as
/// `null`.
struct HostStatus: Codable, Equatable, Sendable {
	var product = ""
	var version = ""
	var host = HostIdentity()
	var hardware = Hardware()
	var load = Load()
	var tunnel = Tunnel()
	var engines: [Engine] = []
	var roles = Roles()
	var devices: [Device] = []
	var stats = Stats()
	var pairing: PairingOffer?
	var pulls: [PullProgress] = []

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		product = c.value(.product, or: "")
		version = c.value(.version, or: "")
		host = c.value(.host, or: HostIdentity())
		hardware = c.value(.hardware, or: Hardware())
		load = c.value(.load, or: Load())
		tunnel = c.value(.tunnel, or: Tunnel())
		engines = c.value(.engines, or: [])
		roles = c.value(.roles, or: Roles())
		devices = c.value(.devices, or: [])
		stats = c.value(.stats, or: Stats())
		pairing = c.optional(.pairing)
		pulls = c.value(.pulls, or: [])
	}
}

struct HostIdentity: Codable, Equatable, Sendable {
	var id = ""
	var name = ""
	var startedAt: Date?
	var address = ""
	var endpoint = ""

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		name = c.value(.name, or: "")
		startedAt = c.optional(.startedAt)
		address = c.value(.address, or: "")
		endpoint = c.value(.endpoint, or: "")
	}
}

struct Hardware: Codable, Equatable, Sendable {
	var model = ""
	var kind = "desktop"
	var chip = ""
	var cores = 0
	var memoryBytes: Int64 = 0
	var diskBytes: Int64 = 0
	var diskFreeBytes: Int64 = 0
	var os = ""
	var arch = ""
	var gpus: [GPU] = []

	struct GPU: Codable, Equatable, Sendable {
		var name = ""
		var memoryBytes: Int64 = 0

		init() {}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			name = c.value(.name, or: "")
			memoryBytes = c.value(.memoryBytes, or: 0)
		}
	}

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		model = c.value(.model, or: "")
		kind = c.value(.kind, or: "desktop")
		chip = c.value(.chip, or: "")
		cores = c.value(.cores, or: 0)
		memoryBytes = c.value(.memoryBytes, or: 0)
		diskBytes = c.value(.diskBytes, or: 0)
		diskFreeBytes = c.value(.diskFreeBytes, or: 0)
		os = c.value(.os, or: "")
		arch = c.value(.arch, or: "")
		gpus = c.value(.gpus, or: [])
	}

	/// The SF Symbol that stands for this kind of machine.
	var symbolName: String {
		switch kind {
		case "laptop": "laptopcomputer"
		case "server": "server.rack"
		default: "macmini"
		}
	}
}

struct Load: Codable, Equatable, Sendable {
	var memoryUsedBytes: Int64 = 0
	var cpuPercent: Double = 0
	var at: Date?

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		memoryUsedBytes = c.value(.memoryUsedBytes, or: 0)
		cpuPercent = c.value(.cpuPercent, or: 0)
		at = c.optional(.at)
	}
}

struct Tunnel: Codable, Equatable, Sendable {
	enum State: String, Codable, Sendable {
		case connected, connecting, offline, disabled
	}

	var enabled = false
	var state: State = .disabled
	var relay = ""
	var since: Date?
	var lastError: String?

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		enabled = c.value(.enabled, or: false)
		// A state this version does not know reads as offline.
		let raw: String = c.value(.state, or: State.disabled.rawValue)
		state = State(rawValue: raw) ?? .offline
		relay = c.value(.relay, or: "")
		since = c.optional(.since)
		lastError = c.optional(.lastError)
	}

	/// The relay's host, without the scheme.
	var relayHost: String {
		guard let components = URLComponents(string: relay), let host = components.host else { return relay }
		if let port = components.port { return "\(host):\(port)" }
		return host
	}
}

struct Engine: Codable, Equatable, Sendable, Identifiable {
	var id = ""
	var kind = ""
	var baseURL = ""
	var state = "unreachable"
	var version: String?
	var error: String?
	var models: [Model] = []

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		kind = c.value(.kind, or: "")
		baseURL = c.value(.baseURL, or: "")
		state = c.value(.state, or: "unreachable")
		version = c.optional(.version)
		error = c.optional(.error)
		models = c.value(.models, or: [])
	}

	var isReady: Bool { state == "ready" }
	/// True when the host can download and delete models on this engine.
	var managesDownloads: Bool { kind == "ollama" }
}

struct Model: Codable, Equatable, Sendable, Identifiable {
	var id = ""
	var engine = ""
	var name = ""
	var sizeBytes: Int64?
	var family: String?
	var parameters: String?
	var quantization: String?
	var contextLength: Int?
	/// The window the model server runs the model with now. It can be far
	/// smaller than `contextLength`. Nil when the model is not loaded.
	var contextInUse: Int?
	var capabilities: [String] = []
	var loaded = false

	init() {}

	/// True when the model runs with a smaller window than it should, so
	/// that a long request is cut short.
	///
	/// - Parameter asked: The window the host asks for, in tokens, or zero
	///   when the host leaves the window to the model server. A model that
	///   runs with what the host asked for is not cut, even when it
	///   supports more.
	func windowIsCut(asked: Int) -> Bool {
		guard let contextInUse, contextInUse > 0 else { return false }
		let limit = contextLength ?? 0
		let wanted = asked > 0 ? (limit > 0 ? min(asked, limit) : asked) : limit
		return wanted > 0 && contextInUse < wanted
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		engine = c.value(.engine, or: "")
		name = c.value(.name, or: "")
		sizeBytes = c.optional(.sizeBytes)
		family = c.optional(.family)
		parameters = c.optional(.parameters)
		quantization = c.optional(.quantization)
		contextLength = c.optional(.contextLength)
		contextInUse = c.optional(.contextInUse)
		capabilities = c.value(.capabilities, or: [])
		loaded = c.value(.loaded, or: false)
	}
}

struct Roles: Codable, Equatable, Sendable {
	var deep = ""
	var quick = ""
	var single = true
	/// The context window the host asks for, per kind of work, in tokens.
	/// Zero means the host leaves it to the model server.
	var window = RoleWindows()

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		deep = c.value(.deep, or: "")
		quick = c.value(.quick, or: "")
		single = c.value(.single, or: quick.isEmpty || quick == deep)
		window = c.value(.window, or: RoleWindows())
	}

	/// The window the host asks for on the model in a slot. One model for
	/// everything runs with the deep window.
	func askedWindow(for slot: ModelSlot) -> Int {
		slot == .quick && !single ? window.quick : window.deep
	}

	/// True when one assigned model serves every kind of work. With no
	/// model assigned there is nothing to share, so this is false.
	var usesOneModel: Bool { single && !deep.isEmpty }

	/// The model ID that serves a role.
	func modelID(for role: Role) -> String {
		switch role {
		case .deep: deep
		case .quick: single ? deep : quick
		}
	}
}

/// The two kinds of work a host serves.
enum Role: String, Codable, CaseIterable, Sendable, Identifiable {
	case deep, quick

	var id: String { rawValue }

	/// The full name, for headings and menus.
	var title: String {
		switch self {
		case .deep: "Deep work"
		case .quick: "Quick work"
		}
	}

	/// The short name, for the toolbar and connector labels.
	var shortTitle: String {
		switch self {
		case .deep: "Deep"
		case .quick: "Quick"
		}
	}
}

struct Device: Codable, Equatable, Sendable, Identifiable {
	var id = ""
	var name = ""
	var app: String?
	var appVersion: String?
	var platform: String?
	var publicKey = ""
	var pairedAt: Date?
	var lastSeenAt: Date?
	var online = false
	var requests: Int64 = 0
	var tokensIn: Int64 = 0
	var tokensOut: Int64 = 0

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		name = c.value(.name, or: "")
		app = c.optional(.app)
		appVersion = c.optional(.appVersion)
		platform = c.optional(.platform)
		publicKey = c.value(.publicKey, or: "")
		pairedAt = c.optional(.pairedAt)
		lastSeenAt = c.optional(.lastSeenAt)
		online = c.value(.online, or: false)
		requests = c.value(.requests, or: 0)
		tokensIn = c.value(.tokensIn, or: 0)
		tokensOut = c.value(.tokensOut, or: 0)
	}

	/// The app's name, or a plain stand-in when the device did not send one.
	var appName: String {
		guard let app, !app.isEmpty else { return "Device" }
		return app
	}
}

struct Stats: Codable, Equatable, Sendable {
	var requests: Int64 = 0
	var tokensIn: Int64 = 0
	var tokensOut: Int64 = 0
	var active = 0
	/// The requests in progress. A host older than this field sends none.
	var running: [RunningRequest] = []
	var tokensPerSecond: Double = 0
	var recent: [RequestRecord] = []

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		requests = c.value(.requests, or: 0)
		tokensIn = c.value(.tokensIn, or: 0)
		tokensOut = c.value(.tokensOut, or: 0)
		active = c.value(.active, or: 0)
		running = c.value(.running, or: [])
		tokensPerSecond = c.value(.tokensPerSecond, or: 0)
		recent = c.value(.recent, or: [])
	}
}

/// The window setting for each kind of work.
struct RoleWindows: Codable, Equatable, Sendable {
	var deep = 0
	var quick = 0

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		deep = c.value(.deep, or: 0)
		quick = c.value(.quick, or: 0)
	}
}

/// One request in progress: who sent it and what kind of work it is.
struct RunningRequest: Codable, Equatable, Sendable, Identifiable {
	var id = ""
	var deviceId: String?
	var role: Role?

	init(id: String = "", deviceId: String? = nil, role: Role? = nil) {
		self.id = id
		self.deviceId = deviceId
		self.role = role
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		deviceId = try? c.decodeIfPresent(String.self, forKey: .deviceId)
		role = try? c.decodeIfPresent(Role.self, forKey: .role)
	}
}

/// One finished request. It holds sizes and times, never a prompt or an answer.
struct RequestRecord: Codable, Equatable, Sendable, Identifiable {
	var id = ""
	var at: Date?
	var deviceId: String?
	var source = "local"
	var role: Role?
	var model: String?
	var status = 0
	var durationMs: Int64 = 0
	var tokensIn = 0
	var tokensOut = 0
	var stream = false

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = c.value(.id, or: "")
		at = c.optional(.at)
		deviceId = c.optional(.deviceId)
		source = c.value(.source, or: "local")
		let rawRole: String? = c.optional(.role)
		role = rawRole.flatMap(Role.init(rawValue:))
		model = c.optional(.model)
		status = c.value(.status, or: 0)
		durationMs = c.value(.durationMs, or: 0)
		tokensIn = c.value(.tokensIn, or: 0)
		tokensOut = c.value(.tokensOut, or: 0)
		stream = c.value(.stream, or: false)
	}
}

struct PairingOffer: Codable, Equatable, Sendable {
	var code = ""
	var link = ""
	var expiresAt: Date?

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		code = c.value(.code, or: "")
		link = c.value(.link, or: "")
		expiresAt = c.optional(.expiresAt)
	}
}

/// The progress of one download.
struct PullProgress: Codable, Equatable, Sendable, Identifiable {
	var engine = ""
	var name = ""
	var status = ""
	var completed: Int64 = 0
	var total: Int64 = 0
	var done = false
	var error: String?

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		engine = c.value(.engine, or: "")
		name = c.value(.name, or: "")
		status = c.value(.status, or: "")
		completed = c.value(.completed, or: 0)
		total = c.value(.total, or: 0)
		done = c.value(.done, or: false)
		error = c.optional(.error)
	}

	var id: String { engine + "/" + name }

	/// The share downloaded, from 0 to 1. Nil until the engine knows the size.
	var fraction: Double? {
		guard total > 0 else { return nil }
		return min(1, max(0, Double(completed) / Double(total)))
	}

	var failed: Bool { done && error != nil && error != "cancelled" }
	var cancelled: Bool { done && error == "cancelled" }
}

// MARK: - Lookups

extension HostStatus {
	/// Every model on every engine that answers.
	var models: [Model] { engines.flatMap(\.models) }

	func model(id: String) -> Model? {
		guard !id.isEmpty else { return nil }
		return models.first { $0.id == id }
	}

	func model(for role: Role) -> Model? {
		model(id: roles.modelID(for: role))
	}

	func device(id: String?) -> Device? {
		guard let id else { return nil }
		return devices.first { $0.id == id }
	}

	/// True when the host has engines and none of them answers.
	var noEngineAnswers: Bool {
		!engines.contains { $0.isReady }
	}

	/// The roles a model serves now.
	func roles(servedBy modelID: String) -> [Role] {
		Role.allCases.filter { roles.modelID(for: $0) == modelID }
	}
}

// MARK: - Tolerant decoding

extension KeyedDecodingContainer {
	/// Decodes a value, or returns the fallback when the key is absent, null,
	/// or holds a value of another shape.
	func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
		((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
	}

	func optional<T: Decodable>(_ key: Key) -> T? {
		(try? decodeIfPresent(T.self, forKey: key)) ?? nil
	}
}

/// Parses the times a host writes: RFC 3339 in UTC, with or without a
/// fraction of a second.
enum HostTime {
	static func parse(_ text: String) -> Date? {
		var whole = text
		var fraction = 0.0
		if let dot = text.firstIndex(of: ".") {
			let afterDot = text.index(after: dot)
			let digitsEnd = text[afterDot...].firstIndex { !$0.isNumber } ?? text.endIndex
			fraction = Double("0." + text[afterDot..<digitsEnd]) ?? 0
			whole = String(text[..<dot]) + String(text[digitsEnd...])
		}
		guard let date = try? Date(whole, strategy: .iso8601) else { return nil }
		// Go writes year 1 for a time that was never set.
		guard date.timeIntervalSince1970 > 0 else { return nil }
		return date.addingTimeInterval(fraction)
	}

	static func decoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .custom { decoder in
			let text = try decoder.singleValueContainer().decode(String.self)
			guard let date = parse(text) else {
				throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a time: \(text)"))
			}
			return date
		}
		return decoder
	}

	static func encoder() -> JSONEncoder {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		return encoder
	}
}
