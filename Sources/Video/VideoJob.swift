#if os(macOS)
import AVFoundation

/// Gameplay videos from the command line (issue #145), with no window: the
/// Mac app started with --video runs the game through its core as fast as
/// the Mac can and writes an MP4 (VideoWriter), then quits.
///
///     "Arcade Foundry Insert Coin" --video daytona            the attract mode (no controls) for 2 minutes
///     "Arcade Foundry Insert Coin" --video all                every game this build has a core and ROM set for
///     "Arcade Foundry Insert Coin" --video Race.afreplay      a replay (Replay), as it was played
///     "Arcade Foundry Insert Coin" --video replays            every replay in Replays/ without a video yet
///
/// Options: --seconds N (attract mode, default 120), --skip N (seconds of
/// the boot not written, default 0), --lines 1080|2160 (default 2160),
/// --hevc, --no-caption (the game's name, system and year, lower left),
/// --no-logo (upper right), --no-end-card (the last second fades to black,
/// then 4 s of the logo, website and YouTube channel), --no-sound (no
/// sound track), --music FILE (a track under the game, issue #147) with
/// --game-volume N (the game's sound under it, 0-1, default 0.35), --intro FILE
/// (a screen recording of the app opening the game, played first: it dips
/// to black into the game; with several games, FILE may hold %s for the
/// game's set), --fresh-saves (attract mode: none of your saves, the game's
/// factory settings), --out DIR (default ~/Movies/Arcade Foundry),
/// --roms DIR (ROM sets from DIR first: an unsigned build has no sandbox).
/// scripts/make_videos.sh runs it from the built app.
struct VideoJob {
    enum Source {
        case attract(String)
        case replay(URL)
    }

    var sources: [Source] = []
    var seconds = 120.0
    var skip = 0.0
    var lines = 2160
    var hevc = false
    var freshSaves = false
    var caption = true
    var logo = true
    var endCard = true
    var sound = true
    var music: URL?
    var intro: String?
    var gameVolume: Float = 0.35
    static var romDir: URL?
    var out: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Arcade Foundry", isDirectory: true)

