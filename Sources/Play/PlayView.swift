import SwiftUI

// The game window shared by every app built on the kit (Insert Coin, Game
// Cabinet): the window a game plays in, its pause menu, the touch buttons,
// and the app delegates that turn the screen and quieten the Mac's menus.

#if os(macOS)
/// The Mac's menu bar has no File or Edit menu, and the window no tabs.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var keys: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false // and View's tab items
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Wheel.start() // steering wheels (IOKit HID): connected now, or later
        // The Edit menu's items carried the text keys; text fields keep them.
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let action: String? = switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "x"): "cut:"
            case (.command, "c"): "copy:"
            case (.command, "v"): "paste:"
            case (.command, "a"): "selectAll:"
            case (.command, "z"): "undo:"
            case ([.command, .shift], "z"): "redo:"
            default: nil
            }
            guard let action, NSApp.sendAction(Selector(action), to: nil, from: nil) else { return event }
            return nil
        }
    }

    /// SwiftUI builds the menu bar again from time to time; take the two
    /// menus out each time (found by their items, so in any language).
    func applicationWillUpdate(_ notification: Notification) {
        guard let bar = NSApp.mainMenu else { return }
        let unwanted = [#selector(NSWindow.performClose(_:)), Selector(("undo:")), #selector(NSText.copy(_:))]
        for item in bar.items.dropFirst() {
            let actions = item.submenu?.items.compactMap(\.action) ?? []
            if actions.contains(where: unwanted.contains), !actions.contains(#selector(NSWindow.performMiniaturize(_:))) {
                bar.removeItem(item) // File (Close) or Edit, never Window
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Wheel.shared.letGo() // the self-centring spring off, as the wheel starts
    }
}
#endif

#if os(iOS)
/// iPhone: the library turns upright too, a game is landscape only (the app
/// turns to landscape while one is up). iPad stays landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static var gameUp = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.gameUp || UIDevice.current.userInterfaceIdiom == .pad ? .landscape : .allButUpsideDown
    }

    /// Called as a game starts and stops.
    @MainActor static func game(_ up: Bool) {
        gameUp = up
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if up { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) }
        }
    }
}
#endif

/// The game full window, with the link status over it when linked, and
/// the pause menu over it when open.
struct PlayView: View {
    @ObservedObject var session: GameSession
    var onExit: () -> Void
    @Environment(\.scenePhase) private var phase
    @AppStorage(SettingKey.screenLook) private var globalLook = ScreenLook.standard.rawValue
    @AppStorage private var gameLook: String
    @AppStorage private var crosshair: Bool

    init(session: GameSession, onExit: @escaping () -> Void) {
        self.session = session
        self.onExit = onExit
        _gameLook = AppStorage(wrappedValue: "", ScreenLook.gameKey(session.game.id))
        _crosshair = AppStorage(wrappedValue: session.game.crosshairByDefault, SettingKey.crosshair(session.game.id))
    }

