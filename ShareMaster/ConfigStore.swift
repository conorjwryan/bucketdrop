//
//  ConfigStore.swift
//  ShareMaster
//
//  Stores reusable Accounts (credentials) and Destinations (bucket + path +
//  link/naming options). Non-secret fields are persisted as JSON in
//  UserDefaults; access keys and secrets live in the Keychain, keyed per
//  account. Replaces the old single-config SettingsManager.
//

import Foundation
import Security

// MARK: - Models

/// A reusable set of credentials for one S3-compatible provider login.
/// Transfer fields are optional so existing stored JSON decodes unchanged;
/// nil means "use the app default".
struct Account: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var region: String = "us-east-1"
    var endpoint: String = ""   // "" for AWS, custom URL for R2/MinIO/etc.
    var uploadCapMBps: Double? = nil      // nil/0 = unlimited
    var downloadCapMBps: Double? = nil    // nil/0 = unlimited
    var maxConcurrentParts: Int? = nil    // nil = default (4)
}

enum LinkMode: String, Codable, CaseIterable, Identifiable {
    case publicUrl
    case presigned
    var id: String { rawValue }
}

/// A bucket + path + options. References an Account for its credentials.
struct Destination: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var accountId: UUID
    var bucket: String = ""
    var pathPrefix: String = ""        // "" or "backups/" (normalized on save)
    var publicUrlBase: String = ""
    var namingTemplate: String = NamingTemplate.default
    var makePublic: Bool = true        // x-amz-acl: public-read on upload
    var linkMode: LinkMode = .publicUrl
    var presignExpirySeconds: Int = 86_400  // used when linkMode == .presigned
    var copyOnUpload: Bool = true      // auto-copy resulting link after upload
    var sortOrder: Int = 0
    // Optional overrides of the account's transfer settings (nil = inherit).
    var uploadCapMBps: Double? = nil
    var downloadCapMBps: Double? = nil
    var maxConcurrentParts: Int? = nil
}

enum RecentScope: String, Codable, CaseIterable, Identifiable {
    case perDestination
    case combined
    var id: String { rawValue }
}

/// Fully-resolved config handed to S3Service so it never reads any singleton.
struct S3Config {
    let accessKeyId: String
    let secretAccessKey: String
    let region: String
    let endpoint: String
    let bucket: String
    let pathPrefix: String
    let publicUrlBase: String
    let namingTemplate: String
    let makePublic: Bool
    let linkMode: LinkMode
    let presignExpirySeconds: Int
    let copyOnUpload: Bool
    // Resolved transfer settings (destination override ?? account ?? default).
    let uploadCapMBps: Double      // 0 = unlimited
    let downloadCapMBps: Double    // 0 = unlimited
    let maxConcurrentParts: Int
}

extension S3Config {
    nonisolated static let defaultConcurrentParts = 4

    nonisolated static func resolveConcurrency(_ value: Int?) -> Int {
        min(max(value ?? defaultConcurrentParts, 1), 16)
    }
}

// MARK: - Store

@Observable
final class ConfigStore {
    static let shared = ConfigStore()

    private let defaults = UserDefaults.standard
    private let keychainService = "com.cjwr.ShareMaster"

    private enum Keys {
        static let accounts = "config_accounts"
        static let destinations = "config_destinations"
        static let recentScope = "config_recent_scope"
        static let pinPopover = "config_pin_popover"
        static let recentLimit = "config_recent_limit"
        static let recentsExpanded = "config_recents_expanded"
        static let lastSelectedDestination = "config_last_selected_destination"
    }

    private(set) var accounts: [Account] = [] {
        didSet { persist(accounts, key: Keys.accounts) }
    }
    private(set) var destinations: [Destination] = [] {
        didSet { persist(destinations, key: Keys.destinations) }
    }
    var recentScope: RecentScope = .perDestination {
        didSet { defaults.set(recentScope.rawValue, forKey: Keys.recentScope) }
    }

