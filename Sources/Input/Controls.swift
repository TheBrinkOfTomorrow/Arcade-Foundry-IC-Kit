import GameController
import CoreGraphics
import simd

/// The cabinet's controls from a game controller (and the keyboard on
/// macOS and iPad), sampled once a frame.
///
/// Keyboard: arrows steer (Manx TT: lean), accelerate (up) and brake (down); A/Z gear up
/// and down (also sent as the shift buttons Manx TT and Virtua Racing read); 1-4 views; 5 coin; Return start; F2 test; F3 service.
/// Controller: left stick steers, right/left trigger accelerate and brake,
/// right/left shoulder shift up/down, A/B/X/Y views 1-4, Options (Select)
/// inserts a coin, Menu (Start) presses start.
/// Pause menu: Escape, or Options and Menu together; on Apple TV also the
/// remote's Menu (Back). The system's gestures on these buttons are off
/// (`claimButtons`): holding a PlayStation controller's Share would
/// otherwise offer to record the screen. On Apple TV the game view keeps
/// the controller's buttons from tvOS while a game plays (GameView), or B
/// would leave the app.
/// Virtua Cop 2: the mouse (macOS) or a touch (iOS) aims player 1's gun and
/// fires; the right button or a two-finger touch reloads. With a
/// controller the right stick moves the aim, the right trigger or A fires
/// and B reloads; on the keyboard Space fires. A second controller is
/// player 2's gun, aimed, fired and reloaded the same way. The House of the
/// Dead 4's gun button throws a grenade: the middle mouse button, G, a
/// three-finger touch or X (each controller its player's).
/// Virtua Fighter 2: the left stick or d-pad moves, X punches, A kicks and
/// B guards; a second controller is player 2. With two or more controllers
/// connected the first connected is player 1 and the next player 2 (not
/// whichever was used last). Keyboard: arrows move, A
/// punch, S kick, D guard.
/// Operator mode (the pause menu turns it on, for iPad and Apple TV, which
/// have no F2/F3): A is the cabinet's TEST button and B its SERVICE, the
/// game's own buttons are off, the stick and pedals stay (test mode's input
/// checks and steering calibration).
/// Star Wars Arcade (`flight`): the left stick (keyboard: arrows) is the
/// flight stick, pushed forward to dive; the right trigger is the throttle
/// (keyboard: A opens it, Z closes it); A, the right shoulder or Space
/// fires; B and X (keyboard: X and C) are the stick's other buttons; 6 is
/// player 2's start. Wing War flies the same way: A fires the machine gun,
/// B a missile, X smoke; Y (keyboard: 1-4) changes the view.
/// Virtual-On (`twin`): the left stick (or d-pad) is the left lever, the
/// left trigger its shot and the left shoulder its dash; the right stick,
/// trigger and shoulder are the right lever's. Keyboard: WASD, Q shot, E
/// dash (left); IJKL, U shot, O dash (right). Oratorio Tangram (Model 3)
/// takes the same controls as its shot triggers and turbo buttons.
/// Star Wars Trilogy flies like Star Wars Arcade; its second trigger is the
/// left shoulder (keyboard V), its event buttons B and X.
/// Model 3's light guns (`analogGun`: The Lost World, L.A. Machineguns, The
/// Ocean Hunter) aim as Virtua Cop 2's, but reloading is the gun's second
/// trigger, not a shot off screen (they have no off-screen sense).
/// Sega Bass Fishing and Get Bass (`fishing`): the left stick is the rod
/// (steer and stick_y), the right trigger reels, the left trigger is the
/// line's tension, the d-pad the lure stick, X casts and A selects.
final class Controls {
    /// A driving game (GameControls.drive): a steering wheel steers it (Wheel, macOS).
    var drive = false
    /// The game is flown, not driven (GameInfo.flight).
    var flight = false
    /// Two levers, not a wheel (GameInfo.twin).
    var twin = false
    /// Model 3's light guns (GameInfo.analogGun).
    var analogGun = false
    /// A gun game (GameInfo.aimsGun): the left stick aims as well as the right.
    var gun = false
    /// The gun's button, BUTTON3 (GameInfo.gunButton): HotD4's grenade.
    var gunButton = false
    /// X (G, middle-click) presses its player's Start (GameInfo.gunStart):
    /// Let's Go Jungle!'s action button.
    var gunStart = false
    /// The left stick's forward and back is stick_y (GameInfo.stickY).
    var stickY = false
    /// Sega Bass Fishing (GameInfo.fishing): the left stick is the rod, so
    /// only the d-pad moves the lure stick (UP/DOWN/LEFT/RIGHT).
    var fishing = false
    /// The game's buttons as the player laid them out (game settings); the
    /// sticks, the d-pad, the pause menu and operator mode keep theirs.
    var map = ButtonMap.identity
    /// A and B are TEST and SERVICE (see the class's comment).
    var operatorMode = false { didSet { operatorArmed = false } }
    /// A and B count only once both were up: the A that chose it in the menu is not a TEST.
    private var operatorArmed = false
    private var keyThrottle: Float = 0 // where the keys left the throttle lever
    private var view = 1, viewFrames = 0, viewHeld = false // Wing War: the view Y last picked, how long its button stays down
    private var gear: Int32 = 1
    private var steer: Float = 0
    private var held = Set<String>()

