import CoreGraphics
import Foundation
import ImageIO

/// The kinds of game art (#352): the title screen goes on the game's card
/// and at the top of its page (the in-game shot when there is no title
/// screen); the rest in a row under About this game.
enum ArtKind: String, CaseIterable, Identifiable {
    case title, ingame, flyer, marquee, cabinet
    var id: String { rawValue }

    var name: String {
        switch self {
        case .title: "Title screen"
        case .ingame: "In game"
        case .flyer: "Flyer"
        case .marquee: "Marquee"
        case .cabinet: "Cabinet"
        }
    }

    /// A picture of the game's screen (taken in MAME), not printed art.
    var isScreen: Bool { self == .title || self == .ingame }

    /// The row under About this game, in this order.
    static let extras: [ArtKind] = [.flyer, .marquee, .cabinet, .ingame]

    /// libretro-thumbnails' folder for the same kind of picture, if it has one.
    var libretroFolder: String? {
        switch self {
        case .title: "Named_Titles"
        case .ingame: "Named_Snaps"
        case .flyer: "Named_Boxarts" // MAME's "box art" there is the flyer
        case .marquee, .cabinet: nil
        }
    }
}

/// Game art downloaded on the player's device (#352). The app ships none:
/// the art is Sega's, so each device fetches it for itself, by MAME set
/// name, from the Arcade Database (adb.arcadeitalia.net), and from
/// libretro-thumbnails (by the game's MAME description) when the Arcade
/// Database has none of that kind.
///
/// - Lazy: the card's picture when a card is first drawn, the rest when the
///   game's page is opened. One download at a time (the Arcade Database
///   asks for one connection per device), none while a game plays.
/// - Kept for good: never checked or updated again. A kind neither source
///   has is remembered (<kind>.miss) and not asked for again. A failed
///   connection is tried again the next time the app starts.
/// - Where: iPhone, iPad and Apple TV in Caches/Arcade Foundry/Art/<set>/
///   (the system may clear it; the art then downloads again), the Mac in
///   Application Support/Arcade Foundry/Art/<set>/.
/// - Only the set name is sent, and nothing about the player.
/// - Settings: "Download game art" (SettingKey.downloadArt, on by default)
///   and "Remove downloaded art", which never touches the player's own
///   pictures (Pictures).
/// AF_ART_URL in the environment points both sources at a test server:
/// <AF_ART_URL>/service_scraper.php?..., <AF_ART_URL>/?mame=... and
/// <AF_ART_URL>/libretro/<folder>/<name>.png.
@MainActor final class GameArt: ObservableObject {
    static let shared = GameArt()

    private init() { Self.dropMAMEScreens() }

    /// Sets on a board MAME can't run yet (Lindbergh, Chihiro). Their
    /// title and in-game pictures in the Arcade Database and
    /// libretro-thumbnails are MAME's own screen: its "Screenless System"
    /// card, or noise. Those two kinds aren't downloaded for them, and the
    /// card falls back to the app's screen from the game, then the flyer.
    nonisolated static let noMAMEScreens: Set<String> =
        Set(GameInfo.catalog.filter { $0.platform == .lindbergh || $0.platform == .chihiro }.map(\.id))

    nonisolated static func wanted(_ set: String, _ kind: ArtKind) -> Bool {
        !(kind.isScreen && noMAMEScreens.contains(set))
    }

    /// Such screens downloaded before this rule are removed (with their misses).
    nonisolated private static func dropMAMEScreens() {
        for set in noMAMEScreens {
            for kind in ArtKind.allCases where kind.isScreen {
                try? FileManager.default.removeItem(at: file(set, kind))
                try? FileManager.default.removeItem(at: missFile(set, kind))
            }
        }
    }

    /// Bumped when a picture arrives, so the cards and pages draw again.
    @Published private(set) var arrived = 0

    /// Set while a game runs: nothing downloads until it ends.
    var holding = false {
        didSet { if !holding { pump() } }
    }

