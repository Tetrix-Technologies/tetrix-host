import Foundation

/// Turns the host's numbers and times into the words the app shows.
///
/// Each function is pure, so the tests can pin its output.
enum Format {
	private static let posix = Locale(identifier: "en_US_POSIX")

	// MARK: Sizes

	/// Installed or used memory. Memory is counted in powers of 1024, so a
	/// machine with 17,179,869,184 bytes reads as 16 GB.
	static func memory(_ bytes: Int64) -> String {
		scaled(bytes, base: 1024)
	}

	/// Space on disk and the size of a download, in powers of 1000.
	static func storage(_ bytes: Int64) -> String {
		scaled(bytes, base: 1000)
	}

	private static func scaled(_ bytes: Int64, base: Double) -> String {
		let units = ["bytes", "KB", "MB", "GB", "TB"]
		var value = Double(max(0, bytes))
		var unit = 0
		while value >= base, unit < units.count - 1 {
			value /= base
			unit += 1
		}
		// Whole numbers below a gigabyte. One decimal from there up.
		if unit < 3 { return "\(Int(value.rounded())) \(units[unit])" }
		let rounded = (value * 10).rounded() / 10
		if rounded == rounded.rounded() { return "\(Int(rounded)) \(units[unit])" }
		return String(format: "%.1f %@", locale: posix, rounded, units[unit])
	}

	/// "7.4 GB of 11.4 GB". Before the size is known, only the part so far.
	static func progress(completed: Int64, total: Int64) -> String {
		guard total > 0 else { return completed > 0 ? storage(completed) : "" }
		return "\(storage(completed)) of \(storage(total))"
	}

	static func percent(_ fraction: Double) -> String {
		"\(Int((min(1, max(0, fraction)) * 100).rounded())) percent"
	}

	static func percentShort(_ fraction: Double) -> String {
		"\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
	}

	// MARK: Counts

	static func count(_ value: Int64) -> String {
		value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
	}

	static func count(_ value: Int) -> String { count(Int64(value)) }

	static func tokens(_ value: Int) -> String {
		value == 1 ? "1 token" : "\(count(value)) tokens"
	}

	/// Generation speed, such as "42 tokens a second". Empty when unknown.
	static func speed(_ tokensPerSecond: Double) -> String {
		guard tokensPerSecond > 0 else { return "" }
		if tokensPerSecond < 10 {
			return String(format: "%.1f tokens a second", locale: posix, tokensPerSecond)
		}
		return "\(Int(tokensPerSecond.rounded())) tokens a second"
	}

	// MARK: Times

	/// How long something has run, such as "2 hours 14 minutes".
	static func uptime(from start: Date?, to now: Date) -> String {
		guard let start else { return "" }
		let seconds = max(0, Int(now.timeIntervalSince(start)))
		let days = seconds / 86_400
		let hours = (seconds % 86_400) / 3_600
		let minutes = (seconds % 3_600) / 60
		if days > 0 { return join(plural(days, "day"), hours > 0 ? plural(hours, "hour") : nil) }
		if hours > 0 { return join(plural(hours, "hour"), minutes > 0 ? plural(minutes, "minute") : nil) }
		if minutes > 0 { return plural(minutes, "minute") }
		return "Less than a minute"
	}

