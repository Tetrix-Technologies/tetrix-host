#if DEBUG
import SwiftUI

// Drawings of the system's controls, for snapshots only.
//
// AppKit draws the app's buttons, switches, pickers, and fields, and none of
// them render offscreen. Each control in `Components.swift` swaps in one of
// these while a snapshot is drawn. Their sizes and fills are measured from
// the system's own controls in a key window, under the app's moss tint. A
// release build has none of them.

private enum ReplicaMetrics {
	/// A regular control is 24 points tall. A large button is 28.
	static func height(_ size: ControlSize) -> CGFloat { size == .large ? 28 : 24 }
	static func padding(_ size: ControlSize) -> CGFloat { size == .large ? 14 : 12 }
	static let radius: CGFloat = 6
	static let fieldPadding: CGFloat = 7

	static let switchWidth: CGFloat = 44
	static let switchHeight: CGFloat = 20
	static let knobWidth: CGFloat = 25
	static let knobInset: CGFloat = 2

	/// The wash a bordered control takes from its tint.
	static let wash: Double = 0.05
	/// The fill of a control that holds no tint: a track, an off switch.
	static let trackOpacity: Double = 0.1
	static let borderOpacity: Double = 0.15
	static let disabledOpacity: Double = 0.5
}

/// A push button. A large one is a capsule. A regular one has small corners.
struct ReplicaButtonStyle: ButtonStyle {
	var kind: SystemButtonKind
	var size: ControlSize
	@Environment(\.isEnabled) private var isEnabled

	private var tint: ColorToken {
		kind == .destructive ? Palette.rust : Palette.moss
	}

	func makeBody(configuration: Configuration) -> some View {
		let height = ReplicaMetrics.height(size)
		let shape = RoundedRectangle(cornerRadius: size == .large ? height / 2 : ReplicaMetrics.radius, style: .continuous)
		configuration.label
			.font(Typography.body)
			.foregroundStyle(kind == .prominent ? Palette.onMoss : tint)
			.padding(.horizontal, ReplicaMetrics.padding(size))
			.frame(minWidth: height + ReplicaMetrics.padding(size), minHeight: height)
			.background {
				if kind == .prominent {
					shape.fill(Palette.moss)
				} else {
					shape.fill(tint.opacity(ReplicaMetrics.wash))
				}
			}
			.opacity(isEnabled ? 1 : ReplicaMetrics.disabledOpacity)
	}
}

/// A small switch with its title on the left.
struct ReplicaSwitchRow: View {
	var title: String
	var isOn: Bool
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		HStack(spacing: Space.s) {
			Text(title)
				.font(Typography.row)
				.foregroundStyle(Palette.ink)
				.frame(maxWidth: .infinity, alignment: .leading)
			ZStack(alignment: isOn ? .trailing : .leading) {
				if isOn {
					Capsule().fill(Palette.moss)
				} else {
					Capsule().fill(Palette.ink.opacity(ReplicaMetrics.trackOpacity))
				}
				// The system's knob is white in both appearances.
				Capsule()
					.fill(Palette.paperRaised.color(scheme: .light))
					.frame(width: ReplicaMetrics.knobWidth)
					.padding(ReplicaMetrics.knobInset)
			}
			.frame(width: ReplicaMetrics.switchWidth, height: ReplicaMetrics.switchHeight)
			.opacity(isEnabled ? 1 : ReplicaMetrics.disabledOpacity)
		}
	}
}

/// A segmented control with one segment chosen.
struct ReplicaSegments: View {
	var titles: [String]
	var chosen: Int?

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: ReplicaMetrics.radius, style: .continuous)
		HStack(spacing: 0) {
			ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
				// The chosen segment takes the deep moss in both
				// appearances, as the control's own tint does.
				Text(title)
					.font(Typography.body)
					.foregroundStyle(index == chosen ? AnyShapeStyle(Palette.onMoss.color(scheme: .light)) : AnyShapeStyle(Palette.ink))
					.padding(.horizontal, ReplicaMetrics.padding(.large))
					.frame(height: ReplicaMetrics.height(.regular))
					.background {
						if index == chosen {
							shape.fill(Palette.moss.color(scheme: .light))
						}
					}
			}
		}
		.background(shape.fill(Palette.ink.opacity(ReplicaMetrics.trackOpacity)))
	}
}

/// A pop-up button that shows what is chosen.
struct ReplicaMenuChoice: View {
	var title: String
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: ReplicaMetrics.radius, style: .continuous)
		HStack(spacing: Space.l) {
			Text(title)
				.font(Typography.body)
				.foregroundStyle(Palette.moss)
				.lineLimit(1)
			Image(systemName: "chevron.up.chevron.down")
				.font(Typography.caption.weight(.bold))
				.foregroundStyle(Palette.ink)
		}
		.padding(.leading, ReplicaMetrics.padding(.regular))
		.padding(.trailing, Space.s)
		.frame(height: ReplicaMetrics.height(.regular))
		.background(shape.fill(Palette.moss.opacity(ReplicaMetrics.wash)))
		.opacity(isEnabled ? 1 : ReplicaMetrics.disabledOpacity)
	}
}

/// A text field with a rounded border. The system fills a field with white
/// in light mode and with near black in dark mode. The palette's nearest
/// values stand in for those.
struct ReplicaField: View {
	var text: String
	var placeholder: String
	var mono: Bool
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: ReplicaMetrics.radius, style: .continuous)
		Text(text.isEmpty ? placeholder : text)
			.font(mono ? Typography.mono() : Typography.row)
			.foregroundStyle(text.isEmpty ? Palette.inkMuted : Palette.ink)
			.lineLimit(1)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, ReplicaMetrics.fieldPadding)
			.frame(height: ReplicaMetrics.height(.regular))
			.background(shape.fill(colorScheme == .dark ? Palette.paper : Palette.paperRaised))
			.overlay(shape.strokeBorder(Palette.ink.opacity(ReplicaMetrics.borderOpacity), lineWidth: Stroke.hairline))
	}
}
#endif
