import SwiftUI

/// "Download a model". A person names a model or picks a suggestion. Once a
/// download runs, the sheet shows its progress. Hide keeps it going.
struct DownloadSheet: View {
	var close: () -> Void
	@Environment(HostStore.self) private var store
	/// What a person typed or picked. Nil until they do, and the field
	/// then holds the first suggestion that fits.
	@State private var typed: String?

	private var memory: Int64 { store.status?.hardware.memoryBytes ?? 0 }

	private var suggestions: [ModelCatalog.Suggestion] {
		ModelCatalog.suggestions(memoryBytes: memory, installed: Set(store.status?.models.map(\.name) ?? []))
	}

	private var name: String {
		typed ?? ModelCatalog.firstChoice(in: suggestions) ?? ""
	}

	var body: some View {
		let pulls = store.shownPulls
		if pulls.isEmpty {
			form
		} else {
			progress(pulls)
		}
	}

	// MARK: Form

	private var form: some View {
		SheetFrame(title: "Download a model") {
			VStack(alignment: .leading, spacing: Space.m) {
				VStack(alignment: .leading, spacing: Space.xs) {
					Text("Name")
						.font(Typography.row)
						.foregroundStyle(Palette.inkMuted)
					FieldBox(
						title: "Model name",
						// A field that takes focus writes its text back unchanged.
						// Only a real change counts as typing.
						text: Binding(get: { name }, set: { if $0 != name { typed = $0 } }),
						placeholder: "Model name",
						mono: true
					) {
						start()
					}
				}

				if !suggestions.isEmpty {
					VStack(alignment: .leading, spacing: Space.s) {
						Text("Sized for \(Format.memory(memory)) of memory")
							.font(Typography.row)
							.foregroundStyle(Palette.inkMuted)
						VStack(spacing: 0) {
							ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
								if index > 0 { Hairline() }
								SuggestionRow(suggestion: suggestion, isChosen: name == suggestion.entry.name) {
									typed = suggestion.entry.name
								}
							}
						}
						.background(Palette.paper)
						.clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
						.overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.rule, lineWidth: Stroke.hairline))
					}
				}

				if let notice = store.notice, !notice.isEmpty {
					Text(notice)
						.font(Typography.row)
						.foregroundStyle(Palette.rust)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		} actions: {
			Spacer()
			Button("Cancel", action: close)
				.systemButton(.bordered, size: .large)
				.keyboardShortcut(.cancelAction)
			PrimaryButton("Download") { start() }
				.keyboardShortcut(.defaultAction)
				.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.status == nil)
		}
	}

	private func start() {
		let name = name
		Task { await store.download(name) }
	}

	// MARK: Progress

	private func progress(_ pulls: [PullProgress]) -> some View {
		let running = pulls.contains { !$0.done }
		return SheetFrame(title: running ? "Downloading a model" : "Download a model") {
			VStack(spacing: Space.l) {
				ForEach(pulls) { pull in
					PullProgressView(pull: pull)
				}
			}
		} actions: {
			if running {
				// The button's name says what it does, so it asks nothing more.
				Button("Stop download", role: .destructive) {
					Task {
						for pull in pulls where !pull.done { await store.cancelDownload(pull) }
					}
				}
				.systemButton(.destructive, size: .large)
				Spacer()
				PrimaryButton("Hide", action: close)
					.keyboardShortcut(.defaultAction)
					.help("The download keeps going")
			} else {
				Spacer()
				Button("Download another") {
					store.dismissFinishedDownloads()
					typed = nil
				}
				.systemButton(.bordered, size: .large)
				PrimaryButton("Done", action: finish)
					.keyboardShortcut(.defaultAction)
			}
		}
		// Escape does what Return does here: it puts the sheet away.
		.background {
			Button("Close", action: running ? close : finish)
				.keyboardShortcut(.cancelAction)
				.opacity(0)
				.accessibilityHidden(true)
		}
	}

	private func finish() {
		store.dismissFinishedDownloads()
		close()
	}
}

/// One suggested model: its name, its size, and a badge when it needs more
/// memory than the machine has.
private struct SuggestionRow: View {
	var suggestion: ModelCatalog.Suggestion
	var isChosen: Bool
	var choose: () -> Void

	var body: some View {
		Button(action: choose) {
			HStack(spacing: Space.s) {
				VStack(alignment: .leading, spacing: 0) {
					Text(suggestion.entry.name)
						.font(Typography.mono(.callout))
						.foregroundStyle(Palette.ink)
					// Muted ink is too faint on the tint of a chosen row.
					Text("\(suggestion.entry.role.title) · about \(Format.storage(suggestion.entry.sizeBytes))")
						.font(Typography.caption)
						.foregroundStyle(isChosen ? Palette.inkSoft : Palette.inkMuted)
				}
				Spacer(minLength: Space.s)
				if !suggestion.fits {
					Text("Needs more memory")
						.font(Typography.label)
						.foregroundStyle(Palette.harvest)
						.padding(.horizontal, Space.s)
						.frame(height: Metrics.pillHeight)
						.background(Palette.linen, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
				}
				Image(systemName: "checkmark")
					.font(Typography.caption.weight(.semibold))
					.foregroundStyle(Palette.moss)
					.opacity(isChosen ? 1 : 0)
					.accessibilityHidden(true)
			}
			.padding(.horizontal, Space.m)
			.padding(.vertical, Space.s)
			.background(isChosen ? Palette.aloe : Palette.paper)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isChosen ? .isSelected : [])
	}
}

/// The progress of one download: the model, how much has arrived, and a bar.
struct PullProgressView: View {
	var pull: PullProgress

	/// The line under the bar. While bytes arrive the sheet's title says
	/// so already, and there is no line.
	static func statusLine(for pull: PullProgress) -> String? {
		if pull.failed { return pull.error ?? "The download failed." }
		if pull.done { return "Downloaded. The model is ready to use." }
		switch pull.status {
		case "Starting": return "Starting"
		case "Verifying": return "Checking the download"
		case "Finishing": return "Finishing"
		default: return nil
		}
	}

	var body: some View {
		let fraction = pull.done && !pull.failed ? 1 : (pull.fraction ?? 0)
		let status = Self.statusLine(for: pull)
		let showsPercent = pull.total > 0 || pull.done
		VStack(spacing: Space.s) {
			Text(pull.name)
				.font(Typography.mono(.callout))
				.foregroundStyle(Palette.inkSoft)
			HStack(alignment: .firstTextBaseline) {
				Text(Format.progress(completed: pull.completed, total: pull.total))
					.font(Typography.row)
					.monospacedDigit()
					.foregroundStyle(Palette.inkMuted)
				Spacer()
				if showsPercent {
					Text(Format.percentShort(fraction))
						.font(Typography.control)
						.monospacedDigit()
						.foregroundStyle(Palette.ink)
				}
			}
			// A download is not a load, so its bar does not warn as it fills.
			MeterBar(fraction: fraction, height: Metrics.progressHeight, tint: pull.failed ? Palette.rust : Palette.inkSoft)
			// The line keeps its place while it is blank, so the sheet does
			// not change height as a download moves between stages.
			Text(status ?? " ")
				.font(Typography.row)
				.foregroundStyle(pull.failed ? Palette.rust : Palette.inkMuted)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel([
			pull.name,
			status ?? "Downloading",
			Format.progress(completed: pull.completed, total: pull.total),
			showsPercent ? Format.percent(fraction) : "",
		].filter { !$0.isEmpty }.joined(separator: ". "))
	}
}
