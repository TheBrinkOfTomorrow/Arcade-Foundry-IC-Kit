import Foundation
import UniformTypeIdentifiers

/// The arcade platforms, for the library's filter.
enum Platform: String, CaseIterable, Identifiable {
    case classic2d, model1, model2, model3, chihiro, lindbergh, pc
    var id: String { rawValue }
    var name: String {
        switch self {
        case .classic2d: "Classic 2D"
        case .model1: "Model 1"
        case .model2: "Model 2"
        case .model3: "Model 3"
        case .chihiro: "Chihiro"
        case .lindbergh: "Lindbergh"
        case .pc: "PC based" // RingWide, RingEdge, Europa-R, Sega PC, ALLS (PCGames)
        }
    }
}

/// What this release leaves out while it is untested. The code stays: take a
/// game's `hidden` out of games.toml (or turn the headset button on) to bring it back.
enum ThisRelease {
    /// Games not listed in the library (their cores, controls and saves
    /// stay): `hidden = true` in games.toml (scripts/gen_games.py).
    static let hiddenGames = GameNames.hidden
    /// The Mac's "Play in Apple Vision Pro" button: not yet played end to end.
    static let headsetButton = false
}

/// How a game is played (games.toml's controls): picks the controller
/// layout and the controls list on the game's page.
enum GameControls {
    case drive // a wheel and pedals, handlebars, or a stick and buttons that drive
    case flight // a flight stick and throttle (Star Wars Arcade, Wing War)
    case twin // two sticks, each with a shot and a dash (Virtual-On)
    case gun // a light gun
    case turret // a gun turret that draws its own sight (Gunblade NY, Behind Enemy Lines, Rail Chase 2)
    case analogGun // Model 3's light guns: no off-screen sense, so the second trigger reloads
    case fighting // a joystick and buttons: X, A, B and Y are buttons 1-4 (punch, kick, guard)
    case fishing // Sega Bass Fishing and Get Bass: the left stick is the rod, the right trigger the reel
}

/// What kind of game it is (games.toml's category): groups the game lists,
/// and tells the Game Director how a session runs (racing links one cabinet
/// per device; shooter and fighting games have two players on one board).
enum GameCategory: String, CaseIterable {
    case racing, shooter, fighting, other

    var title: String {
        switch self {
        case .racing: return "Racing"
        case .shooter: return "Shooters"
        case .fighting: return "Fighting"
        case .other: return "Other"
        }
    }

    /// The category a game's controls give it, as afgames.py's CATEGORY_OF_CONTROLS.
    init(_ controls: GameControls) {
        switch controls {
        case .drive: self = .racing
        case .gun, .turret, .analogGun: self = .shooter
        case .fighting: self = .fighting
        case .flight, .twin, .fishing: self = .other
        }
    }
}

/// The ROM sets Arcade Foundry: Insert Coin knows, one per version of a game. A version is
/// playable when this build has its core and the user has added its ROM set.
/// The list is GameInfo.catalog in GameList.swift, written from games.toml
/// (the app's and the cores') by scripts/gen_games.py.
struct GameInfo: Identifiable, Hashable {
    let id: String // the MAME ROM set
    let title: String
    let detail: String
    var platform = Platform.model2
    var controls = GameControls.drive
    var link = false // the core has link play
    var players = 1 // a second controller is player 2 when 2
    var stickY = false // the left stick's forward and back is a second analog control (afcore_input.stick_y): Ski Super G's swing, Top Skater's slide, the fishing rod
    var gunButton = false // the gun has a button besides the trigger: The House of the Dead 4's grenade, Line of Fire's missile (BUTTON3; Controls)
    /// games.toml's category where it isn't the one the controls give
    /// (gen_games.py writes it only then): Virtua Striker, Zero Gunner, Desert Tank.
    var categoryOverride: GameCategory? = nil

    var category: GameCategory { categoryOverride ?? GameCategory(controls) }

