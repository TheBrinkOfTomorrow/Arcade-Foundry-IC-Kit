import CoreVideo
import Foundation
import QuartzCore
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// A game being played: the core, its sound and its controls. Frames follow
/// the board's own rate (57.52 a second), so 60 Hz and 120 Hz displays both
/// play at the arcade's speed. Each display refresh (tick, on the main
/// thread) reads the controls and runs the frames due, or, with "Game on
/// its own thread" (SettingKey.coreThread, per device, on by default),
/// leaves them to a thread of its own so a slow frame never holds up the
/// display; either way the view draws the newest screen.
final class GameSession: ObservableObject {
    let game: GameInfo
    let core: GameCore
    let audio = AudioOutput()
    let controls = Controls()
    @Published var status = ""
    /// The speed shown in the window title (macOS) or a corner of the game
    /// (iOS, tvOS): display refreshes and game frames a second, the game's
    /// as a share of the board's rate.
    @Published private(set) var speed = ""
    @Published var exitRequested = false
    /// The core stopped (see GameCore.error): shown, then back to the library.
    @Published var stopped: String?
    /// The pause menu (Resume, Quit to library) and its highlighted item.
    @Published private(set) var menuOpen = false
    /// The game's controls over the pause menu (Help on the Mac).
    @Published var showControls = false
    /// Wheel and pedals over the pause menu (macOS: WheelSettingsSection).
    @Published var showWheel = false
    #if os(macOS)
    let wheelPanel = WheelPanelModel()
    #endif
    @Published var menuIndex = 0
    /// Operator mode: A and B are the cabinet's TEST and SERVICE buttons
    /// (Controls.operatorMode), for test mode where there is no F2/F3.
    @Published private(set) var operatorMode = false
    enum MenuItem { case resume, saveState, loadState, operatorMode, picture, record, thread, wheel, screen3D, vrView, recentre, quit }
    var menu: [MenuItem] {
        var items: [MenuItem] = [.resume]
        if statesAllowed { items += [.saveState, .loadState] }
        items += [.operatorMode, .picture]
        if replay != nil { items.append(.record) }
        items.append(.thread)
        #if os(macOS)
        items.append(.wheel)
        #endif
        if hasStereo { items.append(.screen3D) }
        if StereoBridge.shared.open { items += [.vrView, .recentre] }
        return items + [.quit]
    }
    var menuItems: [String] {
        menu.map {
            switch $0 {
            case .resume: "Resume"
            case .saveState: "Save state"
            case .loadState: "Load state"
            case .operatorMode: operatorMode ? "Leave operator mode" : "Operator mode (Test, Service)"
            case .picture: "Use this screen as the picture"
            case .record: "Record replay: \(recording ? "on" : "off")"
            case .thread: "Game on its own thread: \(threaded ? "on" : "off")"
            case .wheel: "Wheel and pedals"
            case .screen3D: "3D on this screen: \(screen3D.title)"
            case .vrView: "Headset view: \(StereoBridge.shared.view.title)"
            case .recentre: "Recentre the headset view"
            case .quit: "Quit to library"
            }
        }
    }
    /// Save state and Load state (SaveStates): the core has them, and the
    /// game isn't linked (the other cabinets can't go back with this one)
    /// nor in Game Cabinet (its Game Director's games are linked).
    let statesAllowed: Bool
    enum SlotMode { case save, load }
    /// Save state or Load state is open over the pause menu: its slots (1 to
    /// SaveStates.slots), the one highlighted (0-based).
    @Published var slotMode: SlotMode?
    @Published var slotIndex = 0
    /// Under the pause menu: what Save state or Load state did, or "".
    @Published private(set) var slotNote = ""
    /// Each slot's date and play time, for the slots screen.
    var slotLines: [String] {
        (1...SaveStates.slots).map { SaveStates.describe(SaveStates.slot(game.id, $0), coreVersion: core.library.version) }
    }
    func slotPicture(_ index: Int) -> URL { SaveStates.file(game.id, index + 1, "png") }

