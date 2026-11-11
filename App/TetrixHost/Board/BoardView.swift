import AppKit
import SwiftUI

/// The freeform board: cards joined by connectors on a dotted ground.
///
/// Drag the ground or scroll with two fingers to pan. Pinch to zoom. Drag a
/// card to move it, or hold Option and press an arrow key. The geometry
/// comes from `BoardLayout`, which is pure.
struct BoardView: View {
	var status: HostStatus

	@Environment(HostStore.self) private var store
	@Environment(BoardState.self) private var board
	@Environment(WindowState.self) private var window
	@Environment(\.renderMode) private var renderMode

	@FocusState private var focus: BoardCardID?
	@State private var lifted: BoardCardID?
	@State private var dragStart: CGPoint?
	@State private var panStart: BoardTransform?
	@State private var zoomStart: BoardTransform?
	@State private var scroll = ScrollMonitor()

	private static let space = "board"
	private static let dragThreshold: CGFloat = 3

	var body: some View {
		let scene = BoardLayout.scene(for: status)
		let frames = BoardLayout.frames(for: scene, saved: board.positions)
		let bounds = BoardLayout.bounds(of: frames)

		GeometryReader { proxy in
			let viewport = proxy.size
			let transform = board.transform(content: bounds, viewport: viewport)
			let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)

			NowReader(every: 30) { now in
				let active = BoardLayout.activeConnectors(
					in: scene,
					requestsInProgress: status.stats.active,
					running: status.stats.running,
					glows: store.glows,
					now: renderMode == .snapshot ? now : .now
				)
				ZStack {
					BoardDots(transform: transform)
						.contentShape(Rectangle())
						.onTapGesture { clearFocus() }
						.gesture(panGesture(from: transform))
						.pointerStyle(panStart == nil ? .grabIdle : .grabActive)

					ZStack {
						ForEach(BoardLayout.drawOrder(of: scene.connectors, active: active)) { connector in
							if let route = route(of: connector, in: frames, center: center) {
								ConnectorLine(connector: connector, route: route, isActive: active.contains(connector.id))
							}
						}
						// Every pill sits over every line, so no line
						// crosses a label.
						ForEach(scene.connectors) { connector in
							if let label = connector.label, let route = route(of: connector, in: frames, center: center) {
								ConnectorPill(label: label, point: route.labelPoint, isActive: active.contains(connector.id))
							}
						}
						// Cards are laid in reading order, so Tab and
						// VoiceOver follow the board as a person arranged it.
						ForEach(BoardLayout.readingOrder(of: frames).compactMap(scene.card)) { card in
							if let frame = frames[card.id] {
								cardView(card, frame: frame, frames: frames, zoom: transform.zoom, now: now)
									.frame(width: frame.width, height: frame.height)
									.position(x: center.x + frame.midX, y: center.y + frame.midY)
									.zIndex(lifted == card.id ? 1 : 0)
							}
						}
					}
					.frame(width: viewport.width, height: viewport.height)
					.scaleEffect(transform.zoom)
					.offset(transform.pan)
				}
			}
			.coordinateSpace(.named(Self.space))
			.simultaneousGesture(magnifyGesture(from: transform, center: center))
			.onChange(of: viewport, initial: true) { board.viewport = viewport }
			.onChange(of: bounds, initial: true) { board.contentBounds = bounds }
			.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in scroll.frame = frame }
		}
		.clipped()
		.onChange(of: focus) { _, focused in
			guard let focused else { return }
			if scene.card(focused)?.kind.isGhost == false {
				window.select(focused)
			}
			// Focus that the keyboard moved may land on a card out of view.
			// A click lands on a card a person can see, and a pan under the
			// pointer would throw off a drag, so a click pans nothing.
			if NSEvent.pressedMouseButtons == 0, let frame = frames[focused] {
				board.reveal(frame)
			}
		}
		.onChange(of: scene) { window.reconcile(with: scene) }
		.onAppear {
			scroll.onScroll = { delta in board.pan(by: delta) }
			scroll.install()
		}
		.onDisappear { scroll.remove() }
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Board")
	}

	private func route(of connector: BoardConnector, in frames: [BoardCardID: CGRect], center: CGPoint) -> ConnectorRoute? {
		guard let from = frames[connector.from], let to = frames[connector.to] else { return nil }
		return BoardLayout.route(from: from, to: to, shape: connector.shape).offset(by: center)
	}

	/// A click on the ground drops the selection and takes focus from
	/// whatever held it, so a field in the inspector saves its edit.
	private func clearFocus() {
		window.select(nil)
		focus = nil
		NSApp.keyWindow?.makeFirstResponder(nil)
	}

	// MARK: Cards

	@ViewBuilder
	private func cardView(_ card: BoardCard, frame: CGRect, frames: [BoardCardID: CGRect], zoom: CGFloat, now: Date) -> some View {
		let isSelected = window.selection == card.id
		let isFocused = focus == card.id
		let isLifted = lifted == card.id
		let tunnelOff = !status.tunnel.enabled

		switch card.kind {
		case .machine:
			let problem = CardProblem.machine(engines: status.engines)
			MachineCard(name: status.host.name, hardware: status.hardware, load: status.load, problem: problem, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted)
				.modifier(interaction(card, frame: frame, frames: frames, summary: CardSummary.machine(name: status.host.name, status.hardware, load: status.load, problem: problem)))

		case .tunnel:
			TunnelCard(tunnel: status.tunnel, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted)
				.modifier(interaction(card, frame: frame, frames: frames, summary: CardSummary.tunnel(status.tunnel)))

		case .model(let slot, let modelID):
			let model = status.model(id: modelID)
			ModelCard(slot: slot, modelID: modelID, model: model, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted)
				.modifier(interaction(card, frame: frame, frames: frames, summary: CardSummary.model(slot: slot, modelID: modelID, model: model)))
				.contextMenu {
					if let model {
						ModelActions(model: model)
					}
				}

		case .device(let id):
			if let device = status.device(id: id) {
				DeviceCard(device: device, now: now, tunnelOff: tunnelOff, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted)
					.modifier(interaction(card, frame: frame, frames: frames, summary: CardSummary.device(device, now: now, tunnelOff: tunnelOff)))
					.accessibilityAction(named: "Unpair") { window.deviceToUnpair = device }
					.contextMenu {
						Button("Show details") { window.inspect(card.id) }
						Divider()
						Button("Unpair…", role: .destructive) { window.deviceToUnpair = device }
					}
			}

		case .pairDevice:
			GhostCard(title: "Pair a device", isFocused: isFocused, isLifted: isLifted)
				.modifier(interaction(card, frame: frame, frames: frames, summary: "Pair a device", hint: "Opens the pairing sheet."))

		case .chooseModel:
			// With nothing installed there is nothing to choose, so the
			// card offers a download. Otherwise it leads to the pickers.
			let nothingInstalled = status.models.isEmpty
			let title = nothingInstalled ? "Download a model" : "Choose a model"
			GhostCard(title: title, isFocused: isFocused, isLifted: isLifted)
				.modifier(interaction(
					card,
					frame: frame,
					frames: frames,
					summary: title,
					hint: nothingInstalled ? "Opens the download sheet." : "Shows the host in the inspector, where you choose a model for each kind of work."
				))
		}
	}

	/// The cards that take focus: every card the board draws. A device card
	/// draws only while the status still lists its device.
	private func focusable(in frames: [BoardCardID: CGRect]) -> Set<BoardCardID> {
		Set(BoardLayout.scene(for: status).cards.filter { card in
			if case .device(let id) = card.kind { return status.device(id: id) != nil }
			return true
		}.map(\.id)).intersection(frames.keys)
	}

	private func interaction(
		_ card: BoardCard,
		frame: CGRect,
		frames: [BoardCardID: CGRect],
		summary: String,
		hint: String = "Shows the details in the inspector."
	) -> some ViewModifier {
		CardInteraction(
			id: card.id,
			summary: summary,
			hint: hint,
			isGhost: card.kind.isGhost,
			isSelected: window.selection == card.id,
			focus: $focus,
			drag: dragGesture(card, frame: frame),
			onTap: {
				focus = card.id
				if card.kind.isGhost {
					activate(card)
				} else {
					window.select(card.id)
				}
			},
			onActivate: { activate(card) },
			onDelete: {
				guard case .device(let id) = card.kind, let device = status.device(id: id) else { return false }
				window.deviceToUnpair = device
				return true
			},
			onMove: { direction in
				if let next = BoardLayout.neighbor(of: card.id, toward: direction, among: frames, focusable: focusable(in: frames)) {
					focus = next
				}
			},
			onNudge: { direction in
				let center = board.nudge(card.id, from: CGPoint(x: frame.midX, y: frame.midY), toward: direction)
				board.reveal(CGRect(x: center.x - frame.width / 2, y: center.y - frame.height / 2, width: frame.width, height: frame.height))
			},
			onEscape: {
				window.select(nil)
				focus = nil
			}
		)
	}

	/// Return on a card, or a double click: show its details, or do what a
	/// ghost card offers.
	private func activate(_ card: BoardCard) {
		switch card.kind {
		case .pairDevice:
			window.sheet = .pairing
		case .chooseModel:
			if status.models.isEmpty {
				window.sheet = .download
			} else {
				window.inspectHost()
			}
		default:
			window.inspect(card.id)
		}
	}

	// MARK: Gestures

	private func dragGesture(_ card: BoardCard, frame: CGRect) -> some Gesture {
		DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.space))
			.onChanged { value in
				if dragStart == nil {
					dragStart = CGPoint(x: frame.midX, y: frame.midY)
					lifted = card.id
					if !card.kind.isGhost { window.select(card.id) }
				}
				guard let start = dragStart else { return }
				let zoom = board.zoom
				board.move(card.id, to: CGPoint(
					x: start.x + value.translation.width / zoom,
					y: start.y + value.translation.height / zoom
				))
			}
			.onEnded { _ in
				dragStart = nil
				lifted = nil
				board.commitPositions()
			}
	}

	private func panGesture(from transform: BoardTransform) -> some Gesture {
		DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.space))
			.onChanged { value in
				if panStart == nil { panStart = transform }
				guard let start = panStart else { return }
				board.setTransform(BoardTransform(
					zoom: start.zoom,
					pan: CGSize(width: start.pan.width + value.translation.width, height: start.pan.height + value.translation.height)
				))
			}
			.onEnded { _ in panStart = nil }
	}

	private func magnifyGesture(from transform: BoardTransform, center: CGPoint) -> some Gesture {
		MagnifyGesture()
			.onChanged { value in
				if zoomStart == nil { zoomStart = transform }
				guard let start = zoomStart else { return }
				let anchor = CGPoint(x: value.startLocation.x - center.x, y: value.startLocation.y - center.y)
				board.setTransform(BoardLayout.zoomed(start, to: start.zoom * value.magnification, anchor: anchor))
			}
			.onEnded { _ in zoomStart = nil }
	}
}

