import CloudKit
import Foundation
import Network
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// This device as an arcade cabinet: an ID of its own and a name the user
/// picks. Each game's saved settings (the board's EEPROM and backup RAM,
/// which hold the cabinet's link role as well as its records) are backed up
/// to iCloud under this cabinet, never shared with the others, so linked
/// cabinets keep their roles. On iOS and tvOS the ID lives in the Keychain,
/// which outlives Caches being cleared and usually the app being deleted;
/// on macOS in the app's preferences.
enum Cabinet {
    // The Keychain item's name, not the bundle ID: kept as it is for every
    // build, or devices would lose their cabinet ID.
    private static let service = "com.thebrinkoftomorrow.arcadefoundry.insertcoin.cabinet"
    private static let nameKey = "cabinetName"

    /// Whether this launch made a new ID (a new device, or one that lost
    /// its own): the app then offers to continue as a cabinet in iCloud.
    private(set) static var isNew = false

    /// A second (third, ...) cabinet on the same Mac, for testing links on
    /// one machine: the Game Director opens extra copies of Game Cabinet
    /// with `-cabinetInstance <n>` (2 and up). Each copy is its own cabinet:
    /// an ID and name of its own, its own folder (`Storage.root`) and its
    /// own link settings. Nil for the usual single copy. Mac only.
    static let instance: Int? = {
        #if os(macOS)
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let v = args["cabinetInstance"]
        let n = (v as? Int) ?? (v as? String).flatMap { Int($0) }
        return n.flatMap { $0 > 1 ? $0 : nil }
        #else
        return nil
        #endif
    }()

    static var id: String {
        let base: String
        if let id = stored() {
            base = id
        } else {
            base = UUID().uuidString
            store(base)
            isNew = true
        }
        return instance.map { "\(base)-\($0)" } ?? base
    }

    static var name: String {
        get {
            if let n = instance { return UserDefaults.standard.string(forKey: "\(nameKey).\(n)") ?? "\(model) #\(n)" }
            return UserDefaults.standard.string(forKey: nameKey) ?? model
        }
        set { UserDefaults.standard.set(newValue, forKey: instance.map { "\(nameKey).\($0)" } ?? nameKey) }
    }

