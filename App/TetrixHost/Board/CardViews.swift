import SwiftUI

/// Something wrong with what a card stands for. The card's header strip
/// names it, with a symbol, so the board shows a problem without a click.
struct CardProblem: Equatable, Sendable {
	enum Level: Sendable {
		/// On its way, or held up by something a person can fix.
		case waiting
		case failed

		var color: ColorToken {
			switch self {
			case .waiting: Palette.harvest
			case .failed: Palette.rust
			}
		}
	}

	var level: Level
	/// A word or two, such as "Offline". It follows the card's own name.
	var text: String

	static func tunnel(_ tunnel: Tunnel) -> CardProblem? {
		guard tunnel.enabled else { return nil }
		switch tunnel.state {
		case .connecting: return CardProblem(level: .waiting, text: Format.tunnelState(tunnel))
		case .offline: return CardProblem(level: .failed, text: Format.tunnelState(tunnel))
		case .connected, .disabled: return nil
		}
	}

	/// A machine with no model server that answers can serve nothing. One
	/// with a server that answers and one that does not can serve some of
	/// its models.
	static func machine(engines: [Engine]) -> CardProblem? {
		if !engines.contains(where: \.isReady) { return CardProblem(level: .waiting, text: "No model server") }
		if engines.contains(where: { !$0.isReady }) { return CardProblem(level: .waiting, text: "A server is down") }
		return nil
	}

	/// A role names a model that no model server lists.
	static func model(_ model: Model?) -> CardProblem? {
		model == nil ? CardProblem(level: .waiting, text: "Not available") : nil
	}
}

/// The frame every card shares: a tinted header strip, a raised body, and a
/// hairline border that turns moss when the card is selected.
struct CardChrome<Content: View>: View {
	var header: String
	var problem: CardProblem?
	var isSelected = false
	var isFocused = false
	var isLifted = false
	@ViewBuilder var content: Content

	@State private var isHovered = false

	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
	}

	/// A card in mid-drag keeps the moss border of a selected one.
	private var isMarked: Bool { isSelected || isLifted }

	private var border: ColorToken {
		if isMarked { return Palette.moss }
		return isHovered ? Palette.ruleStrong : Palette.rule
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: Space.xs) {
				if let problem {
					Image(systemName: "exclamationmark.triangle")
						.accessibilityHidden(true)
					Text("\(header) · \(problem.text)")
				} else {
					Text(header)
				}
			}
			.font(Typography.label)
			.foregroundStyle(problem?.level.color ?? Palette.inkSoft)
			.lineLimit(1)
			.padding(.horizontal, Space.s)
			.frame(maxWidth: .infinity)
			.frame(height: Metrics.cardHeaderHeight)
			.background(Palette.aloe)
			Hairline()
			content
				.padding(Space.m)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		.background(Palette.paperRaised)
		.clipShape(shape)
		.overlay(shape.strokeBorder(border, lineWidth: isMarked ? Stroke.selected : Stroke.hairline))
		.cardFocusRing(isFocused, shape: shape)
		.onHover { isHovered = $0 }
	}
}

extension View {
	/// A moss ring outside a card that has keyboard focus.
	func cardFocusRing(_ visible: Bool, shape: RoundedRectangle) -> some View {
		overlay {
			if visible {
				shape
					.inset(by: -Stroke.focusRing)
					.stroke(Palette.moss, lineWidth: Stroke.focusRing)
			}
		}
	}
}

/// The symbol and the title at the top of a card's body.
private struct CardHeading: View {
	var symbol: String
	var title: String
	var mono = false
	/// Puts the symbol on the title's line, for a card with little to say.
	var inline = false

	private var titleText: some View {
		Text(title)
			.font(mono ? Typography.mono(.headline, weight: .semibold) : Typography.cardTitle)
			.foregroundStyle(Palette.ink)
			.lineLimit(1)
			.truncationMode(.middle)
	}

	var body: some View {
		if inline {
			HStack(spacing: Space.s) {
				Image(systemName: symbol)
					.font(Typography.body)
					.foregroundStyle(Palette.inkSoft)
					.frame(width: Metrics.cardIconBox, alignment: .leading)
					.accessibilityHidden(true)
				titleText
			}
		} else {
			VStack(alignment: .leading, spacing: Space.s) {
				Image(systemName: symbol)
					.font(.system(size: Metrics.cardIcon, weight: .regular))
					.foregroundStyle(Palette.inkSoft)
					.frame(height: Metrics.cardIconBox, alignment: .leading)
					.accessibilityHidden(true)
				titleText
			}
		}
	}
}

private let cardRowSpacing = Space.xs

