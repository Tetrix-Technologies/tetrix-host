import SwiftUI

/// Everything one window needs, made once and shared through the environment.
@MainActor
@Observable
final class AppModel {
	let store: HostStore
	let board: BoardState
	let chat: ChatSession
	let window: WindowState

	init(store: HostStore, board: BoardState, chat: ChatSession = ChatSession(), window: WindowState = WindowState()) {
		self.store = store
		self.board = board
		self.chat = chat
		self.window = window
	}
}

extension View {
	func appModel(_ model: AppModel) -> some View {
		environment(model.store)
			.environment(model.board)
			.environment(model.chat)
			.environment(model.window)
	}
}

/// The window: the board, the inspector, the toolbar, and the sheets.
struct RootView: View {
	var model: AppModel

	var body: some View {
		@Bindable var window = model.window
		let store = model.store

		MainView()
			.inspector(isPresented: $window.inspectorVisible) {
				InspectorView()
					.inspectorColumnWidth(min: Metrics.inspectorMinWidth, ideal: Metrics.inspectorWidth, max: Metrics.inspectorMaxWidth)
					.toolbar {
						// The spacer keeps the toggle at the trailing edge
						// of the inspector's part of the toolbar.
						ToolbarSpacer(.flexible)
						ToolbarItem(placement: .primaryAction) {
							InspectorToggle()
						}
					}
			}
			.toolbar {
				// One item that holds system controls, so the system draws
				// one glass background behind them.
				ToolbarItem(placement: .principal) {
					HStack(spacing: Space.s) {
						if let status = store.status {
							RoleMenu(status: status)
						}
						HostStatusLabel()
						if let status = store.status {
							CopyButton(text: status.host.copyableAddress, label: "Copy address")
						}
						RunButton()
					}
				}

				if store.pullFraction != nil {
					ToolbarItem(placement: .primaryAction) {
						DownloadRingButton()
					}
				}
				ToolbarItem(placement: .primaryAction) {
					PairButton()
				}
			}
			.sheet(item: $window.sheet) { sheet in
				switch sheet {
				case .pairing:
					PairingSheet { window.sheet = nil }
						.task { await store.beginPairing() }
						.onDisappear { Task { await store.endPairing() } }
						.sheetSurface()
				case .download:
					DownloadSheet { window.sheet = nil }
						.onDisappear { store.dismissFinishedDownloads() }
						.sheetSurface()
				}
			}
			.confirmationDialog(
				"Unpair \(window.deviceToUnpair?.name ?? "this device")?",
				isPresented: Binding(get: { window.deviceToUnpair != nil }, set: { if !$0 { window.deviceToUnpair = nil } }),
				presenting: window.deviceToUnpair
			) { device in
				Button("Unpair", role: .destructive) {
					Task { await store.unpair(deviceID: device.id) }
				}
				Button("Cancel", role: .cancel) {}
			} message: { _ in
				Text("This device can no longer use this host.")
			}
			.confirmationDialog(
				"Delete \(window.modelToDelete?.name ?? "this model")?",
				isPresented: Binding(get: { window.modelToDelete != nil }, set: { if !$0 { window.modelToDelete = nil } }),
				presenting: window.modelToDelete
			) { model in
				Button("Delete", role: .destructive) {
					Task { await store.deleteModel(id: model.id) }
				}
				Button("Cancel", role: .cancel) {}
			} message: { _ in
				Text("The host removes the model from this machine. You can download it again.")
			}
			.frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
			.background(Palette.paper)
			// The toolbar sits on paper too, not on the system's grey.
			.containerBackground(Palette.paper, for: .window)
			.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
			.tint(Palette.moss.dynamicColor)
			.appModel(model)
			.task { await store.run() }
	}
}

extension View {
	/// The look of a sheet: raised paper and the sheet radius.
	func sheetSurface() -> some View {
		presentationBackground(Palette.paperRaised)
			.presentationCornerRadius(Radius.sheet)
	}
}