    /// Open the pause menu: set on the frame Escape, or Options and Menu
    /// together (Apple TV: or the remote's Menu), go down.
    var pauseRequested = false
    /// Frames since Options (coin) or Menu (start) was pressed, or -1. The
    /// game sees a press a few frames late, so pressing both to pause
    /// neither inserts a coin nor starts.
    private var coinWait = -1, startWait = -1
    /// Options and Menu were pressed together: neither counts until both are up.
    private var chord = false
    private static let grace = 4, pulse = 6

    /// Edge detection: true on the call where `down` first becomes true.
    private func pressed(_ name: String, _ down: Bool) -> Bool {
        defer { if down { held.insert(name) } else { held.remove(name) } }
        return down && !held.contains(name)
    }

    /// Controllers whose system gestures are already off.
    private var claimed = Set<ObjectIdentifier>()

    /// Turns off the system's gestures on the buttons the game uses (Share
    /// records the screen, Options and Home open system UI when held).
    private func claimButtons() {
        for controller in GCController.controllers() where !claimed.contains(ObjectIdentifier(controller)) {
            claimed.insert(ObjectIdentifier(controller))
            guard let pad = controller.extendedGamepad else { continue }
            for button in [pad.buttonOptions, pad.buttonMenu, pad.buttonHome] {
                button?.preferredSystemGestureState = .disabled
            }
        }
    }