    var flight: Bool { controls == .flight }
    var twin: Bool { controls == .twin }
    var analogGun: Bool { controls == .analogGun }

    /// Aimed like a gun (the light gun and turret games): the mouse, a
    /// touch, or either stick of a controller.
    /// Let's Go Jungle!: the cabinet's big Start buttons are its action
    /// buttons during play, so X (and G, middle-click) press Start too (#404).
    var gunStart: Bool { ["letsgoju", "letsgojua", "letsgojusp"].contains(id) }
    var aimsGun: Bool { [.gun, .turret, .analogGun].contains(controls) }

    /// Gets a crosshair where a controller aims (CrosshairView): the gun
    /// games but the turrets, which draw their own sight. The game's page can
    /// turn it off.
    var showsCrosshair: Bool { aimsGun && controls != .turret }

    /// The crosshair is on until turned off, but for Let's Go Jungle, which
    /// draws its own reticle where the gun aims.
    var crosshairByDefault: Bool { !["letsgoju", "letsgojua", "letsgojusp"].contains(id) }

    /// Sega Bass Fishing and Get Bass: the left stick is the rod, the right
    /// trigger the reel, the d-pad the lure stick, X cast and A select.
    var fishing: Bool { controls == .fishing }

    /// A joystick and buttons (the fighting games, and the others played
    /// the same way): X, A, B and Y are buttons 1-4 (punch, kick, guard).
    var fighting: Bool { controls == .fighting }

    /// The games this device can run, less `ThisRelease.hiddenGames`. Apple
    /// TV has no Lindbergh games: a Lindbergh core needs a 4 GB address window
    /// (iOS's extended virtual addressing), which tvOS does not give an app.
    /// The Chihiro games need the same window, so they are on macOS and
    /// iOS/iPadOS but not Apple TV. The PC-based games (PCGames) are on the
    /// Mac only for now.
    static let all: [GameInfo] = {
        #if os(tvOS)
        catalog.filter { $0.platform != .lindbergh && $0.platform != .chihiro && $0.platform != .pc && !ThisRelease.hiddenGames.contains($0.id) }
        #elseif os(iOS)
        catalog.filter { $0.platform != .pc && !ThisRelease.hiddenGames.contains($0.id) }
        #else
        catalog.filter { !ThisRelease.hiddenGames.contains($0.id) }
        #endif
    }()

    /// The platform filter's choices: the platforms with a game in `all`, so
    /// a platform whose games are all hidden for this release has no tab.
    static let platforms: [Platform] = Platform.allCases.filter { p in all.contains { $0.platform == p } }
}

/// One card in the library: a game on one platform, with its versions
/// (Daytona USA on Model 2: daytona93 and daytona).
struct ArcadeGame: Identifiable, Hashable {
    let title: String
    let platform: Platform
    let versions: [GameInfo]
    var id: String { "\(platform.rawValue)/\(title)" }

    /// GameInfo.all grouped by title and platform, in catalog order.
    static let all: [ArcadeGame] = {
        var order: [String] = [], groups: [String: [GameInfo]] = [:]
        for game in GameInfo.all {
            let key = "\(game.platform.rawValue)/\(game.title)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(game)
        }
        return order.map { key in
            let v = groups[key]!
            return ArcadeGame(title: v[0].title, platform: v[0].platform, versions: v)
        }
    }()

    static func with(id: String) -> ArcadeGame? { all.first { $0.id == id } }

    /// The release year of its earliest version (each detail starts with it).
    var year: Int { versions.compactMap { Int($0.detail.prefix(4)) }.min() ?? 9999 }

    /// The title for A–Z: "The House of the Dead" under H.
    private var sortTitle: String { title.hasPrefix("The ") ? String(title.dropFirst(4)) : title }

