import CoreGraphics
import Foundation

/// The name of one card on the board. Saved positions are keyed by it.
struct BoardCardID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
	let rawValue: String

	init(rawValue: String) { self.rawValue = rawValue }

	static let machine = BoardCardID(rawValue: "machine")
	static let tunnel = BoardCardID(rawValue: "tunnel")
	static let pairDevice = BoardCardID(rawValue: "ghost:pair")

	static func model(_ slot: ModelSlot) -> BoardCardID { BoardCardID(rawValue: "model:\(slot.rawValue)") }
	static func device(_ id: String) -> BoardCardID { BoardCardID(rawValue: "device:\(id)") }

	var description: String { rawValue }
}

/// The work a model card stands for.
enum ModelSlot: String, Sendable, CaseIterable {
	case deep, quick
	/// One model for everything.
	case all

	init(_ role: Role) {
		switch role {
		case .deep: self = .deep
		case .quick: self = .quick
		}
	}

	var title: String {
		switch self {
		case .deep: Role.deep.title
		case .quick: Role.quick.title
		case .all: "All work"
		}
	}

	var shortTitle: String {
		switch self {
		case .deep: Role.deep.shortTitle
		case .quick: Role.quick.shortTitle
		case .all: "All work"
		}
	}
}

enum BoardCardKind: Equatable, Sendable {
	case machine
	case tunnel
	case model(slot: ModelSlot, modelID: String)
	/// A dashed stand-in for a role that has no model.
	case chooseModel(slot: ModelSlot)
	case device(id: String)
	/// A dashed stand-in that opens the pairing sheet.
	case pairDevice

	var isGhost: Bool {
		switch self {
		case .chooseModel, .pairDevice: true
		default: false
		}
	}
}

struct BoardCard: Identifiable, Equatable, Sendable {
	let id: BoardCardID
	let kind: BoardCardKind

	var size: CGSize { CGSize(width: BoardLayout.cardWidth, height: BoardLayout.height(of: kind)) }
}

struct BoardConnector: Identifiable, Equatable, Sendable {
	/// Where the elbow turns and where the label sits.
	enum Shape: Sendable {
		/// The elbow turns halfway, and the label sits at the middle of the
		/// line.
		case balanced
		/// The elbow turns close to the far card, so the near card has a
		/// branch of its own, and the label sits on that branch. Lines that
		/// share a far card share a trunk, and each label stays with its
		/// own card.
		case branch
	}

	let from: BoardCardID
	let to: BoardCardID
	var label: String?
	/// A line to a ghost card.
	var isGhost = false
	/// True when traffic can travel this path now. A path that is not live
	/// is drawn dashed.
	var isLive: Bool
	var shape: Shape = .balanced

	var id: String { "\(from.rawValue)>\(to.rawValue)" }
}

/// The cards and connectors that one status document calls for.
struct BoardScene: Equatable, Sendable {
	var cards: [BoardCard] = []
	var connectors: [BoardConnector] = []

	func card(_ id: BoardCardID) -> BoardCard? { cards.first { $0.id == id } }
}

/// Where the board's content sits in the window.
struct BoardTransform: Equatable, Sendable {
	var zoom: CGFloat = 1
	/// The offset of the board's origin from the middle of the view.
	var pan: CGSize = .zero
}

/// A connector's route: the corners of an elbow line and the spot for its label.
struct ConnectorRoute: Equatable, Sendable {
	var points: [CGPoint]
	var labelPoint: CGPoint
}

enum MoveDirection: Sendable, CaseIterable {
	case up, down, left, right
}

/// The geometry of the board. Every function is pure.
enum BoardLayout {
	static let cardWidth: CGFloat = 220
	/// Two of the largest spacing step. One step is narrower than a pill,
	/// and a device's pill needs a branch of its own before the trunk.
	static let columnGap: CGFloat = Space.xxl * 2
	static let rowGap: CGFloat = Space.l
	static let dotSpacing: CGFloat = 24
	static let dotRadius: CGFloat = 1
	static let connectorRadius: CGFloat = Radius.small
	/// The least room between two cards for an elbow to fit.
	static let minimumElbowGap: CGFloat = 24
	/// How far from the far card a branch connector turns.
	static let trunkInset: CGFloat = Space.l
	static let minZoom: CGFloat = 0.5
	static let maxZoom: CGFloat = 2
	static let zoomStep: CGFloat = 1.25
	/// The smallest zoom the automatic fit picks. Below it the text is too
	/// small to read, so a board that large is panned instead. A person can
	/// still zoom out to `minZoom` by hand.
	static let fitFloor: CGFloat = 0.75
	/// The machine card while the host is stopped, when it has no live rows.
	static let stoppedMachineHeight: CGFloat = 168

