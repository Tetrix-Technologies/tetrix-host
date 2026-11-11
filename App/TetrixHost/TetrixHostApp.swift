import AppKit
import SwiftUI

/// The program's entry point. A debug build can also render snapshots or
/// the app icon and exit, without opening a window.
@main
enum Main {
	@MainActor
	static func main() {
		#if DEBUG
		if let task = DebugTask(arguments: CommandLine.arguments) {
			task.run()
			return
		}
		#endif
		TetrixHostApp.main()
	}
}

/// Tetrix Host: a window onto the host that runs on this machine.
struct TetrixHostApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@State private var model: AppModel

	init() {
		let supervisor = AppDelegate.supervisor
		let model = AppModel(store: HostStore(supervisor: supervisor), board: BoardState())
		#if DEBUG
		DebugLaunch.apply(CommandLine.arguments, to: model.window)
		#endif
		_model = State(initialValue: model)
	}

	var body: some Scene {
		Window("Tetrix Host", id: "main") {
			if AppDelegate.isUnderTest {
				// The unit tests load into the app. They need no window
				// content and no connection to a host.
				Color.clear
			} else {
				RootView(model: model)
			}
		}
		.windowToolbarStyle(.unified(showsTitle: false))
		.windowResizability(.contentMinSize)
		.defaultSize(width: Metrics.windowDefaultWidth, height: Metrics.windowDefaultHeight)
		.commands {
			HostCommands(model: model)
			BoardCommands(model: model)
			InspectorCommands()
		}
	}
}

extension FocusedValues {
	/// True while a text field has keyboard focus. Command-Delete belongs to
	/// the field then, so the Edit menu's commands for a card stand down.
	@Entry var isEditingText: Bool?
}

/// The Host menu, and the Edit menu's commands for the selected card.
struct HostCommands: Commands {
	var model: AppModel
	@FocusedValue(\.isEditingText) private var isEditingText

	private var store: HostStore { model.store }
	private var isTyping: Bool { isEditingText == true }
	private var selectedDevice: Device? { store.status?.device(on: model.window.selection) }
	private var selectedModel: Model? { store.status?.model(on: model.window.selection) }

	/// Two menu items cannot share one shortcut, so Command-Delete goes to
	/// whichever of the two applies to the selected card.
	private static let deleteShortcut = KeyboardShortcut(.delete, modifiers: .command)

	var body: some Commands {
		// The app has one window, so the File menu has nothing to make.
		CommandGroup(replacing: .newItem) {}

		CommandGroup(after: .pasteboard) {
			Divider()
			Button("Unpair…") { model.window.deviceToUnpair = selectedDevice }
				.keyboardShortcut(selectedModel == nil ? Self.deleteShortcut : nil)
				.disabled(selectedDevice == nil || isTyping)
			Button("Delete…") { model.window.modelToDelete = selectedModel }
				.keyboardShortcut(selectedModel == nil ? nil : Self.deleteShortcut)
				.disabled(selectedModel == nil || isTyping)
		}

		CommandMenu("Host") {
			Button(store.showsStop ? "Stop host" : "Start host") {
				Task { await store.toggleRunning() }
			}
			.disabled(!store.canToggleRunning)
			Button("Copy address") {
				if let host = store.status?.host { Pasteboard.copy(host.copyableAddress) }
			}
			.disabled(store.status == nil)
			Divider()
			Button("Pair a device") { model.window.sheet = .pairing }
				.keyboardShortcut("n", modifiers: .command)
				.disabled(store.status == nil)
			Button("Download a model") { model.window.sheet = .download }
				.keyboardShortcut("d", modifiers: .command)
				.disabled(store.status == nil)
			Divider()
			Toggle("Use the tunnel", isOn: Binding(
				get: { store.status?.tunnel.enabled ?? false },
				set: { enabled in Task { await store.setTunnelEnabled(enabled) } }
			))
			.disabled(store.status == nil)
			if let status = store.status {
				Divider()
				RoleMenuItems(status: status, showsDownload: false)
					.environment(model.store)
					.environment(model.window)
			}
		}
	}
}

/// The View menu's board commands.
struct BoardCommands: Commands {
	var model: AppModel

	var body: some Commands {
		CommandGroup(before: .toolbar) {
			Button("Zoom in") { model.board.zoomIn() }
				.keyboardShortcut("+", modifiers: .command)
				.disabled(!model.board.canZoomIn)
			Button("Zoom out") { model.board.zoomOut() }
				.keyboardShortcut("-", modifiers: .command)
				.disabled(!model.board.canZoomOut)
			Button("Actual size") { model.board.actualSize() }
				.keyboardShortcut("0", modifiers: .command)
			Button("Zoom to fit") { model.board.zoomToFit() }
				.keyboardShortcut("9", modifiers: .command)
				.disabled(model.board.isFitted)
			Button("Tidy board") { model.board.tidy() }
				.keyboardShortcut("t", modifiers: [.command, .shift])
				.disabled(model.board.isTidy)
			Divider()
			Button(model.window.drawerOpen ? "Hide model drawer" : "Show model drawer") {
				model.window.drawerOpen.toggle()
			}
			.keyboardShortcut("j", modifiers: .command)
			Divider()
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	/// One supervisor for the life of the app, so the delegate can stop a
	/// host the app started when the app quits.
	static let supervisor = LiveHostSupervisor()

	static var isUnderTest: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}

	func applicationWillTerminate(_ notification: Notification) {
		Self.supervisor.stopNow()
	}
}
