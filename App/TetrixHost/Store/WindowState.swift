import Foundation
import Observation

/// What the window shows: the selected card, the open panels, and the sheet.
@MainActor
@Observable
final class WindowState {
	enum Sheet: String, Identifiable, Sendable {
		case pairing, download

		var id: String { rawValue }
	}

	var selection: BoardCardID?
	var inspectorVisible = true
	var drawerOpen = false
	var sheet: Sheet?
	/// The device a person asked to unpair. The window asks before it does.
	var deviceToUnpair: Device?
	/// The model a person asked to delete. The window asks before it does.
	var modelToDelete: Model?

	func select(_ id: BoardCardID?) {
		selection = id
	}

	/// Selects a card and shows its details.
	func inspect(_ id: BoardCardID) {
		selection = id
		inspectorVisible = true
	}

	/// Shows the host's details, which is what the inspector holds when no
	/// card is selected.
	func inspectHost() {
		selection = nil
		inspectorVisible = true
	}

	/// Drops a selection whose card left the board.
	func reconcile(with scene: BoardScene) {
		if let selection, scene.card(selection) == nil {
			self.selection = nil
		}
	}
}