    private var pad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().compactMap(\.extendedGamepad).first
    }

    enum MenuCommand { case up, down, left, right, select, close, clear }

    /// The pause menu's input: up/down (left/right and X or Delete for the
    /// Wheel and pedals screen), A or Return choose, B, Escape or
    /// Options and Menu close it (a wheel's d-pad and buttons count as a
    /// gamepad's, and its pause button closes it) (Apple TV: also the Siri Remote, GameView
    /// keeps the controller from tvOS's focus while the menu is open too).
    func menuCommands() -> [MenuCommand] {
        var up = false, down = false, left = false, right = false
        var select = false, back = false, clear = false, toggle = false
        if let pad = MenuPad.read() { // a gamepad, or on the Mac a wheel's d-pad and buttons
            up = pad.moveY > 0.5
            down = pad.moveY < -0.5
            left = pad.moveX < -0.5
            right = pad.moveX > 0.5
            select = pad.a
            back = pad.b
            clear = pad.buttonX
            toggle = pad.menu && pad.options
        }
        #if os(macOS)
        toggle = toggle || Wheel.shared.state().held.contains(.pause) // the wheel's pause button closes it too
        #endif
        #if os(tvOS)
        // The Siri Remote: swipe or press up and down, click to choose, Menu (Back) closes.
        for remote in GCController.controllers() where remote.extendedGamepad == nil {
            guard let micro = remote.microGamepad else { continue }
            up = up || micro.dpad.yAxis.value > 0.5
            down = down || micro.dpad.yAxis.value < -0.5
            select = select || micro.buttonA.isPressed
            toggle = toggle || micro.buttonMenu.isPressed
        }
        #else
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func key(_ k: GCKeyCode) -> Bool { kb.button(forKeyCode: k)?.isPressed ?? false }
            up = up || key(.upArrow)
            down = down || key(.downArrow)
            left = left || key(.leftArrow)
            right = right || key(.rightArrow)
            select = select || key(.returnOrEnter) || key(.spacebar)
            clear = clear || key(.deleteOrBackspace)
            toggle = toggle || key(.escape)
        }
        #endif
        var out: [MenuCommand] = []
        if pressed("m.up", up) { out.append(.up) }
        if pressed("m.down", down) { out.append(.down) }
        if pressed("m.left", left) { out.append(.left) }
        if pressed("m.right", right) { out.append(.right) }
        if pressed("m.select", select) { out.append(.select) }
        if pressed("m.clear", clear) { out.append(.clear) }
        if pressed("m.back", back) { out.append(.close) }
        if pressed("pause", toggle) { out.append(.close) } // the same control opened it
        if escapePressed { escapePressed = false; if !out.contains(.close) { out.append(.close) } }
        return out
    }
    /// Buttons held on the touch screen's overlay (coin, start, ...).
    var touchButtons: UInt32 = 0

    /// Virtua Cop 2's gun, set by the game view from the mouse or a touch:
    /// where it aims, 0...1 across and down the game's picture.
    var aim = SIMD2<Float>(0.5, 0.5)
    /// Player 2's gun, aimed with the second controller's sticks.
    var aim2 = SIMD2<Float>(0.5, 0.5)
    /// A second controller is connected: player 2 has a gun.
    private(set) var secondGun = false
    /// Player 2 pressed Start on the second controller: in the game, so its
    /// crosshair shows (the game's own player state is out of sight).
    private(set) var secondJoined = false
    /// Where the game view last drew the picture, as shares of the view
    /// (0...1, top-left origin; ScreenRenderer), for the aim and the crosshair.
    var picture = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The aim and picture as CrosshairView shows them.
    let shown = AimShown()
    var pointerFire = false
    var pointerReload = false
    var pointerGrenade = false
    /// Escape was pressed in the game window (macOS, GameMTKView's key
    /// monitor): taken once, by the game (opens the pause menu) or by the
    /// menu (closes it). GCKeyboard did not report Escape on the Mac, so the
    /// pause menu could not be opened from the keyboard (#407).
    var escapePressed = false

    /// Touch on the game's picture is the gun (iPhone and iPad): set in the
    /// gun games while they aim by touch (#359). Elsewhere a touch on the
    /// picture does nothing.
    var touchAims = false

    #if os(iOS)
    /// The on-screen controller's buttons for a kind of game. Every layout
    /// has A and B, which operator mode needs as TEST and SERVICE.
    enum TouchLayout {
        /// The driving games (#362): the stick steers; on the right A is the
        /// gas, B the brake, X and Y shift down and up, and the right
        /// shoulder steps through the views (Apple places the triggers and
        /// left shoulder beside the stick, under the steering thumb).
        case drive
        /// The flying games and the rest: stick, triggers, shoulders, A and B.
        case standard
        /// Virtua Fighter: the stick and X, A, B, Y (punch, kick, guard, escape).
        case fighting
        /// Bass Fishing: the stick (rod), triggers (reel, tension), X (cast), A and B.
        case fishing
        /// Virtual-On and Oratorio Tangram: both sticks (levers), triggers (shots), shoulders (dashes).
        case twin
        /// A gun game aimed by the controller: the stick moves the
        /// crosshair, A fires, B reloads, X throws (HotD4's grenade).
        case gun(button: Bool)

        var elements: Set<String> {
            switch self {
            case .drive: [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
                          GCInputRightShoulder]
            case .standard: [GCInputLeftThumbstick, GCInputRightTrigger, GCInputLeftTrigger,
                             GCInputRightShoulder, GCInputLeftShoulder, GCInputButtonA, GCInputButtonB]
            case .fighting: [GCInputLeftThumbstick, GCInputButtonX, GCInputButtonA, GCInputButtonB, GCInputButtonY]
            case .fishing: [GCInputLeftThumbstick, GCInputRightTrigger, GCInputLeftTrigger, GCInputButtonX, GCInputButtonA, GCInputButtonB]
            case .twin: [GCInputLeftThumbstick, GCInputRightThumbstick, GCInputLeftTrigger, GCInputRightTrigger,
                         GCInputLeftShoulder, GCInputRightShoulder, GCInputButtonA, GCInputButtonB]
            case .gun(let button): button ? [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB, GCInputButtonX]
                : [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB]
            }
        }
    }

    private var virtualPad: GCVirtualController?
    private var touchMode = TouchControls.off
    private var touchLayout: TouchLayout?
    private var watchers: [NSObjectProtocol] = []

    /// The on-screen controller for a game (nil: none, the gun games aimed
    /// by touch), shown as the mode says: Automatic follows controllers
    /// connecting and disconnecting during the game.
    func startTouchControls(_ mode: TouchControls, layout: TouchLayout?) {
        stopTouchControls()
        touchMode = mode
        touchLayout = layout
        guard layout != nil, mode == .automatic else { updateTouchControls(); return }
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            watchers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateTouchControls()
            })
        }
        updateTouchControls()
    }

    /// The game is over: the on-screen controller goes.
    func stopTouchControls() {
        for w in watchers { NotificationCenter.default.removeObserver(w) }
        watchers.removeAll()
        touchLayout = nil
        updateTouchControls()
    }

    /// A real controller (not the on-screen one) is connected. Apple's
    /// on-screen controller names itself "Apple Touch Controller", which
    /// also covers the moment before `controller` is set.
    private var realController: Bool {
        GCController.controllers().contains {
            $0 !== virtualPad?.controller && $0.vendorName != "Apple Touch Controller" && $0.extendedGamepad != nil
        }
    }

    private func updateTouchControls() {
        let show: Bool
        switch touchMode {
        case .always: show = touchLayout != nil
        case .automatic: show = touchLayout != nil && !realController
        case .off: show = false
        }
        if show, virtualPad == nil, let layout = touchLayout {
            let cfg = GCVirtualController.Configuration()
            cfg.elements = layout.elements
            let pad = GCVirtualController(configuration: cfg)
            virtualPad = pad // before connect(): its own DidConnect must not count as a controller
            pad.connect()
        } else if !show, let pad = virtualPad {
            virtualPad = nil
            pad.disconnect()
        }
    }
    #endif

    /// This pad is the on-screen controller showing the driving layout.
    private func touchDriving(_ pad: GCExtendedGamepad) -> Bool {
        #if os(iOS)
        if case .drive = touchLayout, let touch = virtualPad?.controller?.extendedGamepad { return pad === touch }
        #endif
        return false
    }

    /// The connected controllers in player order: the real ones in the
    /// order they connected, then the on-screen controller (player 2 when
    /// it is shown beside a controller, Always).
    private var pads: [GCExtendedGamepad] {
        #if os(iOS)
        if let touch = virtualPad?.controller {
            let real = GCController.controllers().filter { $0 !== touch }
            return (real + [touch]).compactMap(\.extendedGamepad)
        }
        #endif
        return GCController.controllers().compactMap(\.extendedGamepad)
    }

    /// The fighting games' buttons and joystick from one controller (Escape
    /// is Virtua Fighter 3's).
    private func fight(_ pad: GCExtendedGamepad?) -> UInt32 {
        guard let pad else { return 0 }
        var b: UInt32 = 0
        let x = abs(pad.dpad.xAxis.value) > 0.5 || fishing ? pad.dpad.xAxis.value : pad.leftThumbstick.xAxis.value
        let y = abs(pad.dpad.yAxis.value) > 0.5 || fishing ? pad.dpad.yAxis.value : pad.leftThumbstick.yAxis.value
        if map.pressed(.x, pad) { b |= UInt32(AFCORE_PUNCH) }
        if map.pressed(.a, pad) { b |= UInt32(AFCORE_KICK) }
        if map.pressed(.b, pad) { b |= UInt32(AFCORE_GUARD) }
        if map.pressed(.y, pad) { b |= UInt32(AFCORE_BUTTON2) }
        if y > 0.5 { b |= UInt32(AFCORE_UP) }
        if y < -0.5 { b |= UInt32(AFCORE_DOWN) }
        if x < -0.5 { b |= UInt32(AFCORE_LEFT) }
        if x > 0.5 { b |= UInt32(AFCORE_RIGHT) }
        return b
    }

    func sample() -> afcore_input {
        var input = afcore_input()
        input.size = UInt32(MemoryLayout<afcore_input>.size)
        var target: Float = 0, accel: Float = 0, brake: Float = 0, handbrake: Float = 0
        var buttons: UInt32 = touchButtons
        var up = false, down = false
        var keySteer = false
        var fire = pointerFire, reload = pointerReload, grenade = pointerGrenade
        var pauseDown = false, coinDown = false, startDown = false
        claimButtons()

        // With two controllers each is a player, in the order they connected:
        // the one used last (GCController.current) would make both player 1.
        let pads = self.pads
        let first: GCExtendedGamepad? = pads.count > 1 ? pads[0] : pad
        let second: GCExtendedGamepad? = pads.count > 1 ? pads[1] : nil
        secondGun = second != nil
        var fire2 = false, reload2 = false, grenade2 = false
        buttons |= fight(first) // Virtua Fighter 2 (the other games ignore these)
        input.buttons2 = fight(second)
        if map.pressed(.menu, second) {
            buttons |= UInt32(AFCORE_START2)
            secondJoined = true
        }
        if let pad = first, touchDriving(pad) {
            // The driving layout on the on-screen controller (#362); the views
            // are sent as in the flying games (view, viewFrames).
            target = pad.leftThumbstick.xAxis.value
            accel = pad.buttonA.isPressed ? 1 : 0
            brake = pad.buttonB.isPressed ? 1 : 0
            up = pad.buttonY.isPressed
            down = pad.buttonX.isPressed
            let next = pad.rightShoulder.isPressed
            if next && !viewHeld { view = view % 4 + 1; viewFrames = 6 }
            viewHeld = next
            if viewFrames > 0 {
                viewFrames -= 1
                buttons |= [UInt32(AFCORE_VIEW1), UInt32(AFCORE_VIEW2), UInt32(AFCORE_VIEW3), UInt32(AFCORE_VIEW4)][view - 1]
            }
        } else if let pad = first {
            target = pad.leftThumbstick.xAxis.value
            if abs(pad.dpad.xAxis.value) > 0.5 { target = pad.dpad.xAxis.value }
            accel = map.value(.rightTrigger, pad)
            brake = map.value(.leftTrigger, pad)
            up = up || map.pressed(.rightShoulder, pad)
            down = down || map.pressed(.leftShoulder, pad)
            if map.pressed(.a, pad) { buttons |= UInt32(AFCORE_VIEW1) }
            if map.pressed(.b, pad) { buttons |= UInt32(AFCORE_VIEW2) }
            if map.pressed(.x, pad) { buttons |= UInt32(AFCORE_VIEW3) }
            if map.pressed(.y, pad) { buttons |= UInt32(AFCORE_VIEW4) }
            coinDown = map.pressed(.options, pad)
            startDown = map.pressed(.menu, pad)
            handbrake = map.pressed(.b, pad) ? 1 : 0 // Sega Rally's hand brake (its only view button is VIEW1)
            moveAim(&aim, pad)
            if map.value(.rightTrigger, pad) > 0.5 || map.pressed(.a, pad) { fire = true }
            if map.pressed(.b, pad) { reload = true }
            if map.pressed(.x, pad) { grenade = true }
        }
        if gun, let pad = second { // player 2's gun
            moveAim(&aim2, pad)
            fire2 = map.value(.rightTrigger, pad) > 0.5 || map.pressed(.a, pad)
            reload2 = map.pressed(.b, pad)
            grenade2 = map.pressed(.x, pad)
        }

        #if !os(tvOS)
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func key(_ k: GCKeyCode) -> Bool { kb.button(forKeyCode: k)?.isPressed ?? false }
            let l = key(.leftArrow), r = key(.rightArrow)
            if l || r {
                keySteer = true
                let want: Float = (r ? 1 : 0) - (l ? 1 : 0)
                steer += max(-0.12, min(0.12, want - steer)) // keys ramp towards full lock, as in the recomp's app
            }
            if key(.upArrow) { accel = 1 }
            if key(.downArrow) { brake = 1 }
            up = up || key(.keyA)
            down = down || key(.keyZ)
            if key(.one) { buttons |= UInt32(AFCORE_VIEW1) }
            if key(.two) { buttons |= UInt32(AFCORE_VIEW2); handbrake = 1 }
            if key(.three) { buttons |= UInt32(AFCORE_VIEW3) }
            if key(.four) { buttons |= UInt32(AFCORE_VIEW4) }
            if key(.five) { buttons |= UInt32(AFCORE_COIN) }
            if key(.returnOrEnter) { buttons |= UInt32(AFCORE_START) }
            if key(.F2) { buttons |= UInt32(AFCORE_TEST) }
            if key(.F3) { buttons |= UInt32(AFCORE_SERVICE) }
            if key(.escape) { pauseDown = true }
            if key(.spacebar) { fire = true }
            if key(.keyG) { grenade = true }
            if key(.keyA) { buttons |= UInt32(AFCORE_PUNCH) } // Virtua Fighter 2
            if key(.keyS) { buttons |= UInt32(AFCORE_KICK) }
            if key(.keyD) { buttons |= UInt32(AFCORE_GUARD) }
            if key(.keyF) { buttons |= UInt32(AFCORE_BUTTON2) } // Virtua Fighter 3's Escape
            if key(.upArrow) { buttons |= UInt32(AFCORE_UP) }
            if key(.downArrow) { buttons |= UInt32(AFCORE_DOWN) }
            if l { buttons |= UInt32(AFCORE_LEFT) }
            if r { buttons |= UInt32(AFCORE_RIGHT) }
        }
        #endif
        #if os(macOS)
        // A steering wheel (Wheel): in the driving games it steers when turned
        // past the gamepad's stick, its pedals add to the triggers and its
        // shifter, paddles and buttons to the rest. Coin, start and the pause
        // menu work in every game.
        let wheel = Wheel.shared.state()
        if wheel.connected {
            if drive && !flight && !twin {
                if abs(wheel.steer) >= abs(target) { target = wheel.steer }
                accel = max(accel, wheel.gas)
                brake = max(brake, wheel.brake)
                up = up || wheel.held.contains(.shiftUp) || wheel.held.contains(.paddleUp)
                down = down || wheel.held.contains(.shiftDown) || wheel.held.contains(.paddleDown)
                if wheel.held.contains(.view1) { buttons |= UInt32(AFCORE_VIEW1) }
                if wheel.held.contains(.view2) { buttons |= UInt32(AFCORE_VIEW2) }
                if wheel.held.contains(.view3) { buttons |= UInt32(AFCORE_VIEW3) }
                if wheel.held.contains(.view4) { buttons |= UInt32(AFCORE_VIEW4) }
                if wheel.held.contains(.handbrake) { handbrake = 1 }
            }
            coinDown = coinDown || wheel.held.contains(.coin)
            startDown = startDown || wheel.held.contains(.start)
            if wheel.held.contains(.pause) { pauseDown = true }
        }
        #endif
        if !keySteer { steer = target }

        #if os(tvOS)
        // The Siri Remote's Menu (Back): tvOS doesn't see it while a game plays (GameView).
        if GCController.controllers().contains(where: { $0.extendedGamepad == nil && $0.microGamepad?.buttonMenu.isPressed == true }) {
            pauseDown = true
        }
        #endif
        if coinDown && startDown {
            if !chord { pauseDown = true }
            chord = true
            coinWait = -1
            startWait = -1
        } else if !coinDown && !startDown {
            chord = false
        }
        let coinPress = pressed("coin", coinDown), startPress = pressed("start", startDown)
        if !chord {
            if coinPress { coinWait = 0 }
            if startPress { startWait = 0 }
        }
        // A coin is a short pulse; start lasts as long as Menu is held (codes hold it).
        if coinWait >= 0 {
            if coinWait >= Self.grace { buttons |= UInt32(AFCORE_COIN) }
            coinWait += 1
            if coinWait >= Self.grace + Self.pulse { coinWait = -1 }
        }
        if startWait >= 0 {
            if startWait >= Self.grace { buttons |= UInt32(AFCORE_START) }
            startWait += 1
            if startWait >= Self.grace + Self.pulse && !startDown { startWait = -1 }
        }
        if pressed("pause", pauseDown) { pauseRequested = true }
        if escapePressed { escapePressed = false; pauseRequested = true }
        if operatorMode { return operatorInput(buttons: buttons, accel: accel, brake: brake) }
        if flight { return flightInput(buttons: buttons) }
        if twin { return twinInput(buttons: buttons) }

        // Manx TT and Virtua Racing read the shift buttons themselves; the other cars take a gear.
        if up { buttons |= UInt32(AFCORE_SHIFT_UP) }
        if down { buttons |= UInt32(AFCORE_SHIFT_DOWN) }
        // Sequential shifting on the press.
        if up && !held.contains("up") { gear = min(gear + 1, 4) }
        if down && !held.contains("down") { gear = max(gear - 1, 1) }
        if up { held.insert("up") } else { held.remove("up") }
        if down { held.insert("down") } else { held.remove("down") }

        input.steer = max(-1, min(1, steer))
        input.accel = accel
        input.brake = brake
        input.handbrake = handbrake
        input.gear = gear
        if stickY, let pad = first { input.stick_y = max(-1, min(1, -pad.leftThumbstick.yAxis.value)) } // -1 pushed forward
        if analogGun { // the aim stays on screen; the second trigger reloads (The Lost World)
            if fire && !reload { buttons |= UInt32(AFCORE_TRIGGER1) }
            if reload { buttons |= UInt32(AFCORE_TRIGGER2) }
            input.buttons = buttons
            // Player 2's triggers in buttons2; without a second controller its gun rests at the edge, never fired.
            input.buttons2 = (fire2 && !reload2 ? UInt32(AFCORE_TRIGGER1) : 0) | (reload2 ? UInt32(AFCORE_TRIGGER2) : 0)
            input.gun_x = (aim.x, secondGun ? aim2.x : -1)
            input.gun_y = (aim.y, secondGun ? aim2.y : -1)
            return input
        }
        // TRIGGER1 is player 1's trigger, TRIGGER2 player 2's; a shot off screen reloads.
        if fire || reload { buttons |= UInt32(AFCORE_TRIGGER1) }
        if fire2 || reload2 { buttons |= UInt32(AFCORE_TRIGGER2) }
        if gunButton { // player 1's in buttons, player 2's in buttons2
            if grenade { buttons |= UInt32(AFCORE_BUTTON3) }
            if grenade2 { input.buttons2 |= UInt32(AFCORE_BUTTON3) }
        } else if gunStart { // Start is the action button: X as well as Menu
            if grenade { buttons |= UInt32(AFCORE_START) }
            if grenade2 { buttons |= UInt32(AFCORE_START2) }
        }
        input.buttons = buttons
        input.gun_x = (reload ? -1 : aim.x, secondGun && !reload2 ? aim2.x : -1) // player 2's gun: off screen without a second controller
        input.gun_y = (reload ? -1 : aim.y, secondGun && !reload2 ? aim2.y : -1)
        return input
    }

    /// A gun game's aim from a controller: the right stick moves it, and in a
    /// gun game the left one too (whichever is pushed further). The other games ignore it.
    private func moveAim(_ aim: inout SIMD2<Float>, _ pad: GCExtendedGamepad) {
        var stick = SIMD2<Float>(pad.rightThumbstick.xAxis.value, -pad.rightThumbstick.yAxis.value)
        let left = SIMD2<Float>(pad.leftThumbstick.xAxis.value, -pad.leftThumbstick.yAxis.value)
        if gun && simd_length(left) > simd_length(stick) { stick = left }
        if abs(stick.x) > 0.15 || abs(stick.y) > 0.15 {
            aim = simd_clamp(aim + stick * 0.025, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1))
        }
    }

    /// Operator mode: TEST and SERVICE on A and B (see the class's comment).
    private func operatorInput(buttons: UInt32, accel: Float, brake: Float) -> afcore_input {
        var input = afcore_input()
        input.size = UInt32(MemoryLayout<afcore_input>.size)
        var buttons = buttons & (UInt32(AFCORE_COIN) | UInt32(AFCORE_START) | UInt32(AFCORE_START2)
                                 | UInt32(AFCORE_TEST) | UInt32(AFCORE_SERVICE))
        let test = pad?.buttonA.isPressed == true, service = pad?.buttonB.isPressed == true
        if !test && !service { operatorArmed = true }
        if operatorArmed && test { buttons |= UInt32(AFCORE_TEST) }
        if operatorArmed && service { buttons |= UInt32(AFCORE_SERVICE) }
        input.steer = max(-1, min(1, steer))
        input.accel = accel
        input.brake = brake
        input.gear = gear
        input.buttons = buttons
        input.gun_x = (-1, -1)
        input.gun_y = (-1, -1)
        return input
    }

    /// Virtual-On's two levers (see the class's comment): the left one as
    /// player 1's fighting-game buttons (punch = shot, kick = dash), the
    /// right one as buttons2 (the core puts them on IN1 and IN2). Oratorio
    /// Tangram reads the levers the same way, and its shots and turbos as
    /// TRIGGER1/BUTTON2 (left) and TRIGGER2/BUTTON3 (right), all in buttons.
    private func twinInput(buttons: UInt32) -> afcore_input {
        var input = afcore_input()
        input.size = UInt32(MemoryLayout<afcore_input>.size)
        var left = buttons & (UInt32(AFCORE_COIN) | UInt32(AFCORE_START) | UInt32(AFCORE_TEST) | UInt32(AFCORE_SERVICE))
        var right: UInt32 = 0
        func lever(_ x: Float, _ y: Float, _ to: inout UInt32) { // y: up is positive
            if y > 0.5 { to |= UInt32(AFCORE_UP) }
            if y < -0.5 { to |= UInt32(AFCORE_DOWN) }
            if x < -0.5 { to |= UInt32(AFCORE_LEFT) }
            if x > 0.5 { to |= UInt32(AFCORE_RIGHT) }
        }
        if let pad {
            let x = abs(pad.dpad.xAxis.value) > 0.5 ? pad.dpad.xAxis.value : pad.leftThumbstick.xAxis.value
            let y = abs(pad.dpad.yAxis.value) > 0.5 ? pad.dpad.yAxis.value : pad.leftThumbstick.yAxis.value
            lever(x, y, &left)
            lever(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value, &right)
            if map.value(.leftTrigger, pad) > 0.5 { left |= UInt32(AFCORE_PUNCH) | UInt32(AFCORE_TRIGGER1) }
            if map.pressed(.leftShoulder, pad) { left |= UInt32(AFCORE_KICK) | UInt32(AFCORE_BUTTON2) }
            if map.value(.rightTrigger, pad) > 0.5 { right |= UInt32(AFCORE_PUNCH); left |= UInt32(AFCORE_TRIGGER2) }
            if map.pressed(.rightShoulder, pad) { right |= UInt32(AFCORE_KICK); left |= UInt32(AFCORE_BUTTON3) }
        }
        #if !os(tvOS)
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func key(_ k: GCKeyCode) -> Bool { kb.button(forKeyCode: k)?.isPressed ?? false }
            func axis(_ minus: GCKeyCode, _ plus: GCKeyCode) -> Float { (key(plus) ? 1 : 0) - (key(minus) ? 1 : 0) }
            lever(axis(.keyA, .keyD), axis(.keyS, .keyW), &left)
            lever(axis(.keyJ, .keyL), axis(.keyK, .keyI), &right)
            if key(.keyQ) { left |= UInt32(AFCORE_PUNCH) | UInt32(AFCORE_TRIGGER1) }
            if key(.keyE) { left |= UInt32(AFCORE_KICK) | UInt32(AFCORE_BUTTON2) }
            if key(.keyU) { right |= UInt32(AFCORE_PUNCH); left |= UInt32(AFCORE_TRIGGER2) }
            if key(.keyO) { right |= UInt32(AFCORE_KICK); left |= UInt32(AFCORE_BUTTON3) }
        }
        #endif
        input.buttons = left
        input.buttons2 = right
        input.gun_x = (-1, -1)
        input.gun_y = (-1, -1)
        return input
    }

    /// Star Wars Arcade's stick, throttle and buttons (see the class's comment).
    private func flightInput(buttons: UInt32) -> afcore_input {
        var input = afcore_input()
        input.size = UInt32(MemoryLayout<afcore_input>.size)
        // The shared mapping's coin, starts, test and service; not its views, shifts, fighting buttons or gun.
        var buttons = buttons & (UInt32(AFCORE_COIN) | UInt32(AFCORE_START) | UInt32(AFCORE_START2)
                                 | UInt32(AFCORE_TEST) | UInt32(AFCORE_SERVICE))
        var fire = false
        let x = steer // the left stick, or the arrows ramping as for a wheel
        var y: Float = 0, throttle: Float = 0
        if let pad {
            y = -pad.leftThumbstick.yAxis.value
            if abs(pad.dpad.yAxis.value) > 0.5 { y = -pad.dpad.yAxis.value }
            throttle = map.value(.rightTrigger, pad)
            if map.pressed(.a, pad) || map.pressed(.rightShoulder, pad) { fire = true }
            if map.pressed(.b, pad) { buttons |= UInt32(AFCORE_BUTTON2) }
            if map.pressed(.x, pad) { buttons |= UInt32(AFCORE_BUTTON3) }
            if map.pressed(.leftShoulder, pad) { buttons |= UInt32(AFCORE_TRIGGER2) } // Star Wars Trilogy's second trigger
            // Wing War's four view buttons: Y steps to the next view
            let next = map.pressed(.y, pad)
            if next && !viewHeld { view = view % 4 + 1; viewFrames = 6 }
            viewHeld = next
        }
        if viewFrames > 0 {
            viewFrames -= 1
            buttons |= [UInt32(AFCORE_VIEW1), UInt32(AFCORE_VIEW2), UInt32(AFCORE_VIEW3), UInt32(AFCORE_VIEW4)][view - 1]
        }
        #if !os(tvOS)
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            func key(_ k: GCKeyCode) -> Bool { kb.button(forKeyCode: k)?.isPressed ?? false }
            if key(.upArrow) { y = -1 }
            if key(.downArrow) { y = 1 }
            if key(.keyA) { keyThrottle = min(1, keyThrottle + 0.03) }
            if key(.keyZ) { keyThrottle = max(0, keyThrottle - 0.03) }
            if key(.spacebar) { fire = true }
            if key(.keyX) { buttons |= UInt32(AFCORE_BUTTON2) }
            if key(.keyC) { buttons |= UInt32(AFCORE_BUTTON3) }
            if key(.keyV) { buttons |= UInt32(AFCORE_TRIGGER2) }
            if key(.six) { buttons |= UInt32(AFCORE_START2) }
            if key(.one) { buttons |= UInt32(AFCORE_VIEW1) }
            if key(.two) { buttons |= UInt32(AFCORE_VIEW2) }
            if key(.three) { buttons |= UInt32(AFCORE_VIEW3) }
            if key(.four) { buttons |= UInt32(AFCORE_VIEW4) }
        }
        #endif
        if fire { buttons |= UInt32(AFCORE_TRIGGER1) }
        input.steer = max(-1, min(1, x))
        input.stick_y = max(-1, min(1, y))
        input.accel = max(throttle, keyThrottle)
        input.buttons = buttons
        input.gun_x = (-1, -1)
        input.gun_y = (-1, -1)
        return input
    }
}
