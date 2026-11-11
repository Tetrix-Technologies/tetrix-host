import CoreGraphics
import Foundation
import Observation

/// Where a person put the cards and how they look at the board.
///
/// It saves card positions, pan, and zoom in UserDefaults. Until a person
/// pans or zooms, the board fits its content to the window.
@MainActor
@Observable
final class BoardState {
	/// Card centers a person chose, in board points.
	private(set) var positions: [BoardCardID: CGPoint] = [:]
	/// The view a person chose. Nil means fit the content.
	private(set) var custom: BoardTransform?
	/// The size of the board's view, which the zoom commands need.
	var viewport: CGSize = .zero
	/// The bounds of the cards, which the zoom commands need.
	var contentBounds: CGRect = .null

	@ObservationIgnored private let defaults: UserDefaults?

	private enum Key {
		static let positions = "board.positions"
		static let pan = "board.pan"
		static let zoom = "board.zoom"
	}

	/// Pass nil to keep the state in memory only.
	init(defaults: UserDefaults? = .standard) {
		self.defaults = defaults
		load()
	}

	// MARK: View

	func transform(content: CGRect, viewport: CGSize) -> BoardTransform {
		custom ?? BoardLayout.fit(content: content, viewport: viewport, padding: Space.xl)
	}

	private var current: BoardTransform {
		transform(content: contentBounds, viewport: viewport)
	}

	func setTransform(_ transform: BoardTransform) {
		custom = BoardTransform(zoom: BoardLayout.clampZoom(transform.zoom), pan: transform.pan)
		save()
	}

	func pan(by delta: CGSize) {
		var next = current
		next.pan.width += delta.width
		next.pan.height += delta.height
		setTransform(next)
	}

	func zoomIn() { setTransform(BoardLayout.zoomed(current, to: current.zoom * BoardLayout.zoomStep)) }
	func zoomOut() { setTransform(BoardLayout.zoomed(current, to: current.zoom / BoardLayout.zoomStep)) }

	/// Life size, with the content centered.
	func actualSize() {
		let center = contentBounds.isNull ? CGPoint.zero : CGPoint(x: contentBounds.midX, y: contentBounds.midY)
		setTransform(BoardTransform(zoom: 1, pan: CGSize(width: -center.x, height: -center.y)))
	}

	/// Goes back to the fitted view. Cards stay where a person put them.
	func zoomToFit() {
		custom = nil
		save()
	}

	/// Pans by the least distance that brings a card into view. A card in
	/// view already leaves the view as it is.
	func reveal(_ frame: CGRect) {
		guard let next = BoardLayout.revealing(frame, in: viewport, transform: current, padding: Space.m) else { return }
		setTransform(next)
	}

	var zoom: CGFloat { current.zoom }
	var canZoomIn: Bool { current.zoom < BoardLayout.maxZoom }
	var canZoomOut: Bool { current.zoom > BoardLayout.minZoom }
	/// True while the view is the fitted one, so "Zoom to fit" has nothing to do.
	var isFitted: Bool { custom == nil }

	// MARK: Cards

	func move(_ id: BoardCardID, to center: CGPoint) {
		positions[id] = center
	}

	/// Saves the positions once a drag ends.
	func commitPositions() {
		save()
	}

	/// Moves a card one dot of the ground, as Option and an arrow key do,
	/// and saves it as a drag does. Returns the card's new center.
	@discardableResult
	func nudge(_ id: BoardCardID, from center: CGPoint, toward direction: MoveDirection) -> CGPoint {
		let next = BoardLayout.nudged(center, toward: direction)
		move(id, to: next)
		commitPositions()
		return next
	}

	/// Restores the default layout and the fitted view.
	func tidy() {
		positions.removeAll()
		custom = nil
		save()
	}

	var isTidy: Bool { positions.isEmpty && custom == nil }

	// MARK: Storage

	private func load() {
		guard let defaults else { return }
		if let stored = defaults.dictionary(forKey: Key.positions) as? [String: [Double]] {
			for (key, value) in stored where value.count == 2 {
				positions[BoardCardID(rawValue: key)] = CGPoint(x: value[0], y: value[1])
			}
		}
		if let pan = defaults.array(forKey: Key.pan) as? [Double], pan.count == 2, defaults.object(forKey: Key.zoom) != nil {
			let zoom = BoardLayout.clampZoom(defaults.double(forKey: Key.zoom))
			custom = BoardTransform(zoom: zoom, pan: CGSize(width: pan[0], height: pan[1]))
		}
	}

	private func save() {
		guard let defaults else { return }
		var stored: [String: [Double]] = [:]
		for (id, point) in positions {
			stored[id.rawValue] = [point.x, point.y]
		}
		defaults.set(stored, forKey: Key.positions)
		if let custom {
			defaults.set([custom.pan.width, custom.pan.height], forKey: Key.pan)
			defaults.set(custom.zoom, forKey: Key.zoom)
		} else {
			defaults.removeObject(forKey: Key.pan)
			defaults.removeObject(forKey: Key.zoom)
		}
	}
}
