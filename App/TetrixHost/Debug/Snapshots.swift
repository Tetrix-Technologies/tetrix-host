#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Work a debug build does from the command line and then exits:
///
///     "Tetrix Host" --snapshot <dir>      render the window from fixture data
///     "Tetrix Host" --render-icon <dir>   render the app icon
///
/// A debug build also takes `--show download`, `--show pairing`, or
/// `--show chat` to open the real window with that part showing. See
/// `DebugLaunch`.
enum DebugTask {
	case snapshot(URL)
	case icon(URL)

	init?(arguments: [String]) {
		func directory(after flag: String) -> URL? {
			guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
			return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
		}
		if let directory = directory(after: "--snapshot") {
			self = .snapshot(directory)
		} else if let directory = directory(after: "--render-icon") {
			self = .icon(directory)
		} else {
			return nil
		}
	}

	@MainActor
	func run() {
		// Rendering needs AppKit loaded, but no window and no Dock icon.
		NSApplication.shared.setActivationPolicy(.prohibited)
		do {
			switch self {
			case .snapshot(let directory):
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				for scene in SnapshotScene.all {
					let url = directory.appending(path: scene.name + ".png")
					try Renderer.write(scene.view(), width: scene.size.width, height: scene.size.height, scale: 2, to: url)
					print("Wrote \(url.path)")
				}
			case .icon(let directory):
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
				let url = directory.appending(path: "icon-1024.png")
				try Renderer.write(IconMark(), width: IconMark.side, height: IconMark.side, scale: 1, to: url)
				print("Wrote \(url.path)")
			}
		} catch {
			FileHandle.standardError.write(Data("Could not render: \(error)\n".utf8))
			exit(1)
		}
		exit(0)
	}
}

/// Opens the real window with one part already showing, so a person or a
/// script can look at a sheet without clicking through to it.
enum DebugLaunch {
	@MainActor
	static func apply(_ arguments: [String], to window: WindowState) {
		guard let index = arguments.firstIndex(of: "--show"), arguments.indices.contains(index + 1) else { return }
		switch arguments[index + 1] {
		case "download": window.sheet = .download
		case "pairing": window.sheet = .pairing
		case "chat": window.drawerOpen = true
		default: break
		}
	}
}

@MainActor
private enum Renderer {
	struct Failure: Error {}

	/// A nil height lets the view take the height it asks for.
	static func write(_ view: some View, width: CGFloat, height: CGFloat?, scale: CGFloat, to url: URL) throws {
		let renderer = ImageRenderer(content: view.frame(width: width, height: height))
		renderer.proposedSize = ProposedViewSize(width: width, height: height)
		renderer.scale = scale
		renderer.isOpaque = false
		guard let image = renderer.cgImage else { throw Failure() }
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure() }
		CGImageDestinationAddImage(destination, image, nil)
		guard CGImageDestinationFinalize(destination) else { throw Failure() }
	}
}

// MARK: - Scenes

/// One picture of the window in one state.
@MainActor
struct SnapshotScene {
	static let windowSize = CGSize(width: 1280, height: 800)

	/// What the picture shows.
	enum Subject {
		/// The whole window.
		case window
		/// The inspector alone, as tall as its content, which shows the
		/// part a person would scroll to.
		case inspector
	}

	var name: String
	var subject: Subject = .window
	var scheme: ColorScheme = .light
	var phase: HostStore.Phase = .running
	var status: HostStatus? = .fixture()
	var sheet: WindowState.Sheet?
	var prepare: (AppModel) -> Void = { _ in }

	func view() -> some View {
		let service = FixtureHostService(status: status ?? .fixture())
		let supervisor = FixtureHostSupervisor(service: service, running: status != nil, owns: status != nil)
		let model = AppModel(
			store: HostStore(supervisor: supervisor, phase: phase, status: status),
			board: BoardState(defaults: nil)
		)
		model.window.inspectorVisible = false
		prepare(model)
		return content(model)
			.environment(\.renderMode, .snapshot)
			.environment(\.fixedNow, Fixture.now)
			.environment(\.colorScheme, scheme)
	}

	var size: (width: CGFloat, height: CGFloat?) {
		switch subject {
		case .window: (Self.windowSize.width, Self.windowSize.height)
		case .inspector: (Metrics.inspectorWidth, nil)
		}
	}

	@ViewBuilder
	private func content(_ model: AppModel) -> some View {
		switch subject {
		case .window:
			SnapshotWindow(model: model, sheet: sheet)
		case .inspector:
			InspectorView()
				.fixedSize(horizontal: false, vertical: true)
				.appModel(model)
		}
	}