extension ConnectorRoute {
	func offset(by delta: CGPoint) -> ConnectorRoute {
		ConnectorRoute(
			points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
			labelPoint: CGPoint(x: labelPoint.x + delta.x, y: labelPoint.y + delta.y)
		)
	}
}

extension MoveDirection {
	/// The direction an arrow key points.
	init?(_ key: KeyEquivalent) {
		switch key {
		case .upArrow: self = .up
		case .downArrow: self = .down
		case .leftArrow: self = .left
		case .rightArrow: self = .right
		default: return nil
		}
	}

	/// The name of the action that moves a card this way.
	var actionName: String {
		switch self {
		case .up: "Move up"
		case .down: "Move down"
		case .left: "Move left"
		case .right: "Move right"
		}
	}
}

/// What every card on the board answers to: the pointer, the keyboard, and
/// VoiceOver. A card reads as one element with one summary.
private struct CardInteraction<Drag: Gesture>: ViewModifier {
	var id: BoardCardID
	var summary: String
	var hint: String
	var isGhost: Bool
	var isSelected: Bool
	var focus: FocusState<BoardCardID?>.Binding
	var drag: Drag
	var onTap: () -> Void
	var onActivate: () -> Void
	var onDelete: () -> Bool
	var onMove: (MoveDirection) -> Void
	/// Moves the card itself one step, as Option and an arrow key do.
	var onNudge: (MoveDirection) -> Void
	var onEscape: () -> Void