    private var look: ScreenLook { ScreenLook.resolved(global: globalLook, game: gameLook) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            #if os(tvOS)
            GameView(session: session, look: look, capture: session.stopped == nil) // the pause menu polls the controller too
                .ignoresSafeArea()
            #else
            GameView(session: session, look: look).underTitleBar()
            #endif
            if session.game.showsCrosshair && crosshair {
                CrosshairView(shown: session.controls.shown).underTitleBar()
            }
            if session.operatorMode {
                VStack {
                    Text(operatorHint)
                        .font(.caption.weight(.semibold)).padding(8)
                        .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.black).padding(.top, 60)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            if session.recording {
                VStack {
                    HStack {
                        Spacer()
                        Circle().fill(.red).frame(width: 12, height: 12)
                            .accessibilityLabel("Recording a replay")
                    }
                    Spacer()
                }
                .padding(.top, 70).padding(.trailing, 24)
                .allowsHitTesting(false)
            }
            if !session.status.isEmpty {
                Text(session.status)
                    .font(.caption).padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white).padding(12)
            }
            #if os(iOS)
            VStack {
                HStack(spacing: 12) {
                    Button { session.openMenu() } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.bordered).tint(.white)
                    SpeedLabel(speed: session.speed)
                    Spacer()
                    if session.operatorMode {
                        TouchButton(title: "Test", bit: UInt32(AFCORE_TEST), controls: session.controls)
                        TouchButton(title: "Service", bit: UInt32(AFCORE_SERVICE), controls: session.controls)
                    }
                    TouchButton(title: "Coin", bit: UInt32(AFCORE_COIN), controls: session.controls)
                    TouchButton(title: "Start", bit: UInt32(AFCORE_START), controls: session.controls)
                }
                .padding(16)
                Spacer()
            }
            #endif
            #if os(tvOS)
            VStack {
                HStack { Spacer(); SpeedLabel(speed: session.speed) }
                Spacer()
            }
            .padding(40)
            #endif
            #if os(macOS)
            VStack { // the window title has it too, but full screen has no title (#411)
                HStack { Spacer(); SpeedLabel(speed: session.speed) }
                Spacer()
            }
            .padding(12)
            .allowsHitTesting(false)
            #endif
        }
        #if os(macOS)
        .navigationTitle(session.speed.isEmpty ? session.game.title : "\(session.game.title) — \(session.speed)")
        .toolbar { if ThisRelease.headsetButton { ToolbarItem { HeadsetButton() } } }
        .focusedSceneValue(\.gameSession, session) // Help shows its controls
        #endif
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let game = session.game
            let byTouch = game.aimsGun && TouchControls.aimsByTouch(game.id) // the gun is the touch screen
            session.controls.touchAims = byTouch
            let layout: Controls.TouchLayout? = byTouch ? nil
                : game.aimsGun ? .gun(button: game.gunButton)
                : game.fighting ? .fighting : game.fishing ? .fishing : game.twin ? .twin
                : game.controls == .drive ? .drive : .standard
            session.controls.startTouchControls(TouchControls.resolved(game.id), layout: layout)
        }
        .onDisappear { session.controls.stopTouchControls() }
        #endif
        .overlay {
            if session.menuOpen { PauseMenu(session: session) }
        }
        .onNewValue(of: session.exitRequested) { exit in if exit { onExit() } }
        .alert("\(session.game.title) stopped", isPresented: Binding(get: { session.stopped != nil }, set: { _ in })) {
            Button("Back to the library") { onExit() }
        } message: {
            Text("The game reached something its core can't run yet:\n\(session.stopped ?? "")")
        }
        .onNewValue(of: phase) { p in
            // Leaving the app pauses under the menu: the game never carries on by itself.
            if p != .active { session.openMenu() }
            // and, with Resume where I left off, keeps it in the Resume slot (the system may end the app)
            if p == .background { session.saveResume() }
        }
    }
}

/// The window title's speed over the game: where there is no window title
/// (iPhone, iPad, Apple TV) and on the Mac for full screen (#411); only when
/// Settings has Show speed on.
private struct SpeedLabel: View {
    var speed: String
    @AppStorage(SettingKey.showSpeed) private var show = false

