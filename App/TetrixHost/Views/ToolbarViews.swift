import SwiftUI

// MARK: - Role menu

/// The items that assign a model to each kind of work. The toolbar menu and
/// the Host menu share them.
struct RoleMenuItems: View {
	var status: HostStatus
	/// The Host menu has its own "Download a model", so it leaves this one out.
	var showsDownload = true
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		let models = status.models
		if models.isEmpty {
			Text("No models yet")
		} else {
			ForEach(Role.allCases) { role in
				Section(role.title) {
					ForEach(models) { model in
						Toggle(isOn: Binding(
							get: { status.roles.modelID(for: role) == model.id },
							set: { on in
								guard on else { return }
								Task { await store.setModel(model.id, for: role) }
							}
						)) {
							Text(model.name)
						}
					}
				}
			}
			Divider()
			Toggle("One model for everything", isOn: Binding(
				get: { status.roles.usesOneModel },
				set: { single in Task { await store.setSingle(single) } }
			))
			.disabled(status.roles.deep.isEmpty || (status.roles.single && models.count < 2))
		}
		if showsDownload {
			Divider()
			Button("Download a model") { window.sheet = .download }
		}
	}
}

/// The actions for one model, for its card's menu.
struct ModelActions: View {
	var model: Model
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		Button("Use for deep work") { Task { await store.setModel(model.id, for: .deep) } }
		Button("Use for quick work") { Task { await store.setModel(model.id, for: .quick) } }
		Divider()
		Button("Delete…", role: .destructive) { window.modelToDelete = model }
	}
}

// MARK: - Principal items

/// The menu that assigns a model to each kind of work. Its label says what
/// is assigned now.
struct RoleMenu: View {
	var status: HostStatus

	var body: some View {
		Menu {
			RoleMenuItems(status: status)
		} label: {
			RoleSummary(status: status)
		}
		.accessibilityLabel("Models. \(RoleSummary.spoken(status))")
		.help("Choose the model for each kind of work")
	}
}

/// The roles in short form: "Deep qwen3:8b · Quick gemma3:4b", or
/// "qwen3:8b for everything".
struct RoleSummary: View {
	var status: HostStatus

	private func name(_ role: Role) -> String {
		let id = status.roles.modelID(for: role)
		return status.model(id: id)?.name ?? Format.modelName(fromID: id)
	}

	var body: some View {
		Group {
			if status.roles.deep.isEmpty {
				Text(status.models.isEmpty ? "No model" : "Choose a model")
			} else if status.roles.single {
				Text("\(Text(name(.deep)).font(Typography.mono(.callout))) for everything")
			} else {
				Text("Deep \(Text(name(.deep)).font(Typography.mono(.callout)))  ·  Quick \(Text(name(.quick)).font(Typography.mono(.callout)))")
			}
		}
		.font(Typography.control)
		.lineLimit(1)
	}

	static func spoken(_ status: HostStatus) -> String {
		let roles = status.roles
		if roles.deep.isEmpty { return "No model is assigned." }
		let deep = status.model(id: roles.deep)?.name ?? Format.modelName(fromID: roles.deep)
		if roles.single { return "\(deep) for everything." }
		let quick = status.model(id: roles.quick)?.name ?? Format.modelName(fromID: roles.quick)
		return "Deep work uses \(deep). Quick work uses \(quick)."
	}
}

/// The host's health as a dot, beside its local address, or beside a word
/// for its state while it does not run. The dot never stands alone.
struct HostStatusLabel: View {
	@Environment(HostStore.self) private var store

	private var stoppedLabel: String {
		switch store.phase {
		case .starting: "Starting"
		case .connecting: "Looking for the host"
		default: "Stopped"
		}
	}