	func body(content: Content) -> some View {
		content
			.contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
			// Like a row in a list, a card takes focus from a click or from
			// Tab, whatever the system's keyboard navigation setting is.
			.focusable(interactions: .edit)
			.focused(focus, equals: id)
			.focusEffectDisabled()
			.onKeyPress(.return) {
				onActivate()
				return .handled
			}
			.onKeyPress(.space) {
				onActivate()
				return .handled
			}
			.onKeyPress(keys: [.delete, .deleteForward]) { _ in
				onDelete() ? .handled : .ignored
			}
			.onKeyPress(.escape) {
				onEscape()
				return .handled
			}
			// Option and an arrow key move the card. A plain arrow key is
			// left alone here, and moves the focus below.
			.onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
				guard press.modifiers.contains(.option), let direction = MoveDirection(press.key) else { return .ignored }
				onNudge(direction)
				return .handled
			}
			.onMoveCommand { direction in
				switch direction {
				case .up: onMove(.up)
				case .down: onMove(.down)
				case .left: onMove(.left)
				case .right: onMove(.right)
				@unknown default: break
				}
			}
			.gesture(drag)
			.simultaneousGesture(TapGesture(count: 2).onEnded { if !isGhost { onActivate() } })
			.onTapGesture(perform: onTap)
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(summary)
			.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
			.accessibilityHint(hint)
			.accessibilityAction { onActivate() }
			.accessibilityAction(named: MoveDirection.up.actionName) { onNudge(.up) }
			.accessibilityAction(named: MoveDirection.down.actionName) { onNudge(.down) }
			.accessibilityAction(named: MoveDirection.left.actionName) { onNudge(.left) }
			.accessibilityAction(named: MoveDirection.right.actionName) { onNudge(.right) }
	}
}