// MARK: - Machine

struct MachineCard: View {
	/// The name a person gave the host. Nil while the host is stopped, when
	/// the card takes the computer's own name.
	var name: String?
	var hardware: Hardware
	/// Nil while the host is stopped, when there is no live reading.
	var load: Load?
	var problem: CardProblem?
	var isSelected = false
	var isFocused = false
	var isLifted = false

	static func title(name: String?, hardware: Hardware) -> String {
		if let name, !name.isEmpty { return name }
		return hardware.model.isEmpty ? "This machine" : hardware.model
	}

	var body: some View {
		CardChrome(header: "This machine", problem: problem, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted) {
			VStack(alignment: .leading, spacing: Space.s) {
				CardHeading(symbol: hardware.symbolName, title: Self.title(name: name, hardware: hardware))
				VStack(spacing: cardRowSpacing) {
					// While the host is stopped the title is the model's
					// stand-in already, so the row would say it twice.
					if name != nil, !hardware.model.isEmpty {
						LabeledRow("Model", hardware.model)
					}
					LabeledRow("Chip", hardware.chip)
					LabeledRow("Memory", Format.memory(hardware.memoryBytes))
					LabeledRow("Free space", Format.storage(hardware.diskFreeBytes))
				}
				if let load {
					Hairline()
					VStack(spacing: cardRowSpacing) {
						LabeledRow("Memory in use", Format.memory(load.memoryUsedBytes))
						MeterBar(fraction: hardware.memoryBytes > 0 ? Double(load.memoryUsedBytes) / Double(hardware.memoryBytes) : 0)
						LabeledRow("Processor", Format.percentShort(load.cpuPercent / 100))
					}
				}
			}
		}
	}
}

// MARK: - Model

struct ModelCard: View {
	var slot: ModelSlot
	var modelID: String
	/// Nil when the engine no longer lists the model the role names.
	var model: Model?
	var isSelected = false
	var isFocused = false
	var isLifted = false