    nonisolated static let folder: URL = {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Arcade Foundry/Art", isDirectory: true)
    }()

    nonisolated static func file(_ set: String, _ kind: ArtKind) -> URL {
        folder.appendingPathComponent("\(set)/\(kind.rawValue).png")
    }

    nonisolated private static func missFile(_ set: String, _ kind: ArtKind) -> URL {
        folder.appendingPathComponent("\(set)/\(kind.rawValue).miss")
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingKey.downloadArt) as? Bool ?? true
    }

    private static let testServer = ProcessInfo.processInfo.environment["AF_ART_URL"]
    private static let adb = testServer ?? "https://adb.arcadeitalia.net"
    private static let libretro = testServer.map { "\($0)/libretro" } ?? "https://thumbnails.libretro.com/MAME"

    private var queue: [(set: String, kind: ArtKind)] = []
    private var running = false
    /// The one downloading now.
    private var current: (set: String, kind: ArtKind)?
    /// Sets the Arcade Database couldn't be reached for, this run.
    private var offline = Set<String>()
    /// Each set's answer from the Arcade Database, this run.
    private var answers: [String: AdbGame] = [:]

    func image(_ set: String, _ kind: ArtKind) -> CGImage? { Self.wanted(set, kind) ? Pictures.load(Self.file(set, kind)) : nil }

    /// The card's picture: the title screen, else the in-game shot.
    func cardImage(_ set: String) -> CGImage? { image(set, .title) ?? image(set, .ingame) }

    /// The card's last choice, after the app's own screen from the game.
    func cardFlyer(_ set: String) -> CGImage? { image(set, .flyer) }

    func has(_ set: String, _ kind: ArtKind) -> Bool {
        Self.wanted(set, kind) && FileManager.default.fileExists(atPath: Self.file(set, kind).path)
    }

    private func missed(_ set: String, _ kind: ArtKind) -> Bool {
        FileManager.default.fileExists(atPath: Self.missFile(set, kind).path)
    }

    /// The card's picture, unless the player has their own: the title
    /// screen, then the in-game shot if there is no title screen, then the
    /// flyer (the only one for the boards MAME can't run).
    func wantCard(_ set: String) {
        guard !Pictures.hasOwn(set) else { return }
        for kind in [ArtKind.title, .ingame, .flyer] where Self.wanted(set, kind) {
            if has(set, kind) { return }
            if !missed(set, kind) { want(set, [kind]); return }
        }
    }

    /// Queues the kinds this device doesn't have yet (and that aren't known
    /// to be missing), if downloads are on.
    func want(_ set: String, _ kinds: [ArtKind]) {
        guard Self.enabled, !offline.contains(set) else { return }
        for kind in kinds where Self.wanted(set, kind) && !has(set, kind) && !missed(set, kind)
            && !(current?.set == set && current?.kind == kind)
            && !queue.contains(where: { $0.set == set && $0.kind == kind }) {
            queue.append((set, kind))
        }
        pump()
    }

    /// Settings' "Remove downloaded art": every downloaded picture and
    /// every miss goes (the player's own pictures are elsewhere).
    func removeAll() {
        queue.removeAll()
        offline.removeAll()
        answers.removeAll()
        try? FileManager.default.removeItem(at: Self.folder)
        arrived += 1
    }

    /// How much the downloaded art takes, for Settings.
    nonisolated static func size() -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func pump() {
        guard !running, !holding, Self.enabled, !queue.isEmpty else { return }
        running = true
        let next = queue.removeFirst()
        current = next
        Task {
            let outcome = await fetch(next.set, next.kind)
            current = nil
            switch outcome {
            case .saved: arrived += 1
            case .missing:
                Self.mark(next.set, next.kind)
                // The card falls back to the in-game shot, then the flyer.
                if next.kind.isScreen { wantCard(next.set) }
                arrived += 1
            case .offline:
                offline.insert(next.set)
                queue.removeAll { $0.set == next.set }
            }
            running = false
            pump()
        }
    }

    private enum Outcome { case saved, missing, offline }

    /// The Arcade Database's answer for a set: its MAME description and the
    /// address of each kind it has a picture of.
    private struct AdbGame {
        var description = ""
        var urls: [ArtKind: URL] = [:]
    }

    private func fetch(_ set: String, _ kind: ArtKind) async -> Outcome {
        let answer: AdbGame
        if let known = answers[set] {
            answer = known
        } else {
            guard let got = await query(set) else { return .offline }
            answers[set] = got
            answer = got
        }
        if let url = answer.urls[kind] {
            switch await download(url, to: Self.file(set, kind), kind: kind) {
            case .saved: return .saved
            case .offline: return .offline
            case .missing: break
            }
        }
        guard let folder = kind.libretroFolder, !answer.description.isEmpty,
              let url = URL(string: "\(Self.libretro)/\(folder)/\(Self.libretroName(answer.description)).png")
        else { return .missing }
        return await download(url, to: Self.file(set, kind), kind: kind)
    }

    /// The Arcade Database's scraper answer for one set (nil: no answer, try another time).
    private func query(_ set: String) async -> AdbGame? {
        guard let url = URL(string: "\(Self.adb)/service_scraper.php?ajax=query_mame&game_name=\(set)"),
              let (data, response) = try? await Self.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var game = AdbGame()
        guard let first = (json["result"] as? [[String: Any]])?.first else { return game } // a set it doesn't know
        game.description = first["title"] as? String ?? ""
        for kind in ArtKind.allCases {
            if let s = (first["url_image_\(kind.rawValue)"] as? String)?.replacingOccurrences(of: "&amp;", with: "&"),
               !s.isEmpty, var url = URL(string: s) {
                if let test = Self.testServer, let q = url.query { url = URL(string: "\(test)/?\(q)") ?? url }
                game.urls[kind] = url
            }
        }
        return game
    }

    /// One picture, kept as PNG at most 1600 pixels across (the title
    /// screen 1024): missing when the answer isn't an image.
    private func download(_ url: URL, to file: URL, kind: ArtKind) async -> Outcome {
        let got: (Data, URLResponse)
        do {
            got = try await Self.session.data(from: url)
        } catch {
            return .offline
        }
        let status = (got.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 500 || status == 429 { return .offline }
        guard status == 200, (got.1.mimeType ?? "image/").hasPrefix("image/"), let image = Self.decode(got.0) else { return .missing }
        Pictures.write(image, to: file, longest: kind == .title || kind == .ingame ? 1024 : 1600)
        return FileManager.default.fileExists(atPath: file.path) ? .saved : .missing
    }

    /// Pictures can take minutes to arrive from the Arcade Database; a
    /// stalled one is given up on (and tried again the next start).
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()

    /// A real picture. The Arcade Database answers a missing one with 200
    /// and a stand-in: its 140 x 105 "no image" picture, or a blank (all
    /// black) frame at the game's resolution; so a picture under 160 x 120,
    /// or of one colour, counts as missing.
    nonisolated private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= 160, image.height >= 120, !blank(image) else { return nil }
        return image
    }

    /// Every pixel the same colour (drawn small, 32 x 24, and compared).
    nonisolated private static func blank(_ image: CGImage) -> Bool {
        let w = 32, h = 24
        var px = [UInt32](repeating: 0, count: w * h)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        return px.allSatisfy { $0 == px[0] }
    }

    nonisolated private static func mark(_ set: String, _ kind: ArtKind) {
        let file = missFile(set, kind)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
    }

    /// libretro-thumbnails' file name for a MAME description: &*/:`<>?\|"
    /// become _, and the rest is escaped for the address.
    nonisolated static func libretroName(_ description: String) -> String {
        let swapped = String(description.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
        return swapped.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? swapped
    }
}