    /// When true the popover stays open while other apps have focus
    /// (semitransient). Default false: it closes as soon as focus moves away.
    var pinPopover: Bool = false {
        didSet { defaults.set(pinPopover, forKey: Keys.pinPopover) }
    }

    /// How many recent uploads to show per listing. Keeps list traffic and
    /// per-object link resolution down on metered providers.
    var recentLimit: Int = 5 {
        didSet { defaults.set(recentLimit, forKey: Keys.recentLimit) }
    }

    /// Whether the Recent Uploads section is expanded in the popover.
    /// Collapsed (default) skips listing entirely until the user opens it.
    var recentsExpanded: Bool = false {
        didSet { defaults.set(recentsExpanded, forKey: Keys.recentsExpanded) }
    }

    /// Remembered across popover teardowns (the content view is released a
    /// minute after the popover closes to keep idle memory low).
    var lastSelectedDestinationID: UUID? {
        didSet { defaults.set(lastSelectedDestinationID?.uuidString, forKey: Keys.lastSelectedDestination) }
    }

    var isConfigured: Bool { !destinations.isEmpty }

    private init() {
        accounts = load([Account].self, key: Keys.accounts) ?? []
        destinations = load([Destination].self, key: Keys.destinations) ?? []
        if let raw = defaults.string(forKey: Keys.recentScope),
           let scope = RecentScope(rawValue: raw) {
            recentScope = scope
        }
        pinPopover = defaults.bool(forKey: Keys.pinPopover)
        let storedLimit = defaults.integer(forKey: Keys.recentLimit)
        if storedLimit > 0 { recentLimit = storedLimit }
        recentsExpanded = defaults.bool(forKey: Keys.recentsExpanded)
        if let raw = defaults.string(forKey: Keys.lastSelectedDestination) {
            lastSelectedDestinationID = UUID(uuidString: raw)
        }
        migrateLegacyConfigIfNeeded()
    }

    // MARK: - Queries

    func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    var sortedDestinations: [Destination] {
        destinations.sorted { $0.sortOrder < $1.sortOrder }
    }

    func destinationsUsing(accountId: UUID) -> [Destination] {
        destinations.filter { $0.accountId == accountId }
    }

    /// Builds a fully-resolved config for a destination, pulling the account's
    /// secrets from the Keychain. Returns nil if the account is missing.
    func s3Config(for destination: Destination) -> S3Config? {
        guard let account = account(id: destination.accountId) else { return nil }
        let accessKeyId = keychainGet(key: accessKeyIdKey(account.id)) ?? ""
        let secret = keychainGet(key: secretKey(account.id)) ?? ""
        return S3Config(
            accessKeyId: accessKeyId,
            secretAccessKey: secret,
            region: account.region.isEmpty ? "us-east-1" : account.region,
            endpoint: account.endpoint,
            bucket: destination.bucket,
            pathPrefix: normalizePrefix(destination.pathPrefix),
            publicUrlBase: destination.publicUrlBase,
            namingTemplate: destination.namingTemplate.isEmpty ? NamingTemplate.default : destination.namingTemplate,
            makePublic: destination.makePublic,
            linkMode: destination.linkMode,
            presignExpirySeconds: destination.presignExpirySeconds,
            copyOnUpload: destination.copyOnUpload,
            uploadCapMBps: destination.uploadCapMBps ?? account.uploadCapMBps ?? 0,
            downloadCapMBps: destination.downloadCapMBps ?? account.downloadCapMBps ?? 0,
            maxConcurrentParts: S3Config.resolveConcurrency(destination.maxConcurrentParts ?? account.maxConcurrentParts)
        )
    }