    /// The core draws its scene for two eyes (afcore.h 4.15).
    let hasStereo: Bool
    /// The stereo picture on this screen (SettingKey.screen3D); changed under the pause menu.
    @Published private(set) var screen3D = Screen3D(rawValue: UserDefaults.standard.string(forKey: SettingKey.screen3D) ?? "") ?? .off
    /// The game's inputs since it booted, for a replay (issue #145); nil
    /// with link play (the other cabinets are not in it).
    private let replay: ReplayRecorder?
    /// "Record replay" (ReplayRecorder.enabled): the replay is saved when the game ends.
    @Published private(set) var recording: Bool
    /// The core runs on its own thread (SettingKey.coreThread); changed under the pause menu.
    @Published private(set) var threaded = UserDefaults.standard.object(forKey: SettingKey.coreThread) as? Bool ?? true

    // Main thread only.
    private var paused = false
    private var statsStart: CFTimeInterval = 0
    private var statsTicks = 0, statsFramesSeen = 0
    private var screenSeen = 0

    // Shared with the core thread, under `lock`.
    private let lock = NSLock()
    private var input: afcore_input? // the controls as last read, nil until the first refresh
    private var running = true // false under the pause menu and once the core stopped
    private var coreThreaded = false // `threaded`, for the core thread
    private var coreScreen3D = Screen3D.off // `screen3D`, for the core thread
    private var quit = false
    private var framesRun = 0
    private var screen = [UInt32](), screenWidth = 0, screenHeight = 0, screenCount = 0
    private var surface: CVPixelBuffer? // the screen as the core's GPU buffer, in place of `screen` (screenSurface)

    /// Held while the core runs a frame, so saving (pause, stop) waits for it.
    private let coreLock = NSLock()
    private let coreDone = DispatchSemaphore(value: 0)

    // Whoever runs the frames (the main thread, or the core thread when threaded).
    private var last: CFTimeInterval = 0
    private var owed = 0.0 // frames due
    private var frame = 0
    private var audioBuffer = [Float](repeating: 0, count: 2 * 4096)
    private var backScreen = [UInt32](), backWidth = 0, backHeight = 0
    private var backSurface: CVPixelBuffer?

