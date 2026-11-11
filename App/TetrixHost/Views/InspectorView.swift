import SwiftUI

/// The panel on the right. With nothing selected it shows the host. With a
/// card selected it shows that card's details and actions.
struct InspectorView: View {
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		ScrollArea {
			VStack(alignment: .leading, spacing: 0) {
				if let status = store.status {
					content(status)
				} else {
					InspectorSection("Host") {
						LabeledRow(label: "Status") {
							DotValue(tone: store.phase == .starting ? .waiting : .off, text: store.phase == .starting ? "Starting" : "Stopped")
						}
					}
				}
			}
			.padding(.vertical, Space.s)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.background(Palette.paper)
	}

	@ViewBuilder
	private func content(_ status: HostStatus) -> some View {
		let card = window.selection.flatMap { BoardLayout.scene(for: status).card($0) }
		switch card?.kind {
		case .device(let id):
			if let device = status.device(id: id) {
				DeviceInspector(device: device, tunnelOff: !status.tunnel.enabled)
			} else {
				HostInspector(status: status)
			}
		case .model(let slot, let modelID):
			ModelInspector(slot: slot, modelID: modelID, model: status.model(id: modelID), status: status)
		case .machine:
			MachineInspector(status: status)
		case .tunnel:
			InspectorSection("Tunnel") {
				TunnelRows(status: status)
			}
		default:
			HostInspector(status: status)
		}
	}
}

// MARK: - Building blocks

/// A group of rows, closed by a hairline. A group whose one button already
/// says what it is for takes no title.
struct InspectorSection<Content: View>: View {
	var title: String?
	@ViewBuilder var content: Content

	init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
		self.title = title
		self.content = content()
	}

	var body: some View {
		VStack(alignment: .leading, spacing: Space.s) {
			if let title {
				Text(title)
					.font(Typography.section)
					.foregroundStyle(Palette.ink)
					.lineLimit(2)
					.accessibilityAddTraits(.isHeader)
			}
			content
		}
		.padding(.horizontal, Space.m)
		.padding(.top, Space.m)
		.padding(.bottom, Space.s)
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay(alignment: .bottom) {
			Hairline().padding(.horizontal, Space.m)
		}
	}
}

/// A text field that holds a setting. It shows the host's value until a
/// person types. It saves on Return and when it loses focus, if the text
/// changed and can be saved, and says "Saved" for a moment. Text that
/// cannot be saved goes back to the host's value, and the field says why.
struct SettingField: View {
	var title: String
	var value: String
	var mono = false
	/// Why a text cannot be saved, or nil when it can.
	var problem: (String) -> String? = { _ in nil }
	/// Sends the text to the host. Returns true when the host took it.
	var save: (String) async -> Bool

	@State private var draft = ""
	@State private var edited = false
	/// The text just saved, shown until the host's own value catches up.
	@State private var pending: String?
	@State private var saved = false
	@State private var complaint: String?

	/// The check every name shares.
	static func nameProblem(_ name: String) -> String? {
		name.isEmpty ? "A name cannot be empty." : nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: Space.xs) {
			HStack(alignment: .firstTextBaseline, spacing: Space.s) {
				Text(title)
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
				Spacer(minLength: Space.s)
				if saved {
					Text("Saved")
						.font(Typography.row)
						.foregroundStyle(Palette.inkMuted)
				}
			}
			FieldBox(
				title: title,
				text: Binding(
					get: { edited ? draft : (pending ?? value) },
					set: { text in
						draft = text
						edited = true
						complaint = nil
					}
				),
				mono: mono,
				onSubmit: commit,
				onBlur: commit
			)
			if let complaint {
				Text(complaint)
					.font(Typography.caption)
					.foregroundStyle(Palette.rust)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.onChange(of: value) {
			edited = false
			pending = nil
		}
	}

	private func commit() {
		guard edited else { return }
		edited = false
		let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard text != value else { return }
		if let reason = problem(text) {
			complaint = reason
			Announcer.post(reason)
			return
		}
		pending = text
		Task {
			if await save(text) {
				saved = true
				Announcer.post("Saved")
				try? await Task.sleep(for: Motion.confirmation)
				saved = false
			}
			// By now the host's value has arrived, or the save failed and
			// the store has said why. Either way the field shows the host.
			pending = nil
		}
	}
}

/// A row that picks one installed model from a pop-up menu.
struct ModelPicker: View {
	var title: String
	var selection: String
	var models: [Model]
	var choose: (String) -> Void