	static var all: [SnapshotScene] {
		[
			SnapshotScene(name: "board-light"),
			SnapshotScene(name: "board-dark", scheme: .dark),
			SnapshotScene(name: "board-inspector-light") { $0.window.inspectorVisible = true },
			SnapshotScene(name: "board-inspector-dark", scheme: .dark) { $0.window.inspectorVisible = true },
			SnapshotScene(name: "pairing-light", sheet: .pairing, prepare: offerCode),
			SnapshotScene(name: "pairing-dark", scheme: .dark, sheet: .pairing, prepare: offerCode),
			SnapshotScene(name: "paired-light", sheet: .pairing) { model in
				if let device = model.store.status?.devices.first {
					model.store.setPairingForSnapshot(.paired(device))
				}
			},
			SnapshotScene(name: "download-light", sheet: .download),
			SnapshotScene(name: "download-dark", scheme: .dark, sheet: .download),
			SnapshotScene(name: "download-progress-light", sheet: .download, prepare: startDownload),
			SnapshotScene(name: "download-progress-dark", scheme: .dark, sheet: .download, prepare: startDownload),
			SnapshotScene(name: "stopped-light", phase: .stopped, status: nil),
			SnapshotScene(name: "chat-light", prepare: openChat),
			SnapshotScene(name: "chat-dark", scheme: .dark, prepare: openChat),
			SnapshotScene(name: "inspector-host-light", subject: .inspector),
			SnapshotScene(name: "inspector-host-dark", subject: .inspector, scheme: .dark),
			SnapshotScene(name: "inspector-device-light") { model in
				model.window.inspect(.device(Fixture.laptopID))
			},
			SnapshotScene(name: "inspector-model-light") { model in
				model.window.inspect(.model(.deep))
			},
			SnapshotScene(name: "inspector-machine-light") { model in
				model.window.inspect(.machine)
			},
			SnapshotScene(name: "no-server-light", status: Self.noServer) { $0.window.inspectorVisible = true },
			SnapshotScene(name: "tunnel-off-light", status: Self.tunnelOff),
			SnapshotScene(name: "tunnel-off-dark", scheme: .dark, status: Self.tunnelOff),
			SnapshotScene(name: "busy-light", status: Self.busy),
			SnapshotScene(name: "problem-light", status: Self.problem),
			SnapshotScene(name: "problem-dark", scheme: .dark, status: Self.problem),
			SnapshotScene(name: "eight-devices-light", status: Self.eightDevices),
			SnapshotScene(name: "eight-devices-dark", scheme: .dark, status: Self.eightDevices),
		]
	}

	private static func offerCode(_ model: AppModel) {
		var offer = PairingOffer()
		offer.code = "AEBY-IKII-H6DH-P4HT-7HNG-3B6D-6SEQ-HX52-YBSE-C4JY-HAMA"
		offer.link = "tetrix-host://pair/\(offer.code)?relay=wss%3A%2F%2Frelay.tetrix.tech"
		offer.expiresAt = Fixture.now.addingTimeInterval(9 * 60 + 41)
		model.store.setPairingForSnapshot(.offered(offer))
	}

	private static func startDownload(_ model: AppModel) {
		var pull = PullProgress()
		pull.engine = "ollama"
		pull.name = "qwen3:14b"
		pull.status = "Downloading"
		pull.completed = 3_100_000_000
		pull.total = 9_300_000_000
		model.store.setPullForSnapshot(pull)
	}

	private static func openChat(_ model: AppModel) {
		model.window.drawerOpen = true
		model.chat.setMessagesForSnapshot([
			ChatSession.Message(speaker: .person, text: "Why does a host on my own machine keep my work private?"),
			ChatSession.Message(
				speaker: .model,
				text: "Your prompt travels from the app to this machine through a sealed tunnel, and the model that reads it runs here. The relay in the middle passes sealed bytes and cannot read them. The work happens on hardware you own.",
				reasoning: "The person asks about privacy. Name the path the words take and who can read them at each step.",
				role: .deep,
				speed: 42.3
			),
		])
	}

	/// A host whose model server does not answer, so it has no models.
	private static var noServer: HostStatus {
		var status = HostStatus.fixture()
		status.engines[0].state = "unreachable"
		status.engines[0].error = "The connection was refused."
		status.engines[0].models = []
		status.roles = Roles()
		status.devices = []
		status.stats = Stats()
		return status
	}

	private static var tunnelOff: HostStatus {
		var status = HostStatus.fixture()
		status.tunnel.enabled = false
		status.tunnel.state = .disabled
		status.tunnel.since = nil
		status.devices[0].online = false
		status.devices[0].lastSeenAt = Fixture.now.addingTimeInterval(-25 * 60)
		return status
	}

	/// A host in the middle of a request from the laptop, with one model
	/// for everything.
	private static var busy: HostStatus {
		var status = HostStatus.fixture()
		status.roles.quick = ""
		status.roles.single = true
		status.stats.active = 1
		status.stats.running = [RunningRequest(id: "r148", deviceId: Fixture.laptopID, role: .deep)]
		return status
	}

