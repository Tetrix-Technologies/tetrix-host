import Foundation
import Testing
@testable import TetrixHostKit

/// These tests write to the login keychain, under a service name made for
/// one run, and remove what they wrote. Set `TETRIX_HOST_SKIP_KEYCHAIN` to
/// skip them where no keychain is unlocked, such as a build machine.
@Suite("Keychain store", .enabled(if: ProcessInfo.processInfo.environment["TETRIX_HOST_SKIP_KEYCHAIN"] == nil))
struct StoreTests {
	private func pairing(_ id: String, name: String) -> PairedHost {
		PairedHost(
			hostID: id, hostName: name, relay: URL(string: "wss://relay.example.com")!,
			hostStaticKey: Data(repeating: 1, count: 32), deviceID: "d_\(id)",
			deviceStaticKey: Data(repeating: 2, count: 32)
		)
	}

	@Test("Pairings are saved, listed, replaced, and removed")
	func roundTrip() throws {
		// The test binary is unsigned, so it cannot use the data protection
		// keychain. A signed app leaves that on.
		let store = PairedHostStore(service: "tech.tetrix.host.tests.\(UUID().uuidString)", dataProtection: false)
		let studio = pairing("aaaaaaaaaaaaaaaa", name: "Studio")
		let attic = pairing("bbbbbbbbbbbbbbbb", name: "Attic")
		defer {
			try? store.remove(hostID: studio.hostID)
			try? store.remove(hostID: attic.hostID)
		}

		#expect(try store.all().isEmpty)
		#expect(try store.host(id: studio.hostID) == nil)

		try store.save(studio)
		try store.save(attic)
		// Sorted by name, and each item reads back whole, private key and all.
		#expect(try store.all() == [attic, studio])
		#expect(try store.host(id: studio.hostID) == studio)

		// Saving a host again replaces its entry.
		var renamed = studio
		renamed.hostName = "Studio upstairs"
		try store.save(renamed)
		#expect(try store.all().count == 2)
		#expect(try store.host(id: studio.hostID)?.hostName == "Studio upstairs")

		try store.remove(hostID: studio.hostID)
		#expect(try store.all() == [attic])
		// Removing what is not there is not an error.
		try store.remove(hostID: studio.hostID)

		// Another service sees none of it.
		#expect(try PairedHostStore(service: "tech.tetrix.host.tests.other", dataProtection: false).all().isEmpty)
	}
}
