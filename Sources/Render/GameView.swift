import GameController
import MetalKit
import SwiftUI

/// The light gun games' crosshair, drawn where the gun aims when it is
/// aimed with a controller's stick (always on Apple TV; on the Mac and iPad
/// while a controller is connected, since the mouse and touch show where
/// they are). Player 2's, in blue, once player 2 pressed Start on a second
/// controller.
/// The game view moves them each frame the aim moves (AimShown).
struct CrosshairView: View {
    @ObservedObject var shown: AimShown

    var body: some View {
        GeometryReader { geo in
            if Self.visible {
                let p = shown.picture
                let r = CGRect(x: p.minX * geo.size.width, y: p.minY * geo.size.height,
                               width: p.width * geo.size.width, height: p.height * geo.size.height)
                if shown.second { crosshair(shown.aim2, .blue, in: r) }
                crosshair(shown.aim, .red, in: r)
            }
        }
        .allowsHitTesting(false)
    }

    private func crosshair(_ aim: SIMD2<Float>, _ color: Color, in r: CGRect) -> some View {
        Image(systemName: "scope")
            .font(.system(size: max(24, r.width / 22), weight: .bold))
            .foregroundStyle(color)
            .shadow(color: .black, radius: 2)
            .position(x: r.minX + CGFloat(aim.x) * r.width, y: r.minY + CGFloat(aim.y) * r.height)
    }

    private static var visible: Bool {
        #if os(tvOS)
        return true
        #else
        return GCController.controllers().contains { $0.extendedGamepad != nil && !$0.isSnapshot }
        #endif
    }
}

/// Controls.aim and the picture's place, published for CrosshairView by
/// the game view when they change (Controls itself is read every frame and
/// publishes nothing).
final class AimShown: ObservableObject {
    @Published var aim = SIMD2<Float>(0.5, 0.5)
    @Published var aim2 = SIMD2<Float>(0.5, 0.5) // player 2's (Controls.aim2)
    @Published var second = false                // player 2 has a controller and pressed Start on it (Controls.secondJoined)
    @Published var picture = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// The game's screen in SwiftUI: an MTKView that ticks the session on each
/// display refresh and draws the core's latest screen through a Metal texture.
final class GameViewCoordinator: NSObject, MTKViewDelegate {
    let session: GameSession
    var renderer: ScreenRenderer?
    var look = ScreenLook()

    init(session: GameSession) { self.session = session }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer else { return }
        session.tick()
        session.newScreen(pixels: { renderer.upload($0, width: $1, height: $2) }, surface: { renderer.show($0) })
        renderer.look = look
        renderer.squarePixels = session.game.platform == .lindbergh
        renderer.draw(in: view)
        let controls = session.controls
        controls.picture = renderer.picture
        if controls.shown.aim != controls.aim { controls.shown.aim = controls.aim }
        if controls.shown.aim2 != controls.aim2 { controls.shown.aim2 = controls.aim2 }
        let second = controls.secondGun && controls.secondJoined
        if controls.shown.second != second { controls.shown.second = second }
        if controls.shown.picture != controls.picture { controls.shown.picture = controls.picture }
    }

    func makeView() -> MTKView {
        let view = GameMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.preferredFramesPerSecond = 120 // the core thread keeps the board's clock; the display shows its newest screen
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        renderer = ScreenRenderer(view: view)
        view.controls = session.controls
        #if os(iOS)
        view.isMultipleTouchEnabled = true // a second finger reloads Virtua Cop 2's gun
        #endif
        view.delegate = self
        return view
    }
}

/// The game reads the keyboard through GameController; on macOS the view
/// also takes the key events, so AppKit does not beep at keys nothing
/// handles.
final class GameMTKView: MTKView {
    /// Virtua Cop 2's gun follows the mouse or a touch (Controls.aim).
    weak var controls: Controls?