    /// `resume`: from the game's Resume slot (SaveStates); else from
    /// power-on, which drops the Resume slot (the saves move on past it).
    init(game: GameInfo, library: CoreLibrary, rom: URL, volume: Double, resume: Bool = false) throws {
        self.game = game
        let link = LinkSettings(romset: game.id)
        // Not on Apple TV yet: its replays have no way to the Mac (no iCloud Drive).
        #if os(tvOS) || CABINET
        replay = nil // the player: no Replays folder (no iCloud Drive)
        #else
        replay = game.link && link.enabled ? nil : ReplayRecorder(game: game, library: library, saveDir: Storage.saves(game.id))
        #endif
        recording = replay != nil && ReplayRecorder.enabled(game.id)
        core = try GameCore(library: library, romURL: rom, saveDir: Storage.saves(game.id))
        hasStereo = core.hasStereo
        #if CABINET
        statesAllowed = false
        #else
        statesAllowed = core.hasStates && !(game.link && link.enabled)
        #endif
        if statesAllowed && resume {
            do {
                try core.loadState(SaveStates.read(romset: game.id, slot: 0))
                replay?.ended = true // the replay would start from power-on
            } catch {
                status = "Resume didn't load (\(error.localizedDescription)): the game starts from the beginning"
            }
        } else if statesAllowed && SaveStates.slot(game.id, 0) != nil {
            SaveStates.remove(romset: game.id, slot: 0)
            #if !CABINET
            let romset = game.id
            Task { await SaveSync.uploadResume(romset) } // the cabinet's copy goes too
            #endif
        }
        coreScreen3D = hasStereo ? screen3D : .off
        if game.link && link.enabled {
            try core.startLink(listenPort: link.port, next: link.next, frameSync: link.frameSync)
        }
        audio.volume = Float(volume)
        controls.drive = game.controls == .drive
        controls.flight = game.flight
        controls.twin = game.twin
        controls.analogGun = game.analogGun
        controls.gun = game.aimsGun
        controls.gunButton = game.gunButton
        controls.gunStart = game.gunStart
        controls.stickY = game.stickY
        controls.fishing = game.fishing
        controls.map = ButtonMap.load(game.id)
        audio.start(rates: [core.audioRate(0), core.audioRate(1), core.audioRate(2)])
        coreThreaded = threaded
        let thread = Thread { [self] in runCore() }
        thread.name = "Arcade Foundry core"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// One display refresh: the pause menu, or the controls for the core
    /// and, unless it has its own thread, the frames due.
    func tick() {
        defer { countSpeed() }
        if menuOpen {
            for command in controls.menuCommands() {
                if showControls { // the controls card: any key or button goes back to the menu
                    if command == .select || command == .close { showControls = false }
                    continue
                }
                if let mode = slotMode { // Save state or Load state's slots
                    switch command {
                    case .up: slotIndex = max(0, slotIndex - 1)
                    case .down: slotIndex = min(SaveStates.slots - 1, slotIndex + 1)
                    case .select: useSlot(slotIndex, mode)
                    case .close: slotMode = nil
                    case .left, .right, .clear: break
                    }
                    continue
                }
                if showWheel { // its own rows (WheelPanelModel); B at the top goes back
                    #if os(macOS)
                    if !wheelPanel.handle(command) { showWheel = false }
                    #else
                    showWheel = false
                    #endif
                    continue
                }
                switch command {
                case .up: menuIndex = max(0, menuIndex - 1)
                case .down: menuIndex = min(menuItems.count - 1, menuIndex + 1)
                case .select: choose(menuIndex)
                case .close: closeMenu()
                case .left, .right, .clear: break
                }
            }
            return
        }
        guard !paused else { return }
        var sampled = controls.sample()
        // A streamed seat: the player's controls come from the Game Director instead.
        if let r = remoteInput { sampled = r }
        if controls.pauseRequested {
            controls.pauseRequested = false
            openMenu()
            return
        }
        noteInputs(sampled)
        lock.lock()
        input = sampled
        lock.unlock()
        if !threaded { _ = runDue(sampled, upTo: .max) }
    }

    /// The player's own inputs since the game started, for the Game
    /// Director's "racing" rule (Game Cabinet reports them in its state):
    /// Coin and Start presses, and when the wheel or pedals last moved.
    struct PlayerInputs {
        var coins = 0
        var starts = 0
        var lastDrive: Date?
    }
    /// Read on the thread that runs `tick`.
    private(set) var playerInputs = PlayerInputs()
    private var heldButtons: UInt32 = 0
    private var lastSteer: Float = 0

    private func noteInputs(_ s: afcore_input) {
        let pressed = s.buttons & ~heldButtons
        heldButtons = s.buttons
        if pressed & UInt32(AFCORE_COIN) != 0 { playerInputs.coins += 1 }
        if pressed & (UInt32(AFCORE_START) | UInt32(AFCORE_START2)) != 0 { playerInputs.starts += 1 }
        if s.accel > 0.2 || s.brake > 0.2 || abs(s.steer - lastSteer) > 0.05 { playerInputs.lastDrive = Date() }
        lastSteer = s.steer
    }

    /// Hands the core's newest screen to the view when there is one it has
    /// not drawn yet: as the core's GPU buffer where it gives one, else as pixels.
    func newScreen(pixels draw: (UnsafePointer<UInt32>, Int, Int) -> Void, surface show: (CVPixelBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard screenCount != screenSeen, screenWidth > 0 else { return }
        screenSeen = screenCount
        if let surface {
            show(surface)
            tap?(.surface(surface))
        } else {
            screen.withUnsafeBufferPointer {
                draw($0.baseAddress!, screenWidth, screenHeight)
                tap?(.pixels($0.baseAddress!, screenWidth, screenHeight))
            }
        }
    }

    /// A new screen as `newScreen` hands it to the view.
    enum Screen {
        /// XRGB8888 (BGRA in memory), width * 4 bytes a row.
        case pixels(UnsafePointer<UInt32>, Int, Int)
        /// The core's GPU buffer (BGRA).
        case surface(CVPixelBuffer)
    }

    /// Each new screen the view draws, on the view's thread with the
    /// session's lock held: copy the pixels or retain the buffer and return.
    /// Game Cabinet sends the Game Director's spectator seat from it.
    var screenTap: ((Screen) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return tap }
        set { lock.lock(); tap = newValue; lock.unlock() }
    }
    private var tap: ((Screen) -> Void)?

    /// The game's sound as it's made, on the core's thread: the stream (the
    /// sound board's two, Star Wars Arcade's Digital Sound Board), its rate
    /// in Hz, and that many stereo frames (interleaved floats). Copy and
    /// return. Game Cabinet streams a seat's sound to the Game Director from it.
    var soundTap: ((Int, Double, UnsafePointer<Float>, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return soundSink }
        set { lock.lock(); soundSink = newValue; lock.unlock() }
    }
    private var soundSink: ((Int, Double, UnsafePointer<Float>, Int) -> Void)?

    /// A streamed seat's controls (Game Director, GAME-DIRECTOR-PART2.md
    /// "2b plan"): while set, the game takes these instead of this device's
    /// own; nil hands it back. Set from any thread.
    var remoteInput: afcore_input? {
        get { lock.lock(); defer { lock.unlock() }; return remote }
        set { lock.lock(); remote = newValue; lock.unlock() }
    }
    private var remote: afcore_input?

    /// The core thread: runs the frames due while the game has its own
    /// thread, and waits for the next.
    private func runCore() {
        while true {
            lock.lock()
            let (ending, go, sampled) = (quit, running && coreThreaded, input)
            lock.unlock()
            if ending { break }
            guard go, let sampled else {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let wait = runDue(sampled, upTo: 1)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        coreDone.signal()
    }

    /// Runs up to `limit` of the frames due by the board's clock; returns
    /// how long until the next is due.
    private func runDue(_ sampled: afcore_input, upTo limit: Int) -> Double {
        let hz = core.library.frameHz
        let now = CACurrentMediaTime()
        if last == 0 { last = now }
        owed += (now - last) * hz
        last = now
        if owed > 4 { owed = 1 } // a stall (window drag, debugger): skip ahead rather than race
        var ran = 0
        while owed >= 1 && ran < limit {
            owed -= 1
            guard runFrame(sampled) else { return 0.005 }
            ran += 1
        }
        return max(0, (1 - owed) / hz)
    }

    /// One frame: its sound to the audio thread, its screen to the view.
    /// False when the game is paused or stopped instead.
    private func runFrame(_ sampled: afcore_input) -> Bool {
        let hz = core.library.frameHz
        coreLock.lock()
        lock.lock()
        let still = running && !quit // pause() may have saved since the caller looked
        lock.unlock()
        guard still else { coreLock.unlock(); return false }
        replay?.add(sampled)
        core.runFrame(sampled)
        let reason = core.error()
        if reason == nil {
            drainAudio()
            copyScreen()
            drawStereo()
        }
        frame += 1
        let link = frame % 30 == 0 ? linkStatus() : nil
        coreLock.unlock()

        if let reason {
            lock.lock()
            running = false
            lock.unlock()
            DispatchQueue.main.async { [self] in
                paused = true
                stopped = reason
            }
            return false
        }
        lock.lock()
        swap(&screen, &backScreen)
        surface = backSurface
        (screenWidth, screenHeight) = (backWidth, backHeight)
        screenCount += 1
        framesRun += 1
        lock.unlock()
        if let link {
            DispatchQueue.main.async { [self] in if status != link { status = link } }
        }
        // A game without a picture takes one after half a minute (Pictures),
        // or two and a half on the slow booting boards.
        if frame == Int(hz * Pictures.screenAfter(game.platform)) {
            DispatchQueue.main.async { [self] in if !Pictures.exists(game.id) && !Pictures.hasOwn(game.id) { savePicture(own: false) } }
        }
        return true
    }

    /// The core's screen into `backScreen` (under coreLock).
    private func copyScreen() {
        // A core that gives its screen as a GPU buffer: no copy (Lindbergh
        // on iOS, Model 3 with Metal). Not while this screen shows a 3D
        // picture, which is drawn into backScreen (drawStereo).
        lock.lock()
        let flat = coreScreen3D == .off
        lock.unlock()
        if flat, let s = core.screenSurface() {
            backSurface = s
            (backWidth, backHeight) = (CVPixelBufferGetWidth(s), CVPixelBufferGetHeight(s))
            return
        }
        backSurface = nil
        let s = core.screen()
        let n = s.width * s.height
        if backScreen.count != n { backScreen = [UInt32](repeating: 0, count: n) }
        backScreen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: s.pixels, count: n) }
        (backWidth, backHeight) = (s.width, s.height)
    }

    /// The stereo pictures (under coreLock): this screen's 3D in place of
    /// `backScreen`, and the headset's frame when its view is open.
    private func drawStereo() {
        let request = StereoBridge.shared.currentRequest()
        guard hasStereo || request != nil else { return }
        lock.lock()
        let mode = coreScreen3D
        lock.unlock()
        var pair: StereoImages?
        if mode != .off, let p = core.renderPair() {
            pair = p
            let (w, h) = (p.width, p.height)
            switch mode {
            case .sideBySide:
                if backScreen.count != 2 * w * h { backScreen = [UInt32](repeating: 0, count: 2 * w * h) }
                for y in 0..<h {
                    backScreen.replaceSubrange((2 * y * w)..<(2 * y * w + w), with: p.left[(y * w)..<(y * w + w)])
                    backScreen.replaceSubrange((2 * y * w + w)..<(2 * y * w + 2 * w), with: p.right[(y * w)..<(y * w + w)])
                }
                (backWidth, backHeight) = (2 * w, h)
            case .redCyan: // red from the left eye, green and blue from the right
                if backScreen.count != w * h { backScreen = [UInt32](repeating: 0, count: w * h) }
                for i in 0..<(w * h) { backScreen[i] = (p.left[i] & 0xffff_0000) | (p.right[i] & 0x0000_ffff) }
                (backWidth, backHeight) = (w, h)
            case .off: break
            }
        }
        guard let request else { return }
        var f = StereoBridge.Frame()
        let s = core.screen()
        f.screen = [UInt32](UnsafeBufferPointer(start: s.pixels, count: s.width * s.height))
        (f.screenWidth, f.screenHeight) = (s.width, s.height)
        switch request {
        case .pair:
            f.stereo = pair ?? core.renderPair()
        case .head(let eyes, let tag):
            f.stereo = core.renderHead(eyes)
            f.head = true
            f.tag = tag
        }
        StereoBridge.shared.publish(f)
    }

    /// The last second's display refreshes and game frames a second
    /// (`countSpeed`), for the Game Director's race log.
    private var screenFps = 0.0, gameFps = 0.0

    /// How the game runs, for the Game Director's race log: frames run so far, the
    /// last second's refreshes and game frames a second, the speed as a
    /// share of the board's frame rate, and whether it's paused.
    func stats() -> [String: Any] {
        lock.lock()
        let frames = framesRun
        lock.unlock()
        let hz = core.library.frameHz
        return ["frames": frames, "fps": (screenFps * 10).rounded() / 10, "gameFps": (gameFps * 10).rounded() / 10,
                "speedPct": hz > 0 ? (1000 * gameFps / hz).rounded() / 10 : 0, "paused": menuOpen || paused]
    }

    /// Counts a display refresh; once a second sets `speed` from the
    /// refreshes and the frames the core ran ("60 fps · game 57.5 fps (100%)").
    private func countSpeed() {
        let now = CACurrentMediaTime()
        if statsStart == 0 {
            statsStart = now
            lock.lock()
            statsFramesSeen = framesRun
            lock.unlock()
        }
        statsTicks += 1
        let span = now - statsStart
        guard span >= 1 else { return }
        lock.lock()
        let frames = framesRun - statsFramesSeen
        statsFramesSeen = framesRun
        lock.unlock()
        let screen = Double(statsTicks) / span, game = Double(frames) / span
        screenFps = screen
        gameFps = menuOpen || paused ? 0 : game
        speed = menuOpen || paused ? String(format: "%.0f fps · paused", screen)
            : String(format: "%.0f fps · game %.1f fps (%.0f%%)", screen, game, 100 * game / core.library.frameHz)
        statsStart = now
        statsTicks = 0
    }

    private func drainAudio() {
        let sink = soundTap
        audioBuffer.withUnsafeMutableBufferPointer { buf in
            for stream in 0..<3 { // the sound board's two, Star Wars Arcade's Digital Sound Board
                while true {
                    let n = core.readAudio(stream, into: buf.baseAddress!, maxFrames: buf.count / 2)
                    if n == 0 { break }
                    if stream < audio.rings.count, let ring = audio.rings[stream] {
                        ring.write(buf.baseAddress!, frames: n)
                    }
                    if let sink { sink(stream, core.audioRate(stream), buf.baseAddress!, n) }
                }
            }
        }
    }

    /// The link's state for `status` (core thread, under coreLock), or nil when not linked.
    private func linkStatus() -> String? {
        guard game.link && LinkSettings(romset: game.id).enabled else { return nil }
        switch core.linkState {
        case .off:
            #if CABINET
            // The Game Director sent the seat's settings: the game just hasn't started its link yet (booting).
            return "Link: waiting for the game to start its link"
            #else
            return "Link on: set the cabinet in test mode (F2)"
            #endif
        case .waiting: return "Link: looking for the other cabinets"
        case .up(let id, let count): return "Linked: cabinet \(id) of \(count)"
        case .lost: return "Link lost: leave and start the game again"
        }
    }

    func setVolume(_ v: Double) { audio.volume = Float(v) }

    /// Stops the game under the pause menu (its settings saved and backed up).
    func openMenu() {
        guard !menuOpen else { return }
        menuIndex = 0
        menuOpen = true
        pause()
    }

    func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        slotMode = nil
        slotNote = ""
        showControls = false
        showWheel = false
        #if os(macOS)
        wheelPanel.close()
        #endif
        resume()
    }

