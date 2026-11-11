import SwiftUI

/// The drawer at the bottom of the window. A person types a prompt and sees
/// how the model behind a role answers.
struct ChatDrawer: View {
	/// The height of the part that opens, which the window's size caps.
	var openHeight: CGFloat = Metrics.drawerHeight
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window
	@Environment(ChatSession.self) private var chat
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	/// The open drawer's height in a window whose content is this tall: its
	/// usual height, or 40 percent of the content when that is less.
	static func openHeight(inContent height: CGFloat) -> CGFloat {
		min(Metrics.drawerHeight, (height * Metrics.drawerMaxShare).rounded(.down))
	}

	var body: some View {
		VStack(spacing: 0) {
			Hairline()
			bar
			if window.drawerOpen {
				Hairline()
				VStack(spacing: Space.s) {
					messages
					composer
				}
				.padding(.horizontal, Space.m)
				.padding(.vertical, Space.m)
				.frame(height: openHeight)
			}
		}
		.background(Palette.paperRaised)
	}

	// MARK: Bar

	private var bar: some View {
		@Bindable var chat = chat
		return HStack(spacing: Space.m) {
			Button {
				withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.settle)) {
					window.drawerOpen.toggle()
				}
			} label: {
				HStack(spacing: Space.s) {
					Image(systemName: "chevron.up")
						.font(Typography.caption.weight(.semibold))
						.rotationEffect(.degrees(window.drawerOpen ? 180 : 0))
						.foregroundStyle(Palette.inkMuted)
						.accessibilityHidden(true)
					Text("Try a model")
						.font(Typography.control)
						.foregroundStyle(Palette.inkSoft)
					Spacer(minLength: 0)
				}
				.frame(maxHeight: .infinity)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Try a model")
			.accessibilityValue(window.drawerOpen ? "Open" : "Closed")
			.accessibilityHint("Opens or closes the drawer.")

			if window.drawerOpen {
				if !chat.messages.isEmpty {
					Button("Clear") { chat.clear() }
						.buttonStyle(LinkButtonStyle())
				}
				SegmentedChoice(title: "Kind of work", options: Role.allCases, selection: $chat.role) { $0.shortTitle }
					.disabled(chat.isStreaming)
			}
		}
		.padding(.horizontal, Space.m)
		.frame(height: Metrics.drawerBarHeight)
	}

	// MARK: Messages

	private var messages: some View {
		ScrollViewReader { proxy in
			ScrollArea {
				VStack(alignment: .leading, spacing: Space.m) {
					if chat.messages.isEmpty {
						Text(emptyHint)
							.font(Typography.row)
							.foregroundStyle(Palette.inkMuted)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.top, Space.s)
					}
					ForEach(chat.messages) { message in
						ChatMessageView(message: message) { chat.toggleReasoning(message.id) }
							.id(message.id)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, Space.xs)
			}
			.onChange(of: chat.messages.last?.text) {
				if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
			}
			.onChange(of: chat.messages.count) {
				if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
			}
		}
		.frame(maxHeight: .infinity)
	}

	private var modelName: String? {
		store.status?.model(for: chat.role)?.name
	}

	private var emptyHint: String {
		guard store.status != nil else { return "Start the host to try a model." }
		guard modelName != nil else { return "Choose a model for \(chat.role.title.lowercased()) first." }
		return "What you type here goes to the model on this machine and nowhere else."
	}

	// MARK: Composer

	private var composer: some View {
		@Bindable var chat = chat
		return VStack(alignment: .leading, spacing: Space.xs) {
			HStack(spacing: Space.s) {
				FieldBox(title: "Prompt", text: $chat.draft, placeholder: placeholder) { send() }
				if chat.isStreaming {
					Button {
						chat.stop()
					} label: {
						Label("Stop", systemImage: "stop.fill")
							.labelStyle(.titleAndIcon)
					}
					.systemButton(.bordered)
				} else {
					PrimaryButton("Send", systemImage: "arrow.up", size: .regular) { send() }
						.disabled(!canSend)
				}
			}
			if let speed = lastSpeed {
				Text(speed)
					.font(Typography.caption)
					.foregroundStyle(Palette.inkMuted)
					.accessibilityLabel("The last answer ran at \(speed)")
			}
		}
	}

	private var canSend: Bool {
		chat.canSend && modelName != nil
	}

	private var placeholder: String {
		if let modelName { return "Ask \(modelName)" }
		return "Ask the model"
	}

	private var lastSpeed: String? {
		guard let last = chat.messages.last, last.speaker == .model, last.state == .done else { return nil }
		let speed = Format.speed(last.speed)
		return speed.isEmpty ? nil : speed
	}

	private func send() {
		guard canSend else { return }
		chat.send(using: store)
	}
}

/// One turn of the conversation. A person's turn sits on the right in a
/// tinted bubble. The model's answer sits on the left as plain text, with
/// its reasoning dimmed and collapsed above it.
struct ChatMessageView: View {
	var message: ChatSession.Message
	var toggleReasoning: () -> Void

	var body: some View {
		switch message.speaker {
		case .person:
			HStack {
				Spacer(minLength: Space.xxl)
				Text(message.text)
					.font(Typography.body)
					.foregroundStyle(Palette.ink)
					.textSelection(.enabled)
					.padding(.horizontal, Space.m)
					.padding(.vertical, Space.s)
					.background(Palette.aloe, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
					// In dark mode the tint is close to the drawer's own
					// color, so a hairline keeps the bubble's edge.
					.overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
					.frame(maxWidth: Metrics.chatBubbleMaxWidth, alignment: .trailing)
			}
			.accessibilityLabel("You said: \(message.text)")

		case .model:
			VStack(alignment: .leading, spacing: Space.s) {
				if !message.reasoning.isEmpty {
					reasoning
				}
				if !message.text.isEmpty {
					Text(message.text)
						.font(Typography.body)
						.foregroundStyle(Palette.ink)
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
				}
				status
			}
			.frame(maxWidth: Metrics.chatAnswerMaxWidth, alignment: .leading)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var reasoning: some View {
		VStack(alignment: .leading, spacing: Space.xs) {
			Button(action: toggleReasoning) {
				HStack(spacing: Space.xs) {
					Image(systemName: "chevron.right")
						.font(Typography.caption.weight(.semibold))
						.rotationEffect(.degrees(message.reasoningExpanded ? 90 : 0))
						.accessibilityHidden(true)
					Text("Reasoning")
						.font(Typography.label)
				}
				.foregroundStyle(Palette.inkMuted)
				.frame(minWidth: Metrics.minimumTarget, minHeight: Metrics.minimumTarget)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.accessibilityValue(message.reasoningExpanded ? "Shown" : "Hidden")

			if message.reasoningExpanded {
				Text(message.reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, Space.m)
					.overlay(alignment: .leading) {
						Hairline(vertical: true)
					}
			}
		}
	}

	@ViewBuilder private var status: some View {
		switch message.state {
		case .streaming:
			if message.text.isEmpty {
				Text(message.reasoning.isEmpty ? "Waiting for the model" : "Reasoning")
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
			}
		case .stopped:
			Text("Stopped.")
				.font(Typography.caption)
				.foregroundStyle(Palette.inkMuted)
		case .failed(let reason):
			Text(reason)
				.font(Typography.row)
				.foregroundStyle(Palette.rust)
				.fixedSize(horizontal: false, vertical: true)
		case .done:
			EmptyView()
		}
	}
}