    /// The kind of device, the default name.
    static var model: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(tvOS)
        return "Apple TV"
        #else
        return UIDevice.current.model // "iPhone", "iPad"
        #endif
    }

    /// Takes a new ID of its own: leaves the cabinet it shared with another
    /// device (after a transfer), keeping its name and saves.
    static func renew() {
        store(UUID().uuidString)
        isNew = false
    }

    /// Becomes another cabinet (one this device replaces): its ID and name.
    static func adopt(id: String, name: String) {
        store(id)
        self.name = name
        isNew = false
    }

    #if os(macOS)
    private static func stored() -> String? { UserDefaults.standard.string(forKey: service) }
    private static func store(_ id: String) { UserDefaults.standard.set(id, forKey: service) }
    #else
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "id",
         kSecAttrSynchronizable as String: false] // this device's own, not shared through iCloud Keychain
    }

    private static func stored() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func store(_ id: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(id.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    #endif
}

/// The cabinets' saves in iCloud (CloudKit, the app's private database, in
/// a zone of its own): a Cabinet record per cabinet (name, model, last
/// seen) and a Save record per cabinet and game (its save files, when).
/// Everything here fails quietly without iCloud: the saves stay on the
/// device as before.
enum SaveSync {
    /// iCloud.<bundle ID>, as in the entitlements (APP_BUNDLE_ID in Signing.xcconfig).
    static let containerID = "iCloud." + (Bundle.main.bundleIdentifier ?? "com.thebrinkoftomorrow.arcadefoundry.insertcoin")
    /// Nil when the app isn't signed for CloudKit in that container: an
    /// ad hoc or unsigned build, or a team without iCloud. CKContainer traps
    /// (EXC_BREAKPOINT) then instead of failing, so it is only made when
    /// the entitlements allow it (IC-Kit #7).
    static let container: CKContainer? = Entitlements.cloudKit(containerID) ? CKContainer(identifier: containerID) : nil
    private struct NoICloud: Error {}
    private static var db: CKDatabase {
        get throws {
            guard let container else { throw NoICloud() }
            return container.privateCloudDatabase
        }
    }
    private static let zone = CKRecordZone.ID(zoneName: "Cabinets", ownerName: CKCurrentUserDefaultName)
    private static var zoneReady = false

    struct CabinetInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let model: String
        let lastSeen: Date?
        var games: [String: Date] // romset: saved
    }

    static func available() async -> Bool {
        // A test copy (instance) stays out of iCloud: it is not a cabinet anyone keeps.
        guard Cabinet.instance == nil, let container else { return false }
        return (try? await container.accountStatus()) == .available
    }

    private static func ensureZone() async throws {
        if zoneReady { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        zoneReady = true
    }

    private static func cabinetID(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName: "cabinet.\(id)", zoneID: zone) }
    private static func saveID(_ cabinet: String, _ romset: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "save.\(cabinet).\(romset)", zoneID: zone)
    }

    private static func put(_ record: CKRecord) async throws {
        let (results, _) = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        if case .failure(let e)? = results[record.recordID] { throw e }
    }

    /// Records this cabinet (its name, that it was seen now).
    static func announce() async {
        guard await available() else { return }
        do {
            try await ensureZone()
            let r = CKRecord(recordType: "Cabinet", recordID: cabinetID(Cabinet.id))
            r["name"] = Cabinet.name
            r["model"] = Cabinet.model
            r["lastSeen"] = Date()
            try await put(r)
        } catch {
            print("SaveSync: announce: \(error)")
        }
    }

    /// Backs up this cabinet's save files for `romset` (after the core has
    /// written them), dated when the game was played (the newest file). It
    /// stays pending until it reaches iCloud (see `retryPending`), and never
    /// replaces a backup played later on another device sharing this
    /// cabinet, unless `force`.
    static func upload(_ romset: String, force: Bool = false) async {
        let files = readFiles(Storage.saves(romset))
        guard !files.isEmpty else { return }
        setPending(romset, true)
        guard await available() else { return }
        do {
            try await ensureZone()
            let id = saveID(Cabinet.id, romset)
            let played = playedAt(romset) ?? Date()
            if !force, let saved = try await savedAt(id), saved >= played {
                setPending(romset, false)
                return
            }
            let r = CKRecord(recordType: "Save", recordID: id)
            r["cabinet"] = Cabinet.id
            r["romset"] = romset
            r["files"] = try PropertyListEncoder().encode(files)
            r["saved"] = played
            try await put(r)
            setPending(romset, false)
        } catch {
            print("SaveSync: upload \(romset): \(error)")
        }
    }

    /// Before a game starts: a pending backup of this device's save goes up
    /// first, then this cabinet's backup comes down when it was played later
    /// than this device's save (on another device sharing the cabinet, or
    /// this one lost its saves). Gives up after a few seconds offline: the
    /// game then starts from this device's save.
    static func sync(_ romset: String) async {
        await withTimeout(seconds: 6) {
            if isPending(romset) { await upload(romset) }
            guard let saved = try? await savedAt(saveID(Cabinet.id, romset)) else { return }
            if let played = playedAt(romset), played >= saved { return }
            _ = try? await download(cabinet: Cabinet.id, romset: romset)
        }
    }

    // MARK: Pending backups

    private static let pendingKey = "SaveSync.pending"
    private static let pendingLock = NSLock()
    private static let network = NWPathMonitor()

    /// Retries the pending backups whenever the network comes back (and once
    /// as the app starts). Nothing runs while none are pending.
    static func start() {
        network.pathUpdateHandler = { path in
            if path.status == .satisfied { Task { await retryPending() } }
        }
        network.start(queue: DispatchQueue(label: "SaveSync.network"))
    }

    /// Uploads the backups that didn't reach iCloud when their game ended.
    static func retryPending() async {
        for romset in pendingList() { await upload(romset) }
        for romset in pendingResumes() { await uploadResume(romset) }
    }

    private static func pendingList() -> [String] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return UserDefaults.standard.stringArray(forKey: pendingKey) ?? []
    }

    private static func isPending(_ romset: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return UserDefaults.standard.stringArray(forKey: pendingKey)?.contains(romset) ?? false
    }

    private static func setPending(_ romset: String, _ pending: Bool) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        var set = Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? [])
        if pending { set.insert(romset) } else { set.remove(romset) }
        UserDefaults.standard.set(set.sorted(), forKey: pendingKey)
    }

    /// When this device last played `romset`: its newest save file's date.
    private static func playedAt(_ romset: String) -> Date? {
        let dir = Storage.saves(romset)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap {
            try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.modificationDate] as? Date
        }.max()
    }

    /// When the backup `id` was played, or nil when there is none.
    private static func savedAt(_ id: CKRecord.ID) async throws -> Date? {
        let results = try await db.records(for: [id], desiredKeys: ["saved"])
        switch results[id] {
        case .success(let r)?:
            return r["saved"] as? Date
        case .failure(let e as CKError)? where e.code == .unknownItem || e.code == .zoneNotFound:
            return nil
        case .failure(let e)?:
            throw e
        case nil:
            return nil
        }
    }

    /// Writes cabinet `cabinet`'s saves for `romset` over this device's.
    /// Returns false when it has none.
    @discardableResult
    static func download(cabinet: String, romset: String) async throws -> Bool {
        let r: CKRecord
        do {
            r = try await db.record(for: saveID(cabinet, romset))
        } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
            return false
        }
        guard let data = r["files"] as? Data else { return false }
        let files = try PropertyListDecoder().decode([String: Data].self, from: data)
        let dir = Storage.saves(romset)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Dated when the backup was played, so this device's save counts as
        // that session, not a newer one.
        let saved = r["saved"] as? Date
        for (name, bytes) in files where !name.contains("/") {
            let url = dir.appendingPathComponent(name)
            try bytes.write(to: url, options: .atomic)
            if let saved { try? FileManager.default.setAttributes([.modificationDate: saved], ofItemAtPath: url.path) }
        }
        setPending(romset, false) // this device's own session, if not backed up, is replaced
        return true
    }

    /// Every cabinet in iCloud, with the games it has saves for.
    static func cabinets() async throws -> [CabinetInfo] {
        try await ensureZone()
        var found: [String: CabinetInfo] = [:]
        var saves: [(String, String, Date)] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: token,
                                                         desiredKeys: ["name", "model", "lastSeen", "cabinet", "romset", "saved"])
            for case .success(let m) in changes.modificationResultsByID.values {
                let r = m.record
                if r.recordType == "Cabinet" {
                    let id = String(r.recordID.recordName.dropFirst("cabinet.".count))
                    found[id] = CabinetInfo(id: id, name: r["name"] as? String ?? "Cabinet", model: r["model"] as? String ?? "",
                                            lastSeen: r["lastSeen"] as? Date, games: [:])
                } else if r.recordType == "Save", let c = r["cabinet"] as? String, let s = r["romset"] as? String {
                    saves.append((c, s, r["saved"] as? Date ?? .distantPast))
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        for (c, s, d) in saves { found[c]?.games[s] = d }
        return found.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    /// Takes over another cabinet (this device replaces it): its ID, name
    /// and every save it has, over this device's.
    static func adopt(_ other: CabinetInfo) async throws {
        Cabinet.adopt(id: other.id, name: other.name)
        await MainActor.run { LinkDiscovery.shared.advertise() }
        for romset in other.games.keys {
            try await download(cabinet: other.id, romset: romset)
        }
        await announce()
    }

    /// Makes this device a cabinet of its own (Cabinet.renew), records it,
    /// and backs up every game save it has under the new ID. The cabinet it
    /// left keeps its backups for the other device.
    static func becomeNew() async {
        Cabinet.renew()
        await MainActor.run { LinkDiscovery.shared.advertise() }
        await announce()
        for game in GameInfo.all where !readFiles(Storage.saves(game.id)).isEmpty {
            await upload(game.id)
        }
    }

    /// Copies one game's save from another cabinet to this one (its link
    /// role comes with it), and backs it up as this cabinet's.
    static func copy(_ romset: String, from other: CabinetInfo) async throws {
        try await download(cabinet: other.id, romset: romset)
        await upload(romset, force: true)
    }

    /// Deletes a cabinet and its saves from iCloud.
    static func delete(_ other: CabinetInfo) async throws {
        let ids = [cabinetID(other.id)] + other.games.keys.flatMap { [saveID(other.id, $0), resumeID(other.id, $0)] }
        _ = try await db.modifyRecords(saving: [], deleting: ids)
    }

    private static func readFiles(_ dir: URL) -> [String: Data] {
        let fm = FileManager.default
        var out: [String: Data] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
            if let d = fm.contents(atPath: dir.appendingPathComponent(name).path) { out[name] = d }
        }
        return out
    }

    private static func withTimeout(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            await group.next()
            group.cancelAll()
        }
    }
}

