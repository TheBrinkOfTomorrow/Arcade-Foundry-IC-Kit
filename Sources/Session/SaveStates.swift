import Foundation

/// Save states and Resume (docs/design/SAVE-STATES.md in the app): a game's
/// whole board at one frame, written by its core (GameCore.saveState) into a
/// slot and loaded back.
///
/// A game's states are in States/<romset>/ beside Saves/ (kept out of the
/// save folder, so the save backup, which reads every file there, stays as it
/// is): slot 0 is the Resume slot (resume.afstate), 1 to 3 the player's
/// (1.afstate ...). Each state is compressed (NSData .zlib, raw deflate, as
/// the Linux app's), with a .png of its screen and a .json beside it. States
/// are per cabinet, like the saves they hold.
enum SaveStates {
    static let slots = 3 // the player's, besides the Resume slot (0)

    static func folder(_ romset: String) -> URL {
        Storage.root.appendingPathComponent("States/\(romset)", isDirectory: true)
    }

    static func file(_ romset: String, _ slot: Int, _ ext: String) -> URL {
        folder(romset).appendingPathComponent("\(slot == 0 ? "resume" : String(slot)).\(ext)")
    }

    /// What a slot holds, from its .json.
    struct Slot: Codable, Equatable {
        var date: Date
        var seconds: Double     // play time at its frame
        var coreVersion: String // x.y.z: a state loads only into the same core version
        var appVersion: String

        enum CodingKeys: String, CodingKey {
            case date, seconds
            case coreVersion = "core_version"
            case appVersion = "app_version"
        }
    }

    private static var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .secondsSince1970
        d.dateDecodingStrategy = .secondsSince1970
        return (e, d)
    }

    /// The slot's description, or nil when it is empty.
    static func slot(_ romset: String, _ slot: Int) -> Slot? {
        guard FileManager.default.fileExists(atPath: file(romset, slot, "afstate").path),
              let data = try? Data(contentsOf: file(romset, slot, "json")) else { return nil }
        return try? coder.1.decode(Slot.self, from: data)
    }

    /// "10 Nov 2026, 16:40 · 3:05 played", or "Empty"; "(an older version)" after one that doesn't load.
    static func describe(_ s: Slot?, coreVersion: String) -> String {
        guard let s else { return "Empty" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let t = Int(s.seconds)
        let played = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        return "\(f.string(from: s.date)) · \(played) played" + (s.coreVersion == coreVersion ? "" : " (an older version: doesn't load)")
    }

    /// Writes a state into a slot: compressed, beside the old one and then
    /// moved over it, so a slot is never half written.
    static func write(_ state: Data, romset: String, slot: Int, coreVersion: String, frameHz: Double) throws {
        let packed = try (state as NSData).compressed(using: .zlib) as Data
        try FileManager.default.createDirectory(at: folder(romset), withIntermediateDirectories: true)
        try packed.write(to: file(romset, slot, "afstate"), options: .atomic)
        // The frame count is in the state's header ("AFST", format, core version, frame: afcommon/state.h).
        var frame: UInt64 = 0
        if state.count >= 20 { for i in 0..<8 { frame |= UInt64(state[state.startIndex + 12 + i]) << (8 * UInt64(i)) } }
        let info = Slot(date: Date(), seconds: frameHz > 0 ? Double(frame) / frameHz : 0, coreVersion: coreVersion,
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        try coder.0.encode(info).write(to: file(romset, slot, "json"), options: .atomic)
    }

    /// A slot's state, unpacked.
    static func read(romset: String, slot: Int) throws -> Data {
        let packed = try Data(contentsOf: file(romset, slot, "afstate"))
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    static func remove(romset: String, slot: Int) {
        for ext in ["afstate", "png", "json"] { try? FileManager.default.removeItem(at: file(romset, slot, ext)) }
    }

    /// The game a game page's Resume button is starting (the app reads it
    /// when it makes the GameSession); main thread.
    static var resumeNext: String?

    /// Resume where I left off (Settings, off by default).
    static var resumeOn: Bool { UserDefaults.standard.bool(forKey: SettingKey.resumeGames) }

    /// The game's Resume slot to offer on its page and card: the setting is
    /// on, the core has save states and the slot is from its core version.
    static func canResume(_ romset: String, library: CoreLibrary?) -> Bool {
        guard resumeOn, let library, library.hasStates, let s = slot(romset, 0) else { return false }
        return s.coreVersion == library.version
    }
}