/// Turns two-finger scrolling over the board into panning.
///
/// SwiftUI has no scroll gesture on the Mac, so this watches the app's own
/// scroll events and takes the ones that land on the board.
@MainActor
final class ScrollMonitor {
	/// The board's frame in the window, measured from the top left.
	var frame: CGRect = .zero
	var onScroll: ((CGSize) -> Void)?

	private var monitor: Any?
	/// A mouse wheel reports lines. This many points make one line.
	private nonisolated static let pointsPerLine: CGFloat = 10

	func install() {
		guard monitor == nil else { return }
		monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
			let window = event.window
			let ordinary = window.map { $0.sheetParent == nil && $0.attachedSheet == nil && $0.level == .normal && $0.styleMask.contains(.titled) } ?? false
			let height = window?.contentView?.bounds.height ?? 0
			let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
			let scale = event.hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine
			let delta = CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)
			let zooming = event.modifierFlags.contains(.command)
			let taken = MainActor.assumeIsolated {
				self?.take(point: point, delta: delta, ordinary: ordinary && !zooming) ?? false
			}
			return taken ? nil : event
		}
	}

	func remove() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
	}

	private func take(point: CGPoint, delta: CGSize, ordinary: Bool) -> Bool {
		guard ordinary, frame.contains(point), delta != .zero else { return false }
		onScroll?(delta)
		return true
	}
}