	static func height(of kind: BoardCardKind) -> CGFloat {
		switch kind {
		case .machine: 244
		case .tunnel: 196
		case .model: 186
		case .device: 116
		case .chooseModel, .pairDevice: 64
		}
	}

	// MARK: Scene

	/// The board for a status document. With no document the host is
	/// stopped, and the board holds this machine alone.
	static func scene(for status: HostStatus?) -> BoardScene {
		guard let status else {
			return BoardScene(cards: [BoardCard(id: .machine, kind: .machine)])
		}
		var scene = BoardScene()
		let tunnelUp = status.tunnel.enabled && status.tunnel.state == .connected

		for device in status.devices {
			let id = BoardCardID.device(device.id)
			// A device's path is sealed only while the device holds a session
			// through a connected tunnel, so the label shows only then.
			let live = tunnelUp && device.online
			scene.cards.append(BoardCard(id: id, kind: .device(id: device.id)))
			scene.connectors.append(BoardConnector(from: id, to: .tunnel, label: live ? "Sealed" : nil, isLive: live, shape: .branch))
		}
		scene.cards.append(BoardCard(id: .pairDevice, kind: .pairDevice))
		scene.connectors.append(BoardConnector(from: .pairDevice, to: .tunnel, isGhost: true, isLive: false, shape: .branch))

		scene.cards.append(BoardCard(id: .tunnel, kind: .tunnel))
		scene.connectors.append(BoardConnector(from: .tunnel, to: .machine, isLive: tunnelUp))
		scene.cards.append(BoardCard(id: .machine, kind: .machine))

		if status.roles.deep.isEmpty {
			scene.cards.append(BoardCard(id: .model(.all), kind: .chooseModel(slot: .all)))
			scene.connectors.append(BoardConnector(from: .machine, to: .model(.all), isGhost: true, isLive: false))
		} else if status.roles.single {
			scene.cards.append(BoardCard(id: .model(.all), kind: .model(slot: .all, modelID: status.roles.deep)))
			scene.connectors.append(BoardConnector(from: .machine, to: .model(.all), label: ModelSlot.all.shortTitle, isLive: true))
		} else {
			for role in Role.allCases {
				let slot = ModelSlot(role)
				scene.cards.append(BoardCard(id: .model(slot), kind: .model(slot: slot, modelID: status.roles.modelID(for: role))))
				scene.connectors.append(BoardConnector(from: .machine, to: .model(slot), label: slot.shortTitle, isLive: true))
			}
		}
		return scene
	}

	// MARK: Default positions

	private static func column(of kind: BoardCardKind) -> Int {
		switch kind {
		case .device, .pairDevice: 0
		case .tunnel: 1
		case .machine: 2
		case .model, .chooseModel: 3
		}
	}

	/// The center of each card in the default layout: devices in a column on
	/// the left, then the tunnel, then the machine, then the models. The
	/// layout as a whole is centered on the origin.
	static func defaultPositions(for scene: BoardScene) -> [BoardCardID: CGPoint] {
		let columns = Dictionary(grouping: scene.cards) { column(of: $0.kind) }
		let used = columns.keys.sorted()
		let step = cardWidth + columnGap
		let span = CGFloat(max(0, used.count - 1)) * step

		var positions: [BoardCardID: CGPoint] = [:]
		for (index, key) in used.enumerated() {
			let cards = columns[key] ?? []
			let x = CGFloat(index) * step - span / 2
			let total = cards.reduce(CGFloat(0)) { $0 + $1.size.height } + CGFloat(max(0, cards.count - 1)) * rowGap
			var y = -total / 2
			for card in cards {
				positions[card.id] = CGPoint(x: x, y: y + card.size.height / 2)
				y += card.size.height + rowGap
			}
		}
		return positions
	}

	/// The frame of each card, from its saved position or its default one.
	static func frames(for scene: BoardScene, saved: [BoardCardID: CGPoint]) -> [BoardCardID: CGRect] {
		let defaults = defaultPositions(for: scene)
		var frames: [BoardCardID: CGRect] = [:]
		for card in scene.cards {
			let center = saved[card.id] ?? defaults[card.id] ?? .zero
			frames[card.id] = CGRect(
				x: center.x - card.size.width / 2,
				y: center.y - card.size.height / 2,
				width: card.size.width,
				height: card.size.height
			)
		}
		return frames
	}