    /// `games` in the library's order. Platform is Classic 2D, Model 1, Model
    /// 2, Model 3, Chihiro, Lindbergh, PC based (their release order), each by year; Recently played puts
    /// the games never played after the others, A–Z.
    static func sorted(_ games: [ArcadeGame], by sort: LibrarySort) -> [ArcadeGame] {
        let byTitle: (ArcadeGame, ArcadeGame) -> Bool = {
            $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending
        }
        let byYear: (ArcadeGame, ArcadeGame) -> Bool = { $0.year != $1.year ? $0.year < $1.year : byTitle($0, $1) }
        switch sort {
        case .title:
            return games.sorted(by: byTitle)
        case .year:
            return games.sorted(by: byYear)
        case .platform:
            let rank = { (g: ArcadeGame) in Platform.allCases.firstIndex(of: g.platform) ?? 0 }
            return games.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : byYear($0, $1) }
        case .recent:
            let played = LastPlayed.all()
            let last = { (g: ArcadeGame) in g.versions.compactMap { played[$0.id] }.max() }
            return games.sorted {
                switch (last($0), last($1)) {
                case let (a?, b?): return a != b ? a > b : byTitle($0, $1)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byTitle($0, $1)
                }
            }
        }
    }
}

/// The Lindbergh games took MAME's set names (2026-10-28): a device's game
/// folders, saves, pictures and settings under the old names move to the new
/// ones, once, at launch. iCloud Drive files and ROM server files under the
/// old names are still found (Storage.otherNames).
enum SetRenames {
    static let renamed = GameNames.renamed // games.toml's renamed_from

    static func migrate() {
        let fm = FileManager.default
        for (old, new) in renamed {
            let moves = [(Storage.roms.appendingPathComponent(old, isDirectory: true), Storage.roms.appendingPathComponent(new, isDirectory: true)),
                         (Storage.saves(old), Storage.saves(new)),
                         (Pictures.url(old), Pictures.url(new))]
            for (from, to) in moves where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        // Per-game settings: "<kind>.<romset>[.<more>]" (screenLook., buttons., replay., link., vrView.)
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() {
            var parts = key.components(separatedBy: ".")
            guard parts.count >= 2, let new = renamed[parts[1]] else { continue }
            parts[1] = new
            let newKey = parts.joined(separator: ".")
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
            defaults.removeObject(forKey: key)
        }
        if var played = defaults.dictionary(forKey: SettingKey.lastPlayed), played.keys.contains(where: { renamed[$0] != nil }) {
            for (old, new) in renamed { if let t = played.removeValue(forKey: old), played[new] == nil { played[new] = t } }
            defaults.set(played, forKey: SettingKey.lastPlayed)
        }
    }
}

/// Where the app keeps ROM sets and each game's saved settings:
/// Application Support/Arcade Foundry/{ROMs,Saves/<romset>}.
enum Storage {
    static let root: URL = {
        #if os(tvOS)
        // tvOS apps may only keep files in Caches (the system can clear it:
        // the ROM sets download again from the ROM server).
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let root = base.appendingPathComponent("Arcade Foundry", isDirectory: true)
        // Another cabinet on the same Mac (Cabinet.instance) keeps its ROM sets and saves apart.
        return Cabinet.instance.map { root.appendingPathComponent("Cabinets/\($0)", isDirectory: true) } ?? root
    }()
    static var roms: URL { root.appendingPathComponent("ROMs", isDirectory: true) }
    static func saves(_ romset: String) -> URL { root.appendingPathComponent("Saves/\(romset)", isDirectory: true) }

    static let romExtensions = ["zip", "7z"]
    static var romTypes: [UTType] {
        [UTType.zip, .folder] + [UTType(filenameExtension: "7z"), UTType(filenameExtension: GamePackage.ext)].compactMap { $0 }
    }

    /// Lindbergh games are a folder, not an archive: the game's disk as the
    /// cabinet mounts it (the folder that holds disk0), named after its set
    /// ("hotd4a"). In iCloud Drive and on the ROM server they are one file,
    /// <set>.tar (GamePackage), unpacked into the folder before play.
    /// A Chihiro game is a folder too: the one that holds its XBE ("vcop3",
    /// holding vc3.xbe), and travels the same way.
    static func isFolder(_ romset: String) -> Bool {
        let platform = GameInfo.all.first { $0.id == romset }?.platform
        return platform == .lindbergh || platform == .chihiro
    }

