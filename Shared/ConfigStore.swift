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
    /// Where downloads land (nil = .downloads, or .custom when a bookmark was
    /// saved before this field existed). Option-clicking the download button
    /// always shows a save panel regardless of this setting.
    var downloadLocation: DownloadLocation? = nil
    /// Security-scoped bookmark of the custom download folder. Stored as a
    /// bookmark because the app is sandboxed.
    var downloadDirBookmark: Data? = nil

    nonisolated var effectiveDownloadLocation: DownloadLocation {
        downloadLocation ?? (downloadDirBookmark != nil ? .custom : .downloads)
    }
}

enum RecentScope: String, Codable, CaseIterable, Identifiable {
    case perDestination
    case combined
    var id: String { rawValue }
}

enum DownloadLocation: String, Codable {
    case downloads   // the user's Downloads folder
    case custom      // the folder in downloadDirBookmark
    case ask         // save panel on every download
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

    /// App Group shared between the iOS app and its share extension so both
    /// see the same accounts/destinations. Unused on macOS.
    nonisolated static let appGroupID = "group.com.cjwr.ShareMaster"

    /// Keychain access group shared by the Mac app, iOS app and extension
    /// (same team). Items here are kSecAttrSynchronizable, so iCloud Keychain
    /// carries the credentials between devices. Must match the
    /// $(AppIdentifierPrefix)-prefixed group in every target's entitlements.
    nonisolated static let syncKeychainGroup = "HU9TH52NNC.com.cjwr.ShareMaster.sync"

    #if os(iOS)
    private let defaults = UserDefaults(suiteName: ConfigStore.appGroupID) ?? .standard
    #else
    private let defaults = UserDefaults.standard
    #endif
    private let keychainService = "com.cjwr.ShareMaster"

    private enum Keys {
        static let accounts = "config_accounts"
        static let destinations = "config_destinations"
        static let recentScope = "config_recent_scope"
        static let pinPopover = "config_pin_popover"
        static let recentLimit = "config_recent_limit"
        static let recentsExpanded = "config_recents_expanded"
        static let lastSelectedDestination = "config_last_selected_destination"
        static let cloudUpdatedAt = "config_cloud_updated_at"
    }

    private(set) var accounts: [Account] = [] {
        didSet {
            persist(accounts, key: Keys.accounts)
            if !isAdoptingCloud { pushToCloud() }
        }
    }
    private(set) var destinations: [Destination] = [] {
        didSet {
            persist(destinations, key: Keys.destinations)
            if !isAdoptingCloud { pushToCloud() }
        }
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
        startCloudSync()
    }

    // MARK: - iCloud sync (via iCloud Keychain)

    /// The whole config (accounts + destinations + timestamp) syncs between
    /// devices as ONE synchronizable keychain item, alongside the per-account
    /// secret items. iCloud Keychain is the only sync channel available to a
    /// personal (free) developer team — KVS/CloudKit require a paid account.
    /// The keychain posts no change notifications, so callers re-check via
    /// refreshFromCloud() on launch and when coming to the foreground.
    private var isAdoptingCloud = false
    private static let cloudPayloadKey = "cloud_config_payload"

    private struct CloudPayload: Codable {
        var accounts: [Account]
        var destinations: [Destination]
        var updatedAt: Double
    }

    /// Timestamp of the cloud payload this device last wrote or adopted.
    private var localUpdatedAt: Double {
        get { defaults.double(forKey: Keys.cloudUpdatedAt) }
        set { defaults.set(newValue, forKey: Keys.cloudUpdatedAt) }
    }

    private func startCloudSync() {
        // Force-read every account's secrets: keychainGet upgrades legacy
        // (device-local) items into the synchronizable group as a side
        // effect, so a device configured before sync existed publishes its
        // credentials at launch instead of waiting for a lazy read.
        for account in accounts {
            _ = keychainGet(key: accessKeyIdKey(account.id))
            _ = keychainGet(key: secretKey(account.id))
        }
        adoptCloudIfNewer()
        // Seed the cloud from a device that was configured before sync existed.
        if keychainGet(key: Self.cloudPayloadKey) == nil,
           !accounts.isEmpty || !destinations.isEmpty {
            pushToCloud()
        }
    }

    /// Adopts remote changes if another device has pushed a newer config.
    /// Call when the UI (re)appears; cheap when nothing changed.
    func refreshFromCloud() {
        adoptCloudIfNewer()
    }

    private func pushToCloud() {
        let payload = CloudPayload(
            accounts: accounts,
            destinations: destinations,
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return }
        localUpdatedAt = payload.updatedAt
        keychainSet(key: Self.cloudPayloadKey, value: json)
    }

    private func adoptCloudIfNewer() {
        guard let json = keychainGet(key: Self.cloudPayloadKey),
              let payload = try? JSONDecoder().decode(CloudPayload.self, from: Data(json.utf8)),
              payload.updatedAt > localUpdatedAt
        else { return }
        isAdoptingCloud = true
        accounts = payload.accounts
        destinations = payload.destinations
        isAdoptingCloud = false
        localUpdatedAt = payload.updatedAt
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

    #if os(macOS)
    /// Resolves a destination's download folder. Returns the URL plus whether
    /// it is security-scoped (caller must start/stop accessing around use).
    nonisolated static func downloadDirectory(for destination: Destination) -> (url: URL, isScoped: Bool) {
        if destination.effectiveDownloadLocation == .custom,
           let data = destination.downloadDirBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return (url, true)
            }
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return (downloads, false)
    }
    #endif

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

    /// Base query for the current storage: synchronizable items in the shared
    /// access group, so iCloud Keychain syncs the credentials across devices
    /// and every target (Mac app, iOS app, share extension) reads them.
    private func keychainBaseQuery(key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: Self.syncKeychainGroup,
            kSecAttrSynchronizable as String: true
        ]
        #if os(macOS)
        // Synchronizable items require the data-protection (iOS-style)
        // keychain on macOS.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// Where secrets lived before iCloud sync: the default (login) keychain on
    /// macOS, the App Group access group on iOS.
    private func legacyKeychainQuery(key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService
        ]
        #if os(iOS)
        query[kSecAttrAccessGroup as String] = Self.appGroupID
        #endif
        return query
    }

    private func keychainSet(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query = keychainBaseQuery(key: key)
        SecItemDelete(query as CFDictionary)
        var newQuery = query
        newQuery[kSecValueData as String] = data
        // AfterFirstUnlock (the strictest level synchronizable items support)
        // keeps secrets readable by the share extension right after a
        // screenshot, even from the lock screen.
        newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(newQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Build isn't provisioned for the sync group (e.g. ad-hoc/dev
            // signing) — fall back to a device-local item so nothing is lost.
            var legacy = legacyKeychainQuery(key: key)
            SecItemDelete(legacy as CFDictionary)
            legacy[kSecValueData as String] = data
            SecItemAdd(legacy as CFDictionary, nil)
        }
    }

    private func keychainGet(key: String) -> String? {
        var query = keychainBaseQuery(key: key)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        // Pre-sync item: read the old location and upgrade it in place.
        var legacy = legacyKeychainQuery(key: key)
        legacy[kSecReturnData as String] = true
        var legacyResult: AnyObject?
        guard SecItemCopyMatching(legacy as CFDictionary, &legacyResult) == errSecSuccess,
              let data = legacyResult as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        keychainSet(key: key, value: value)
        return value
    }

    private func keychainDelete(key: String) {
        SecItemDelete(keychainBaseQuery(key: key) as CFDictionary)
        SecItemDelete(legacyKeychainQuery(key: key) as CFDictionary)
    }
}