	/// How long ago something happened, in the short form a card has room
	/// for, such as "25 min ago" or "3 h ago".
	static func ago(_ date: Date, now: Date) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(date)))
		if seconds < 60 { return "just now" }
		if seconds < 3_600 { return "\(seconds / 60) min ago" }
		if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
		return plural(seconds / 86_400, "day") + " ago"
	}

	/// How long ago something happened, in whole words for VoiceOver, such
	/// as "3 hours ago".
	static func agoSpoken(_ date: Date, now: Date) -> String {
		let seconds = max(0, Int(now.timeIntervalSince(date)))
		if seconds < 60 { return "just now" }
		if seconds < 3_600 { return plural(seconds / 60, "minute") + " ago" }
		if seconds < 86_400 { return plural(seconds / 3_600, "hour") + " ago" }
		return plural(seconds / 86_400, "day") + " ago"
	}

	/// A device's state: "Connected", or when the host last saw it. While
	/// the tunnel is off no device can reach the host, so every device
	/// reads "Unreachable". `spoken` writes the time in whole words.
	static func deviceState(_ device: Device, now: Date, tunnelOff: Bool = false, spoken: Bool = false) -> String {
		if tunnelOff { return "Unreachable" }
		if device.online { return "Connected" }
		guard let seen = device.lastSeenAt else { return "Not seen yet" }
		return "Seen " + (spoken ? agoSpoken(seen, now: now) : ago(seen, now: now))
	}

	/// The app on a device and its version, such as "Cue 2.4.0".
	static func app(_ device: Device) -> String {
		guard let version = device.appVersion, !version.isEmpty else { return device.appName }
		return "\(device.appName) \(version)"
	}

	/// How long a request took, such as "320 ms" or "4.2 s".
	static func duration(milliseconds: Int64) -> String {
		if milliseconds < 1_000 { return "\(milliseconds) ms" }
		let seconds = Double(milliseconds) / 1_000
		if seconds < 60 { return String(format: "%.1f s", locale: posix, seconds) }
		return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
	}

	/// The time left on a pairing code, such as "9:41".
	static func countdown(to end: Date?, now: Date) -> String {
		guard let end else { return "" }
		let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
		return String(format: "%d:%02d", seconds / 60, seconds % 60)
	}

	static func clock(_ date: Date?, timeZone: TimeZone = .current) -> String {
		guard let date else { return "" }
		var style = Date.FormatStyle(date: .omitted, time: .shortened)
		style.timeZone = timeZone
		return date.formatted(style)
	}

	static func day(_ date: Date?, timeZone: TimeZone = .current) -> String {
		guard let date else { return "" }
		var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
		style.timeZone = timeZone
		return date.formatted(style)
	}

	// MARK: Models

	/// What a model can do beyond chat, in plain words.
	static func capability(_ raw: String) -> String? {
		switch raw {
		case "tools": "Use tools"
		case "vision": "See images"
		case "thinking": "Reason"
		case "embedding": "Embed text"
		default: nil
		}
	}

	/// The capabilities as one phrase, such as "Use tools, reason".
	static func capabilities(_ raw: [String]) -> String {
		let words = raw.compactMap(capability)
		guard let first = words.first else { return "Chat" }
		return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
	}

	static func context(_ tokens: Int?) -> String {
		guard let tokens, tokens > 0 else { return "" }
		return self.tokens(tokens)
	}

	/// A model's window, such as "40,960 tokens". When the model server
	/// runs the model with less than it supports, both figures show, such
	/// as "4,096 of 40,960 tokens", because the smaller one is the limit.
	/// "Unknown" when the model server reports neither.
	static func window(supported: Int?, inUse: Int?) -> String {
		let whole = context(supported)
		if let inUse, inUse > 0, let supported, inUse < supported {
			return "\(count(inUse)) of \(whole)"
		}
		if whole.isEmpty { return inUse.map { context($0) } ?? "Unknown" }
		return whole
	}

	/// A model's name from its ID, for a model the engine no longer lists.
	static func modelName(fromID id: String) -> String {
		guard let slash = id.firstIndex(of: "/") else { return id }
		return String(id[id.index(after: slash)...])
	}

	// MARK: Tunnel

	static func tunnelState(_ tunnel: Tunnel) -> String {
		guard tunnel.enabled else { return "Off" }
		switch tunnel.state {
		case .connected: return "Connected"
		case .connecting: return "Connecting"
		case .offline: return "Offline"
		case .disabled: return "Off"
		}
	}

	/// Why a relay address cannot be saved, or nil when it can. A relay is
	/// a WebSocket server, so its address is a `wss://` or `ws://` URL.
	static func relayProblem(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
			return "A relay address starts with wss:// or ws://."
		}
		guard scheme == "wss" || scheme == "ws" else {
			return "A relay address starts with wss:// or ws://."
		}
		guard let host = components.host, !host.isEmpty else {
			return "The relay address names no server."
		}
		return nil
	}

	// MARK: Helpers

	static func plural(_ count: Int, _ noun: String) -> String {
		count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
	}

	private static func join(_ first: String, _ second: String?) -> String {
		guard let second else { return first }
		return first + " " + second
	}
}
