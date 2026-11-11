import AppKit
import SwiftUI

/// One color of the Tetrix palette, with a value for each appearance.
///
/// A token is a `ShapeStyle`, so it resolves against the environment of the
/// view that draws it. That keeps light, dark, and Increase Contrast correct
/// in a window and in an offscreen render alike.
struct ColorToken: ShapeStyle, Hashable, Sendable {
	let light: UInt32
	let dark: UInt32
	/// The values to use when Increase Contrast is on. Absent means no change.
	var strongLight: UInt32?
	var strongDark: UInt32?

	func resolve(in environment: EnvironmentValues) -> Color {
		color(scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
	}

	func hex(scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> UInt32 {
		let increased = contrast == .increased
		switch scheme {
		case .dark: return increased ? (strongDark ?? dark) : dark
		default: return increased ? (strongLight ?? light) : light
		}
	}

	func color(scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
		Color(hex: hex(scheme: scheme, contrast: contrast))
	}

	/// A dynamic color for the few APIs that take a `Color` and not a style.
	var dynamicColor: Color {
		let token = self
		return Color(nsColor: NSColor(name: nil) { appearance in
			let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			return NSColor(hex: token.hex(scheme: dark ? .dark : .light))
		})
	}
}

extension Color {
	init(hex: UInt32) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255
		)
	}
}

extension NSColor {
	convenience init(hex: UInt32) {
		self.init(
			srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
			green: CGFloat((hex >> 8) & 0xFF) / 255,
			blue: CGFloat(hex & 0xFF) / 255,
			alpha: 1
		)
	}
}

/// The Tetrix palette. Every color in the app comes from here.
enum Palette {
	/// Window and board background.
	static let paper = ColorToken(light: 0xF7F6F3, dark: 0x1B1A18)
	/// Cards.
	static let paperRaised = ColorToken(light: 0xFDFCFA, dark: 0x24221F)
	/// Inset and grouped backgrounds.
	static let linen = ColorToken(light: 0xEFECE4, dark: 0x24221F)
	/// Hairlines, borders, board dots.
	static let rule = ColorToken(light: 0xE2DED6, dark: 0x3A3731, strongLight: 0x736D61, strongDark: 0x8C877C)
	static let ruleStrong = ColorToken(light: 0xCFC9BD, dark: 0x3A3731, strongLight: 0x4A4741, strongDark: 0xB8B3A8)
	/// Primary text.
	static let ink = ColorToken(light: 0x1A1A1A, dark: 0xEFEDE8)
	/// Body text.
	static let inkSoft = ColorToken(light: 0x4A4741, dark: 0xB8B3A8, strongLight: 0x1A1A1A, strongDark: 0xEFEDE8)
	/// Captions.
	static let inkMuted = ColorToken(light: 0x736D61, dark: 0x8C877C, strongLight: 0x4A4741, strongDark: 0xB8B3A8)
	/// The one accent. It marks interaction only.
	static let moss = ColorToken(light: 0x4C583E, dark: 0x9BAA84, strongLight: 0x2C3424, strongDark: 0x9BAA84)
	/// Pressed accent.
	static let mossDeep = ColorToken(light: 0x2C3424, dark: 0x9BAA84)
	/// Text and icons on a moss fill.
	static let onMoss = ColorToken(light: 0xF7F6F3, dark: 0x1B1A18)
	/// Selection and tint fills, card header strips.
	static let aloe = ColorToken(light: 0xE3E6DC, dark: 0x252A21)
	/// Warm emphasis, used sparingly.
	static let clay = ColorToken(light: 0xA8491A, dark: 0xD07B4A)
	/// Icons and large text only. Marks a healthy status.
	static let olive = ColorToken(light: 0x768064, dark: 0x768064)
	/// Warning.
	static let harvest = ColorToken(light: 0x8A6414, dark: 0xC99A3F)
	/// Error.
	static let rust = ColorToken(light: 0x9E3B30, dark: 0xC87A6E)
	/// Information.
	static let water = ColorToken(light: 0x3F4E4F, dark: 0x8FA5AD)
}

/// The spacing scale.
enum Space {
	static let xs: CGFloat = 4
	static let s: CGFloat = 8
	static let m: CGFloat = 16
	static let l: CGFloat = 24
	static let xl: CGFloat = 32
	static let xxl: CGFloat = 48
}

