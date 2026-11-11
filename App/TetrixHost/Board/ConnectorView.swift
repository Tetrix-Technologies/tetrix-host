import SwiftUI

/// One elbow line between two cards.
///
/// A live line is solid. A line that carries nothing now is dashed. A line
/// with a request on it gains a dash that travels along it, in ink.
struct ConnectorLine: View {
	var connector: BoardConnector
	var route: ConnectorRoute
	/// True while a request travels this path.
	var isActive: Bool

	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
	@Environment(\.renderMode) private var renderMode

	private var path: Path { Path(BoardLayout.path(for: route)) }

	var body: some View {
		line
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}

	@ViewBuilder private var line: some View {
		if isActive, reduceMotion || renderMode == .snapshot {
			// Nothing moves here, so a heavier line says what the dash would.
			path.stroke(Palette.ink, style: StrokeStyle(lineWidth: Stroke.activeConnector, lineCap: .round, lineJoin: .round))
		} else {
			if connector.isLive {
				path.stroke(Palette.inkMuted, style: StrokeStyle(lineWidth: Stroke.connector, lineCap: .round, lineJoin: .round))
			} else {
				path.stroke(
					Palette.ruleStrong,
					style: StrokeStyle(lineWidth: Stroke.connector, lineCap: .round, dash: Metrics.ghostConnectorDash)
				)
			}
			if isActive {
				// Ink on a muted line is a change of color. A person who
				// asked not to rely on color gets a heavier dash as well.
				MarchingDashes(path: path, lineWidth: differentiateWithoutColor ? Stroke.activeConnector : Stroke.connector)
			}
		}
	}
}

/// The pill label of a connector. The board draws the pills over every
/// line, so no line crosses a label.
struct ConnectorPill: View {
	var label: String
	var point: CGPoint
	var isActive: Bool

	var body: some View {
		Text(label)
			.font(Typography.label)
			.foregroundStyle(isActive ? Palette.ink : Palette.inkSoft)
			.padding(.horizontal, Space.s)
			.frame(height: Metrics.pillHeight)
			.background(Palette.paperRaised, in: Capsule())
			.overlay(Capsule().strokeBorder(isActive ? Palette.ink : Palette.ruleStrong, lineWidth: isActive ? Stroke.selected : Stroke.hairline))
			.fixedSize()
			.position(point)
			.allowsHitTesting(false)
			.accessibilityHidden(true)
	}
}

/// A slow dash that travels along a path, in ink.
private struct MarchingDashes: View {
	var path: Path
	var lineWidth: CGFloat
	@State private var phase: CGFloat = 0

	var body: some View {
		path
			.stroke(
				Palette.ink,
				style: StrokeStyle(
					lineWidth: lineWidth,
					lineCap: .round,
					dash: Metrics.marchingDash,
					dashPhase: phase
				)
			)
			.onAppear {
				withAnimation(.linear(duration: Motion.dashCycle).repeatForever(autoreverses: false)) {
					// A negative phase moves the dashes from the start of
					// the path to its end.
					phase = -Metrics.marchingDashPeriod
				}
			}
	}
}

/// The board's dotted ground.
struct BoardDots: View {
	var transform: BoardTransform

	var body: some View {
		Canvas { context, size in
			let spacing = BoardLayout.dotSpacing * transform.zoom
			let radius = BoardLayout.dotRadius * max(1, transform.zoom)
			var x = (size.width / 2 + transform.pan.width).truncatingRemainder(dividingBy: spacing)
			if x < 0 { x += spacing }
			var startY = (size.height / 2 + transform.pan.height).truncatingRemainder(dividingBy: spacing)
			if startY < 0 { startY += spacing }

			var dots = Path()
			while x < size.width {
				var y = startY
				while y < size.height {
					dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
					y += spacing
				}
				x += spacing
			}
			context.fill(dots, with: .style(Palette.rule))
		}
		.accessibilityHidden(true)
	}
}
