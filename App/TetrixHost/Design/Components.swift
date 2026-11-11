import Accessibility
import AppKit
import SwiftUI

// MARK: - Environment

/// How the views are being drawn.
enum RenderMode: Sendable {
	/// In a window.
	case live
	/// Offscreen, to an image. Controls that AppKit draws cannot render
	/// there, so each one has a stand-in that looks the same at rest.
	case snapshot
}

extension EnvironmentValues {
	@Entry var renderMode: RenderMode = .live
	/// A fixed "now" for snapshots, so their times do not move.
	@Entry var fixedNow: Date?
}

/// Hands its content the current time, and again each time it ticks.
struct NowReader<Content: View>: View {
	var every: TimeInterval = 1
	@ViewBuilder var content: (Date) -> Content
	@Environment(\.fixedNow) private var fixedNow

	var body: some View {
		if let fixedNow {
			content(fixedNow)
		} else {
			TimelineView(.periodic(from: .now, by: every)) { context in
				content(context.date)
			}
		}
	}
}

// MARK: - Small marks

struct StatusDot: View {
	enum Tone {
		case healthy, waiting, failed, off

		var color: ColorToken {
			switch self {
			case .healthy: Palette.olive
			case .waiting: Palette.harvest
			case .failed: Palette.rust
			case .off: Palette.inkMuted
			}
		}
	}

	var tone: Tone

	var body: some View {
		Group {
			if tone == .off {
				Circle().strokeBorder(tone.color, lineWidth: Stroke.selected)
			} else {
				Circle().fill(tone.color)
			}
		}
		.frame(width: Metrics.statusDot, height: Metrics.statusDot)
		.accessibilityHidden(true)
	}
}

extension Tunnel {
	var tone: StatusDot.Tone {
		guard enabled else { return .off }
		switch state {
		case .connected: return .healthy
		case .connecting: return .waiting
		case .offline: return .failed
		case .disabled: return .off
		}
	}
}

extension HostStatus {
	/// The health of the host as a whole, for the dot in the toolbar. A
	/// tunnel that is on and offline is a failure. A host with no model
	/// server, or a tunnel on its way up, is waiting.
	var health: StatusDot.Tone {
		if tunnel.enabled, tunnel.state == .offline { return .failed }
		if noEngineAnswers { return .waiting }
		if tunnel.enabled, tunnel.state == .connecting { return .waiting }
		return .healthy
	}

	/// The health in words, for VoiceOver and for the dot's help tag.
	var healthSummary: String {
		var parts: [String] = []
		if tunnel.enabled, tunnel.state == .offline { parts.append("The tunnel is offline.") }
		if noEngineAnswers { parts.append("No model server is answering.") }
		if tunnel.enabled, tunnel.state == .connecting { parts.append("The tunnel is connecting.") }
		return parts.isEmpty ? "Running." : parts.joined(separator: " ")
	}
}

struct Hairline: View {
	var vertical = false

	var body: some View {
		Rectangle()
			.fill(Palette.rule)
			.frame(width: vertical ? Stroke.hairline : nil, height: vertical ? nil : Stroke.hairline)
			.accessibilityHidden(true)
	}
}

/// A thin bar that shows a share of a whole.
struct MeterBar: View {
	var fraction: Double
	var height: CGFloat = Metrics.meterHeight
	/// The fill. Nil picks the fill a load meter takes, which warns as the
	/// meter nears full.
	var tint: ColorToken?
	/// The track. Paper suits a raised surface, such as a card or a sheet.
	var track: ColorToken = Palette.paper

	/// The fill of a load meter: ink, and the warning color from 90 percent.
	static func fill(for fraction: Double) -> ColorToken {
		fraction >= Metrics.meterWarningShare ? Palette.harvest : Palette.inkSoft
	}

	var body: some View {
		GeometryReader { proxy in
			ZStack(alignment: .leading) {
				Capsule().fill(track)
				Capsule()
					.fill(tint ?? Self.fill(for: fraction))
					.frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
			}
		}
		.frame(height: height)
		.accessibilityHidden(true)
	}
}

/// A small ring that fills as a download advances.
struct ProgressRing: View {
	var fraction: Double

	var body: some View {
		ZStack {
			Circle().stroke(Palette.rule, lineWidth: Metrics.ringStroke)
			Circle()
				.trim(from: 0, to: max(0.03, min(1, fraction)))
				.stroke(Palette.inkSoft, style: StrokeStyle(lineWidth: Metrics.ringStroke, lineCap: .round))
				.rotationEffect(.degrees(-90))
		}
		.frame(width: Metrics.progressRing, height: Metrics.progressRing)
	}
}