    /// A folder game that travels as <set>.tar (iCloud Drive, the ROM server): every one (Lindbergh, Chihiro).
    static func isPacked(_ romset: String) -> Bool { isFolder(romset) }

    /// What a game folder holds that marks it as the game's: disk0, or the Chihiro game's XBE.
    static func folderMark(_ romset: String) -> String {
        GameNames.chihiroXbe[romset] ?? "disk0"
    }

    /// The ROM set the user added for `romset`, if any.
    static func rom(_ romset: String) -> URL? {
        if PCGames.isPC(romset) { return PCGames.folder(romset) } // a game folder the player chose, never copied in
        if isFolder(romset) {
            let url = roms.appendingPathComponent(romset, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(folderMark(romset)).path) ? url : nil
        }
        // Over Rev's split .zip lacks its parent's files: the .7z (the whole set) first.
        // Then the set's other names: Virtua Formula's files are in Virtua Racing's vr.7z.
        for name in names(romset) {
            for ext in romset == "overrevb" ? Array(romExtensions.reversed()) : romExtensions {
                let url = roms.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Other names a set's file may have, and the app's set they are
    /// (scripts/game_sets.py's OTHER_NAMES): MAME parents that hold a clone's
    /// set (hotd.7z with The House of the Dead's original set, hotdo; doa.zip
    /// with Dead or Alive's Revision B, doab, in older romsets) and the names
    /// the app gave the Lindbergh games before it took MAME's (or2sp.tar is
    /// outr2sdx; see SetRenames).
    static let otherNames = GameNames.otherNames // games.toml's other_names and renamed_from

    /// The app's set and the other names its files may have.
    static func names(_ romset: String) -> [String] {
        [romset] + otherNames.filter { $0.value == romset }.map(\.key).sorted()
    }

    /// MAME device sets a game's set needs beside it (Wing War's I/O board
    /// BIOS, model1io2.zip), added like a game's ROM set (games.toml's devices).
    static let devices = GameNames.devices

    /// A board's MAME BIOS set its games use when it is there, added like a
    /// ROM set: Chihiro's chihiro.zip, whose EEPROM dumps the core reads from
    /// beside the game (the ROM folder). Without it the game starts with
    /// fresh operator settings, so unlike `devices` it is never required.
    static let biosSets: [Platform: String] = [.chihiro: "chihiro"]

    /// The app's set for a file's name: its own when it is a game's set (vr.7z
    /// is Virtua Racing's, though it also holds its clone Virtua Formula's
    /// files), otherwise the set it is another name for (hotd.7z is hotdo).
    static func appSet(_ name: String) -> String {
        if GameInfo.all.contains(where: { $0.id == name }) { return name }
        return otherNames[name] ?? name
    }

    /// The set a ROM file is for ("srallyc.7z" is srallyc), if Arcade Foundry: Insert Coin
    /// knows it (a game's, or a device set one needs).
    static func romset(of url: URL) -> String? {
        if url.hasDirectoryPath {
            let set = appSet(url.lastPathComponent.lowercased())
            return isFolder(set) ? set : nil
        }
        let ext = url.pathExtension.lowercased()
        let set = appSet(url.deletingPathExtension().lastPathComponent.lowercased())
        if ext == GamePackage.ext { return isPacked(set) ? set : nil }
        guard romExtensions.contains(ext),
              GameInfo.all.contains(where: { $0.id == set }) || devices.values.contains(where: { $0.contains(set) })
                || biosSets.values.contains(set) else { return nil }
        return set
    }

    /// Adds a ROM set the user picked, named after its set ("srallyc.7z"),
    /// replacing an older one: into iCloud Drive when `cloud` is its folder
    /// (the user's other devices get it too), otherwise into this device's
    /// ROM folder.
    static func addROM(from source: URL, cloud: URL?) async throws -> String {
        guard let set = romset(of: source) else {
            throw CoreError.failed("\(source.lastPathComponent) is not a ROM set Arcade Foundry: Insert Coin knows (name it after its MAME set: \(GameInfo.all.map(\.id).joined(separator: ", ")), .zip or .7z; a Lindbergh game is its folder or <set>.tar, named after its set)")
        }
        let ext = source.pathExtension.lowercased()
        if isFolder(set) && source.hasDirectoryPath {
            // Played here, and packed into iCloud Drive for the other devices.
            try await Task.detached(priority: .userInitiated) { try installFolder(source, set: set) }.value
            if let cloud, isPacked(set) { try await packToCloud(set, into: cloud) }
            return set
        }
        if isFolder(set) && cloud == nil {
            try await Task.detached(priority: .userInitiated) { try GamePackage.unpack(file: source, set: set) }.value
            return set
        }
        if let cloud {
            try await CloudROMs.copy(source, set: set, ext: ext, into: cloud)
        } else {
            try install(source, set: set, ext: ext, move: false)
        }
        return set
    }

    /// Adds the ROM sets the user picked (Add ROM); what to tell them.
    static func addROMs(_ urls: [URL], cloud: URL?) async -> String? {
        var added: [String] = [], problem: String?
        for url in urls {
            do { added.append(try await addROM(from: url, cloud: cloud)) } catch { problem = error.localizedDescription }
        }
        guard !added.isEmpty else { return problem }
        return "Added \(added.joined(separator: ", "))" + (cloud != nil ? " to iCloud Drive." : ".")
    }

    /// The ROM set to play `romset` with, on this device: the local one, or
    /// the one in iCloud Drive, downloaded first if needed.
    @MainActor static func ready(_ romset: String) async throws -> URL {
        let url: URL
        let localTar = roms.appendingPathComponent("\(romset).\(GamePackage.ext)")
        if let local = rom(romset) {
            url = local
        } else if isPacked(romset), FileManager.default.fileExists(atPath: localTar.path) {
            // <set>.tar put in the ROM folder by hand (the Files app, devicectl): unpacked on first play.
            try await Task.detached(priority: .userInitiated) { try GamePackage.unpack(file: localTar, set: romset) }.value
            guard let local = rom(romset) else { throw CoreError.failed("\(romset).\(GamePackage.ext) did not unpack") }
            url = local
        } else if let item = CloudROMs.shared.items[romset], isPacked(romset) {
            // <set>.tar: unpacked here, then only the game folder is kept on this device.
            let tar = try await CloudROMs.download(item.url)
            try await Task.detached(priority: .userInitiated) { try GamePackage.unpack(file: tar, set: romset) }.value
            try? CloudROMs.evict(item.url)
            guard let local = rom(romset) else { throw CoreError.failed("\(romset).\(GamePackage.ext) did not unpack") }
            url = local
        } else if let item = CloudROMs.shared.items[romset] {
            url = try await CloudROMs.download(item.url)
        } else {
            throw CoreError.failed("There is no ROM set for \(romset) on this device or in iCloud Drive.")
        }
        for device in devices[romset] ?? [] { try await place(device, beside: url) }
        await placeBIOS(for: romset)
        return url
    }

    /// The board's BIOS set (biosSets) in the ROM folder, from iCloud Drive
    /// if it is only there; nothing when it is nowhere (it is optional).
    @MainActor private static func placeBIOS(for romset: String) async {
        guard let platform = GameInfo.all.first(where: { $0.id == romset })?.platform,
              let bios = biosSets[platform], rom(bios) == nil,
              let item = CloudROMs.shared.items[bios],
              let file = try? await CloudROMs.download(item.url) else { return }
        try? install(file, set: bios, ext: file.pathExtension.lowercased(), move: false)
    }

    /// A device set where the core looks for it: beside the game's set.
    @MainActor private static func place(_ device: String, beside url: URL) async throws {
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if romExtensions.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent("\(device).\($0)").path) }) { return }
        var source = rom(device)
        if source == nil, let item = CloudROMs.shared.items[device] { source = try await CloudROMs.download(item.url) }
        guard let source else {
            throw CoreError.failed("This game also needs MAME's \(device) set (its I/O board's BIOS): add \(device).zip like a ROM set.")
        }
        try fm.copyItem(at: source, to: dir.appendingPathComponent(source.lastPathComponent))
    }