    func choose(_ index: Int) {
        guard menu.indices.contains(index) else { return }
        slotNote = ""
        switch menu[index] {
        case .resume: closeMenu()
        case .saveState, .loadState:
            slotIndex = 0
            slotMode = menu[index] == .saveState ? .save : .load
        case .operatorMode:
            operatorMode.toggle()
            controls.operatorMode = operatorMode
            closeMenu()
        case .picture:
            savePicture(own: true) // the screen under the menu, as the player's own
            closeMenu()
        case .record:
            recording.toggle()
            UserDefaults.standard.set(recording ? "on" : "off", forKey: ReplayRecorder.key(game.id)) // this game's own, as on its page
        case .thread:
            // Safe to hand over here: the game is paused under the menu.
            threaded.toggle()
            UserDefaults.standard.set(threaded, forKey: SettingKey.coreThread)
            lock.lock()
            coreThreaded = threaded
            lock.unlock()
        case .screen3D:
            screen3D = screen3D.next
            UserDefaults.standard.set(screen3D.rawValue, forKey: SettingKey.screen3D)
            lock.lock()
            coreScreen3D = screen3D
            lock.unlock()
        case .vrView:
            let bridge = StereoBridge.shared
            bridge.view = bridge.view == .full ? .cabinet : .full
            bridge.view.save(for: game)
            objectWillChange.send()
        case .recentre:
            StereoBridge.shared.recentreCount += 1
            closeMenu()
        case .wheel:
            #if os(macOS)
            wheelPanel.open()
            #endif
            showWheel = true
        case .quit: exitRequested = true
        }
    }