/// A label on the left and a value on the right. VoiceOver reads the two
/// as one element.
struct LabeledRow<Value: View>: View {
	var label: String
	var font: Font = Typography.row
	/// True for a row that holds a button. VoiceOver must reach the button
	/// on its own, so such a row keeps its parts apart.
	var holdsControl = false
	@ViewBuilder var value: Value

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: Space.s) {
			Text(label)
				.font(font)
				.foregroundStyle(Palette.inkMuted)
				.lineLimit(1)
			Spacer(minLength: Space.s)
			// The value keeps its width, so a long row shortens the label.
			value
				.font(font)
				.foregroundStyle(Palette.ink)
				.multilineTextAlignment(.trailing)
				.layoutPriority(1)
		}
		.accessibilityElement(children: holdsControl ? .contain : .combine)
	}
}

extension LabeledRow where Value == Text {
	init(_ label: String, _ value: String, mono: Bool = false) {
		self.label = label
		self.value = Text(value).font(mono ? Typography.mono() : Typography.row)
	}
}

/// A value with a status dot before it.
struct DotValue: View {
	var tone: StatusDot.Tone
	var text: String
	/// What VoiceOver says, when the text on screen is abbreviated.
	var spoken: String?

	var body: some View {
		HStack(spacing: Space.s) {
			StatusDot(tone: tone)
			Text(text)
				.lineLimit(1)
				.accessibilityLabel(spoken ?? text)
		}
	}
}

// MARK: - Buttons

/// The system button styles the app uses.
enum SystemButtonKind: Sendable {
	/// The default action of a view. The window's tint fills it with moss.
	/// Use `PrimaryButton`, which also gives the label a color that reads
	/// on that fill.
	case prominent
	/// Any other action. The tint colors its label.
	case bordered
	/// An action that takes something away. Its label is rust.
	case destructive
}

extension View {
	/// Gives a button a system style and size. Offscreen, AppKit's buttons
	/// do not draw, so a snapshot gets a drawing of the same button.
	func systemButton(_ kind: SystemButtonKind, size: ControlSize = .regular) -> some View {
		modifier(SystemButton(kind: kind, size: size))
	}
}

private struct SystemButton: ViewModifier {
	var kind: SystemButtonKind
	var size: ControlSize
	@Environment(\.renderMode) private var renderMode

	func body(content: Content) -> some View {
		#if DEBUG
		if renderMode == .snapshot {
			content.buttonStyle(ReplicaButtonStyle(kind: kind, size: size))
		} else {
			live(content)
		}
		#else
		live(content)
		#endif
	}

	@ViewBuilder
	private func live(_ content: Content) -> some View {
		switch kind {
		case .prominent: content.buttonStyle(.borderedProminent).controlSize(size)
		case .bordered: content.buttonStyle(.bordered).controlSize(size)
		case .destructive: content.buttonStyle(.bordered).controlSize(size).tint(Palette.rust.dynamicColor)
		}
	}
}

/// The default action of a view, as a prominent system button.
///
/// The system writes a prominent button's label in white. White is too
/// faint on the pale moss of dark mode, about 2.4 to 1, so the label takes
/// the palette's own color for text on moss.
struct PrimaryButton: View {
	var title: String
	/// A symbol to show in place of the title. The title stays as the
	/// button's name for VoiceOver.
	var systemImage: String?
	var size: ControlSize = .large
	var minWidth: CGFloat?
	var action: () -> Void

	init(_ title: String, systemImage: String? = nil, size: ControlSize = .large, minWidth: CGFloat? = nil, action: @escaping () -> Void) {
		self.title = title
		self.systemImage = systemImage
		self.size = size
		self.minWidth = minWidth
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Group {
				if let systemImage {
					Label(title, systemImage: systemImage)
						.labelStyle(.iconOnly)
				} else {
					Text(title)
				}
			}
			.frame(minWidth: minWidth)
			.foregroundStyle(Palette.onMoss)
		}
		.systemButton(.prominent, size: size)
	}
}

/// A text button in moss, for a small action inside a row.
struct LinkButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(Typography.control)
			.foregroundStyle(configuration.isPressed ? Palette.mossDeep : Palette.moss)
			.opacity(isEnabled ? 1 : Metrics.dimmedOpacity)
			.frame(minWidth: Metrics.minimumTarget, minHeight: Metrics.minimumTarget)
			.contentShape(Rectangle())
	}
}

/// An icon button with no frame.
struct IconButtonStyle: ButtonStyle {
	var tint: ColorToken = Palette.inkSoft
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundStyle(configuration.isPressed ? Palette.ink : tint)
			.opacity(isEnabled ? 1 : Metrics.dimmedOpacity)
			.frame(minWidth: Metrics.minimumTarget, minHeight: Metrics.minimumTarget)
			.contentShape(Rectangle())
	}
}

/// Copies text to the pasteboard, and shows a check for a moment.
struct CopyButton: View {
	var text: String
	var label: String
	var showsTitle = false
	@State private var copied = false

