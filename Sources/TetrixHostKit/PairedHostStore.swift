import Foundation
import Security

/// Keeps pairings in the Keychain.
///
/// A pairing holds this device's private key, so it does not belong in
/// `UserDefaults` or a plain file. Items are saved for this device only:
/// they stay out of iCloud Keychain and out of backups that move to another
/// device, because a host pairs with one device, not with a person.
public struct PairedHostStore: Sendable {
	private let service: String
	private let accessGroup: String?
	private let dataProtection: Bool

	/// - Parameters:
	///   - service: The Keychain service name. Use one per app, unless two
	///     apps mean to share their pairings.
	///   - accessGroup: A Keychain access group, to share pairings between
	///     apps from one team.
	///   - dataProtection: Whether to use the data protection keychain.
	///     Leave it on in a signed app. On macOS it is what makes "this
	///     device only" hold, because the older file keychain does not
	///     enforce it. It needs an app with an application identifier, so
	///     an unsigned tool or test passes `false`. iOS has no other
	///     keychain, and ignores the value.
	public init(service: String = "tech.tetrix.host.pairings", accessGroup: String? = nil, dataProtection: Bool = true) {
		self.service = service
		self.accessGroup = accessGroup
		self.dataProtection = dataProtection
	}

	public struct KeychainError: Error, Sendable, Equatable {
		public let status: OSStatus
	}

	private func query(hostID: String? = nil) -> [String: Any] {
		var query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrSynchronizable as String: false,
		]
		if let hostID { query[kSecAttrAccount as String] = hostID }
		if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
		if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
		return query
	}

	/// Every stored pairing, sorted by host name.
	public func all() throws -> [PairedHost] {
		// The macOS file keychain refuses a query that asks for the data of
		// every match at once. List the accounts, then read each item.
		var query = query()
		query[kSecMatchLimit as String] = kSecMatchLimitAll
		query[kSecReturnAttributes as String] = true
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess else { throw KeychainError(status: status) }
		let items = (result as? [[String: Any]]) ?? []
		return try items
			.compactMap { $0[kSecAttrAccount as String] as? String }
			.compactMap { try host(id: $0) }
			.sorted { $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending }
	}

	/// The pairing with one host, if this device has one.
	public func host(id: String) throws -> PairedHost? {
		var query = query(hostID: id)
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		query[kSecReturnData as String] = true
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess else { throw KeychainError(status: status) }
		guard let data = result as? Data else { return nil }
		return try? JSONDecoder().decode(PairedHost.self, from: data)
	}

	/// Saves a pairing. A pairing with the same host replaces the old one.
	public func save(_ host: PairedHost) throws {
		let data = try JSONEncoder().encode(host)
		let update = SecItemUpdate(
			query(hostID: host.hostID) as CFDictionary,
			[kSecValueData as String: data, kSecAttrLabel as String: host.hostName] as CFDictionary
		)
		if update == errSecSuccess { return }
		guard update == errSecItemNotFound else { throw KeychainError(status: update) }

		var item = query(hostID: host.hostID)
		item[kSecValueData as String] = data
		item[kSecAttrLabel as String] = host.hostName
		item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let add = SecItemAdd(item as CFDictionary, nil)
		guard add == errSecSuccess else { throw KeychainError(status: add) }
	}

	/// Forgets a pairing. The host still lists the device until its owner
	/// unpairs it there.
	public func remove(hostID: String) throws {
		let status = SecItemDelete(query(hostID: hostID) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw KeychainError(status: status)
		}
	}
}