    /// The job in the app's arguments, or nil when it was started as an app.
    init?(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--video") else { return nil }
        var args = Array(arguments[(i + 1)...])
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        var what: [String] = []
        while let a = value() {
            switch a {
            case "--seconds": seconds = Double(value() ?? "") ?? seconds
            case "--skip": skip = Double(value() ?? "") ?? skip
            case "--lines": lines = Int(value() ?? "") == 1080 ? 1080 : 2160
            case "--hevc": hevc = true
            case "--fresh-saves": freshSaves = true
            case "--no-caption": caption = false
            case "--no-logo": logo = false
            case "--no-end-card": endCard = false
            case "--no-sound": sound = false
            case "--music": if let f = value() { music = URL(fileURLWithPath: (f as NSString).expandingTildeInPath) }
            case "--intro": intro = value().map { ($0 as NSString).expandingTildeInPath }
            case "--game-volume": gameVolume = Float(value() ?? "").map { max(0, min(1, $0)) } ?? gameVolume
            case "--roms": if let d = value() { Self.romDir = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true) }
            case "--out": if let d = value() { out = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true) }
            default: if !a.hasPrefix("-") { what.append(a) } // Xcode's own -NSDocumentRevisions... arguments
            }
        }
        for w in what {
            switch w {
            case "all":
                sources += GameInfo.all.filter { CoreLibrary.load($0.id) != nil && Self.rom($0.id) != nil }.map { .attract($0.id) }
            case "replays":
                let done = Set(((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).map { ($0 as NSString).deletingPathExtension })
                sources += Self.replays().filter { !done.contains($0.deletingPathExtension().lastPathComponent) }.map { .replay($0) }
            default:
                sources.append(w.hasSuffix(".\(Replay.ext)") ? .replay(URL(fileURLWithPath: (w as NSString).expandingTildeInPath)) : .attract(w))
            }
        }
    }

    /// Runs every video in turn; the app's exit status.
    func run() -> Int32 {
        if sources.isEmpty {
            log("Nothing to make: name a game's set, all, a .\(Replay.ext) file or replays")
            return 1
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failed = 0
        for source in sources {
            do {
                try make(source)
            } catch {
                failed += 1
                log("  failed: \(error.localizedDescription)")
            }
        }
        return failed == 0 ? 0 : 1
    }

    private func make(_ source: Source) throws {
        let romset: String, name: String, replay: Replay?
        switch source {
        case .attract(let set):
            romset = set
            replay = nil
            name = "\(set)-attract"
        case .replay(let url):
            let r = try Replay(contentsOf: url)
            romset = r.header.romset
            replay = r
            name = url.deletingPathExtension().lastPathComponent
        }
        guard let game = GameInfo.all.first(where: { $0.id == romset }) else { throw CoreError.failed("\(romset) is not a game Arcade Foundry: Insert Coin knows") }
        guard let lib = CoreLibrary.load(romset) else { throw CoreError.failed(CoreLibrary.unavailable(romset)) }
        guard let rom = Self.rom(romset) else { throw CoreError.failed("No ROM set for \(romset): add it in the app first") }
        if let replay, replay.header.coreVersion != lib.api.pointee.core_version {
            throw CoreError.failed("The replay is from \(game.title)'s core \(CoreLibrary.format(replay.header.coreVersion)), this build has \(lib.version): it would not play the same")
        }

        // The game's own saves stay as they are: it runs from a copy.
        // (one per process: two renders of one game at once shared it, and
        // one of them started in the test menu)
        let saves = FileManager.default.temporaryDirectory.appendingPathComponent("video-saves-\(romset)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        if let replay {
            try Replay.restore(replay.header.saves, to: saves)
        } else {
            try Replay.restore(freshSaves ? [:] : Replay.files(in: Storage.saves(romset)), to: saves)
        }
        defer { try? FileManager.default.removeItem(at: saves) }

        let file = out.appendingPathComponent("\(name).mp4")
        let hz = lib.frameHz
        let total = replay?.frames ?? Int((skip + seconds) * hz)
        let skipFrames = min(total, Int(skip * hz))
        log("\(game.title) (\(romset)) → \(file.path)")

        // A core whose game runs by the host's clock (Chihiro) follows the
        // frames instead, so its sound comes out with them at any render speed.
        if lib.useRenderClock() { log("  render clock: 1/60 s of game time per frame") }
        let core = try GameCore(library: lib, romURL: rom, saveDir: saves)
        let track = try music.map(Self.load)
        let writer = try VideoWriter(url: file, lines: lines, hevc: hevc, squarePixels: game.platform == .lindbergh, sound: sound)
        let introFile = intro.map { URL(fileURLWithPath: $0.replacingOccurrences(of: "%s", with: romset)) }
        if caption || logo {
            writer.caption = VideoCaption(width: writer.width, height: writer.height, title: caption ? game.title : nil,
                                          subtitle: caption ? VideoCaption.subtitle(game) : nil, logo: logo)
        }
        let mixer = SoundMixer(rates: [core.audioRate(0), core.audioRate(1), core.audioRate(2)])
        var idle = afcore_input()
        idle.size = UInt32(MemoryLayout<afcore_input>.size)
        var buffer = [Float](repeating: 0, count: 2 * 4096)
        let started = Date()
        var lastLog = started
        // The intro, if any, comes first; the game's time starts after it.
        var lead = 0.0
        // The game's last second fades out, picture and sound, before the end card.
        var gameEnd: Double { lead + Double(total - skipFrames) / hz }
        let fadeOut = endCard ? 1.0 : 0, dip = 0.3
        func faded(_ mix: [Float]) -> [Float] {
            guard fadeOut > 0 || track != nil else { return mix }
            var mix = mix
            let at = Int(writer.audioSeconds * VideoWriter.sampleRate)
            for j in 0..<(mix.count / 2) {
                if let track {
                    let k = 2 * (at + j)
                    mix[2 * j] *= gameVolume
                    mix[2 * j + 1] *= gameVolume
                    if k + 1 < track.count { mix[2 * j] += track[k]; mix[2 * j + 1] += track[k + 1] }
                }
                guard fadeOut > 0 else { continue }
                let gain = Float(max(0, min(1, (gameEnd - Double(at + j) / VideoWriter.sampleRate) / fadeOut)))
                if gain < 1 { mix[2 * j] *= gain; mix[2 * j + 1] *= gain }
            }
            return mix
        }

        do {
            if let introFile {
                // The recording as it is, fading to black over its last
                // moments, in silence; then the game comes up from black.
                let rec = try VideoIntro(url: introFile, width: writer.width, height: writer.height)
                while rec.advance(to: writer.seconds) {
                    try writer.addStill(rec.frame, level: Float(max(0, min(1, (rec.duration - writer.seconds) / dip))))
                }
                lead = writer.seconds
                try writer.addAudio([Float](repeating: 0, count: Int(lead * VideoWriter.sampleRate) * 2))
            }
            for i in 0..<total {
                core.runFrame(replay?.input(i) ?? idle)
                if let reason = core.error() { throw CoreError.failed("The core stopped after \(i) frames: \(reason)") }
                let writing = i >= skipFrames
                buffer.withUnsafeMutableBufferPointer { buf in
                    for stream in 0..<3 {
                        while true {
                            let n = core.readAudio(stream, into: buf.baseAddress!, maxFrames: buf.count / 2)
                            if n == 0 { break }
                            if writing { mixer.add(stream, buf.baseAddress!, frames: n) }
                        }
                    }
                }
                guard writing else { continue }

                // The board's frames (57.52 a second) on a 60 fps timeline:
                // each video frame shows the newest screen at its time.
                let end = lead + Double(i + 1 - skipFrames) / hz
                let s = core.screen()
                while writer.seconds < end {
                    var level = fadeOut > 0 ? (gameEnd - writer.seconds) / fadeOut : 1
                    if lead > 0 { level = min(level, (writer.seconds - lead) / dip) }
                    writer.fade = Float(max(0, min(1, level)))
                    try writer.addFrame(s.pixels, s.width, s.height)
                }
                var mix = mixer.take()
                if mix.isEmpty && mixer.silent { // nothing yet: silence, so the sound stays in step
                    let due = Int(end * VideoWriter.sampleRate) - Int(writer.audioSeconds * VideoWriter.sampleRate)
                    mix = [Float](repeating: 0, count: max(0, due) * 2)
                }
                try writer.addAudio(faded(mix))

                if Date().timeIntervalSince(lastLog) >= 5 {
                    lastLog = Date()
                    let pace = writer.seconds / lastLog.timeIntervalSince(started)
                    log(String(format: "  %.0f of %.0f s (%.1fx real time)", writer.seconds, gameEnd, pace))
                }
            }
            try writer.addAudio(faded(mixer.take(flush: true)))
            if endCard {
                // Up from black over half a second, then held, in silence.
                let card = VideoCaption.endCard(width: writer.width, height: writer.height)
                let start = writer.seconds
                while writer.seconds < start + 4 {
                    try writer.addStill(card, level: Float(min(1, (writer.seconds - start) / 0.5)))
                }
                let due = Int((writer.seconds - writer.audioSeconds) * VideoWriter.sampleRate)
                try writer.addAudio([Float](repeating: 0, count: max(0, due) * 2))
            }
            try writer.finish()
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        log(String(format: "  done: %.0f s of video in %.0f s", writer.seconds, Date().timeIntervalSince(started)))
    }

    /// A music file (anything AVFoundation reads) as interleaved stereo at 48 kHz.
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VideoWriter.sampleRate, channels: 2, interleaved: true)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: out),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CoreError.failed("Can't read \(url.lastPathComponent)")
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * VideoWriter.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { throw CoreError.failed("Can't read \(url.lastPathComponent)") }
        var given = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength) * 2))
    }

    /// The ROM set on this Mac, or in the iCloud Drive folder (downloaded first).
    static func rom(_ romset: String) -> URL? {
        if let dir = romDir, Storage.isFolder(romset) { // Lindbergh, Chihiro: the game's folder (<set>/disk0, <set>/vc3.xbe)
            for name in Storage.names(romset) {
                let url = dir.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(Storage.folderMark(romset)).path) { return url }
            }
        } else if let dir = romDir {
            for name in Storage.names(romset) {
                for ext in Storage.romExtensions where FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).\(ext)").path) {
                    return dir.appendingPathComponent("\(name).\(ext)")
                }
            }
        }
        if let local = Storage.rom(romset) { return local }
        guard !Storage.isFolder(romset), let docs = cloudDocuments else { return nil }
        for name in Storage.names(romset) {
            for ext in Storage.romExtensions {
                let url = docs.appendingPathComponent("\(name).\(ext)")
                guard (try? url.checkResourceIsReachable()) == true || FileManager.default.fileExists(atPath: url.path) else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                var local = url, error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { local = $0 }
                if error == nil { return local }
            }
        }
        return nil
    }

    private static var cloudDocuments: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The replays in iCloud Drive's Replays folder and this Mac's own.
    static func replays() -> [URL] {
        var urls: [URL] = []
        for dir in [cloudDocuments?.appendingPathComponent(ReplayRecorder.folderName), Storage.root.appendingPathComponent(ReplayRecorder.folderName)] {
            guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names.sorted() {
                // iCloud keeps a file not yet on this Mac as ".<name>.icloud".
                if n.hasPrefix("."), n.hasSuffix(".\(Replay.ext).icloud") {
                    let url = dir.appendingPathComponent(String(n.dropFirst().dropLast(".icloud".count)))
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    var local = url, error: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { local = $0 }
                    if error == nil { urls.append(local) }
                } else if n.hasSuffix(".\(Replay.ext)") {
                    urls.append(dir.appendingPathComponent(n))
                }
            }
        }
        return urls
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
#endif
