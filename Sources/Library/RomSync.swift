import Foundation

/// ROM sets in the app's iCloud Drive folder (iCloud Drive > Arcade Foundry),
/// which every Mac, iPhone and iPad signed in to the same Apple Account
/// sees. A set added on one device shows up on the others and downloads
/// when it is played. A Lindbergh game is in it as <set>.tar. Apple TV has
/// no iCloud Drive: it uses the ROM server.
final class CloudROMs: ObservableObject, @unchecked Sendable { // its state changes on the main thread only
    static let shared = CloudROMs()

    struct Item {
        let url: URL
        let downloaded: Bool
        let downloading: Bool
    }

    /// The iCloud Drive folder, or nil without iCloud Drive (signed out,
    /// iCloud Drive off for the app, or tvOS).
    @Published private(set) var folder: URL?
    /// The ROM sets in it, by set.
    @Published private(set) var items: [String: Item] = [:]
    private var query: NSMetadataQuery?
    private var identityObserver: NSObjectProtocol?
    private var queryObservers: [NSObjectProtocol] = []

    /// Finds the iCloud container and starts watching it. Again when the
    /// user signs in or out of iCloud.
    @MainActor func start() {
        #if !os(tvOS)
        guard identityObserver == nil else { return }
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.locate() }
        }
        locate()
        #endif
    }

    @MainActor private func locate() {
        Task.detached(priority: .utility) {
            // Can take a while the first time (it sets the container up).
            let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            await self.attach(container)
        }
    }

    @MainActor private func attach(_ container: URL?) {
        query?.stop()
        query = nil
        queryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        queryObservers = []
        items = [:]
        guard let container else {
            folder = nil
            return
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        folder = documents

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE[c] '*.zip' OR %K LIKE[c] '*.7z' OR %K LIKE[c] '*.tar'",
                                NSMetadataItemFSNameKey, NSMetadataItemFSNameKey, NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            })
        }
        query = q
        q.start()
    }

    @MainActor private func update() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        var found: [String: Item] = [:]
        for case let item as NSMetadataItem in q.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let set = Storage.romset(of: url) else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let downloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            found[set] = Item(url: url,
                              downloaded: status == NSMetadataUbiquitousItemDownloadingStatusCurrent || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded,
                              downloading: downloading)
        }
        items = found
    }

    /// The ROM set's file on this device, downloaded from iCloud first if
    /// it is not here yet (a coordinated read waits for the download).
    static func download(_ url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var coordinationError: NSError?
            var local = url
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { local = $0 }
            if let coordinationError { throw coordinationError }
            return local
        }.value
    }

    /// Copies a ROM set into the iCloud Drive folder as <set>.<ext>,
    /// replacing an older one.
    static func copy(_ source: URL, set: String, ext: String, into folder: URL) async throws {
        let dst = folder.appendingPathComponent("\(set).\(ext)")
        if source.standardizedFileURL == dst.standardizedFileURL { return } // picked from the folder itself
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges,
                                           writingItemAt: dst, options: .forReplacing, error: &coordinationError) { src, out in
                do {
                    for old in Storage.romExtensions where old != ext {
                        try? fm.removeItem(at: folder.appendingPathComponent("\(set).\(old)"))
                    }
                    if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
                    try fm.copyItem(at: src, to: out)
                } catch {
                    copyError = error
                }
            }
            if let e = coordinationError ?? copyError { throw e }
        }.value
    }

    /// Deletes a ROM set from iCloud Drive, on every device.
    static func delete(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var deleteError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { u in
                do { try FileManager.default.removeItem(at: u) } catch { deleteError = error }
            }
            if let e = coordinationError ?? deleteError { throw e }
        }.value
    }

    /// Removes the downloaded copy from this device; it stays in iCloud.
    static func evict(_ url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}

/// Settings shared by all the user's devices through iCloud (key-value
/// storage, which Apple TV has too): the ROM server address, so it is typed
/// once, not on every device.
enum SharedSettings {
    static let keys = [SettingKey.romServer]
    private static var store: NSUbiquitousKeyValueStore { .default }

    static func start() {
        NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                               object: store, queue: .main) { _ in pull() }
        store.synchronize()
        // A value set on this device before sharing existed goes up first.
        for k in keys where store.object(forKey: k) == nil {
            if let v = UserDefaults.standard.object(forKey: k) { store.set(v, forKey: k) }
        }
        pull()
    }

    static func pull() {
        for k in keys {
            if let v = store.object(forKey: k) { UserDefaults.standard.set(v, forKey: k) }
        }
    }

    static func push(_ key: String, _ value: Any) {
        store.set(value, forKey: key)
    }
}