	var body: some View {
		CardChrome(header: slot.title, problem: .model(model), isSelected: isSelected, isFocused: isFocused, isLifted: isLifted) {
			VStack(alignment: .leading, spacing: Space.s) {
				CardHeading(symbol: "cube", title: model?.name ?? Format.modelName(fromID: modelID), mono: true)
				if let model {
					VStack(spacing: cardRowSpacing) {
						LabeledRow("Size", model.sizeBytes.map(Format.storage) ?? "Unknown")
						LabeledRow("Context", Format.window(supported: model.contextLength, inUse: model.contextInUse))
						LabeledRow("Can", Format.capabilities(model.capabilities))
						LabeledRow(label: "State") {
							DotValue(tone: model.loaded ? .healthy : .off, text: model.loaded ? "In memory" : "On disk")
						}
					}
				} else {
					LabeledRow(label: "State") {
						DotValue(tone: .waiting, text: "Not available")
					}
					Text("The model server does not list this model now.")
						.font(Typography.caption)
						.foregroundStyle(Palette.inkMuted)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}
}

// MARK: - Tunnel

struct TunnelCard: View {
	var tunnel: Tunnel
	var isSelected = false
	var isFocused = false
	var isLifted = false

	var body: some View {
		CardChrome(header: "Tunnel", problem: .tunnel(tunnel), isSelected: isSelected, isFocused: isFocused, isLifted: isLifted) {
			VStack(alignment: .leading, spacing: Space.s) {
				CardHeading(symbol: "lock", title: "Relay")
				VStack(spacing: cardRowSpacing) {
					LabeledRow(label: "Address") {
						Text(tunnel.relayHost)
							.font(Typography.mono(.subheadline))
							.lineLimit(1)
							.truncationMode(.middle)
					}
					LabeledRow(label: "State") {
						DotValue(tone: tunnel.tone, text: Format.tunnelState(tunnel))
					}
				}
				if tunnel.enabled, tunnel.state == .offline, let error = tunnel.lastError, !error.isEmpty {
					Text(error)
						.font(Typography.caption)
						.foregroundStyle(Palette.rust)
						.lineLimit(3)
						.fixedSize(horizontal: false, vertical: true)
				} else {
					Text("Sealed from end to end. The relay cannot read what passes.")
						.font(Typography.caption)
						.foregroundStyle(Palette.inkMuted)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}
}

// MARK: - Device

struct DeviceCard: View {
	var device: Device
	var now: Date
	/// True while the tunnel is off, when no device can reach the host.
	var tunnelOff = false
	var isSelected = false
	var isFocused = false
	var isLifted = false

	static func symbol(for platform: String?) -> String {
		switch platform?.lowercased() {
		case "ios": "iphone"
		case "ipados": "ipad"
		case "macos": "laptopcomputer"
		case "visionos": "vision.pro"
		default: "desktopcomputer"
		}
	}

	static func tone(for device: Device, tunnelOff: Bool) -> StatusDot.Tone {
		device.online && !tunnelOff ? .healthy : .off
	}

	var body: some View {
		CardChrome(header: device.appName, isSelected: isSelected, isFocused: isFocused, isLifted: isLifted) {
			VStack(alignment: .leading, spacing: Space.s) {
				// The symbol says the platform, so the card has no row for it.
				CardHeading(symbol: Self.symbol(for: device.platform), title: device.name, inline: true)
				VStack(spacing: cardRowSpacing) {
					LabeledRow(label: "State") {
						DotValue(tone: Self.tone(for: device, tunnelOff: tunnelOff), text: Format.deviceState(device, now: now, tunnelOff: tunnelOff))
					}
					LabeledRow("Requests", Format.count(device.requests))
				}
			}
		}
	}
}

// MARK: - Ghost

/// A dashed stand-in for a card that does not exist yet. It reads as a button.
struct GhostCard: View {
	var title: String
	var isFocused = false
	var isLifted = false

	@State private var isHovered = false

	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
	}

	var body: some View {
		HStack(spacing: Space.s) {
			Image(systemName: "plus")
				.font(Typography.control)
				.accessibilityHidden(true)
			Text(title)
				.font(Typography.control)
		}
		.foregroundStyle(Palette.moss)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background {
			if isHovered {
				shape.fill(Palette.aloe)
			} else {
				shape.fill(Palette.paper.opacity(Metrics.dimmedOpacity))
			}
		}
		.overlay(
			shape.strokeBorder(
				isLifted ? Palette.moss : Palette.ruleStrong,
				style: StrokeStyle(lineWidth: Stroke.selected, dash: Metrics.ghostDash)
			)
		)
		.cardFocusRing(isFocused, shape: shape)
		.contentShape(shape)
		.onHover { isHovered = $0 }
	}
}

// MARK: - Spoken summaries

/// What VoiceOver says for each card. Each card reads as one element.
enum CardSummary {
	/// `name` is the host's name, or nil while the host is stopped.
	static func machine(name: String? = nil, _ hardware: Hardware, load: Load?, problem: CardProblem? = nil) -> String {
		var parts = ["This machine", name ?? "", hardware.model, hardware.chip, "\(Format.memory(hardware.memoryBytes)) memory", "\(Format.storage(hardware.diskFreeBytes)) free"]
		if let load {
			parts.append("\(Format.memory(load.memoryUsedBytes)) of memory in use")
			parts.append("processor at \(Format.percent(load.cpuPercent / 100))")
		}
		if let problem { parts.append(problem.text.lowercased()) }
		return sentence(parts)
	}

	static func model(slot: ModelSlot, modelID: String, model: Model?) -> String {
		guard let model else {
			return sentence([slot.title, "model \(Format.modelName(fromID: modelID))", "not available"])
		}
		var parts = [slot.title, "model \(model.name)"]
		if let size = model.sizeBytes { parts.append(Format.storage(size)) }
		if model.contextLength != nil || model.contextInUse != nil {
			parts.append("context of \(Format.window(supported: model.contextLength, inUse: model.contextInUse))")
		}
		parts.append("can \(Format.capabilities(model.capabilities).lowercased())")
		parts.append(model.loaded ? "in memory" : "on disk")
		return sentence(parts)
	}

	static func tunnel(_ tunnel: Tunnel) -> String {
		var parts = ["Tunnel", "relay \(tunnel.relayHost)", Format.tunnelState(tunnel).lowercased()]
		if tunnel.enabled, tunnel.state == .offline, let error = tunnel.lastError, !error.isEmpty { parts.append(error) }
		return sentence(parts)
	}

	/// While the tunnel is off the device cannot reach the host, and the
	/// summary says so in place of when the host last saw it.
	static func device(_ device: Device, now: Date, tunnelOff: Bool = false) -> String {
		var parts = ["\(device.appName) on \(device.name)"]
		if let platform = device.platform { parts.append(platform) }
		if !tunnelOff { parts.append(Format.deviceState(device, now: now, spoken: true).lowercased()) }
		parts.append(Format.plural(Int(device.requests), "request"))
		return sentence(parts) + (tunnelOff ? " Unreachable. The tunnel is off." : "")
	}

	private static func sentence(_ parts: [String]) -> String {
		parts.filter { !$0.isEmpty }.joined(separator: ", ") + "."
	}
}
