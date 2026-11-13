import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Keeps a game's inputs from its first frame, so "Record replay" (the
/// pause menu, a game's page) can be switched on at any time and still save
/// the whole game: when the game ends with it on, the inputs are written as
/// a Replay to Replays/ in the iCloud Drive folder (this device's own
/// Replays/ without iCloud Drive), for VideoJob to render on the Mac.
/// About 3 KB a second of play, kept in memory.
final class ReplayRecorder {
    static let folderName = "Replays"

    /// A game's own "Record replay" (String, this device only): "on" or
    /// "off", or absent or empty to follow Settings (SettingKey.recordReplay),
    /// as a game's own screen settings do.
    static func key(_ romset: String) -> String { "replay.\(romset)" }

    /// Whether `romset` records a replay: its own setting, else Settings'.
    static func enabled(_ romset: String) -> Bool {
        switch UserDefaults.standard.string(forKey: key(romset)) {
        case "on": true
        case "off": false
        default: UserDefaults.standard.bool(forKey: SettingKey.recordReplay)
        }
    }

    private var header: Replay.Header
    private var inputs = Data()

    /// Before the core boots: the saves it boots with.
    init(game: GameInfo, library: CoreLibrary, saveDir: URL) {
        #if os(macOS)
        let device = Host.current().localizedName ?? "Mac"
        #else
        let device = UIDevice.current.model
        #endif
        header = Replay.Header(
            romset: game.id, title: game.title,
            coreVersion: library.api.pointee.core_version, frameHz: library.frameHz,
            inputSize: MemoryLayout<afcore_input>.size, recorded: Date(), device: device,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            saves: Replay.files(in: saveDir))
    }

    /// A save state was loaded (or the game resumed from one): the inputs
    /// no longer replay from power-on, so the recording ends here and what
    /// was recorded is kept.
    var ended = false

    /// The input of the frame about to run (whoever runs the frames).
    func add(_ input: afcore_input) {
        guard !ended else { return }
        var input = input
        withUnsafeBytes(of: &input) { inputs.append(contentsOf: $0) }
    }

    var frames: Int { inputs.count / header.inputSize }

    /// Writes the replay; its file, or nil when there was nothing to keep.
    @discardableResult
    func save(into folder: URL?) -> URL? {
        guard frames > 0 else { return nil }
        let dir = (folder ?? Storage.root).appendingPathComponent(Self.folderName, isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("\(header.romset)-\(f.string(from: header.recorded)).\(Replay.ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Replay(header: header, inputs: inputs).write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