    var body: some View {
        if show, !speed.isEmpty {
            Text(speed)
                .font(.caption.monospacedDigit()).padding(6)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

extension PlayView {
    fileprivate var operatorHint: String {
        #if os(macOS)
        "Operator mode: controller A = Test, B = Service (or F2, F3). Pause to leave."
        #elseif os(tvOS)
        "Operator mode: A = Test, B = Service. Pause, then Leave operator mode."
        #else
        "Operator mode: A = Test, B = Service, or the buttons above. Pause to leave."
        #endif
    }
}

/// Resume, operator mode, the picture or Quit over the stopped game. A
/// controller or the keyboard moves the highlight (GameSession polls them,
/// on Apple TV too: GameView keeps the controller from tvOS's focus); the
/// mouse and touch work too.
struct PauseMenu: View {
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            #if os(macOS)
            if session.showControls {
                ControlsCard(game: session.game) { session.showControls = false }
            } else if session.showWheel {
                WheelPanel(model: session.wheelPanel) { session.showWheel = false }
            } else if let mode = session.slotMode {
                slots(mode)
            } else {
                items
            }
            #else
            if let mode = session.slotMode { slots(mode) } else { items }
            #endif
        }
    }

    private var items: some View {
        VStack(spacing: 16) {
            Text("Paused").font(.largeTitle.bold()).foregroundStyle(.white)
            Text(session.game.title).foregroundStyle(.white.opacity(0.7))
            ForEach(Array(session.menuItems.enumerated()), id: \.offset) { i, item in
                #if os(tvOS)
                row(item, i).frame(minWidth: 520) // not a Button: nothing here takes tvOS's focus
                #else
                Button {
                    session.menuIndex = i
                    session.choose(i)
                } label: {
                    row(item, i).frame(minWidth: 260)
                }
                .buttonStyle(.plain)
                #endif
            }
            if !session.slotNote.isEmpty {
                Text(session.slotNote).foregroundStyle(.yellow)
            }
        }
        .padding(40)
    }

    /// Save state or Load state: the three slots with their date and play
    /// time, the highlighted one's screen beside them.
    private func slots(_ mode: GameSession.SlotMode) -> some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(spacing: 16) {
                Text(mode == .save ? "Save state" : "Load state").font(.largeTitle.bold()).foregroundStyle(.white)
                Text(session.game.title).foregroundStyle(.white.opacity(0.7))
                ForEach(Array(session.slotLines.enumerated()), id: \.offset) { i, line in
                    #if os(tvOS)
                    row("Slot \(i + 1): \(line)", i, chosen: session.slotIndex).frame(minWidth: 720)
                    #else
                    Button {
                        session.slotIndex = i
                        session.chooseSlot(i)
                    } label: {
                        row("Slot \(i + 1): \(line)", i, chosen: session.slotIndex).frame(minWidth: 360)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                Text(mode == .save ? "Saving replaces what the slot holds."
                     : "Loading puts the game's settings and records back to that moment too.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                #if !os(tvOS)
                Button("Back") { session.slotMode = nil }.buttonStyle(.bordered)
                #endif
            }
            if let image = Pictures.load(session.slotPicture(session.slotIndex)) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(4 / 3, contentMode: .fit)
                    .frame(width: 320).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(40)
    }

    private func row(_ item: String, _ i: Int, chosen: Int? = nil) -> some View {
        let on = i == (chosen ?? session.menuIndex)
        return Text(item).font(.title2.weight(.semibold)).padding(.vertical, 12).padding(.horizontal, 24)
            .background(on ? Self.highlight : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(on ? Self.highlightText : Color.white)
    }

    // Apple TV's accent colour is white: its highlight is white with dark
    // text, like a focused button there.
    #if os(tvOS)
    private static let highlight = Color.white
    private static let highlightText = Color.black
    #else
    private static let highlight = Color.accentColor
    private static let highlightText = Color.white
    #endif
}

#if os(iOS)
/// A cabinet button on the touch screen, held while touched.
struct TouchButton: View {
    let title: String
    let bit: UInt32
    let controls: Controls
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white.opacity(down ? 0.5 : 0.2), in: Capsule())
            .foregroundStyle(.white)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !down { down = true; controls.touchButtons |= bit }
                }
                .onEnded { _ in
                    down = false
                    controls.touchButtons &= ~bit
                })
    }
}
#endif

private extension View {
    /// The game fills the screen on iOS and tvOS. On macOS it stays below
    /// the window's title bar, which macOS draws over the content.
    @ViewBuilder func underTitleBar() -> some View {
        #if os(macOS)
        self
        #else
        ignoresSafeArea()
        #endif
    }
}

private extension View {
    /// onChange with the new value, without the macOS 14 deprecation: the
    /// two-value form on the Mac and on iOS and tvOS 17 and later; iOS and
    /// tvOS 16 keep the one-value form.
    @ViewBuilder func onNewValue<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        #if os(macOS)
        onChange(of: value) { _, new in action(new) }
        #else
        if #available(iOS 17, tvOS 17, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
        #endif
    }
}