    /// The game's screen as its picture in the library: the player's own
    /// (the pause menu) or the app's (after half a minute).
    private func savePicture(own: Bool) {
        withScreen { Pictures.save(game.id, own: own, pixels: $0, width: $1, height: $2) }
    }

    /// The newest screen's pixels (BGRA), from the core's GPU buffer or
    /// its copy; nothing when there is no screen yet.
    private func withScreen(_ use: (UnsafePointer<UInt32>, Int, Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard screenWidth > 0 else { return } // no screen yet
        if let surface {
            CVPixelBufferLockBaseAddress(surface, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(surface, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(surface) else { return }
            let stride = CVPixelBufferGetBytesPerRow(surface)
            var pixels = [UInt32](repeating: 0, count: screenWidth * screenHeight)
            for y in 0..<screenHeight {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<screenWidth { pixels[y * screenWidth + x] = row[x] | 0xff00_0000 }
            }
            pixels.withUnsafeBufferPointer { use($0.baseAddress!, screenWidth, screenHeight) }
            return
        }
        screen.withUnsafeBufferPointer { use($0.baseAddress!, screenWidth, screenHeight) }
    }

    /// Saves the board into a slot (0 Resume, 1 to 3 the player's), with
    /// the screen as its picture. Paused (the pause menu) or stopped: no
    /// frame runs meanwhile.
    private func saveSlot(_ slot: Int) throws {
        coreLock.lock()
        defer { coreLock.unlock() }
        let state = try core.saveState()
        try SaveStates.write(state, romset: game.id, slot: slot, coreVersion: core.library.version, frameHz: core.library.frameHz)
        let picture = SaveStates.file(game.id, slot, "png")
        try? FileManager.default.removeItem(at: picture)
        withScreen { Pictures.save(pixels: $0, width: $1, height: $2, to: picture) }
    }

    /// A slot clicked or touched on the slots screen.
    func chooseSlot(_ index: Int) {
        if let mode = slotMode { useSlot(index, mode) }
    }

    /// Save state or Load state's slot `index` (0-based) chosen.
    private func useSlot(_ index: Int, _ mode: SlotMode) {
        let slot = index + 1
        slotMode = nil
        do {
            switch mode {
            case .save:
                try saveSlot(slot)
                slotNote = "Saved in slot \(slot)"
            case .load:
                let state = try SaveStates.read(romset: game.id, slot: slot)
                coreLock.lock()
                defer { coreLock.unlock() }
                try core.loadState(state)
                replay?.ended = true // the replay so far is kept, ending here
                for ring in audio.rings { ring?.clear() } // the sound queued was from before it
                closeMenu() // back in the game, at that frame
            }
        } catch {
            slotNote = error.localizedDescription
        }
    }

    /// Resume where I left off: the game as it is now into its Resume slot
    /// (leaving the game, or the app going to the background).
    func saveResume() {
        guard statesAllowed, SaveStates.resumeOn, stopped == nil else { return }
        lock.lock()
        let played = framesRun > 0
        lock.unlock()
        guard played else { return }
        #if os(iOS) || os(tvOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Resume slot", expirationHandler: nil)
        defer { UIApplication.shared.endBackgroundTask(task) }
        #endif
        guard (try? saveSlot(0)) != nil else { return }
        #if !CABINET
        let romset = game.id
        #if os(iOS) || os(tvOS)
        Task { @MainActor in
            let upload = UIApplication.shared.beginBackgroundTask(withName: "Back up the Resume slot", expirationHandler: nil)
            await SaveSync.uploadResume(romset)
            UIApplication.shared.endBackgroundTask(upload)
        }
        #else
        Task { await SaveSync.uploadResume(romset) }
        #endif
        #endif
    }

    func pause() {
        paused = true
        lock.lock()
        running = false
        let ended = quit
        lock.unlock()
        guard !ended else { return } // stopped: the core is closed
        audio.pause()
        coreLock.lock() // the frame under way, if any, ends first
        core.save()
        coreLock.unlock()
        backUp()
    }

    func resume() {
        paused = false
        last = 0
        lock.lock()
        running = stopped == nil
        lock.unlock()
        audio.resume()
    }

    /// Ends the core thread and saves; the session is done.
    func stop() {
        lock.lock()
        let already = quit
        quit = true
        lock.unlock()
        guard !already else { return }
        coreDone.wait()
        audio.stop()
        saveResume()
        core.save()
        backUp()
        if recording { replay?.save(into: CloudROMs.shared.folder) }
        core.close() // the next game can start at once (GameCore.close)
    }

    /// Backs the saves up to iCloud as this cabinet's (see SaveSync), with
    /// time to finish if the app is going to the background.
    private func backUp() {
        #if CABINET
        return // Game Cabinet has no iCloud: its saves stay on the device
        #else
        let romset = game.id
        #if os(iOS) || os(tvOS)
        Task { @MainActor in
            let task = UIApplication.shared.beginBackgroundTask(withName: "Back up saves", expirationHandler: nil)
            await SaveSync.upload(romset)
            UIApplication.shared.endBackgroundTask(task)
        }
        #else
        Task { await SaveSync.upload(romset) }
        #endif
        #endif
    }
}
