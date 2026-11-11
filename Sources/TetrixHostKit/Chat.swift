import Foundation

/// One message of a conversation, in the shape the host's chat route takes.
public struct ChatMessage: Codable, Sendable, Equatable {
	public var role: String
	public var content: String

	public init(role: String, content: String) {
		self.role = role
		self.content = content
	}

	public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
	public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
	public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: text) }
}

/// One piece of a streamed answer.
public struct ChatDelta: Sendable, Equatable {
	/// More of the answer.
	public var content: String?
	/// More of the model's reasoning, for a model that shows it.
	public var reasoning: String?
	/// Set on the last piece: `stop`, `length`, or `tool_calls`.
	public var finishReason: String?
	/// Set on the usage piece, which arrives after the last content.
	public var usage: ChatUsage?
}

public struct ChatUsage: Sendable, Equatable {
	public var promptTokens: Int
	public var completionTokens: Int
}

extension HostClient {
	/// Streams an answer to a plain conversation.
	///
	/// This covers text in and text out. An app that sends tools or images
	/// builds its own request body and reads `lines(for:)`, because the
	/// host's chat route takes the full OpenAI chat-completions shape.
	public nonisolated func chat(
		_ messages: [ChatMessage],
		role: HostRole = .deep,
		temperature: Double? = nil,
		maxTokens: Int? = nil
	) -> AsyncThrowingStream<ChatDelta, any Error> {
		struct Body: Encodable {
			var model: String
			var messages: [ChatMessage]
			var stream = true
			var temperature: Double?
			var max_tokens: Int?
		}
		let request: HostRequest
		do {
			let body = Body(model: role.rawValue, messages: messages, temperature: temperature, max_tokens: maxTokens)
			request = .json("/v1/chat/completions", body: try JSONEncoder().encode(body))
		} catch {
			return AsyncThrowingStream { $0.finish(throwing: error) }
		}
		let lines = lines(for: request)
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await line in lines {
						if let delta = ChatDelta(eventLine: line) { continuation.yield(delta) }
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

extension ChatDelta {
	/// Reads one line of a chat event stream. Returns nil for a line that
	/// carries nothing: a blank line, a comment, or the closing `[DONE]`.
	public init?(eventLine line: String) {
		guard line.hasPrefix("data:") else { return nil }
		let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
		guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }

		struct Chunk: Decodable {
			struct Choice: Decodable {
				struct Delta: Decodable {
					var content: String?
					var reasoning: String?
					var reasoning_content: String?
				}
				var delta: Delta?
				var finish_reason: String?
			}
			struct Usage: Decodable {
				var prompt_tokens: Int?
				var completion_tokens: Int?
			}
			var choices: [Choice]?
			var usage: Usage?
		}
		guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
		let choice = chunk.choices?.first
		content = choice?.delta?.content
		// Engines disagree on the name of the reasoning field.
		reasoning = choice?.delta?.reasoning ?? choice?.delta?.reasoning_content
		finishReason = choice?.finish_reason
		if let usage = chunk.usage {
			self.usage = ChatUsage(promptTokens: usage.prompt_tokens ?? 0, completionTokens: usage.completion_tokens ?? 0)
		}
		if content == nil, reasoning == nil, finishReason == nil, usage == nil { return nil }
	}
}
