import Foundation

/// One piece of news from the host's event stream.
enum HostEvent: Equatable, Sendable {
	/// The status document is out of date.
	case changed
	case load(Load)
	case pull(PullProgress)
	case request(RequestRecord)
	case paired(Device)

	/// Reads an event from one message of the stream. Returns nil for an
	/// event this version does not know.
	static func decode(_ message: ServerSentEvent, decoder: JSONDecoder = HostTime.decoder()) -> HostEvent? {
		let data = Data(message.data.utf8)
		switch message.event {
		case "changed":
			return .changed
		case "load":
			return (try? decoder.decode(Envelope<Load>.self, from: data)).map { .load($0.data) }
		case "pull":
			return (try? decoder.decode(Envelope<PullProgress>.self, from: data)).map { .pull($0.data) }
		case "request":
			return (try? decoder.decode(Envelope<RequestRecord>.self, from: data)).map { .request($0.data) }
		case "paired":
			return (try? decoder.decode(Envelope<Device>.self, from: data)).map { .paired($0.data) }
		default:
			return nil
		}
	}

	private struct Envelope<Payload: Decodable>: Decodable {
		let data: Payload
	}
}

/// One message of a server-sent event stream.
struct ServerSentEvent: Equatable, Sendable {
	var event = "message"
	var data = ""
}

/// Splits a byte stream into server-sent events.
///
/// It reads bytes and not lines, because a blank line ends a message and a
/// line reader that drops blank lines would lose that boundary.
struct ServerSentEventParser: Sendable {
	private var line: [UInt8] = []
	private var event = ""
	private var data: [String] = []
	private var sawCarriageReturn = false

	/// Feeds bytes in and returns the messages they complete.
	mutating func feed(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
		var out: [ServerSentEvent] = []
		for byte in bytes {
			if let message = feed(byte) { out.append(message) }
		}
		return out
	}

	/// Feeds one byte in and returns the message it completes, if any.
	mutating func feed(_ byte: UInt8) -> ServerSentEvent? {
		let newline = UInt8(ascii: "\n")
		let carriageReturn = UInt8(ascii: "\r")
		if byte == newline, sawCarriageReturn {
			// The second half of a CRLF pair. The line already ended.
			sawCarriageReturn = false
			return nil
		}
		sawCarriageReturn = byte == carriageReturn
		guard byte == newline || byte == carriageReturn else {
			line.append(byte)
			return nil
		}
		defer { line.removeAll(keepingCapacity: true) }
		return take(String(decoding: line, as: UTF8.self))
	}

	private mutating func take(_ text: String) -> ServerSentEvent? {
		if text.isEmpty {
			defer {
				event = ""
				data.removeAll()
			}
			// A blank line with no data ends nothing, such as after a comment.
			guard !data.isEmpty else { return nil }
			return ServerSentEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
		}
		// A line that starts with a colon is a comment. The host sends one
		// every 15 seconds to keep the connection alive.
		if text.hasPrefix(":") { return nil }
		let field: Substring
		var value: Substring
		if let colon = text.firstIndex(of: ":") {
			field = text[..<colon]
			value = text[text.index(after: colon)...]
			if value.hasPrefix(" ") { value = value.dropFirst() }
		} else {
			field = text[...]
			value = ""
		}
		switch field {
		case "event": event = String(value)
		case "data": data.append(String(value))
		default: break
		}
		return nil
	}
}
