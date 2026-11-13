import GameController

/// A controller button the games read. The sticks and the d-pad keep
/// their jobs; these can be swapped per game (ButtonMap).
enum PadButton: String, CaseIterable, Identifiable {
    case a, b, x, y, leftShoulder, rightShoulder, leftTrigger, rightTrigger, options, menu

    var id: String { rawValue }

    /// As the common controllers label it.
    var name: String {
        switch self {
        case .a: return "A (Cross)"
        case .b: return "B (Circle)"
        case .x: return "X (Square)"
        case .y: return "Y (Triangle)"
        case .leftShoulder: return "L1 / LB"
        case .rightShoulder: return "R1 / RB"
        case .leftTrigger: return "L2 / LT"
        case .rightTrigger: return "R2 / RT"
        case .options: return "Options (Share, View)"
        case .menu: return "Menu (Options, Start)"
        }
    }

    func element(of pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .a: return pad.buttonA
        case .b: return pad.buttonB
        case .x: return pad.buttonX
        case .y: return pad.buttonY
        case .leftShoulder: return pad.leftShoulder
        case .rightShoulder: return pad.rightShoulder
        case .leftTrigger: return pad.leftTrigger
        case .rightTrigger: return pad.rightTrigger
        case .options: return pad.buttonOptions
        case .menu: return pad.buttonMenu
        }
    }
}

/// One game's controller layout: for each button of the default layout
/// (Controls), the button that stands in for it. Saved per game on this
/// device; the default is every button as itself.
struct ButtonMap: Equatable {
    private var map: [PadButton: PadButton] = [:]

    static let identity = ButtonMap()

    subscript(_ button: PadButton) -> PadButton {
        get { map[button] ?? button }
        set { map[button] = newValue == button ? nil : newValue }
    }

    var isDefault: Bool { map.isEmpty }

    /// How far `button` (of the default layout) is pressed, 0...1: the
    /// triggers are analog (pedals, throttle), a button that stands in
    /// for one is 0 or 1.
    func value(_ button: PadButton, _ pad: GCExtendedGamepad?) -> Float {
        guard let pad, let element = self[button].element(of: pad) else { return 0 }
        return element.isAnalog ? element.value : (element.isPressed ? 1 : 0)
    }

    func pressed(_ button: PadButton, _ pad: GCExtendedGamepad?) -> Bool {
        guard let pad, let element = self[button].element(of: pad) else { return false }
        return element.isPressed
    }

    private static func key(_ romset: String) -> String { "buttons.\(romset)" }

    static func load(_ romset: String) -> ButtonMap {
        var m = ButtonMap()
        let saved = UserDefaults.standard.dictionary(forKey: key(romset)) as? [String: String] ?? [:]
        for (from, to) in saved {
            if let f = PadButton(rawValue: from), let t = PadButton(rawValue: to) { m[f] = t }
        }
        return m
    }

