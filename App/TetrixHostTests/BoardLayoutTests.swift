import CoreGraphics
import Foundation
import Testing
@testable import TetrixHost

@Suite("Board layout")
struct BoardLayoutTests {
	private let status = HostStatus.fixture()

	// MARK: Scene

	@Test("A stopped host shows this machine alone")
	func stoppedScene() {
		let scene = BoardLayout.scene(for: nil)
		#expect(scene.cards.map(\.id) == [.machine])
		#expect(scene.connectors.isEmpty)
	}

	@Test("A running host shows devices, the tunnel, the machine, and a card per role")
	func runningScene() {
		let scene = BoardLayout.scene(for: status)
		#expect(scene.cards.map(\.id) == [
			.device(Fixture.laptopID), .device(Fixture.phoneID), .pairDevice,
			.tunnel, .machine, .model(.deep), .model(.quick),
		])
		let labels = Dictionary(uniqueKeysWithValues: scene.connectors.map { ($0.id, $0.label) })
		#expect(labels["device:\(Fixture.laptopID)>tunnel"] == "Sealed")
		#expect(labels["machine>model:deep"] == "Deep")
		#expect(labels["machine>model:quick"] == "Quick")
		#expect(labels["tunnel>machine"] == .some(nil))
		#expect(scene.connectors.first { $0.from == .pairDevice }?.isGhost == true)
	}

	private func connector(_ id: String, in status: HostStatus) -> BoardConnector? {
		BoardLayout.scene(for: status).connectors.first { $0.id == id }
	}

	@Test("A device's connector is live, and says Sealed, only while the device is connected through a connected tunnel")
	func deviceConnectorIsLive() {
		let laptop = "device:\(Fixture.laptopID)>tunnel"
		let phone = "device:\(Fixture.phoneID)>tunnel"
		// The fixture's laptop is connected and its phone is not.
		#expect(connector(laptop, in: status)?.isLive == true)
		#expect(connector(laptop, in: status)?.label == "Sealed")
		#expect(connector(phone, in: status)?.isLive == false)
		#expect(connector(phone, in: status)?.label == nil)

		var connecting = status
		connecting.tunnel.state = .connecting
		#expect(connector(laptop, in: connecting)?.isLive == false)
		#expect(connector(laptop, in: connecting)?.label == nil)

		var offline = status
		offline.tunnel.state = .offline
		#expect(connector(laptop, in: offline)?.isLive == false)

		var off = status
		off.tunnel.enabled = false
		#expect(connector(laptop, in: off)?.isLive == false)
		#expect(connector(laptop, in: off)?.label == nil)
	}

	@Test("The tunnel's connector is live while the tunnel is connected")
	func tunnelConnectorIsLive() {
		#expect(connector("tunnel>machine", in: status)?.isLive == true)
		for state in [Tunnel.State.connecting, .offline, .disabled] {
			var changed = status
			changed.tunnel.state = state
			#expect(connector("tunnel>machine", in: changed)?.isLive == false)
		}
		var off = status
		off.tunnel.enabled = false
		#expect(connector("tunnel>machine", in: off)?.isLive == false)
	}

	@Test("A model's connector is live once a model is assigned, and the ghosts' are not")
	func modelConnectorIsLive() {
		#expect(connector("machine>model:deep", in: status)?.isLive == true)
		#expect(connector("machine>model:quick", in: status)?.isLive == true)
		#expect(connector("ghost:pair>tunnel", in: status)?.isLive == false)

		var single = status
		single.roles.quick = ""
		single.roles.single = true
		#expect(connector("machine>model:all", in: single)?.isLive == true)
		#expect(connector("machine>model:all", in: single)?.label == "All work")

		var none = status
		none.roles = Roles()
		#expect(connector("machine>model:all", in: none)?.isLive == false)
		#expect(connector("machine>model:all", in: none)?.label == nil)
	}

	@Test("Lines that carry nothing are drawn first, then live ones, then busy ones")
	func drawOrder() {
		let scene = BoardLayout.scene(for: status)
		let ordered = BoardLayout.drawOrder(of: scene.connectors, active: ["machine>model:quick"]).map(\.id)
		#expect(ordered == [
			"device:\(Fixture.phoneID)>tunnel", "ghost:pair>tunnel",
			"device:\(Fixture.laptopID)>tunnel", "tunnel>machine", "machine>model:deep",
			"machine>model:quick",
		])
	}

	@Test("One model for everything shows one card labelled All work")
	func singleModelScene() {
		var status = status
		status.roles.quick = ""
		status.roles.single = true
		let scene = BoardLayout.scene(for: status)
		let models = scene.cards.filter { if case .model = $0.kind { true } else { false } }
		#expect(models.map(\.id) == [.model(.all)])
		#expect(ModelSlot.all.title == "All work")
	}

	@Test("No assigned model shows a ghost card")
	func ghostModelScene() {
		var status = status
		status.roles = Roles()
		let scene = BoardLayout.scene(for: status)
		#expect(scene.card(.model(.all))?.kind == .chooseModel(slot: .all))
		#expect(scene.connectors.first { $0.to == .model(.all) }?.isGhost == true)
	}

	@Test("A tunnel that is off leaves no live path through it and keeps the devices")
	func tunnelOffScene() {
		var status = status
		status.tunnel.enabled = false
		let scene = BoardLayout.scene(for: status)
		#expect(scene.card(.device(Fixture.laptopID)) != nil)
		#expect(scene.connectors.filter { $0.to == .tunnel || $0.from == .tunnel }.allSatisfy { !$0.isLive && $0.label == nil })
		#expect(scene.connectors.filter { $0.from == .machine }.allSatisfy { $0.isLive })
	}

	// MARK: Default positions

	@Test("The default layout runs left to right: devices, tunnel, machine, models")
	func defaultColumns() throws {
		let scene = BoardLayout.scene(for: status)
		let positions = BoardLayout.defaultPositions(for: scene)
		let device = try #require(positions[.device(Fixture.laptopID)])
		let tunnel = try #require(positions[.tunnel])
		let machine = try #require(positions[.machine])
		let deep = try #require(positions[.model(.deep)])
		#expect(device.x < tunnel.x)
		#expect(tunnel.x < machine.x)
		#expect(machine.x < deep.x)
		#expect(tunnel.x - device.x == BoardLayout.cardWidth + BoardLayout.columnGap)
		#expect(positions[.device(Fixture.phoneID)]?.x == device.x)
		#expect(positions[.model(.quick)]?.x == deep.x)
	}

	@Test("The default layout is centered on the origin and no cards overlap")
	func defaultLayoutIsCenteredAndClear() {
		let scene = BoardLayout.scene(for: status)
		let frames = BoardLayout.frames(for: scene, saved: [:])
		let bounds = BoardLayout.bounds(of: frames)
		#expect(abs(bounds.midX) < 0.001)
		#expect(abs(bounds.midY) < 0.001)

		let all = Array(frames.values)
		for (index, a) in all.enumerated() {
			for b in all[(index + 1)...] {
				#expect(!a.intersects(b))
			}
		}
	}

	@Test("The pairing ghost sits at the bottom of the device column")
	func ghostAtBottom() throws {
		let positions = BoardLayout.defaultPositions(for: BoardLayout.scene(for: status))
		let ghost = try #require(positions[.pairDevice])
		let phone = try #require(positions[.device(Fixture.phoneID)])
		let laptop = try #require(positions[.device(Fixture.laptopID)])
		#expect(laptop.y < phone.y)
		#expect(phone.y < ghost.y)
	}

	@Test("A machine alone sits on the origin")
	func loneMachine() {
		let positions = BoardLayout.defaultPositions(for: BoardLayout.scene(for: nil))
		#expect(positions[.machine] == .zero)
	}

	@Test("A saved position wins over the default one")
	func savedPosition() {
		let scene = BoardLayout.scene(for: status)
		let frames = BoardLayout.frames(for: scene, saved: [.tunnel: CGPoint(x: 400, y: -300)])
		#expect(frames[.tunnel]?.midX == 400)
		#expect(frames[.tunnel]?.midY == -300)
	}

	// MARK: Connectors

	@Test("Cards side by side on one line join with a straight line")
	func straightRoute() {
		let from = CGRect(x: 0, y: 0, width: 100, height: 60)
		let to = CGRect(x: 200, y: 0, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to)
		#expect(route.points == [CGPoint(x: 100, y: 30), CGPoint(x: 200, y: 30)])
		#expect(route.labelPoint == CGPoint(x: 150, y: 30))
	}

	@Test("Cards side by side at different heights join with an elbow that turns halfway")
	func elbowRoute() {
		let from = CGRect(x: 0, y: 0, width: 100, height: 60)
		let to = CGRect(x: 200, y: 200, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to)
		#expect(route.points == [
			CGPoint(x: 100, y: 30), CGPoint(x: 150, y: 30),
			CGPoint(x: 150, y: 230), CGPoint(x: 200, y: 230),
		])
		// The line is 50 + 200 + 50 long, so its middle is on the upright.
		#expect(route.labelPoint == CGPoint(x: 150, y: 130))
	}

	@Test("A branch connector turns close to the far card and keeps its label on its own branch")
	func branchRoute() {
		let from = CGRect(x: 0, y: 0, width: 100, height: 60)
		let to = CGRect(x: 196, y: 200, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to, shape: .branch)
		let turn = 196 - BoardLayout.trunkInset
		#expect(route.points == [
			CGPoint(x: 100, y: 30), CGPoint(x: turn, y: 30),
			CGPoint(x: turn, y: 230), CGPoint(x: 196, y: 230),
		])
		// The label is on the first leg, at the card's own height, short of
		// the corner where the trunk starts.
		#expect(route.labelPoint.y == 30)
		#expect(route.labelPoint.x == (100 + turn - BoardLayout.connectorRadius) / 2)
		#expect(route.labelPoint.x < turn - BoardLayout.connectorRadius)

		// Two cards that share a far card share a trunk, and their labels
		// stay apart.
		let other = BoardLayout.route(from: from.offsetBy(dx: 0, dy: 300), to: to, shape: .branch)
		#expect(other.points[1].x == route.points[1].x)
		#expect(other.labelPoint.y == 330)

		// A card level with the far card has no trunk of its own, and its
		// label keeps the same place on the line.
		let level = BoardLayout.route(from: from.offsetBy(dx: 0, dy: 200), to: to, shape: .branch)
		#expect(level.points.count == 2)
		#expect(level.labelPoint == CGPoint(x: route.labelPoint.x, y: 230))

		// A gap too short for a branch and a stub turns halfway.
		let near = BoardLayout.route(from: from, to: CGRect(x: 130, y: 200, width: 100, height: 60), shape: .branch)
		#expect(near.points[1].x == 115)
	}

	@Test("In the default layout a pill fits between two columns, and a device's pill fits on its branch")
	func pillsFit() {
		// The widest pills at the label size: "All work" at 59 points on
		// the upright between two columns, "Sealed" at 52 on a branch.
		#expect(BoardLayout.columnGap >= 59 + 2 * Space.s)
		let branch = BoardLayout.columnGap - BoardLayout.trunkInset - BoardLayout.connectorRadius
		#expect(branch >= 52 + 2 * Space.xs)
		// One spacing step is too narrow for either.
		#expect(Space.xxl < 52)
	}

	@Test("A card to the left is reached from the left side")
	func leftwardRoute() {
		let from = CGRect(x: 300, y: 0, width: 100, height: 60)
		let to = CGRect(x: 0, y: 0, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to)
		#expect(route.points.first == CGPoint(x: 300, y: 30))
		#expect(route.points.last == CGPoint(x: 100, y: 30))
	}

	@Test("Stacked cards join top to bottom")
	func verticalRoute() {
		let from = CGRect(x: 0, y: 0, width: 100, height: 60)
		let to = CGRect(x: 40, y: 200, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to)
		#expect(route.points.first == CGPoint(x: 50, y: 60))
		#expect(route.points.last == CGPoint(x: 90, y: 200))
		#expect(route.points.count == 4)
	}

	@Test("Overlapping cards join center to center")
	func overlappingRoute() {
		let from = CGRect(x: 0, y: 0, width: 100, height: 60)
		let to = CGRect(x: 50, y: 20, width: 100, height: 60)
		let route = BoardLayout.route(from: from, to: to)
		#expect(route.points == [CGPoint(x: 50, y: 30), CGPoint(x: 100, y: 50)])
	}

	@Test("The midpoint is halfway along the line by length")
	func midpoint() {
		let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)]
		#expect(BoardLayout.length(of: points) == 40)
		#expect(BoardLayout.midpoint(of: points) == CGPoint(x: 10, y: 10))
		#expect(BoardLayout.midpoint(of: []) == .zero)
	}

	@Test("The path starts and ends where the route does, and stays inside its box")
	func roundedPath() {
		let route = BoardLayout.route(
			from: CGRect(x: 0, y: 0, width: 100, height: 60),
			to: CGRect(x: 200, y: 200, width: 100, height: 60)
		)
		let path = BoardLayout.path(for: route)
		#expect(path.currentPoint == CGPoint(x: 200, y: 230))
		let box = path.boundingBoxOfPath
		#expect(abs(box.minX - 100) < 0.001)
		#expect(abs(box.maxX - 200) < 0.001)
		#expect(abs(box.minY - 30) < 0.001)
		#expect(abs(box.maxY - 230) < 0.001)
		// A rounded corner cuts the turn, so the corner point itself is off the line.
		#expect(!path.contains(CGPoint(x: 150, y: 30)))
	}

	@Test("A corner's radius shrinks to fit a short leg")
	func shortLegPath() {
		let route = ConnectorRoute(
			points: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 6), CGPoint(x: 8, y: 6)],
			labelPoint: .zero
		)
		let box = BoardLayout.path(for: route, cornerRadius: 12).boundingBoxOfPath
		#expect(box.width <= 8.001)
		#expect(box.height <= 6.001)
	}

	// MARK: Activity

	@Test("A request in progress lights the model connectors")
	func activeWhileBusy() {
		let scene = BoardLayout.scene(for: status)
		let active = BoardLayout.activeConnectors(in: scene, requestsInProgress: 1, glows: [], now: Fixture.now)
		#expect(active == ["machine>model:deep", "machine>model:quick"])
	}

	@Test("A finished request lights its device, the tunnel, and its role for a moment")
	func activeAfterRequest() {
		let scene = BoardLayout.scene(for: status)
		let glow = HostStore.RequestGlow(deviceID: Fixture.phoneID, role: .quick, until: Fixture.now.addingTimeInterval(2))
		let during = BoardLayout.activeConnectors(in: scene, requestsInProgress: 0, glows: [glow], now: Fixture.now)
		#expect(during == ["device:\(Fixture.phoneID)>tunnel", "tunnel>machine", "machine>model:quick"])
		let after = BoardLayout.activeConnectors(in: scene, requestsInProgress: 0, glows: [glow], now: Fixture.now.addingTimeInterval(3))
		#expect(after.isEmpty)
	}

	@Test("A running request lights its own path and no other")
	func activeRunningRequest() {
		let scene = BoardLayout.scene(for: status)
		let fromPhone = RunningRequest(id: "r1", deviceId: Fixture.phoneID, role: .quick)
		let active = BoardLayout.activeConnectors(in: scene, requestsInProgress: 1, running: [fromPhone], glows: [], now: Fixture.now)
		#expect(active == ["device:\(Fixture.phoneID)>tunnel", "tunnel>machine", "machine>model:quick"])

		// A request from this machine does not cross the tunnel.
		let local = RunningRequest(id: "r2", deviceId: nil, role: .deep)
		let alone = BoardLayout.activeConnectors(in: scene, requestsInProgress: 1, running: [local], glows: [], now: Fixture.now)
		#expect(alone == ["machine>model:deep"])

		// An app that named a model has no role. The machine is at work,
		// and the board does not claim which role.
		let named = RunningRequest(id: "r3", deviceId: Fixture.laptopID, role: nil)
		let both = BoardLayout.activeConnectors(in: scene, requestsInProgress: 1, running: [named], glows: [], now: Fixture.now)
		#expect(both == ["device:\(Fixture.laptopID)>tunnel", "tunnel>machine", "machine>model:deep", "machine>model:quick"])
	}

	@Test("A local request lights the model alone")
	func activeLocalRequest() {
		let scene = BoardLayout.scene(for: status)
		let glow = HostStore.RequestGlow(deviceID: nil, role: .deep, until: Fixture.now.addingTimeInterval(2))
		let active = BoardLayout.activeConnectors(in: scene, requestsInProgress: 0, glows: [glow], now: Fixture.now)
		#expect(active == ["machine>model:deep"])
	}

	// MARK: View

	@Test("Content that fits is shown life size and centered")
	func fitSmallContent() {
		let content = CGRect(x: -100, y: -50, width: 400, height: 200)
		let transform = BoardLayout.fit(content: content, viewport: CGSize(width: 1000, height: 700), padding: 32)
		#expect(transform.zoom == 1)
		#expect(transform.pan == CGSize(width: -100, height: -50))
	}

	@Test("Content wider than the view shrinks to fit, never below 75 percent")
	func fitWideContent() {
		let content = CGRect(x: -500, y: -100, width: 1000, height: 200)
		let transform = BoardLayout.fit(content: content, viewport: CGSize(width: 864, height: 700), padding: 32)
		#expect(abs(transform.zoom - 0.8) < 0.0001)
		#expect(transform.pan == .zero)

		let tiny = BoardLayout.fit(content: content, viewport: CGSize(width: 200, height: 700), padding: 32)
		#expect(tiny.zoom == BoardLayout.fitFloor)
		#expect(BoardLayout.fitFloor == 0.75)
		#expect(BoardLayout.fitFloor > BoardLayout.minZoom)
	}

	@Test("Content too large for the floor starts at its leading and top edges")
	func fitOverflow() {
		// Too wide and short enough: the left edge sits at the padding, and
		// the height stays centered.
		let wide = CGRect(x: -500, y: -100, width: 1000, height: 200)
		let narrow = BoardLayout.fit(content: wide, viewport: CGSize(width: 400, height: 700), padding: 32)
		#expect(narrow.zoom == 0.75)
		#expect(400 / 2 + narrow.pan.width + wide.minX * narrow.zoom == 32)
		#expect(narrow.pan.height == -wide.midY * narrow.zoom)

		// Too tall: the top edge sits at the padding, and the width stays
		// centered.
		let tall = CGRect(x: -100, y: -600, width: 200, height: 1200)
		let short = BoardLayout.fit(content: tall, viewport: CGSize(width: 900, height: 500), padding: 32)
		#expect(short.zoom == 0.75)
		#expect(500 / 2 + short.pan.height + tall.minY * short.zoom == 32)
		#expect(short.pan.width == -tall.midX * short.zoom)
	}

	@Test("The default board fits the default window with the inspector open, and stops at the floor in the smallest one")
	func fitsDefaultWindow() {
		let frames = BoardLayout.frames(for: BoardLayout.scene(for: status), saved: [:])
		let bounds = BoardLayout.bounds(of: frames)
		let chrome = Metrics.toolbarHeight + Metrics.drawerBarHeight

		let usual = CGSize(width: Metrics.windowDefaultWidth - Metrics.inspectorWidth, height: Metrics.windowDefaultHeight - chrome)
		let fitted = BoardLayout.fit(content: bounds, viewport: usual, padding: Space.xl)
		#expect(fitted.zoom >= BoardLayout.fitFloor)
		#expect(bounds.width * fitted.zoom <= usual.width)
		#expect(bounds.height * fitted.zoom <= usual.height)

		let smallest = CGSize(width: Metrics.windowMinWidth - Metrics.inspectorWidth, height: Metrics.windowMinHeight - chrome)
		#expect(BoardLayout.fit(content: bounds, viewport: smallest, padding: Space.xl).zoom == BoardLayout.fitFloor)
	}

	@Test("A card out of view is brought in by the least pan, and a card in view moves nothing")
	func reveal() {
		let viewport = CGSize(width: 800, height: 600)
		let start = BoardTransform(zoom: 1, pan: .zero)
		let inside = CGRect(x: -100, y: -50, width: 200, height: 100)
		#expect(BoardLayout.revealing(inside, in: viewport, transform: start, padding: 16) == nil)

		// Off the right edge by 100 points: the board moves left by that
		// much and the padding.
		let right = CGRect(x: 300, y: -50, width: 200, height: 100)
		let shown = BoardLayout.revealing(right, in: viewport, transform: start, padding: 16)
		#expect(shown == BoardTransform(zoom: 1, pan: CGSize(width: -116, height: 0)))

		// Off the top at half size.
		let half = BoardTransform(zoom: 0.5, pan: .zero)
		let above = CGRect(x: 0, y: -900, width: 200, height: 100)
		let lifted = BoardLayout.revealing(above, in: viewport, transform: half, padding: 16)
		#expect(lifted == BoardTransform(zoom: 0.5, pan: CGSize(width: 0, height: 166)))

		// A card larger than the view keeps its leading edge in view.
		let huge = CGRect(x: -300, y: 0, width: 1200, height: 100)
		let leading = BoardLayout.revealing(huge, in: viewport, transform: start, padding: 16)
		#expect(leading?.pan.width == -84)
	}

	@Test("Zoom stays between 50 and 200 percent")
	func zoomLimits() {
		#expect(BoardLayout.clampZoom(0.1) == 0.5)
		#expect(BoardLayout.clampZoom(9) == 2)
		#expect(BoardLayout.clampZoom(1.3) == 1.3)
	}

	@Test("Zooming keeps the point under the pointer in place")
	func zoomAnchor() {
		let start = BoardTransform(zoom: 1, pan: CGSize(width: 20, height: -10))
		let anchor = CGPoint(x: 120, y: 40)
		let zoomed = BoardLayout.zoomed(start, to: 1.5, anchor: anchor)
		#expect(zoomed.zoom == 1.5)
		// The board point under the anchor before the zoom is under it after.
		let boardX = (anchor.x - start.pan.width) / start.zoom
		let boardY = (anchor.y - start.pan.height) / start.zoom
		#expect(abs(zoomed.pan.width + boardX * zoomed.zoom - anchor.x) < 0.0001)
		#expect(abs(zoomed.pan.height + boardY * zoomed.zoom - anchor.y) < 0.0001)
	}

	// MARK: Keyboard

	@Test("Arrow keys move to the nearest card in that direction")
	func arrowKeys() {
		let frames = BoardLayout.frames(for: BoardLayout.scene(for: status), saved: [:])
		#expect(BoardLayout.neighbor(of: .machine, toward: .left, among: frames) == .tunnel)
		#expect(BoardLayout.neighbor(of: .tunnel, toward: .right, among: frames) == .machine)
		#expect(BoardLayout.neighbor(of: .model(.deep), toward: .down, among: frames) == .model(.quick))
		#expect(BoardLayout.neighbor(of: .model(.quick), toward: .up, among: frames) == .model(.deep))
		#expect(BoardLayout.neighbor(of: .device(Fixture.laptopID), toward: .down, among: frames) == .device(Fixture.phoneID))
		#expect(BoardLayout.neighbor(of: .device(Fixture.phoneID), toward: .down, among: frames) == .pairDevice)
		#expect(BoardLayout.neighbor(of: .device(Fixture.laptopID), toward: .left, among: frames) == nil)
		#expect(BoardLayout.neighbor(of: .model(.deep), toward: .right, among: frames) == nil)
	}

	@Test("An arrow key never moves to a card that cannot take focus")
	func arrowKeysSkipUnfocusable() {
		let frames = BoardLayout.frames(for: BoardLayout.scene(for: status), saved: [:])
		var focusable = Set(frames.keys)
		#expect(BoardLayout.neighbor(of: .tunnel, toward: .right, among: frames, focusable: focusable) == .machine)

		// With the machine out, the nearest card to the right of the tunnel
		// is a model.
		focusable.remove(.machine)
		let next = BoardLayout.neighbor(of: .tunnel, toward: .right, among: frames, focusable: focusable)
		#expect(next == .model(.deep) || next == .model(.quick))

		// With every card to the right out, there is nowhere to go.
		focusable.subtract([.model(.deep), .model(.quick)])
		#expect(BoardLayout.neighbor(of: .tunnel, toward: .right, among: frames, focusable: focusable) == nil)
		#expect(BoardLayout.neighbor(of: .tunnel, toward: .right, among: frames, focusable: []) == nil)
	}

	@Test("Every card on the board takes focus, the ghost that offers a model too")
	func ghostCardsAreInTheScene() {
		var status = status
		status.roles = Roles()
		let scene = BoardLayout.scene(for: status)
		let frames = BoardLayout.frames(for: scene, saved: [:])
		#expect(BoardLayout.neighbor(of: .machine, toward: .right, among: frames, focusable: Set(scene.cards.map(\.id))) == .model(.all))
	}

	@Test("Reading order goes by column, then top to bottom")
	func readingOrder() {
		let frames = BoardLayout.frames(for: BoardLayout.scene(for: status), saved: [:])
		#expect(BoardLayout.readingOrder(of: frames) == [
			.device(Fixture.laptopID), .device(Fixture.phoneID), .pairDevice,
			.tunnel, .machine, .model(.deep), .model(.quick),
		])
	}

	@Test("A card dragged a little to one side keeps its place in the reading order")
	func readingOrderByColumn() {
		let scene = BoardLayout.scene(for: status)
		let defaults = BoardLayout.defaultPositions(for: scene)
		let usual = BoardLayout.readingOrder(of: BoardLayout.frames(for: scene, saved: [:]))

		// The phone is second in its column. One point to the left would
		// put it first if the order went by position alone.
		for nudge in [CGFloat(-1), 1, -40, 40] {
			var saved: [BoardCardID: CGPoint] = [:]
			let phone = defaults[.device(Fixture.phoneID)]!
			saved[.device(Fixture.phoneID)] = CGPoint(x: phone.x + nudge, y: phone.y)
			#expect(BoardLayout.readingOrder(of: BoardLayout.frames(for: scene, saved: saved)) == usual)
		}

		// A card dragged into another column reads with that column.
		var saved: [BoardCardID: CGPoint] = [:]
		let tunnel = defaults[.tunnel]!
		saved[.device(Fixture.phoneID)] = CGPoint(x: tunnel.x, y: tunnel.y - 400)
		#expect(BoardLayout.readingOrder(of: BoardLayout.frames(for: scene, saved: saved)) == [
			.device(Fixture.laptopID), .pairDevice,
			.device(Fixture.phoneID), .tunnel, .machine, .model(.deep), .model(.quick),
		])
	}

	@Test("The four default columns each sit in the middle of a reading column")
	func columns() {
		let step = BoardLayout.cardWidth + BoardLayout.columnGap
		let positions = BoardLayout.defaultPositions(for: BoardLayout.scene(for: status))
		let columns = [BoardCardID.device(Fixture.laptopID), .tunnel, .machine, .model(.deep)].map { BoardLayout.column(ofMidX: positions[$0]!.x) }
		#expect(columns == [-2, -1, 0, 1])
		for id in [BoardCardID.device(Fixture.laptopID), .tunnel, .machine, .model(.deep)] {
			let x = positions[id]!.x
			let offset = x - (x / step).rounded(.down) * step
			#expect(abs(offset - step / 2) < 0.001)
		}
	}

	@Test("Option and an arrow key move a card by one dot of the ground")
	func nudge() {
		let start = CGPoint(x: 10, y: -20)
		#expect(BoardLayout.nudged(start, toward: .left) == CGPoint(x: 10 - BoardLayout.dotSpacing, y: -20))
		#expect(BoardLayout.nudged(start, toward: .right) == CGPoint(x: 10 + BoardLayout.dotSpacing, y: -20))
		#expect(BoardLayout.nudged(start, toward: .up) == CGPoint(x: 10, y: -20 - BoardLayout.dotSpacing))
		#expect(BoardLayout.nudged(start, toward: .down) == CGPoint(x: 10, y: -20 + BoardLayout.dotSpacing))
		#expect(MoveDirection.allCases.map(\.actionName) == ["Move up", "Move down", "Move left", "Move right"])
	}

	@Test("A card stands for its device or its model")
	func cardLookups() {
		#expect(status.device(on: .device(Fixture.phoneID))?.id == Fixture.phoneID)
		#expect(status.device(on: .machine) == nil)
		#expect(status.device(on: nil) == nil)
		#expect(status.model(on: .model(.deep))?.id == Fixture.deepModelID)
		#expect(status.model(on: .device(Fixture.phoneID)) == nil)
		// A role whose model is gone has a card and no model to delete.
		var gone = status
		gone.engines[0].models = []
		#expect(gone.model(on: .model(.deep)) == nil)
	}
}