    /// Moves this device's ROM set for `romset` into iCloud Drive. A game
    /// folder is packed in as <set>.tar and stays here too (unpacking it
    /// again takes minutes).
    static func moveToCloud(_ romset: String, folder: URL) async throws {
        if isFolder(romset) {
            if isPacked(romset), rom(romset) != nil { try await packToCloud(romset, into: folder) }
            return
        }
        guard let url = rom(romset) else { return }
        try await CloudROMs.copy(url, set: romset, ext: url.pathExtension.lowercased(), into: folder)
        removeROM(romset)
    }

    /// Packs this device's game folder into iCloud Drive as <set>.tar.
    static func packToCloud(_ romset: String, into cloud: URL) async throws {
        guard let folder = rom(romset) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(romset).\(GamePackage.ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await Task.detached(priority: .userInitiated) { try GamePackage.pack(folder, set: romset, to: tmp) }.value
        try await CloudROMs.copy(tmp, set: romset, ext: GamePackage.ext, into: cloud)
    }

    static func install(_ file: URL, set: String, ext: String, move: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: roms, withIntermediateDirectories: true)
        for old in romExtensions {
            try? fm.removeItem(at: roms.appendingPathComponent("\(set).\(old)"))
        }
        let dst = roms.appendingPathComponent("\(set).\(ext)")
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        if move { try fm.moveItem(at: file, to: dst) } else { try fm.copyItem(at: file, to: dst) }
    }