	/// The installed models. A role with no model, or with one the model
	/// server no longer lists, gets a row of its own, so the menu can show
	/// what is chosen.
	static func options(models: [Model], selection: String) -> [MenuChoice.Option] {
		var options = models.map { MenuChoice.Option(id: $0.id, title: $0.name) }
		if !models.contains(where: { $0.id == selection }) {
			options.insert(MenuChoice.Option(id: selection, title: selection.isEmpty ? "None" : Format.modelName(fromID: selection)), at: 0)
		}
		return options
	}

	var body: some View {
		HStack(spacing: Space.s) {
			Text(title)
				.font(Typography.row)
				.foregroundStyle(Palette.inkMuted)
				.lineLimit(1)
			Spacer(minLength: Space.s)
			MenuChoice(title: title, options: Self.options(models: models, selection: selection), selection: selection, choose: choose)
				.disabled(models.isEmpty)
		}
	}
}

// MARK: - Host

struct HostInspector: View {
	var status: HostStatus
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	private static let recentShown = 6

	var body: some View {
		InspectorSection("Host") {
			LabeledRow(label: "Status") {
				DotValue(tone: .healthy, text: "Running")
			}
			NowReader(every: 30) { now in
				LabeledRow("Running for", Format.uptime(from: status.host.startedAt, to: now))
			}
			LabeledRow(label: "Address", holdsControl: true) {
				HStack(spacing: Space.s) {
					Text(status.host.address)
						.font(Typography.mono(.callout))
					CopyButton(text: status.host.copyableAddress, label: "Copy address", showsTitle: true)
						.buttonStyle(LinkButtonStyle())
				}
			}
			SettingField(title: "Name", value: status.host.name, problem: SettingField.nameProblem) { name in
				await store.renameHost(name)
			}
		}

		InspectorSection("Tunnel") {
			TunnelRows(status: status)
		}

		InspectorSection("Models") {
			ModelPicker(title: Role.deep.title, selection: status.roles.deep, models: status.models) { id in
				Task { await store.setModel(id, for: .deep) }
			}
			ModelPicker(title: Role.quick.title, selection: status.roles.modelID(for: .quick), models: status.models) { id in
				Task { await store.setModel(id, for: .quick) }
			}
			SwitchRow(title: "One model for everything", isOn: Binding(
				get: { status.roles.usesOneModel },
				set: { single in Task { await store.setSingle(single) } }
			))
			.disabled(status.roles.deep.isEmpty || (status.roles.single && status.models.count < 2))
			Button("Download a model") { window.sheet = .download }
				.systemButton(.bordered)
		}

		InspectorSection("Activity") {
			LabeledRow("Requests", Format.count(status.stats.requests))
			LabeledRow("Tokens out", Format.count(status.stats.tokensOut))
			LabeledRow("Speed", Format.speed(status.stats.tokensPerSecond).isEmpty ? "None yet" : Format.speed(status.stats.tokensPerSecond))
			LabeledRow("In progress", Format.count(status.stats.active))
		}

		InspectorSection("Recent") {
			if status.stats.recent.isEmpty {
				Text("No requests yet.")
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
			} else {
				VStack(spacing: Space.s) {
					ForEach(status.stats.recent.prefix(Self.recentShown)) { record in
						RecentRow(record: record, deviceName: status.device(id: record.deviceId)?.name)
					}
				}
			}
		}
	}
}

/// One finished request: when, who, which kind of work, how much, how long.
struct RecentRow: View {
	var record: RequestRecord
	var deviceName: String?

	/// Who sent a request: this machine, a paired device by name, or a
	/// device that has been unpaired since.
	static func source(of record: RequestRecord, deviceName: String?) -> String {
		if record.deviceId == nil { return "This machine" }
		return deviceName ?? "Unpaired device"
	}

	private var detail: String {
		var parts: [String] = []
		if let role = record.role { parts.append(role.shortTitle) }
		parts.append(Format.tokens(record.tokensOut))
		parts.append(Format.duration(milliseconds: record.durationMs))
		if record.status == 499 {
			parts.append("Cancelled")
		} else if record.status >= 400 {
			parts.append("Failed")
		}
		return parts.joined(separator: " · ")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(alignment: .firstTextBaseline, spacing: Space.s) {
				Text(Self.source(of: record, deviceName: deviceName))
					.font(Typography.row)
					.foregroundStyle(Palette.ink)
					.lineLimit(1)
				Spacer(minLength: Space.s)
				Text(Format.clock(record.at))
					.font(Typography.caption)
					.monospacedDigit()
					.foregroundStyle(Palette.inkMuted)
			}
			Text(detail)
				.font(Typography.caption)
				.foregroundStyle(record.status >= 400 && record.status != 499 ? Palette.rust : Palette.inkMuted)
				.lineLimit(1)
		}
		.accessibilityElement(children: .combine)
	}
}