@Suite("Board state")
@MainActor
struct BoardStateTests {
	private func defaults() -> UserDefaults {
		let name = "TetrixHostTests.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		return defaults
	}

	@Test("Card positions, pan, and zoom survive a restart, keyed by card ID")
	func persistence() {
		let defaults = defaults()
		let first = BoardState(defaults: defaults)
		first.move(.tunnel, to: CGPoint(x: 120, y: -48))
		first.commitPositions()
		first.setTransform(BoardTransform(zoom: 1.5, pan: CGSize(width: 30, height: 40)))

		let stored = defaults.dictionary(forKey: "board.positions") as? [String: [Double]]
		#expect(stored?["tunnel"] == [120, -48])

		let second = BoardState(defaults: defaults)
		#expect(second.positions[.tunnel] == CGPoint(x: 120, y: -48))
		#expect(second.custom == BoardTransform(zoom: 1.5, pan: CGSize(width: 30, height: 40)))
	}

	@Test("Tidy board restores the default layout and the fitted view")
	func tidy() {
		let defaults = defaults()
		let board = BoardState(defaults: defaults)
		board.move(.machine, to: CGPoint(x: 9, y: 9))
		board.commitPositions()
		board.zoomIn()
		#expect(!board.isTidy)

		board.tidy()
		#expect(board.isTidy)
		#expect(board.positions.isEmpty)
		#expect(BoardState(defaults: defaults).isTidy)
	}