    /// A config for an account without a specific destination — used to test
    /// credentials against a given bucket.
    func testConfig(account: Account, accessKeyId: String, secret: String, bucket: String) -> S3Config {
        S3Config(
            accessKeyId: accessKeyId,
            secretAccessKey: secret,
            region: account.region.isEmpty ? "us-east-1" : account.region,
            endpoint: account.endpoint,
            bucket: bucket,
            pathPrefix: "",
            publicUrlBase: "",
            namingTemplate: NamingTemplate.default,
            makePublic: false,
            linkMode: .publicUrl,
            presignExpirySeconds: 86_400,
            copyOnUpload: false,
            uploadCapMBps: 0,
            downloadCapMBps: 0,
            maxConcurrentParts: S3Config.defaultConcurrentParts
        )
    }

    // MARK: - Account mutations

    /// Adds or updates an account. Secrets, when provided, are written to the
    /// Keychain (pass nil to leave an existing secret untouched on edit).
    func upsertAccount(_ account: Account, accessKeyId: String?, secret: String?) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        if let accessKeyId { keychainSet(key: accessKeyIdKey(account.id), value: accessKeyId) }
        if let secret { keychainSet(key: secretKey(account.id), value: secret) }
    }

    func accessKeyId(for accountId: UUID) -> String {
        keychainGet(key: accessKeyIdKey(accountId)) ?? ""
    }

    func secret(for accountId: UUID) -> String {
        keychainGet(key: secretKey(accountId)) ?? ""
    }

    /// Deletes an account only if no destinations reference it.
    @discardableResult
    func deleteAccount(id: UUID) -> Bool {
        guard destinationsUsing(accountId: id).isEmpty else { return false }
        accounts.removeAll { $0.id == id }
        keychainDelete(key: accessKeyIdKey(id))
        keychainDelete(key: secretKey(id))
        return true
    }

    // MARK: - Destination mutations

    func upsertDestination(_ destination: Destination) {
        var dest = destination
        dest.pathPrefix = normalizePrefix(dest.pathPrefix)
        if let idx = destinations.firstIndex(where: { $0.id == dest.id }) {
            destinations[idx] = dest
        } else {
            if dest.sortOrder == 0 {
                dest.sortOrder = (destinations.map(\.sortOrder).max() ?? 0) + 1
            }
            destinations.append(dest)
        }
    }

    func deleteDestination(id: UUID) {
        destinations.removeAll { $0.id == id }
    }

    // MARK: - Helpers

    private func normalizePrefix(_ prefix: String) -> String {
        var p = prefix.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { return "" }
        if !p.hasSuffix("/") { p += "/" }
        return p
    }

    private func accessKeyIdKey(_ id: UUID) -> String { "account_\(id.uuidString)_accessKeyId" }
    private func secretKey(_ id: UUID) -> String { "account_\(id.uuidString)_secret" }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Legacy migration

    /// Migrates the old single-config setup (SettingsManager) into one Account
    /// + one Destination so existing users keep working after the update.
    private func migrateLegacyConfigIfNeeded() {
        guard accounts.isEmpty && destinations.isEmpty else { return }

        let legacyAccessKey = keychainGet(key: "s3_access_key_id") ?? ""
        let legacySecret = keychainGet(key: "s3_secret_access_key") ?? ""
        let legacyBucket = defaults.string(forKey: "s3_bucket") ?? ""
        let legacyRegion = defaults.string(forKey: "s3_region") ?? "us-east-1"
        let legacyEndpoint = defaults.string(forKey: "s3_endpoint") ?? ""
        let legacyPublicBase = defaults.string(forKey: "s3_public_url_base") ?? ""

        guard !legacyAccessKey.isEmpty, !legacySecret.isEmpty, !legacyBucket.isEmpty else { return }

        let account = Account(name: "Default", region: legacyRegion, endpoint: legacyEndpoint)
        upsertAccount(account, accessKeyId: legacyAccessKey, secret: legacySecret)

        var destination = Destination(name: "Default", accountId: account.id)
        destination.bucket = legacyBucket
        destination.publicUrlBase = legacyPublicBase
        destination.sortOrder = 1
        upsertDestination(destination)
    }

    // MARK: - Keychain

    private func keychainSet(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
        var newQuery = query
        newQuery[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(newQuery as CFDictionary, nil)
    }

    private func keychainGet(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }
}
