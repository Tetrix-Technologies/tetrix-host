import Foundation

/// A short table of well-known open models, used to suggest a download.
///
/// The sizes are approximate. The host reports the real size once a
/// download starts.
enum ModelCatalog {
	struct Entry: Equatable, Sendable, Identifiable {
		let name: String
		let sizeBytes: Int64
		/// The kind of work the model suits best.
		let role: Role

		var id: String { name }
	}

	struct Suggestion: Equatable, Sendable, Identifiable {
		let entry: Entry
		/// True when the model fits in the machine's memory with room to work.
		let fits: Bool

		var id: String { entry.id }
	}

	static let entries: [Entry] = [
		Entry(name: "gemma3:1b", sizeBytes: gigabytes(0.8), role: .quick),
		Entry(name: "llama3.2:3b", sizeBytes: gigabytes(2.0), role: .quick),
		Entry(name: "qwen3:4b", sizeBytes: gigabytes(2.5), role: .quick),
		Entry(name: "gemma3:4b", sizeBytes: gigabytes(3.3), role: .quick),
		Entry(name: "qwen3:8b", sizeBytes: gigabytes(5.2), role: .deep),
		Entry(name: "gemma3:12b", sizeBytes: gigabytes(8.1), role: .deep),
		Entry(name: "qwen3:14b", sizeBytes: gigabytes(9.3), role: .deep),
		Entry(name: "gpt-oss:20b", sizeBytes: gigabytes(14), role: .deep),
		Entry(name: "gemma3:27b", sizeBytes: gigabytes(17), role: .deep),
		Entry(name: "qwen3:32b", sizeBytes: gigabytes(20), role: .deep),
		Entry(name: "gpt-oss:120b", sizeBytes: gigabytes(65), role: .deep),
	]

	/// The share of memory a model may take. The rest is for the system and
	/// for the text the model reads.
	static let usableShare = 0.6

	static let limit = 5

	static func fits(_ entry: Entry, memoryBytes: Int64) -> Bool {
		Double(entry.sizeBytes) <= Double(memoryBytes) * usableShare
	}

	/// A few models sized to the machine: the largest models that fit, one
	/// small model for quick work, and one model a size too large, so a
	/// person sees where the limit is.
	static func suggestions(memoryBytes: Int64, installed: Set<String> = []) -> [Suggestion] {
		let open = entries.filter { !installed.contains($0.name) }
		let fitting = open.filter { fits($0, memoryBytes: memoryBytes) }
		let tooLarge = open.filter { !fits($0, memoryBytes: memoryBytes) }

		var picked: [Entry] = []
		let largest = fitting.filter { $0.role == .deep }.suffix(2)
		let small = fitting.filter { $0.role == .quick }.suffix(2)
		picked.append(contentsOf: largest.reversed())
		picked.append(contentsOf: small.reversed())
		if picked.isEmpty { picked.append(contentsOf: fitting.suffix(limit - 1).reversed()) }
		if let next = tooLarge.first { picked.append(next) }

		return picked.prefix(limit).map { Suggestion(entry: $0, fits: fits($0, memoryBytes: memoryBytes)) }
	}

	/// The model the download sheet starts with: the first suggestion that
	/// fits the machine, so Download works without a choice.
	static func firstChoice(in suggestions: [Suggestion]) -> String? {
		suggestions.first { $0.fits }?.entry.name
	}

	private static func gigabytes(_ value: Double) -> Int64 {
		Int64(value * 1_000_000_000)
	}
}
