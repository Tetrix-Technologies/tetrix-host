import SwiftUI

/// The window's content beside the inspector: a banner when something needs
/// a person, the board, and the "Try a model" drawer.
struct MainView: View {
	@Environment(HostStore.self) private var store

	var body: some View {
		GeometryReader { proxy in
			VStack(spacing: 0) {
				if let status = store.status, status.noEngineAnswers {
					EngineBanner()
				}
				ZStack(alignment: .bottom) {
					board
					if let notice = store.notice, !notice.isEmpty {
						NoticeBar(text: notice) { store.dismissNotice() }
							.padding(Space.m)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				ChatDrawer(openHeight: ChatDrawer.openHeight(inContent: proxy.size.height))
			}
		}
		.background(Palette.paper)
	}

	@ViewBuilder private var board: some View {
		if let status = store.status {
			BoardView(status: status)
		} else if store.phase == .connecting {
			BoardDots(transform: BoardTransform())
		} else {
			StoppedBoard()
		}
	}
}

/// The board while no host runs: this machine alone, dimmed, and a way to
/// start.
struct StoppedBoard: View {
	@Environment(HostStore.self) private var store
	@Environment(\.renderMode) private var renderMode
	@State private var hardware = LocalMachine.hardware()

	private var isStarting: Bool { store.phase == .starting }

	var body: some View {
		ZStack {
			BoardDots(transform: BoardTransform())
			VStack(spacing: Space.l) {
				MachineCard(name: nil, hardware: hardware, load: nil)
					.frame(width: BoardLayout.cardWidth, height: BoardLayout.stoppedMachineHeight)
					.opacity(Metrics.dimmedOpacity)
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(CardSummary.machine(hardware, load: nil))
				VStack(spacing: Space.s) {
					Text(isStarting ? "Tetrix Host is starting" : "Tetrix Host is stopped")
						.font(Typography.title)
						.foregroundStyle(Palette.ink)
					Text("Start it to serve models to this machine and to paired devices.")
						.font(Typography.row)
						.foregroundStyle(Palette.inkMuted)
						.multilineTextAlignment(.center)
				}
				PrimaryButton("Start", minWidth: Metrics.startButtonMinWidth) {
					Task { await store.start() }
				}
				.disabled(isStarting)
				.keyboardShortcut(.defaultAction)
			}
			.padding(Space.xl)
		}
	}
}

/// The banner under the toolbar when no model server answers.
struct EngineBanner: View {
	static let downloadPage = URL(string: "https://ollama.com/download")
	@Environment(\.openURL) private var openURL

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: Space.s) {
				Image(systemName: "exclamationmark.triangle")
					.font(.system(size: Metrics.bannerIcon, weight: .medium))
					.foregroundStyle(Palette.harvest)
					.accessibilityHidden(true)
				Text("No model server is answering. Install one, then start it.")
					.font(Typography.row)
					.foregroundStyle(Palette.ink)
				Spacer(minLength: Space.m)
				if let url = Self.downloadPage {
					Button("Open the download page") { openURL(url) }
						.buttonStyle(LinkButtonStyle())
						.accessibilityAddTraits(.isLink)
				}
			}
			.padding(.horizontal, Space.m)
			.padding(.vertical, Space.s)
			.background(Palette.linen)
			Hairline()
		}
	}
}

/// A short message about the last thing that failed.
struct NoticeBar: View {
	var text: String
	var dismiss: () -> Void

	var body: some View {
		HStack(spacing: Space.s) {
			Image(systemName: "exclamationmark.circle")
				.foregroundStyle(Palette.rust)
				.accessibilityHidden(true)
			Text(text)
				.font(Typography.row)
				.foregroundStyle(Palette.ink)
				.fixedSize(horizontal: false, vertical: true)
			Button(action: dismiss) {
				Image(systemName: "xmark")
					.font(Typography.caption.weight(.semibold))
			}
			.buttonStyle(IconButtonStyle())
			.accessibilityLabel("Dismiss")
		}
		.padding(.horizontal, Space.m)
		.padding(.vertical, Space.s)
		.background(Palette.paperRaised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
	}
}