	var body: some View {
		if let status = store.status {
			HStack(spacing: Space.s) {
				StatusDot(tone: status.health)
				Text(status.host.address)
					.font(Typography.mono(.callout))
					.lineLimit(1)
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("Host at \(status.host.address)")
			.accessibilityValue(status.healthSummary)
			.help(status.healthSummary)
		} else {
			HStack(spacing: Space.s) {
				StatusDot(tone: store.phase == .starting ? .waiting : .off)
				Text(stoppedLabel)
					.font(Typography.control)
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel("Host")
			.accessibilityValue(stoppedLabel)
		}
	}
}

extension HostIdentity {
	/// What "Copy address" puts on the pasteboard: the endpoint an app
	/// takes, or the bare address when the host sent no endpoint.
	var copyableAddress: String { endpoint.isEmpty ? address : endpoint }
}

/// Starts the host, or stops a host the app started.
struct RunButton: View {
	@Environment(HostStore.self) private var store
	@Environment(\.renderMode) private var renderMode

	static let backgroundHelp = "The host runs in the background. This app did not start it, so it cannot stop it."

	private var isBusy: Bool { store.phase == .starting || store.phase == .stopping }

	var body: some View {
		Button {
			Task { await store.toggleRunning() }
		} label: {
			Label {
				Text(store.showsStop ? "Stop host" : "Start host")
			} icon: {
				if isBusy, renderMode == .live {
					ProgressView()
						.controlSize(.small)
				} else {
					Image(systemName: store.showsStop ? "stop.fill" : "play.fill")
				}
			}
		}
		.disabled(!store.canToggleRunning)
		.accessibilityHint(store.showsStop && !store.ownsHost ? Self.backgroundHelp : "")
		.help(help)
	}

	private var help: String {
		switch store.phase {
		case .running: store.ownsHost ? "Stop the host" : Self.backgroundHelp
		case .stopped: "Start the host"
		case .starting: "The host is starting"
		case .stopping: "The host is stopping"
		case .connecting: "Looking for the host"
		}
	}
}

// MARK: - Trailing items

/// A ring in the toolbar while a download runs. It opens the download sheet.
struct DownloadRingButton: View {
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		if let fraction = store.pullFraction {
			Button {
				window.sheet = .download
			} label: {
				ProgressRing(fraction: fraction)
					.padding(Space.xs)
			}
			.accessibilityLabel("Downloading, \(Format.percent(fraction))")
			.help("Show the download")
		}
	}
}

/// "Pair a device", in the trailing part of the toolbar.
struct PairButton: View {
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		Button {
			window.sheet = .pairing
		} label: {
			Label("Pair a device", systemImage: "qrcode")
				.labelStyle(.titleAndIcon)
		}
		.disabled(store.status == nil)
		.help("Pair a device with this host")
	}
}

struct InspectorToggle: View {
	@Environment(WindowState.self) private var window

	var body: some View {
		Button {
			window.inspectorVisible.toggle()
		} label: {
			Label(window.inspectorVisible ? "Hide inspector" : "Show inspector", systemImage: "sidebar.trailing")
		}
		.help(window.inspectorVisible ? "Hide inspector" : "Show inspector")
	}
}

// MARK: - Snapshot replica

#if DEBUG
/// A drawing of the window's toolbar, for snapshots. The window's own
/// toolbar belongs to AppKit and cannot render offscreen. This row holds the
/// same items in the same places, on a flat stand-in for the system's glass.
struct ToolbarReplica: View {
	/// The inspector column draws its own part, as the window's toolbar does.
	enum Part {
		case main, inspector
	}

	var part: Part
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		ZStack {
			if part == .main {
				principal
			}
			HStack(spacing: Space.s) {
				if part == .main {
					HStack(spacing: Space.s) {
						ForEach(0..<3, id: \.self) { _ in
							Circle()
								.fill(Palette.ruleStrong)
								.frame(width: Metrics.windowControl, height: Metrics.windowControl)
						}
					}
					.padding(.leading, Space.xs)
				}
				Spacer()
				if part == .main {
					if store.pullFraction != nil {
						DownloadRingButton()
							.buttonStyle(.plain)
							.padding(.horizontal, Space.xs)
							.frame(height: Metrics.toolbarControlHeight)
							.navigationSurface(in: Capsule())
					}
					replica { PairButton() }
				}
				if part == .inspector || !window.inspectorVisible {
					replica { InspectorToggle().labelStyle(.iconOnly) }
				}
			}
		}
		.padding(.horizontal, Space.m)
		.frame(height: Metrics.toolbarHeight)
		.background(Palette.paper)
	}

	/// The principal group: one shared background, as the system draws it.
	private var principal: some View {
		HStack(spacing: Space.m) {
			if let status = store.status {
				HStack(spacing: Space.xs) {
					RoleSummary(status: status)
					Image(systemName: "chevron.down")
						.font(Typography.caption.weight(.semibold))
						.foregroundStyle(Palette.inkSoft)
				}
			}
			HostStatusLabel()
			if store.status != nil {
				Image(systemName: "doc.on.doc")
			}
			RunButton()
				.buttonStyle(.plain)
				.labelStyle(.iconOnly)
		}
		.font(Typography.control)
		.foregroundStyle(Palette.ink)
		.padding(.horizontal, Space.m)
		.frame(height: Metrics.toolbarControlHeight)
		.navigationSurface(in: Capsule())
	}

	private func replica(@ViewBuilder _ content: () -> some View) -> some View {
		content()
			.buttonStyle(.plain)
			.font(Typography.control)
			.foregroundStyle(Palette.ink)
			.padding(.horizontal, Space.m)
			.frame(height: Metrics.toolbarControlHeight)
			.navigationSurface(in: Capsule())
	}
}

private extension View {
	/// A flat stand-in for the glass the system puts behind toolbar items.
	func navigationSurface(in shape: some Shape) -> some View {
		background(Palette.paperRaised, in: shape)
			.overlay(shape.stroke(Palette.rule, lineWidth: Stroke.hairline))
	}
}
#endif