	/// A host with two things wrong at once: the tunnel is offline, and the
	/// model server does not answer, so the roles name models nobody lists.
	private static var problem: HostStatus {
		var status = HostStatus.fixture()
		status.tunnel.state = .offline
		status.tunnel.since = nil
		status.tunnel.lastError = "The relay did not answer."
		status.engines[0].state = "unreachable"
		status.engines[0].error = "The connection was refused."
		status.engines[0].models = []
		status.devices[0].online = false
		status.devices[0].lastSeenAt = Fixture.now.addingTimeInterval(-25 * 60)
		return status
	}

	/// A host with eight paired devices, which is more than the window is
	/// tall.
	private static var eightDevices: HostStatus {
		var status = HostStatus.fixture()
		let more: [(id: String, name: String, platform: String, online: Bool, seen: TimeInterval, requests: Int64)] = [
			("d_kitchen", "Kitchen iPad", "iPadOS", true, 20, 62),
			("d_studio", "Studio Mac", "macOS", true, 5, 311),
			("d_vision", "Noah's Vision Pro", "visionOS", false, 2 * 86_400, 9),
			("d_office", "Office Mac mini", "macOS", false, 26 * 60, 47),
			("d_sam", "Sam's iPhone", "iOS", true, 12, 28),
			("d_workshop", "Workshop PC", "Linux", false, 5 * 3_600, 3),
		]
		for entry in more {
			var device = Device()
			device.id = entry.id
			device.name = entry.name
			device.app = "Cue"
			device.appVersion = "2.4.0"
			device.platform = entry.platform
			device.pairedAt = Fixture.now.addingTimeInterval(-9 * 86_400)
			device.lastSeenAt = Fixture.now.addingTimeInterval(-entry.seen)
			device.online = entry.online
			device.requests = entry.requests
			status.devices.append(device)
		}
		return status
	}
}

/// The window as one view: a drawing of the toolbar, the content, the
/// inspector column, and a sheet over a scrim.
private struct SnapshotWindow: View {
	var model: AppModel
	var sheet: WindowState.Sheet?

	var body: some View {
		HStack(spacing: 0) {
			VStack(spacing: 0) {
				ToolbarReplica(part: .main)
				MainView()
			}
			if model.window.inspectorVisible {
				Hairline(vertical: true)
				VStack(spacing: 0) {
					ToolbarReplica(part: .inspector)
					InspectorView()
				}
				.frame(width: Metrics.inspectorWidth)
			}
		}
		.background(Palette.paper)
		.overlay {
			if let sheet {
				ZStack {
					// The system dims the window under a sheet in both
					// appearances, so the scrim is dark in both.
					Rectangle().fill(Palette.ink.color(scheme: .light).opacity(Metrics.scrimOpacity))
					Group {
						switch sheet {
						case .pairing: PairingSheet {}
						case .download: DownloadSheet {}
						}
					}
					.clipShape(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
					.overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
				}
			}
		}
		.appModel(model)
	}
}

// MARK: - Icon

/// The app's mark: a rounded slab in ink on paper, a machine seen from the
/// front, with its light on. The light is a hole in the slab, so it takes
/// the color of whatever the mark sits on.
///
/// The mark's own drawing is `assets/tetrix-host-mark.svg`, 180 by 80
/// units: corners of 28, and a light 24 across whose center is 44 from the
/// right edge. The sizes below are those figures scaled to a slab 536 wide,
/// about two thirds of the plate.
struct IconMark: View {
	static let side: CGFloat = 1024
	/// The icon grid for the Mac: an 824 point plate in a 1024 canvas.
	private static let plate: CGFloat = 824
	private static let plateRadius: CGFloat = 185
	private static let plateBorder: CGFloat = 3
	private static let slabWidth: CGFloat = 536
	private static let slabHeight: CGFloat = 238
	private static let slabRadius: CGFloat = 83
	private static let light: CGFloat = 71
	private static let lightInset: CGFloat = 95

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: Self.plateRadius, style: .continuous)
				.fill(Palette.paper.color(scheme: .light))
			RoundedRectangle(cornerRadius: Self.plateRadius, style: .continuous)
				.strokeBorder(Palette.ruleStrong.color(scheme: .light), lineWidth: Self.plateBorder)
			RoundedRectangle(cornerRadius: Self.slabRadius, style: .continuous)
				.fill(Palette.ink.color(scheme: .light))
				.frame(width: Self.slabWidth, height: Self.slabHeight)
				.overlay(alignment: .trailing) {
					// The light shows the plate through the slab.
					Circle()
						.fill(Palette.paper.color(scheme: .light))
						.frame(width: Self.light, height: Self.light)
						.padding(.trailing, Self.lightInset)
				}
		}
		.frame(width: Self.plate, height: Self.plate)
		.frame(width: Self.side, height: Self.side)
	}
}
#endif