    /// A point in the view as 0...1 across and down the game's picture
    /// (where ScreenRenderer last drew it); top-left origin.
    private func picture(_ x: CGFloat, _ yFromTop: CGFloat) -> SIMD2<Float> {
        let p = controls?.picture ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        return SIMD2<Float>(Float((x / w - p.minX) / max(p.width, 0.001)), Float((yFromTop / h - p.minY) / max(p.height, 0.001)))
    }

    #if os(macOS)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controls?.aim = picture(p.x, isFlipped ? p.y : bounds.height - p.y)
    }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func rightMouseDragged(with event: NSEvent) { track(event) }
    override func mouseDown(with event: NSEvent) { track(event); controls?.pointerFire = true }
    override func mouseUp(with event: NSEvent) { controls?.pointerFire = false }
    override func rightMouseDown(with event: NSEvent) { controls?.pointerReload = true }
    override func rightMouseUp(with event: NSEvent) { controls?.pointerReload = false }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { controls?.pointerGrenade = true } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { controls?.pointerGrenade = false } }
    override var acceptsFirstResponder: Bool { true }
    /// Escape for the pause menu, from AppKit's key events: GCKeyboard did not
    /// report it on the Mac (#407). A local monitor sees the key whichever view
    /// has focus, the pause menu's included; only this window's, no repeats.
    private var escapeMonitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
        guard window != nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window, let controls = self.controls else { return event }
            if !event.isARepeat { controls.escapePressed = true }
            return nil
        }
    }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    #elseif os(iOS)
    // One finger aims and fires where it touches; a second finger reloads, a
    // third throws HotD4's grenade instead.
    // Only in the gun games aimed by touch (Controls.touchAims, #359).
    private func touch(_ event: UIEvent?) {
        guard controls?.touchAims == true else { return }
        let down = (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        if let first = down.first(where: { $0.view === self }) {
            let p = first.location(in: self)
            controls?.aim = picture(p.x, p.y)
        }
        controls?.pointerFire = !down.isEmpty && down.count < 3
        controls?.pointerReload = down.count == 2
        controls?.pointerGrenade = down.count >= 3
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touch(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touch(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touch(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touch(event) }
    #elseif os(tvOS)
    /// Focused while a game plays, so its GCEventViewController is the one
    /// tvOS sends the controller to (GameView).
    var focusable = true
    override var canBecomeFocused: Bool { focusable }
    #endif
}

#if os(macOS)
struct GameView: NSViewRepresentable {
    let session: GameSession
    var look: ScreenLook

    func makeCoordinator() -> GameViewCoordinator { GameViewCoordinator(session: session) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView, context: Context) { context.coordinator.look = look }
}
#elseif os(tvOS)
/// Apple TV: the game view in a GCEventViewController. While a game plays
/// (`capture`) the controller's buttons go to the game only; tvOS would
/// take B (and Menu) as Back and leave the app. The pause menu and alerts
/// give them back, for focus and Back.
struct GameView: UIViewControllerRepresentable {
    let session: GameSession
    var look: ScreenLook
    var capture: Bool

    func makeCoordinator() -> GameViewCoordinator { GameViewCoordinator(session: session) }
    func makeUIViewController(context: Context) -> GCEventViewController {
        let controller = GCEventViewController()
        controller.view = context.coordinator.makeView()
        update(controller)
        return controller
    }
    func updateUIViewController(_ controller: GCEventViewController, context: Context) {
        context.coordinator.look = look
        update(controller)
    }
    private func update(_ controller: GCEventViewController) {
        controller.controllerUserInteractionEnabled = !capture
        (controller.view as? GameMTKView)?.focusable = capture
        if capture {
            controller.setNeedsFocusUpdate()
            controller.updateFocusIfNeeded()
        }
    }
}
#else
struct GameView: UIViewRepresentable {
    let session: GameSession
    var look: ScreenLook

    func makeCoordinator() -> GameViewCoordinator { GameViewCoordinator(session: session) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ view: MTKView, context: Context) { context.coordinator.look = look }
}
#endif