/// Corner radii.
enum Radius {
	/// Badges and fields.
	static let small: CGFloat = 8
	/// Cards and buttons.
	static let card: CGFloat = 16
	/// Sheets.
	static let sheet: CGFloat = 24
}

/// Line weights.
enum Stroke {
	static let hairline: CGFloat = 1
	static let selected: CGFloat = 1.5
	static let connector: CGFloat = 1.5
	/// A connector that carries a request, when motion or color alone
	/// cannot say so.
	static let activeConnector: CGFloat = 3
	static let focusRing: CGFloat = 3
}

/// Fixed sizes of the window and its parts.
enum Metrics {
	static let windowMinWidth: CGFloat = 1000
	static let windowMinHeight: CGFloat = 660
	static let windowDefaultWidth: CGFloat = 1280
	static let windowDefaultHeight: CGFloat = 800
	static let inspectorWidth: CGFloat = 300
	static let inspectorMinWidth: CGFloat = 260
	static let inspectorMaxWidth: CGFloat = 420
	static let toolbarHeight: CGFloat = 52
	/// The height of the glass the system puts behind toolbar items.
	static let toolbarControlHeight: CGFloat = 36
	/// The height of a row inset in a sheet, such as the pairing link.
	static let insetRowHeight: CGFloat = 32
	static let drawerBarHeight: CGFloat = 36
	static let drawerHeight: CGFloat = 300
	/// The most of the window's content the open drawer may take.
	static let drawerMaxShare: CGFloat = 0.4
	static let sheetWidth: CGFloat = 460
	static let qrSide: CGFloat = 184
	static let statusDot: CGFloat = 8
	static let cardIcon: CGFloat = 20
	static let meterHeight: CGFloat = 4
	static let progressHeight: CGFloat = 6
	static let progressRing: CGFloat = 16
	/// The least width and height of anything a person clicks.
	static let minimumTarget: CGFloat = 24
	static let startButtonMinWidth: CGFloat = 72
	static let cardHeaderHeight: CGFloat = 24
	static let cardIconBox: CGFloat = 24
	static let pillHeight: CGFloat = 20
	static let ringStroke: CGFloat = 3
	static let windowControl: CGFloat = 12
	/// The least height of a sheet's message, so the sheet does not jump
	/// as it moves between states.
	static let sheetStatusMinHeight: CGFloat = 92
	static let chatBubbleMaxWidth: CGFloat = 520
	static let chatAnswerMaxWidth: CGFloat = 720
	static let bannerIcon: CGFloat = 14
	/// The share of a meter at which it turns to the warning color.
	static let meterWarningShare: Double = 0.9
	/// The dashed border of a ghost card.
	static let ghostDash: [CGFloat] = [6, 4]
	/// The dashed line of a connector that carries nothing now.
	static let ghostConnectorDash: [CGFloat] = [4, 6]
	/// The dash that travels along a busy connector, and the length it
	/// travels before the pattern repeats.
	static let marchingDash: [CGFloat] = [6, 6]
	static let marchingDashPeriod: CGFloat = 12
	/// Opacity of a control that is present but out of use.
	static let dimmedOpacity: Double = 0.45
	static let scrimOpacity: Double = 0.28
}

/// Type styles. The system font carries everything. SF Mono is for
/// addresses, IDs, codes, and model names only.
enum Typography {
	static let title: Font = .title3.weight(.semibold)
	static let cardTitle: Font = .headline
	static let section: Font = .subheadline.weight(.semibold)
	static let body: Font = .body
	static let row: Font = .callout
	/// The smallest text in the app, 11 points.
	static let caption: Font = .subheadline
	static let label: Font = .subheadline.weight(.medium)
	static let control: Font = .callout.weight(.medium)
	/// The large mark in a sheet, such as the check when a device pairs.
	static let sheetMark: Font = .largeTitle.weight(.light)

	static func mono(_ style: Font.TextStyle = .callout, weight: Font.Weight = .regular) -> Font {
		.system(style, design: .monospaced).weight(weight)
	}
}

/// Durations of the few animations the app runs.
enum Motion {
	static let quick: Double = 0.18
	static let settle: Double = 0.28
	/// One trip of a dash along a connector.
	static let dashCycle: Double = 1.4
	/// How long a path stays lit after a request finishes on it.
	static let requestGlow: Double = 2.5
	/// How long a word such as "Copied" or "Saved" stays up.
	static let confirmation: Duration = .seconds(1.2)
}