	static func bounds(of frames: [BoardCardID: CGRect]) -> CGRect {
		frames.values.reduce(CGRect.null) { $0.union($1) }
	}

	// MARK: View

	/// The transform that shows all the content, centered, no larger than
	/// life size and no smaller than `fitFloor`.
	///
	/// Content too large for the floor does not fit. On that axis it starts
	/// at its leading or top edge, as a scroll view does, and a person pans
	/// to the rest.
	static func fit(content: CGRect, viewport: CGSize, padding: CGFloat) -> BoardTransform {
		guard !content.isNull, content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else {
			return BoardTransform()
		}
		let room = CGSize(width: max(1, viewport.width - padding * 2), height: max(1, viewport.height - padding * 2))
		let zoom = max(fitFloor, min(1, room.width / content.width, room.height / content.height))
		// Half a point of slack, so content that fits exactly counts as fitting.
		let slack: CGFloat = 0.5
		let fitsWidth = content.width * zoom <= room.width + slack
		let fitsHeight = content.height * zoom <= room.height + slack
		return BoardTransform(zoom: zoom, pan: CGSize(
			width: fitsWidth ? -content.midX * zoom : padding - viewport.width / 2 - content.minX * zoom,
			height: fitsHeight ? -content.midY * zoom : padding - viewport.height / 2 - content.minY * zoom
		))
	}

	static func clampZoom(_ zoom: CGFloat) -> CGFloat {
		min(maxZoom, max(minZoom, zoom))
	}

	/// Zooms while the board point under `anchor` stays put. `anchor` is
	/// measured from the middle of the view.
	static func zoomed(_ transform: BoardTransform, to zoom: CGFloat, anchor: CGPoint = .zero) -> BoardTransform {
		let target = clampZoom(zoom)
		let boardX = (anchor.x - transform.pan.width) / transform.zoom
		let boardY = (anchor.y - transform.pan.height) / transform.zoom
		return BoardTransform(zoom: target, pan: CGSize(width: anchor.x - boardX * target, height: anchor.y - boardY * target))
	}

	/// The transform that brings a card into view, or nil when the card is
	/// in view already. It pans by the least distance and keeps the zoom.
	static func revealing(_ frame: CGRect, in viewport: CGSize, transform: BoardTransform, padding: CGFloat) -> BoardTransform? {
		guard viewport.width > 0, viewport.height > 0 else { return nil }
		// Positions are measured from the middle of the view, as the pan is.
		func shift(low: CGFloat, high: CGFloat, view: CGFloat) -> CGFloat {
			let least = padding - view / 2
			let most = view / 2 - padding
			if low < least { return least - low }
			// A card larger than the view keeps its leading edge in view.
			if high > most { return max(most - high, least - low) }
			return 0
		}
		let dx = shift(
			low: frame.minX * transform.zoom + transform.pan.width,
			high: frame.maxX * transform.zoom + transform.pan.width,
			view: viewport.width
		)
		let dy = shift(
			low: frame.minY * transform.zoom + transform.pan.height,
			high: frame.maxY * transform.zoom + transform.pan.height,
			view: viewport.height
		)
		guard dx != 0 || dy != 0 else { return nil }
		return BoardTransform(zoom: transform.zoom, pan: CGSize(width: transform.pan.width + dx, height: transform.pan.height + dy))
	}

	// MARK: Connectors

