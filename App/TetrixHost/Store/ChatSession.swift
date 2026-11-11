import Foundation
import Observation

/// The conversation in the "Try a model" drawer.
///
/// It lives in memory only. The app keeps no prompt and no answer after it
/// quits.
@MainActor
@Observable
final class ChatSession {
	struct Message: Identifiable, Equatable, Sendable {
		enum Speaker: Equatable, Sendable {
			case person, model
		}

		enum State: Equatable, Sendable {
			case streaming
			case done
			case stopped
			case failed(String)
		}

		let id: UUID
		var speaker: Speaker
		var text = ""
		/// The model's reasoning, which the drawer shows dimmed and collapsed.
		var reasoning = ""
		var reasoningExpanded = false
		var state: State = .done
		var role: Role?
		/// Tokens a second, once the host has counted the answer.
		var speed: Double = 0

		init(id: UUID = UUID(), speaker: Speaker, text: String = "", reasoning: String = "", state: State = .done, role: Role? = nil, speed: Double = 0) {
			self.id = id
			self.speaker = speaker
			self.text = text
			self.reasoning = reasoning
			self.state = state
			self.role = role
			self.speed = speed
		}
	}

	var role: Role = .deep
	var draft = ""
	private(set) var messages: [Message] = []
	private(set) var isStreaming = false

	@ObservationIgnored private var task: Task<Void, Never>?
	/// Speaks the end of an answer to a person who uses VoiceOver.
	@ObservationIgnored private let announce: @MainActor (String) -> Void

	init(announce: @escaping @MainActor (String) -> Void = Announcer.post) {
		self.announce = announce
	}

	#if DEBUG
	func setMessagesForSnapshot(_ messages: [Message]) { self.messages = messages }
	#endif

	var canSend: Bool {
		!isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Sends the draft to the model behind the chosen role.
	func send(using store: HostStore) {
		let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !isStreaming, !prompt.isEmpty else { return }
		draft = ""
		messages.append(Message(speaker: .person, text: prompt))

		let turns = messages.compactMap { message -> ChatTurn? in
			guard !message.text.isEmpty else { return nil }
			return ChatTurn(role: message.speaker == .person ? .user : .assistant, content: message.text)
		}
		let answerID = UUID()
		messages.append(Message(id: answerID, speaker: .model, state: .streaming, role: role))

		// The host reports the speed of the last answer long enough to
		// measure. If the number does not move, this answer was too short,
		// and the number belongs to an earlier one.
		let speedBefore = store.status?.stats.tokensPerSecond ?? 0
		guard let stream = store.chat(role: role, turns: turns) else {
			update(answerID) { $0.state = .failed("The host is not running.") }
			announce("The answer failed. The host is not running.")
			return
		}
		isStreaming = true
		task = Task { [weak self] in
			do {
				for try await delta in stream {
					self?.update(answerID) {
						$0.text += delta.content
						$0.reasoning += delta.reasoning
					}
				}
				// A cancelled stream ends without an error, so ask the task.
				if Task.isCancelled {
					self?.update(answerID) { $0.state = .stopped }
				} else {
					self?.update(answerID) { $0.state = .done }
					self?.announce("The answer is finished.")
					let speed = await store.speedOfLastAnswer()
					if speed != speedBefore {
						self?.update(answerID) { $0.speed = speed }
					}
				}
			} catch {
				let message = HostError.message(for: error)
				self?.update(answerID) { $0.state = message.isEmpty ? .stopped : .failed(message) }
				if !message.isEmpty { self?.announce("The answer failed. \(message)") }
			}
			self?.isStreaming = false
			self?.task = nil
		}
	}

	/// Stops the answer in progress. The host sees the app hang up.
	func stop() {
		task?.cancel()
	}

	func clear() {
		stop()
		messages.removeAll()
	}

	func toggleReasoning(_ id: UUID) {
		update(id) { $0.reasoningExpanded.toggle() }
	}

	private func update(_ id: UUID, _ change: (inout Message) -> Void) {
		guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
		change(&messages[index])
	}
}