struct TunnelRows: View {
	var status: HostStatus
	@Environment(HostStore.self) private var store

	var body: some View {
		let tunnel = status.tunnel
		LabeledRow(label: "State") {
			DotValue(tone: tunnel.tone, text: Format.tunnelState(tunnel))
		}
		if tunnel.enabled, tunnel.state == .offline, let error = tunnel.lastError, !error.isEmpty {
			Text(error)
				.font(Typography.caption)
				.foregroundStyle(Palette.rust)
				.fixedSize(horizontal: false, vertical: true)
		}
		SettingField(title: "Relay", value: tunnel.relay, mono: true, problem: Format.relayProblem) { relay in
			await store.setRelay(relay)
		}
		LabeledRow("Host ID", status.host.id, mono: true)
		SwitchRow(title: "Use the tunnel", isOn: Binding(
			get: { tunnel.enabled },
			set: { enabled in Task { await store.setTunnelEnabled(enabled) } }
		))
		Text("Sealed from end to end. The relay cannot read what passes.")
			.font(Typography.caption)
			.foregroundStyle(Palette.inkMuted)
			.fixedSize(horizontal: false, vertical: true)
	}
}

// MARK: - Device

struct DeviceInspector: View {
	var device: Device
	/// True while the tunnel is off, when no device can reach the host.
	var tunnelOff = false
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		InspectorSection(device.name) {
			SettingField(title: "Name", value: device.name, problem: SettingField.nameProblem) { name in
				await store.renameDevice(id: device.id, to: name)
			}
			LabeledRow("App", Format.app(device))
			LabeledRow("Platform", device.platform ?? "Unknown")
			NowReader(every: 30) { now in
				LabeledRow(label: "State") {
					DotValue(
						tone: DeviceCard.tone(for: device, tunnelOff: tunnelOff),
						text: Format.deviceState(device, now: now, tunnelOff: tunnelOff),
						spoken: Format.deviceState(device, now: now, tunnelOff: tunnelOff, spoken: true)
					)
				}
			}
			LabeledRow("Paired", Format.day(device.pairedAt))
			LabeledRow("Device ID", device.id, mono: true)
		}

		InspectorSection("Activity") {
			LabeledRow("Requests", Format.count(device.requests))
			LabeledRow("Tokens in", Format.count(device.tokensIn))
			LabeledRow("Tokens out", Format.count(device.tokensOut))
		}

		InspectorSection {
			Text("An unpaired device can no longer use this host.")
				.font(Typography.row)
				.foregroundStyle(Palette.inkMuted)
				.fixedSize(horizontal: false, vertical: true)
			Button("Unpair", role: .destructive) { window.deviceToUnpair = device }
				.systemButton(.destructive)
		}
	}
}

// MARK: - Model

struct ModelInspector: View {
	var slot: ModelSlot
	var modelID: String
	var model: Model?
	var status: HostStatus
	@Environment(HostStore.self) private var store
	@Environment(WindowState.self) private var window

	var body: some View {
		InspectorSection(slot.title) {
			LabeledRow("Model", model?.name ?? Format.modelName(fromID: modelID), mono: true)
			if let model {
				LabeledRow("Size", model.sizeBytes.map(Format.storage) ?? "Unknown")
				if let family = model.family, !family.isEmpty { LabeledRow("Family", family, mono: true) }
				if let parameters = model.parameters, !parameters.isEmpty { LabeledRow("Parameters", parameters) }
				if let quantization = model.quantization, !quantization.isEmpty { LabeledRow("Quantization", quantization, mono: true) }
				LabeledRow("Context", Format.window(supported: model.contextLength, inUse: model.contextInUse))
				if model.windowIsCut(asked: status.roles.askedWindow(for: slot)) {
					Text("The model server runs this model with less context than this host asked for. A longer request is cut short without an error. Check the model server.")
						.font(Typography.caption)
						.foregroundStyle(Palette.inkSoft)
						.fixedSize(horizontal: false, vertical: true)
				}
				LabeledRow("Can", Format.capabilities(model.capabilities))
				LabeledRow(label: "State") {
					DotValue(tone: model.loaded ? .healthy : .off, text: model.loaded ? "In memory" : "On disk")
				}
				LabeledRow("Model server", model.engine, mono: true)
			} else {
				LabeledRow(label: "State") {
					DotValue(tone: .waiting, text: "Not available")
				}
			}
		}

		if let model {
			let served = status.roles(servedBy: model.id)
			InspectorSection("Use") {
				ForEach(Role.allCases) { role in
					RoleUse(role: role, isUsed: served.contains(role)) {
						Task { await store.setModel(model.id, for: role) }
					}
				}
			}

			InspectorSection {
				Text("The host removes the model from this machine. You can download it again.")
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
					.fixedSize(horizontal: false, vertical: true)
				Button("Delete", role: .destructive) { window.modelToDelete = model }
					.systemButton(.destructive)
			}
		}
	}
}