    /// Copies a Lindbergh or Chihiro game folder into the ROM folder as <set>/
    /// (a clone, not a copy, on the same APFS volume).
    static func installFolder(_ source: URL, set: String) throws {
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let mark = folderMark(set)
        guard fm.fileExists(atPath: source.appendingPathComponent(mark).path) else {
            throw CoreError.failed("\(source.lastPathComponent) has no \(mark): pick the game folder that holds \(mark)")
        }
        try fm.createDirectory(at: roms, withIntermediateDirectories: true)
        let dst = roms.appendingPathComponent(set, isDirectory: true)
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: source, to: dst)
    }

    static func removeROM(_ romset: String) {
        if isFolder(romset) {
            try? FileManager.default.removeItem(at: roms.appendingPathComponent(romset, isDirectory: true))
            return
        }
        for ext in romExtensions {
            try? FileManager.default.removeItem(at: roms.appendingPathComponent("\(romset).\(ext)"))
        }
    }
}

/// Downloads ROM sets from the user's own server: <server>/<romset>.zip
/// (or .7z; a Lindbergh game's <set>.tar, unpacked as it arrives), once
/// per device, into the device's ROM folder. Any web
/// server that serves the files works, e.g. on the machine with the ROMs:
/// python3 -m http.server 8000 --directory ~/path/to/roms
enum RomServer {
    /// Gives up on a connection that stalls (a server that is gone, or
    /// Local Network access not given to the app on iOS) instead of
    /// waiting for ever.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// The server did not answer: the other sets would wait as long.
    struct Unreachable: LocalizedError {
        let errorDescription: String?
    }

    @MainActor private static var running: [String: Task<Void, Error>] = [:]

    /// Downloads `romset` (and its device sets). A game's page asking for a
    /// set the library is already downloading waits for that download.
    @MainActor static func download(_ romset: String, from server: String) async throws {
        if let task = running[romset] { return try await task.value }
        let task = Task { try await fetch(romset, from: server) }
        running[romset] = task
        defer {
            running[romset] = nil
            Downloads.shared.set(romset, nil)
        }
        try await task.value
    }