	@Test("Zoom to fit drops the custom view and keeps where the cards were put")
	func zoomToFit() {
		let defaults = defaults()
		let board = BoardState(defaults: defaults)
		board.viewport = CGSize(width: 1000, height: 700)
		board.contentBounds = CGRect(x: -100, y: -100, width: 200, height: 200)
		#expect(board.isFitted)

		board.move(.machine, to: CGPoint(x: 9, y: 9))
		board.commitPositions()
		board.setTransform(BoardTransform(zoom: 0.5, pan: CGSize(width: 300, height: -40)))
		#expect(!board.isFitted)
		#expect(board.zoom == 0.5)

		board.zoomToFit()
		#expect(board.isFitted)
		#expect(board.custom == nil)
		#expect(board.zoom == 1)
		#expect(board.positions[.machine] == CGPoint(x: 9, y: 9))

		// Both survive a restart: no custom view, and the saved position.
		let again = BoardState(defaults: defaults)
		#expect(again.isFitted)
		#expect(again.positions[.machine] == CGPoint(x: 9, y: 9))
		// Tidy board is still the command that resets positions.
		#expect(!again.isTidy)
	}

	@Test("A person can zoom out past the fit floor by hand")
	func manualZoomBelowFloor() {
		let board = BoardState(defaults: nil)
		board.viewport = CGSize(width: 300, height: 700)
		board.contentBounds = CGRect(x: -600, y: -100, width: 1200, height: 200)
		#expect(board.zoom == BoardLayout.fitFloor)
		for _ in 0..<5 { board.zoomOut() }
		#expect(board.zoom == BoardLayout.minZoom)
	}

