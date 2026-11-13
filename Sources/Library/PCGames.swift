import Foundation

/// The PC-based games (#452; docs/design/APP-ARCHITECTURE.md, PC-based
/// games): RingWide, RingEdge, Europa-R, the Sega PC games and ALLS. Each is
/// a game folder the player points the app at, never copied (some are 12 GB),
/// run by its core's runner, afgame_<set>, in a process of its own, so a crash
/// in a large PC game never takes the library down. macOS only for now:
/// on iPhone, iPad and Apple TV `GameInfo.all` leaves them out.
enum PCGames {
    static func isPC(_ romset: String) -> Bool {
        GameInfo.catalog.first { $0.id == romset }?.platform == .pc
    }

    /// The game's program, a path inside its game folder (games.toml's
    /// program), or "" when its core names none.
    static func program(_ romset: String) -> String { GameNames.pcPrograms[romset] ?? "" }

    /// The game's runner in the app (Contents/MacOS/afgame_<set>), built by
    /// build_cores.py and signed with the app, inheriting its sandbox.
    static func runner(_ romset: String) -> URL? {
        #if os(macOS)
        return Bundle.main.url(forAuxiliaryExecutable: "afgame_\(romset)")
        #else
        return nil
        #endif
    }

    private static func key(_ romset: String) -> String { "gameFolder.\(romset)" }

    /// Whether `folder` holds the game: its program is in it.
    static func holdsGame(_ folder: URL, _ romset: String) -> Bool {
        let program = program(romset)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return program.isEmpty || FileManager.default.fileExists(atPath: folder.appendingPathComponent(program).path)
    }

    /// The game folder chosen for `romset` (a security-scoped bookmark: the
    /// app is sandboxed), when it is still there and still holds the game.
    static func folder(_ romset: String) -> URL? {
        #if os(macOS)
        guard let data = UserDefaults.standard.data(forKey: key(romset)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        let open = url.startAccessingSecurityScopedResource()
        defer { if open { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) {
            UserDefaults.standard.set(fresh, forKey: key(romset))
        }
        return holdsGame(url, romset) ? url : nil
        #else
        return nil
        #endif
    }

    /// Keeps `url` (from the Choose button's panel) as the game folder, or
    /// says why not.
    static func choose(_ url: URL, for romset: String) throws {
        #if os(macOS)
        let open = url.startAccessingSecurityScopedResource()
        defer { if open { url.stopAccessingSecurityScopedResource() } }
        guard holdsGame(url, romset) else {
            let title = GameInfo.catalog.first { $0.id == romset }?.title ?? romset
            throw CoreError.failed("\(url.path) doesn't hold \(title): its \(program(romset).isEmpty ? "game" : program(romset)) isn't in it.")
        }
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        UserDefaults.standard.set(data, forKey: key(romset))
        #endif
    }

    static func forget(_ romset: String) { UserDefaults.standard.removeObject(forKey: key(romset)) }

    /// Plays the game: its runner as a child process, with
    ///   afgame_<set> --game-dir DIR --saves DIR --fullscreen --display 0 --settings FILE
    /// (the settings file: key=value lines), until it ends. The runner opens
    /// its own full-screen window; the library stays behind it. Throws with
    /// the runner's last "error:" line when it fails (its whole output is
    /// Logs/<set>.log in the app's folder).
    static func play(_ game: GameInfo) async throws {
        #if os(macOS)
        guard let runner = runner(game.id) else { throw CoreError.failed(CoreLibrary.unavailable(game.id)) }
        guard let data = UserDefaults.standard.data(forKey: key(game.id)) else {
            throw CoreError.failed("Choose \(game.title)'s game folder on its page first.")
        }
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        // The runner inherits the app's sandbox; the folder is open to it while the app holds it open.
        let open = folder.startAccessingSecurityScopedResource()
        defer { if open { folder.stopAccessingSecurityScopedResource() } }
        guard holdsGame(folder, game.id) else {
            throw CoreError.failed("\(folder.path) no longer holds \(game.title): choose its game folder again.")
        }
        let fm = FileManager.default
        let saves = Storage.saves(game.id), logs = Storage.root.appendingPathComponent("Logs", isDirectory: true)
        let runs = Storage.root.appendingPathComponent("Runner", isDirectory: true)
        for dir in [saves, logs, runs] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let settings = runs.appendingPathComponent("\(game.id).settings"), log = logs.appendingPathComponent("\(game.id).log")
        try "cabinet=\(Cabinet.name)\n".write(to: settings, atomically: true, encoding: .utf8)
        fm.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        defer { try? out.close() }

        let process = Process()
        process.executableURL = runner
        process.arguments = ["--game-dir", folder.path, "--saves", saves.path, "--fullscreen", "--display", "0",
                             "--settings", settings.path]
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume(throwing: error) }
        }
        LastPlayed.mark(game.id)
        guard status != 0 else { return }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let why = text.split(separator: "\n").last { $0.hasPrefix("error:") }
            .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        throw CoreError.failed((why ?? "\(game.title) stopped (exit code \(status)).") + "\n\nIts output is in \(log.path).")
        #else
        throw CoreError.failed("PC-based games play on a Mac.")
        #endif
    }
}