	var body: some View {
		Button {
			Pasteboard.copy(text)
			copied = true
			Task {
				try? await Task.sleep(for: Motion.confirmation)
				copied = false
			}
		} label: {
			if showsTitle {
				Text(copied ? "Copied" : "Copy")
			} else {
				Label(label, systemImage: copied ? "checkmark" : "doc.on.doc")
			}
		}
		.accessibilityLabel(label)
		.help(label)
	}
}

enum Pasteboard {
	/// Puts text on the pasteboard and tells VoiceOver.
	@MainActor
	static func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		Announcer.post("Copied")
	}
}

/// Speaks a change of state to a person who uses VoiceOver.
enum Announcer {
	@MainActor
	static func post(_ text: String) {
		guard !text.isEmpty else { return }
		AccessibilityNotification.Announcement(text).post()
	}
}

// MARK: - Controls

/// An on-off switch with its title on the left.
struct SwitchRow: View {
	var title: String
	@Binding var isOn: Bool
	@Environment(\.renderMode) private var renderMode

	var body: some View {
		#if DEBUG
		if renderMode == .snapshot {
			ReplicaSwitchRow(title: title, isOn: isOn)
		} else {
			live
		}
		#else
		live
		#endif
	}

	private var live: some View {
		Toggle(isOn: $isOn) {
			Text(title)
				.font(Typography.row)
				.foregroundStyle(Palette.ink)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
		.toggleStyle(.switch)
		.controlSize(.small)
	}
}

/// A row of choices where one is chosen.
struct SegmentedChoice<Value: Hashable & Identifiable>: View {
	var title: String
	var options: [Value]
	@Binding var selection: Value
	var label: (Value) -> String
	@Environment(\.renderMode) private var renderMode

	var body: some View {
		#if DEBUG
		if renderMode == .snapshot {
			ReplicaSegments(titles: options.map(label), chosen: options.firstIndex(of: selection))
		} else {
			live
		}
		#else
		live
		#endif
	}

	private var live: some View {
		Picker(title, selection: $selection) {
			ForEach(options) { option in
				Text(label(option)).tag(option)
			}
		}
		.pickerStyle(.segmented)
		.labelsHidden()
		.fixedSize()
		// The system writes the chosen segment in white, which is too
		// faint on the pale moss of dark mode. The deep moss of light mode
		// carries white in both appearances.
		.tint(Palette.moss.color(scheme: .light))
		.accessibilityLabel(title)
	}
}

/// A pop-up menu that picks one of a few named things.
struct MenuChoice: View {
	struct Option: Identifiable, Equatable {
		var id: String
		var title: String
	}

	var title: String
	var options: [Option]
	var selection: String
	var choose: (String) -> Void
	@Environment(\.renderMode) private var renderMode

	private var chosenTitle: String {
		options.first { $0.id == selection }?.title ?? ""
	}

	var body: some View {
		#if DEBUG
		if renderMode == .snapshot {
			ReplicaMenuChoice(title: chosenTitle)
		} else {
			live
		}
		#else
		live
		#endif
	}

	private var live: some View {
		Picker(title, selection: Binding(get: { selection }, set: { choose($0) })) {
			ForEach(options) { option in
				Text(option.title).tag(option.id)
			}
		}
		.pickerStyle(.menu)
		.labelsHidden()
		.fixedSize()
		.accessibilityLabel(title)
		.accessibilityValue(chosenTitle)
	}
}

/// A one-line text field. It reports Return and the loss of focus apart, so
/// a setting can save on both and a form can act on Return alone.
struct FieldBox: View {
	var title: String
	@Binding var text: String
	var placeholder = ""
	var mono = false
	var onSubmit: () -> Void = {}
	var onBlur: () -> Void = {}

	@Environment(\.renderMode) private var renderMode
	@FocusState private var focused: Bool

	var body: some View {
		#if DEBUG
		if renderMode == .snapshot {
			ReplicaField(text: text, placeholder: placeholder, mono: mono)
		} else {
			live
		}
		#else
		live
		#endif
	}

	private var live: some View {
		TextField(title, text: $text, prompt: Text(placeholder))
			.textFieldStyle(.roundedBorder)
			.font(mono ? Typography.mono() : Typography.row)
			.focused($focused)
			.focusedValue(\.isEditingText, true)
			.onSubmit(onSubmit)
			.onChange(of: focused) { _, isFocused in
				if !isFocused { onBlur() }
			}
			.accessibilityLabel(title)
	}
}

/// A scrolling column. Offscreen it lays its content out without scrolling.
struct ScrollArea<Content: View>: View {
	@ViewBuilder var content: Content
	@Environment(\.renderMode) private var renderMode

	var body: some View {
		if renderMode == .snapshot {
			// Content taller than the view runs off the bottom, as the top
			// of a scroll view does.
			VStack(spacing: 0) {
				content
			}
			.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
			.frame(maxWidth: .infinity)
			.clipped()
		} else {
			ScrollView {
				content
			}
			.scrollIndicators(.automatic)
		}
	}
}
