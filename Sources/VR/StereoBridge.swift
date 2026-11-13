import Foundation
import simd

/// How a game shows in the headset.
enum VRView: String, CaseIterable {
    /// Inside the game: each eye drawn from the player's head, the HUD on a
    /// panel ahead. Racing and flying games.
    case full
    /// A cabinet screen in front of the player with depth inside it (the
    /// game's own camera as a window). The light-gun games, and any game as
    /// the comfortable choice.
    case cabinet

    var title: String { self == .full ? "Full view" : "Cabinet" }

    /// The light-gun games aim at a screen, and their camera swings.
    static func defaultView(for game: GameInfo) -> VRView {
        game.aimsGun ? .cabinet : .full
    }

    static func saved(for game: GameInfo) -> VRView {
        UserDefaults.standard.string(forKey: "vrView.\(game.id)").flatMap(VRView.init) ?? defaultView(for: game)
    }

    func save(for game: GameInfo) { UserDefaults.standard.set(rawValue, forKey: "vrView.\(game.id)") }
}

/// The stereo picture on an ordinary screen (GameSession, pause menu).
enum Screen3D: String, CaseIterable {
    case off, sideBySide, redCyan

    var title: String {
        switch self {
        case .off: "off"
        case .sideBySide: "side by side"
        case .redCyan: "red-cyan glasses"
        }
    }

    var next: Screen3D { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

/// Between the headset's render loop and the game's frames. The render loop
/// says, every display frame, how it wants the next game frame drawn (the
/// eyes at the head's newest pose, or a stereo pair for the cabinet); the
/// game's thread draws it after each frame and leaves the result here.
final class StereoBridge: ObservableObject {
    static let shared = StereoBridge()
    /// The headset's scene (InsertCoinApp).
    static let spaceID = "headset"

    /// The headset view is open (main thread).
    @Published var open = false
    /// The game being played, for the headset view's settings (main thread).
    @Published var game: GameInfo?
    @Published var view = VRView.full { didSet { locked { loopView = view } } }
    /// Bumped to put the seat where the head is now.
    @Published var recentreCount = 0 { didSet { locked { loopRecentre = recentreCount } } }

    /// `view` and `recentreCount` for the render loop's thread.
    var viewForLoop: (view: VRView, recentre: Int) { locked { (loopView, loopRecentre) } }

    enum Request {
        case pair
        case head(eyes: [StereoEye], tag: UInt64)
    }

    /// What the game's thread drew for the headset after one frame.
    struct Frame {
        var count = 0                 // frames drawn so far; changes with every frame
        var screen = [UInt32]()       // the flat screen, always
        var screenWidth = 0, screenHeight = 0
        var stereo: StereoImages?     // nil on a 2D screen, or when the core has no stereo
        var head = false              // stereo is head-tracked (else a pair)
        var tag: UInt64 = 0           // the request's tag (the head pose it was drawn for)
    }

    private let lock = NSLock()
    private var request: Request?
    private var latest = Frame()
    private var loopView = VRView.full, loopRecentre = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Render loop: how to draw from the next game frame on (nil: nothing).
    func setRequest(_ r: Request?) {
        lock.lock()
        request = r
        lock.unlock()
    }

    /// Game thread: what to draw for the headset, if it is open.
    func currentRequest() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    /// Game thread: one frame's pictures for the headset.
    func publish(_ f: Frame) {
        lock.lock()
        var f = f
        f.count = latest.count + 1
        latest = f
        lock.unlock()
    }

    /// Render loop: the newest frame's pictures when newer than `count`.
    func frame(newerThan count: Int) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest.count != count ? latest : nil
    }

    /// Main thread: a game starts or ends.
    func play(_ g: GameInfo?) {
        game = g
        if let g { view = VRView.saved(for: g) }
        lock.lock()
        latest = Frame()
        lock.unlock()
    }
}