    private static func fetch(_ romset: String, from server: String) async throws {
        // Already here: the library's list of missing sets is made before it
        // downloads, and Virtua Racing's vr.7z is also Virtua Formula's.
        if Storage.rom(romset) != nil { return }
        guard var base = URL(string: server.trimmingCharacters(in: .whitespaces)), base.scheme != nil else {
            throw CoreError.failed("The ROM server address is not a URL (for example http://192.168.1.10:8000/roms)")
        }
        if base.path.hasSuffix("/") { base.deleteLastPathComponent() }
        do {
            var lastError: Error = CoreError.failed("not found")
            let names = Storage.names(romset) // hotd.7z for hotdo, or2sp.tar for outr2sdx
            if Storage.isFolder(romset) {
                for name in names {
                    do {
                        try await PackageDownload.run(base.appendingPathComponent("\(name).\(GamePackage.ext)"), set: romset)
                        await check(romset) // the core's file list, when it has one
                        return
                    } catch let error as URLError where unreachable(error) {
                        throw error
                    } catch {
                        lastError = error
                    }
                }
                throw lastError
            }
            for (name, ext) in names.flatMap({ name in Storage.romExtensions.map { (name, $0) } }) {
                let url = base.appendingPathComponent("\(name).\(ext)")
                do {
                    let (file, response) = try await session.download(from: url, delegate: DownloadProgress(set: romset))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        try? FileManager.default.removeItem(at: file)
                        lastError = CoreError.failed("\(url.absoluteString): not on the server")
                        continue
                    }
                    // Filed under the set the file is (vr.7z stays Virtua Racing's), as Add ROM does
                    try Storage.install(file, set: Storage.appSet(name), ext: ext, move: true)
                    for device in Storage.devices[romset] ?? [] where Storage.rom(device) == nil {
                        try await download(device, from: server) // its device sets too
                    }
                    if let platform = GameInfo.all.first(where: { $0.id == romset })?.platform,
                       let bios = Storage.biosSets[platform], Storage.rom(bios) == nil {
                        try? await download(bios, from: server) // the board's BIOS set, when the server has it
                    }
                    await check(romset)
                    return
                } catch let error as URLError where unreachable(error) {
                    throw error // the next name would wait as long
                } catch {
                    lastError = error
                }
            }
            throw lastError
        } catch let error as URLError where unreachable(error) {
            throw Unreachable(errorDescription: "Could not reach the ROM server at \(base.absoluteString) (\(error.localizedDescription))." + localNetworkHint)
        }
    }

    /// Has the game's core check the downloaded set (every file, its size and
    /// CRC against the core's own list); the result shows in Downloads.
    private static func check(_ romset: String) async {
        guard let url = Storage.rom(romset), let core = await MainActor.run(body: { CoreLibrary.load(romset) }) else { return }
        await MainActor.run { Downloads.shared.startCheck(romset) }
        let result = await Task.detached(priority: .utility) { core.checkRoms(url) }.value
        await MainActor.run { Downloads.shared.finishCheck(romset, result) }
    }

    private static func unreachable(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
         .networkConnectionLost, .dnsLookupFailed].contains(error.code)
    }

    private static var localNetworkHint: String {
        #if os(iOS) || os(tvOS)
        " Check that the server is running, and that Arcade Foundry: Insert Coin is on in Settings > Privacy & Security > Local Network."
        #else
        " Check that the server is running and the address is right."
        #endif
    }
}

/// Shows a .zip or .7z download's progress (the library's "Downloading… 42%").
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let set: String
    private var shown = -1.0
    private var observation: NSKeyValueObservation?

    init(set: String) { self.set = set }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self, progress.totalUnitCount > 0 else { return }
            let f = progress.fractionCompleted
            guard f - self.shown >= 0.01 else { return }
            self.shown = f
            let set = self.set
            Task { @MainActor in Downloads.shared.set(set, f) }
        }
    }
}
