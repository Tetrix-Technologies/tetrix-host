import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The frame both sheets share: a title, the content, and a row of buttons.
struct SheetFrame<Content: View, Actions: View>: View {
	var title: String
	@ViewBuilder var content: Content
	@ViewBuilder var actions: Actions

	var body: some View {
		VStack(spacing: Space.l) {
			Text(title)
				.font(Typography.title)
				.foregroundStyle(Palette.ink)
				.accessibilityAddTraits(.isHeader)
			content
			HStack(spacing: Space.s) {
				actions
			}
		}
		.padding(Space.xl)
		.frame(width: Metrics.sheetWidth)
		.background(Palette.paperRaised)
	}
}

/// "Pair a device". Opening it asks the host for a code. Closing it before
/// a device pairs cancels the code.
struct PairingSheet: View {
	var close: () -> Void
	@Environment(HostStore.self) private var store

	var body: some View {
		SheetFrame(title: "Pair a device") {
			switch store.pairing {
			case .idle, .preparing:
				Text("Asking the host for a code")
					.font(Typography.row)
					.foregroundStyle(Palette.inkMuted)
					.frame(height: Metrics.qrSide)
			case .offered(let offer):
				NowReader { now in
					if let expires = offer.expiresAt, expires <= now {
						expired
					} else {
						PairingOfferView(offer: offer, tunnel: store.status?.tunnel, now: now)
					}
				}
			case .paired(let device):
				paired(device)
			case .failed(let reason):
				VStack(spacing: Space.m) {
					Text(reason.isEmpty ? "The host could not make a pairing code." : reason)
						.font(Typography.row)
						.foregroundStyle(Palette.rust)
						.multilineTextAlignment(.center)
					Button("Try again") { Task { await store.beginPairing() } }
						.systemButton(.bordered, size: .large)
				}
				.frame(minHeight: Metrics.sheetStatusMinHeight)
			}
		} actions: {
			Spacer()
			if case .paired = store.pairing {
				PrimaryButton("Done", action: close)
					.keyboardShortcut(.defaultAction)
			} else {
				Button("Cancel", action: close)
					.systemButton(.bordered, size: .large)
					.keyboardShortcut(.cancelAction)
			}
		}
	}

	private var expired: some View {
		VStack(spacing: Space.m) {
			Text("The code expired.")
				.font(Typography.row)
				.foregroundStyle(Palette.inkSoft)
			Button("Make a new code") { Task { await store.beginPairing() } }
				.systemButton(.bordered, size: .large)
		}
		.frame(minHeight: Metrics.sheetStatusMinHeight)
	}

	private func paired(_ device: Device) -> some View {
		VStack(spacing: Space.m) {
			Image(systemName: "checkmark.circle")
				.font(Typography.sheetMark)
				.foregroundStyle(Palette.olive)
				.accessibilityHidden(true)
			Text("Paired. \(device.appName) on \(device.name) can now use this host.")
				.font(Typography.body)
				.foregroundStyle(Palette.ink)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(minHeight: Metrics.sheetStatusMinHeight)
	}
}

/// The code as a QR image and as a link, with the time it has left.
struct PairingOfferView: View {
	var offer: PairingOffer
	var tunnel: Tunnel?
	var now: Date

	private var tunnelWarning: String? {
		guard let tunnel else { return nil }
		if !tunnel.enabled { return "The tunnel is off. Turn it on before you pair a device." }
		switch tunnel.state {
		case .connected: return nil
		case .connecting: return "The tunnel is still connecting. A device can pair once it connects."
		default: return "The tunnel is not connected. A device can pair once it connects."
		}
	}

	var body: some View {
		// A sheet is a raised surface, so each inset here is filled with
		// paper. Linen is the same color as the sheet in dark mode.
		VStack(spacing: Space.m) {
			if let tunnelWarning {
				HStack(alignment: .firstTextBaseline, spacing: Space.s) {
					Image(systemName: "exclamationmark.triangle")
						.foregroundStyle(Palette.harvest)
						.accessibilityHidden(true)
					Text(tunnelWarning)
						.font(Typography.row)
						.foregroundStyle(Palette.ink)
						.fixedSize(horizontal: false, vertical: true)
				}
				.padding(Space.m)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
			}

			// Dark modules on a light ground in both appearances. Many
			// scanners skip a code with its colors reversed.
			QRCodeView(text: offer.link)
				.frame(width: Metrics.qrSide, height: Metrics.qrSide)
				.padding(Space.m)
				.background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
				.environment(\.colorScheme, .light)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel("Pairing code")
				.accessibilityAddTraits(.isImage)

			HStack(spacing: Space.s) {
				Text(offer.link)
					.font(Typography.mono(.subheadline))
					.foregroundStyle(Palette.inkSoft)
					.lineLimit(1)
					.truncationMode(.middle)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
				CopyButton(text: offer.link, label: "Copy the pairing link", showsTitle: true)
					.buttonStyle(LinkButtonStyle())
			}
			.padding(.horizontal, Space.m)
			.frame(height: Metrics.insetRowHeight)
			.background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))

			Text("Scan this code with the app you want to pair, or paste the link into it. The code works once.")
				.font(Typography.row)
				.foregroundStyle(Palette.inkSoft)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)

			Text("Expires in \(Text(Format.countdown(to: offer.expiresAt, now: now)).monospacedDigit())")
				.font(Typography.caption)
				.foregroundStyle(Palette.inkMuted)
		}
	}
}

/// A QR image in the light palette's ink on its paper, whatever the
/// appearance. The image carries its own quiet zone.
struct QRCodeView: View {
	var text: String

	var body: some View {
		if let image = Self.image(for: text) {
			Image(decorative: image, scale: 1)
				.interpolation(.none)
				.resizable()
				.scaledToFit()
		} else {
			Text("The code could not be drawn. Copy the link.")
				.font(Typography.caption)
				.foregroundStyle(Palette.inkSoft)
				.multilineTextAlignment(.center)
		}
	}

	private static func ciColor(_ hex: UInt32) -> CIColor {
		CIColor(
			red: CGFloat((hex >> 16) & 0xFF) / 255,
			green: CGFloat((hex >> 8) & 0xFF) / 255,
			blue: CGFloat(hex & 0xFF) / 255
		)
	}

	/// Pixels per module. The view scales the image without smoothing, so
	/// this only has to be large enough to stay sharp.
	static let moduleScale: CGFloat = 8
	/// The clear margin a scanner needs around a code, in modules.
	static let quietZone: CGFloat = 4
	/// The margin the system's generator leaves on its own.
	private static let generatedMargin: CGFloat = 1

	static func image(for text: String) -> CGImage? {
		let ink = ciColor(Palette.ink.hex(scheme: .light))
		let paper = ciColor(Palette.paper.hex(scheme: .light))

		let generator = CIFilter.qrCodeGenerator()
		generator.message = Data(text.utf8)
		generator.correctionLevel = "M"
		guard let code = generator.outputImage else { return nil }

		let tint = CIFilter.falseColor()
		tint.inputImage = code
		tint.color0 = ink
		tint.color1 = paper
		guard let colored = tint.outputImage else { return nil }

		// Widen the margin to the full quiet zone, in the paper color.
		let extra = quietZone - generatedMargin
		let extent = colored.extent.insetBy(dx: -extra, dy: -extra)
		let padded = colored.composited(over: CIImage(color: paper).cropped(to: extent))

		let scaled = padded.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
		return CIContext().createCGImage(scaled, from: scaled.extent)
	}
}