    func save(_ romset: String) {
        if map.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key(romset))
        } else {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) }),
                                      forKey: Self.key(romset))
        }
    }

    struct Action: Identifiable {
        let button: PadButton
        let name: String
        var id: PadButton { button }
        init(_ button: PadButton, _ name: String) { self.button = button; self.name = name }
    }

    /// What each button does in `game`, in the default layout (Controls).
    static func actions(for game: GameInfo) -> [Action] {
        let coinStart = [Action(.options, "Coin"), Action(.menu, "Start")]
        switch game.id {
        case "vcop", "vcop2", "hotdo", "lostwsga": // The Lost World: B is its second trigger
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.b, "Reload")] + coinStart
        case "crtaxihr": // the shifter's Drive and Reverse on the shift buttons; views 1 and 2 press JUMP
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Drive"),
                    Action(.leftShoulder, "Reverse"), Action(.a, "Jump"), Action(.b, "Jump")] + coinStart
        case "hotd3": // reload pumps the gun's grip (the core pulls it twice)
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.b, "Reload (grip)")] + coinStart
        case "vcop3": // the gun's button changes weapon; Y (BUTTON2, each player's own controller) is the cabinet's foot pedal
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.b, "Reload"), Action(.x, "Change weapon"),
                    Action(.y, "Pedal")] + coinStart
        case "hotd4a": // the gun's button throws a grenade
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.b, "Reload"), Action(.x, "Grenade")] + coinStart
        case "gunblade", "rchase2", "lamachin", "oceanhuna", "jpark", "rchase": // no reload: hold to fire
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire")] + coinStart
        case "letsgoju", "letsgojua", "letsgojusp": // hold to fire; Start is the action button, X too
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.x, "Action (Start)")] + coinStart
        case "ga2": // the three buttons (punch, kick, guard in the fighting layout); the third casts magic
            return [Action(.x, "Button 1"), Action(.a, "Button 2"), Action(.b, "Magic")] + coinStart
        case "sonic": // the trackball rolls with the stick or d-pad; its one button (punch, kick or button 2) spin jumps
            return [Action(.x, "Spin jump"), Action(.a, "Spin jump"), Action(.y, "Spin jump")] + coinStart
        case "doab": // the fighting buttons: punch, kick, then guard holds
            return [Action(.x, "Punch"), Action(.a, "Kick"), Action(.b, "Hold")] + coinStart
        case "vf2", "fvipers", "vf", "lastbrnx", "schamp", "fvipers2":
            return [Action(.x, "Punch"), Action(.a, "Kick"), Action(.b, "Guard")] + coinStart
        case "vs299a": // the fighting buttons: punch, kick, guard
            return [Action(.x, "Short pass"), Action(.a, "Long pass"), Action(.b, "Shoot")] + coinStart
        case "spikeout", "spikeofe": // the fighting buttons: punch, kick, guard, escape
            return [Action(.x, "Beat"), Action(.a, "Charge"), Action(.b, "Shift"), Action(.y, "Jump")] + coinStart
        case "von2": // the shots are its triggers, the dashes its turbo buttons
            return [Action(.leftTrigger, "Left shot"), Action(.leftShoulder, "Left turbo"), Action(.rightTrigger, "Right shot"),
                    Action(.rightShoulder, "Right turbo")] + coinStart
        case "swtrilgy": // Star Wars Arcade's stick: fire, button 2, button 3; the second trigger
            return [Action(.a, "Trigger"), Action(.rightShoulder, "Trigger"), Action(.leftShoulder, "Second trigger"),
                    Action(.b, "Event button 1"), Action(.x, "Event button 2")] + coinStart
        case "vstriker": // the fighting buttons: punch, kick, guard
            return [Action(.x, "Long pass"), Action(.a, "Shoot"), Action(.b, "Short pass")] + coinStart
        case "zerogun", "pltkids": // the fighting buttons: punch, kick
            return [Action(.x, "Shot"), Action(.a, "Special")] + coinStart
        case "motoraid": // Manx TT's lean, throttle and brake; punch and kick (the fighting buttons)
            return [Action(.rightTrigger, "Throttle"), Action(.leftTrigger, "Brake"), Action(.x, "Punch"), Action(.a, "Kick")] + coinStart
        case "dynabb97": // the fighting buttons: its two buttons, then the bat swing
            return [Action(.x, "Button 1"), Action(.a, "Button 2"), Action(.b, "Swing")] + coinStart
        case "bel": // Gunblade NY's turret; B reloads in the gun layout, so X fires the missile
            return [Action(.a, "Machine gun"), Action(.rightTrigger, "Machine gun"), Action(.x, "Missile")] + coinStart
        case "topskatr": // the stick curves and slides; the front and tail of the board jump, the shoulders select
            return [Action(.a, "Jump (front)"), Action(.b, "Jump (tail)"), Action(.leftShoulder, "Select left"),
                    Action(.rightShoulder, "Select right")] + coinStart
        case "skisuprg": // the steering inclines the skis, the stick (up and down) swings; views 1-3 select, the shift buttons zoom
            return [Action(.a, "Select 1"), Action(.b, "Select 2"), Action(.x, "Select 3"), Action(.rightShoulder, "Zoom in"),
                    Action(.leftShoulder, "Zoom out")] + coinStart
        case "segawski": // Start is the set button (A too); the steering slides; up and down on the stick select
            return [Action(.x, "Pitch left"), Action(.b, "Pitch right"), Action(.a, "Set")] + coinStart
        case "waverunr": // the steering turns the handle bar and leans the rider; view 1 is its view change
            return [Action(.rightTrigger, "Throttle"), Action(.a, "View change")] + coinStart
        case "dynamcop": // the fighting buttons: punch, kick, jump
            return [Action(.x, "Punch"), Action(.a, "Kick"), Action(.b, "Jump")] + coinStart
        case "desert": // the shift buttons are the guns; views 1-3 are VR1-3, view 4 the shift lever (held)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Machine gun"),
                    Action(.leftShoulder, "Cannon"), Action(.a, "VR1 (blue)"), Action(.b, "VR2 (green)"), Action(.x, "VR3 (red)"),
                    Action(.y, "Shift (hold)")] + coinStart
        case "skytargt": // Star Wars Arcade's stick and buttons: fire, button 2, button 3
            return [Action(.a, "Machine gun"), Action(.rightShoulder, "Machine gun"), Action(.b, "Missile"), Action(.x, "View change")] + coinStart
        case "bassdx", "getbass", "getbassur", "getbassdx": // the left stick is the rod, the d-pad the lure stick; cast PUNCH, select KICK
            return [Action(.x, "Cast"), Action(.a, "Select"), Action(.rightTrigger, "Reel"), Action(.leftTrigger, "Line tension")] + coinStart
        case "magtruck": // the stick pumps the lever (UP, DOWN); the pedal is the fighting buttons' punch
            return [Action(.x, "Pedal")] + coinStart
        case "vf3":
            return [Action(.x, "Punch"), Action(.a, "Kick"), Action(.b, "Guard"), Action(.y, "Escape")] + coinStart
        case "srally2": // view 1 is its view change; view 2 also sets the hand brake
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"), Action(.leftShoulder, "Shift down"),
                    Action(.a, "View change"), Action(.b, "Hand brake")] + coinStart
        case "segartv": // view 1 is its view change, view 2 its boost; the shift buttons move the gear lever
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Gear up"), Action(.leftShoulder, "Gear down"),
                    Action(.a, "View change"), Action(.b, "Boost")] + coinStart
        case "outr2sdx": // view 1 is its view change; the shift buttons move the gear lever (high and low)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Gear up"), Action(.leftShoulder, "Gear down"),
                    Action(.a, "View change")] + coinStart
        case "pdrift": // the shift buttons move the gear lever (low and high)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "High gear"),
                    Action(.leftShoulder, "Low gear")] + coinStart
        case "outrun": // the shift buttons move the gear lever (low and high)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "High gear"),
                    Action(.leftShoulder, "Low gear")] + coinStart
        case "loffire": // the turret's trigger and missile button; B fires where the gun last aimed
            return [Action(.a, "Fire"), Action(.rightTrigger, "Fire"), Action(.x, "Missile")] + coinStart
        case "smgp": // the shift lever's two switches (up and down)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"),
                    Action(.leftShoulder, "Shift down")] + coinStart
        case "gprider": // throttle grip, brake lever and the shift pedal's two switches
            return [Action(.rightTrigger, "Throttle"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"),
                    Action(.leftShoulder, "Shift down")] + coinStart
        case "hangon", "rachero", "enduror": // throttle grip and brake lever
            return [Action(.rightTrigger, "Throttle"), Action(.leftTrigger, "Brake")] + coinStart
        case "shangon": // the supercharger (turbo) button: SHIFT_UP or VIEW1
            return [Action(.rightTrigger, "Throttle"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Turbo"), Action(.a, "Turbo")] + coinStart
        case "toutrun", "radr": // the shift buttons move the gear lever (low and high); Turbo Out Run's turbo is VIEW1
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "High gear"),
                    Action(.leftShoulder, "Low gear")] + (game.id == "toutrun" ? [Action(.a, "Turbo")] : []) + coinStart
        case "radm": // the light and wiper switches (views 1 and 2); no gears
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.a, "Lights"), Action(.b, "Wiper")] + coinStart
        case "f1en": // gear up and down buttons (manual transmission)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"),
                    Action(.leftShoulder, "Shift down")] + coinStart
        case "orunners": // shift up and down; the radio's music buttons on views 1-3
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"),
                    Action(.leftShoulder, "Shift down"), Action(.a, "Music select"), Action(.b, "Music back"), Action(.x, "Music forward")] + coinStart
        case "dirtdvls", "ecau": // one view change button (view 1)
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"), Action(.leftShoulder, "Shift down"),
                    Action(.a, "View change")] + coinStart
        case "harley": // view 1 is its view change, view 2 its music select
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"), Action(.leftShoulder, "Shift down"),
                    Action(.a, "View change"), Action(.b, "Music select")] + coinStart
        default:
            if game.twin {
                return [Action(.leftTrigger, "Left shot"), Action(.leftShoulder, "Left dash"), Action(.rightTrigger, "Right shot"),
                        Action(.rightShoulder, "Right dash")] + coinStart
            }
            if game.id == "wingwar" {
                return [Action(.a, "Machine gun"), Action(.rightShoulder, "Machine gun"), Action(.b, "Missile"), Action(.x, "Smoke"),
                        Action(.y, "Change view"), Action(.rightTrigger, "Throttle")] + coinStart
            }
            if game.id == "sharrier" { // one fire button on the stick
                return [Action(.a, "Fire"), Action(.rightShoulder, "Fire")] + coinStart
            }
            if game.id == "aburner131" { // the stick's two buttons; no throttle lever
                return [Action(.a, "Vulcan"), Action(.rightShoulder, "Vulcan"), Action(.b, "Missile")] + coinStart
            }
            if game.id == "gforce2" { // the stick's two buttons: shoot and missile
                return [Action(.a, "Shoot"), Action(.rightShoulder, "Shoot"), Action(.b, "Missile"),
                        Action(.rightTrigger, "Throttle")] + coinStart
            }
            if game.id == "gloc" || game.id == "strkfgtr" { // the stick's three buttons: vulcan, missile and after burner
                return [Action(.a, "Vulcan"), Action(.rightShoulder, "Vulcan"), Action(.b, "Missile"), Action(.x, "After burner"),
                        Action(.rightTrigger, "Throttle")] + coinStart
            }
            if game.id == "aburner2" || game.id == "thndrbld" { // the stick's two buttons: vulcan and missile
                return [Action(.a, "Vulcan"), Action(.rightShoulder, "Vulcan"), Action(.b, "Missile"),
                        Action(.rightTrigger, "Throttle")] + coinStart
            }
            if game.flight {
                return [Action(.a, "Fire"), Action(.rightShoulder, "Fire"), Action(.b, "Stick button 2"), Action(.x, "Stick button 3"),
                        Action(.rightTrigger, "Throttle")] + coinStart
            }
            return [Action(.rightTrigger, "Accelerate"), Action(.leftTrigger, "Brake"), Action(.rightShoulder, "Shift up"),
                    Action(.leftShoulder, "Shift down"), Action(.a, "View 1"), Action(.b, "View 2, hand brake"), Action(.x, "View 3"),
                    Action(.y, "View 4")] + coinStart
        }
    }
}