// MARK: The Resume slot (SaveStates)

/// A game's Resume slot goes to iCloud as this cabinet's "Resume" record
/// (cabinet and romset, core version, saved date, the state and its picture
/// as CKAssets: a state is bigger than a record's 1 MB), next to its "Save"
/// record and by the same rules: pending until it reaches iCloud, never
/// replacing one saved later, fetched before the game's page offers Resume.
/// So a game left on the iPad resumes on the Apple TV sharing the cabinet.
/// The three manual slots stay on the device.
extension SaveSync {
    fileprivate static func resumeID(_ cabinet: String, _ romset: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "resume.\(cabinet).\(romset)", zoneID: zone)
    }

    private static let pendingResumeKey = "SaveSync.pendingResume"

    fileprivate static func pendingResumes() -> [String] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return UserDefaults.standard.stringArray(forKey: pendingResumeKey) ?? []
    }

    private static func setResumePending(_ romset: String, _ pending: Bool) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        var set = Set(UserDefaults.standard.stringArray(forKey: pendingResumeKey) ?? [])
        if pending { set.insert(romset) } else { set.remove(romset) }
        UserDefaults.standard.set(set.sorted(), forKey: pendingResumeKey)
    }

    /// The Resume record's saved date, or nil when there is none.
    private static func resumeSavedAt(_ romset: String) async throws -> Date? {
        let id = resumeID(Cabinet.id, romset)
        let results = try await db.records(for: [id], desiredKeys: ["saved"])
        switch results[id] {
        case .success(let r)?: return r["saved"] as? Date
        case .failure(let e as CKError)? where e.code == .unknownItem || e.code == .zoneNotFound: return nil
        case .failure(let e)?: throw e
        case nil: return nil
        }
    }

    /// After the Resume slot was written (or removed: played from power-on):
    /// up to iCloud, or the cabinet's record deleted when this device has
    /// played on past it.
    static func uploadResume(_ romset: String) async {
        guard SaveStates.resumeOn else { return }
        setResumePending(romset, true)
        guard await available() else { return }
        do {
            try await ensureZone()
            let id = resumeID(Cabinet.id, romset)
            let remote = try await resumeSavedAt(romset)
            if let local = SaveStates.slot(romset, 0) {
                if let remote, remote >= local.date { return setResumePending(romset, false) }
                let r = CKRecord(recordType: "Resume", recordID: id)
                r["cabinet"] = Cabinet.id
                r["romset"] = romset
                r["coreVersion"] = local.coreVersion
                r["saved"] = local.date
                r["info"] = try Data(contentsOf: SaveStates.file(romset, 0, "json"))
                r["state"] = CKAsset(fileURL: SaveStates.file(romset, 0, "afstate"))
                let picture = SaveStates.file(romset, 0, "png")
                if FileManager.default.fileExists(atPath: picture.path) { r["picture"] = CKAsset(fileURL: picture) }
                try await put(r)
            } else if let remote, remote < (playedAt(romset) ?? Date()) {
                _ = try await db.modifyRecords(saving: [], deleting: [id])
            }
            setResumePending(romset, false)
        } catch {
            print("SaveSync: Resume \(romset): \(error)")
        }
    }

    /// Before the game's page offers Resume: a pending upload goes first,
    /// then the cabinet's Resume slot comes down when it is newer than this
    /// device's (left on another device sharing the cabinet). Gives up after
    /// a few seconds offline. True when a slot came down.
    @discardableResult
    static func syncResume(_ romset: String) async -> Bool {
        guard SaveStates.resumeOn else { return false }
        final class Got: @unchecked Sendable { var value = false }
        let got = Got()
        await withTimeout(seconds: 6) {
            guard await available() else { return }
            if pendingResumes().contains(romset) { await uploadResume(romset) }
            guard let remote = try? await resumeSavedAt(romset) else { return }
            if let local = SaveStates.slot(romset, 0), local.date >= remote { return }
            // Played from power-on here since then: that one is gone for good.
            if SaveStates.slot(romset, 0) == nil, let played = playedAt(romset), played > remote { return }
            got.value = (try? await downloadResume(romset)) ?? false
        }
        return got.value
    }

    private static func downloadResume(_ romset: String) async throws -> Bool {
        let r = try await db.record(for: resumeID(Cabinet.id, romset))
        guard let state = (r["state"] as? CKAsset)?.fileURL, let info = r["info"] as? Data else { return false }
        let fm = FileManager.default
        try fm.createDirectory(at: SaveStates.folder(romset), withIntermediateDirectories: true)
        try Data(contentsOf: state).write(to: SaveStates.file(romset, 0, "afstate"), options: .atomic)
        if let picture = (r["picture"] as? CKAsset)?.fileURL {
            try? Data(contentsOf: picture).write(to: SaveStates.file(romset, 0, "png"), options: .atomic)
        }
        try info.write(to: SaveStates.file(romset, 0, "json"), options: .atomic)
        return true
    }
}