	@Test("Option and an arrow key move a card and save it as a drag does")
	func nudgeIsSaved() {
		let defaults = defaults()
		let board = BoardState(defaults: defaults)
		let moved = board.nudge(.tunnel, from: CGPoint(x: 0, y: 0), toward: .right)
		#expect(moved == CGPoint(x: BoardLayout.dotSpacing, y: 0))
		#expect(board.positions[.tunnel] == moved)
		board.nudge(.tunnel, from: moved, toward: .up)
		#expect(BoardState(defaults: defaults).positions[.tunnel] == CGPoint(x: BoardLayout.dotSpacing, y: -BoardLayout.dotSpacing))
	}

	@Test("Revealing a card pans the view only when the card is out of it")
	func revealPans() {
		let board = BoardState(defaults: nil)
		board.viewport = CGSize(width: 800, height: 600)
		board.contentBounds = CGRect(x: -300, y: -200, width: 600, height: 400)
		board.reveal(CGRect(x: -100, y: -50, width: 200, height: 100))
		#expect(board.isFitted)
		board.reveal(CGRect(x: 600, y: -50, width: 200, height: 100))
		#expect(!board.isFitted)
		#expect(board.custom?.pan.width == -(800 - 400 + Space.m))
	}

	@Test("The zoom commands step within the limits")
	func zoomCommands() {
		let board = BoardState(defaults: nil)
		board.viewport = CGSize(width: 1000, height: 700)
		board.contentBounds = CGRect(x: -100, y: -100, width: 200, height: 200)
		#expect(board.zoom == 1)
		board.zoomIn()
		#expect(board.zoom == 1.25)
		for _ in 0..<10 { board.zoomIn() }
		#expect(board.zoom == BoardLayout.maxZoom)
		#expect(!board.canZoomIn)
		for _ in 0..<20 { board.zoomOut() }
		#expect(board.zoom == BoardLayout.minZoom)
		board.actualSize()
		#expect(board.zoom == 1)
	}
}