/// One kind of work a model can take. A model that has the work already
/// says so with a check. One that does not offers a button.
private struct RoleUse: View {
	var role: Role
	var isUsed: Bool
	var use: () -> Void

	var body: some View {
		if isUsed {
			HStack(spacing: Space.s) {
				Image(systemName: "checkmark")
					.font(Typography.control)
					.foregroundStyle(Palette.inkSoft)
					.accessibilityHidden(true)
				Text("Used for \(role.title.lowercased())")
					.font(Typography.row)
					.foregroundStyle(Palette.ink)
			}
			.frame(minHeight: Metrics.minimumTarget)
			.accessibilityElement(children: .combine)
		} else {
			Button("Use for \(role.title.lowercased())", action: use)
				.systemButton(.bordered)
		}
	}
}

// MARK: - Machine

struct MachineInspector: View {
	var status: HostStatus

	var body: some View {
		let hardware = status.hardware
		InspectorSection("This machine") {
			LabeledRow("Model", hardware.model)
			LabeledRow("Chip", hardware.chip)
			if hardware.cores > 0 { LabeledRow("Cores", Format.count(hardware.cores)) }
			LabeledRow("Memory", Format.memory(hardware.memoryBytes))
			LabeledRow("Disk", Format.storage(hardware.diskBytes))
			LabeledRow("Free space", Format.storage(hardware.diskFreeBytes))
			if !hardware.os.isEmpty { LabeledRow("System", hardware.os) }
			if !hardware.arch.isEmpty { LabeledRow("Architecture", hardware.arch, mono: true) }
			ForEach(Array(hardware.gpus.enumerated()), id: \.offset) { _, gpu in
				LabeledRow("Graphics", gpu.memoryBytes > 0 ? "\(gpu.name), \(Format.memory(gpu.memoryBytes))" : gpu.name)
			}
		}

		// The inspector sits on paper, so its meters take a linen track.
		InspectorSection("Now") {
			LabeledRow("Memory in use", Format.memory(status.load.memoryUsedBytes))
			MeterBar(fraction: hardware.memoryBytes > 0 ? Double(status.load.memoryUsedBytes) / Double(hardware.memoryBytes) : 0, track: Palette.linen)
			LabeledRow("Processor", Format.percentShort(status.load.cpuPercent / 100))
			MeterBar(fraction: status.load.cpuPercent / 100, track: Palette.linen)
		}

		InspectorSection("Model servers") {
			if status.engines.isEmpty {
				Text("None.")
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
			}
			ForEach(status.engines) { engine in
				VStack(alignment: .leading, spacing: Space.xs) {
					HStack(alignment: .firstTextBaseline, spacing: Space.s) {
						Text(engine.id)
							.font(Typography.mono(.callout))
							.foregroundStyle(Palette.ink)
						Spacer(minLength: Space.s)
						DotValue(tone: engine.isReady ? .healthy : .failed, text: engine.isReady ? "Ready" : "Not answering")
							.font(Typography.row)
							.foregroundStyle(Palette.ink)
					}
					Text(engine.baseURL)
						.font(Typography.mono(.subheadline))
						.foregroundStyle(Palette.inkMuted)
						.lineLimit(1)
						.truncationMode(.middle)
					if engine.isReady {
						Text([engine.version.map { "Version \($0)" }, Format.plural(engine.models.count, "model")].compactMap { $0 }.joined(separator: " · "))
							.font(Typography.caption)
							.foregroundStyle(Palette.inkMuted)
					} else if let error = engine.error, !error.isEmpty {
						Text(error)
							.font(Typography.caption)
							.foregroundStyle(Palette.rust)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				.accessibilityElement(children: .combine)
			}
		}
	}
}