	/// An elbow route between two cards. It leaves the side of `from` that
	/// faces `to`. The shape says where it turns and where its label sits.
	static func route(from: CGRect, to: CGRect, shape: BoardConnector.Shape = .balanced) -> ConnectorRoute {
		if to.minX - from.maxX >= minimumElbowGap {
			return elbow(CGPoint(x: from.maxX, y: from.midY), CGPoint(x: to.minX, y: to.midY), horizontal: true, shape: shape)
		}
		if from.minX - to.maxX >= minimumElbowGap {
			return elbow(CGPoint(x: from.minX, y: from.midY), CGPoint(x: to.maxX, y: to.midY), horizontal: true, shape: shape)
		}
		if to.minY - from.maxY >= minimumElbowGap {
			return elbow(CGPoint(x: from.midX, y: from.maxY), CGPoint(x: to.midX, y: to.minY), horizontal: false, shape: shape)
		}
		if from.minY - to.maxY >= minimumElbowGap {
			return elbow(CGPoint(x: from.midX, y: from.minY), CGPoint(x: to.midX, y: to.maxY), horizontal: false, shape: shape)
		}
		// The cards touch or overlap. A straight line still says they join.
		let points = [CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY)]
		return ConnectorRoute(points: points, labelPoint: midpoint(of: points))
	}

	/// An elbow from `start` to `end`. `horizontal` says whether the line
	/// leaves along x or along y.
	private static func elbow(_ start: CGPoint, _ end: CGPoint, horizontal: Bool, shape: BoardConnector.Shape) -> ConnectorRoute {
		// "Along" is the axis the line leaves on. "Across" is the other one.
		let alongStart = horizontal ? start.x : start.y
		let alongEnd = horizontal ? end.x : end.y
		let acrossStart = horizontal ? start.y : start.x
		let acrossEnd = horizontal ? end.y : end.x
		func point(along: CGFloat, across: CGFloat) -> CGPoint {
			horizontal ? CGPoint(x: along, y: across) : CGPoint(x: across, y: along)
		}

		let heading: CGFloat = alongEnd >= alongStart ? 1 : -1
		let halfway = (alongStart + alongEnd) / 2
		let turn: CGFloat
		switch shape {
		case .balanced:
			turn = halfway
		case .branch:
			// A gap too short for a branch and a stub turns halfway.
			turn = abs(alongEnd - alongStart) >= trunkInset * 2 ? alongEnd - heading * trunkInset : halfway
		}

		let points = acrossStart == acrossEnd
			? [start, end]
			: [start, point(along: turn, across: acrossStart), point(along: turn, across: acrossEnd), end]

		switch shape {
		case .balanced:
			return ConnectorRoute(points: points, labelPoint: midpoint(of: points))
		case .branch:
			// The middle of the straight part of the branch, short of the corner.
			let corner = min(connectorRadius, abs(turn - alongStart))
			let straightEnd = turn - heading * corner
			return ConnectorRoute(points: points, labelPoint: point(along: (alongStart + straightEnd) / 2, across: acrossStart))
		}
	}

	static func length(of points: [CGPoint]) -> CGFloat {
		zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
	}

	/// The point halfway along a line, by length.
	static func midpoint(of points: [CGPoint]) -> CGPoint {
		guard let first = points.first else { return .zero }
		var remaining = length(of: points) / 2
		for (a, b) in zip(points, points.dropFirst()) {
			let segment = hypot(b.x - a.x, b.y - a.y)
			if segment >= remaining, segment > 0 {
				let t = remaining / segment
				return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
			}
			remaining -= segment
		}
		return points.last ?? first
	}

	/// The route as a path with rounded corners. A corner's radius shrinks
	/// to fit a short leg.
	static func path(for route: ConnectorRoute, cornerRadius: CGFloat = connectorRadius) -> CGPath {
		let path = CGMutablePath()
		let points = route.points
		guard let first = points.first else { return path }
		path.move(to: first)
		guard points.count > 2 else {
			if let last = points.last { path.addLine(to: last) }
			return path
		}
		for index in 1..<(points.count - 1) {
			let previous = points[index - 1]
			let corner = points[index]
			let next = points[index + 1]
			let before = hypot(corner.x - previous.x, corner.y - previous.y)
			let after = hypot(next.x - corner.x, next.y - corner.y)
			let radius = min(cornerRadius, before / 2, after / 2)
			path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
		}
		if let last = points.last { path.addLine(to: last) }
		return path
	}

	/// The connectors that carry a request now. A connector is lit while a
	/// request runs on its path, and for a moment after one finishes there.
	///
	/// `running` names each request's device and role, so only that path
	/// lights. A host that sends a count and no list lights every model
	/// connector instead.
	static func activeConnectors(
		in scene: BoardScene,
		requestsInProgress: Int,
		running: [RunningRequest] = [],
		glows: [HostStore.RequestGlow],
		now: Date
	) -> Set<String> {
		var active: Set<String> = []
		let modelConnectors = scene.connectors.filter { $0.from == .machine && !$0.isGhost }

		func light(deviceID: String?, role: Role?, anyModelWithoutRole: Bool) {
			if let deviceID {
				let device = BoardCardID.device(deviceID)
				active.formUnion(scene.connectors.filter { $0.from == device || ($0.from == .tunnel && $0.to == .machine) }.map(\.id))
			}
			if let role {
				let slots: Set<BoardCardID> = [.model(ModelSlot(role)), .model(.all)]
				active.formUnion(modelConnectors.filter { slots.contains($0.to) }.map(\.id))
			} else if anyModelWithoutRole {
				// The app named a model, so the role is unknown. Show that
				// the machine is at work without claiming which role.
				active.formUnion(modelConnectors.map(\.id))
			}
		}

		if running.isEmpty, requestsInProgress > 0 {
			active.formUnion(modelConnectors.map(\.id))
		}
		for request in running {
			light(deviceID: request.deviceId, role: request.role, anyModelWithoutRole: true)
		}
		for glow in glows where glow.until > now {
			light(deviceID: glow.deviceID, role: glow.role, anyModelWithoutRole: false)
		}
		return active
	}

	/// The order to draw the lines in. Lines that carry nothing go down
	/// first, then live ones, then the ones with a request on them, so
	/// where two lines share a trunk the one that says more is on top.
	static func drawOrder(of connectors: [BoardConnector], active: Set<String>) -> [BoardConnector] {
		func rank(_ connector: BoardConnector) -> Int {
			if active.contains(connector.id) { return 2 }
			return connector.isLive ? 1 : 0
		}
		return connectors.enumerated()
			.sorted { a, b in
				let rankA = rank(a.element)
				let rankB = rank(b.element)
				return rankA != rankB ? rankA < rankB : a.offset < b.offset
			}
			.map(\.element)
	}

	// MARK: Keyboard

	/// The card an arrow key moves to: the nearest card in that direction,
	/// with a card straight ahead preferred over one off to the side.
	///
	/// `focusable` names the cards that can take focus. A card outside it is
	/// never the answer, so an arrow key cannot send focus to a card that
	/// would drop it. Nil means every card can take focus.
	static func neighbor(
		of id: BoardCardID,
		toward direction: MoveDirection,
		among frames: [BoardCardID: CGRect],
		focusable: Set<BoardCardID>? = nil
	) -> BoardCardID? {
		guard let origin = frames[id] else { return nil }
		let sidewaysCost: CGFloat = 2
		var best: (id: BoardCardID, score: CGFloat)?
		for (candidate, frame) in frames where candidate != id {
			if let focusable, !focusable.contains(candidate) { continue }
			let dx = frame.midX - origin.midX
			let dy = frame.midY - origin.midY
			let ahead: CGFloat
			let sideways: CGFloat
			switch direction {
			case .right: (ahead, sideways) = (dx, abs(dy))
			case .left: (ahead, sideways) = (-dx, abs(dy))
			case .down: (ahead, sideways) = (dy, abs(dx))
			case .up: (ahead, sideways) = (-dy, abs(dx))
			}
			guard ahead > 0 else { continue }
			let score = ahead + sideways * sidewaysCost
			// Break a tie by name, so the answer does not depend on the
			// order of a dictionary.
			if best == nil || score < best!.score || (score == best!.score && candidate.rawValue < best!.id.rawValue) {
				best = (candidate, score)
			}
		}
		return best?.id
	}

	/// The column a card reads in. Columns are as wide as a card and a gap,
	/// counted from the middle of the board. The default layout puts each of
	/// its four columns in the middle of one, so a card dragged a little to
	/// either side stays in its column.
	static func column(ofMidX midX: CGFloat) -> Int {
		Int((midX / (cardWidth + columnGap)).rounded(.down))
	}

	/// The order Tab and VoiceOver visit the cards: by column, then top to
	/// bottom.
	static func readingOrder(of frames: [BoardCardID: CGRect]) -> [BoardCardID] {
		frames.sorted { a, b in
			let columnA = column(ofMidX: a.value.midX)
			let columnB = column(ofMidX: b.value.midX)
			if columnA != columnB { return columnA < columnB }
			if a.value.midY != b.value.midY { return a.value.midY < b.value.midY }
			if a.value.midX != b.value.midX { return a.value.midX < b.value.midX }
			return a.key.rawValue < b.key.rawValue
		}.map(\.key)
	}

	/// Where Option and an arrow key put a card: one dot of the ground away.
	static func nudged(_ center: CGPoint, toward direction: MoveDirection) -> CGPoint {
		switch direction {
		case .up: CGPoint(x: center.x, y: center.y - dotSpacing)
		case .down: CGPoint(x: center.x, y: center.y + dotSpacing)
		case .left: CGPoint(x: center.x - dotSpacing, y: center.y)
		case .right: CGPoint(x: center.x + dotSpacing, y: center.y)
		}
	}
}

extension HostStatus {
	/// The device a card stands for, if it is a device card.
	func device(on card: BoardCardID?) -> Device? {
		guard let card, case .device(let id) = BoardLayout.scene(for: self).card(card)?.kind else { return nil }
		return device(id: id)
	}

	/// The installed model a card stands for, if it is a model card.
	func model(on card: BoardCardID?) -> Model? {
		guard let card, case .model(_, let id) = BoardLayout.scene(for: self).card(card)?.kind else { return nil }
		return model(id: id)
	}
}
