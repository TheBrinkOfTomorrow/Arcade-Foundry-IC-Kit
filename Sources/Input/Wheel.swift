#if os(macOS)
import Foundation
import IOKit.hid

/// Steering wheels and pedals on the Mac (issue #318), as in the Linux app's
/// wheel.cpp: the Logitech Driving Force GT and G29 first, any Logitech
/// wheel. docs/design/WHEEL-AND-PEDALS.md has the design.
///
/// The wheel is read through IOKit HID, not GameController: Apple's
/// GCRacingWheel knows the G29, G920 and G923 but not the Driving Force GT,
/// and one path keeps the setup, calibration and buttons the same for all.
/// Axes are numbered in their HID usage order (X, Y, Z, Rx, Ry, Rz, slider,
/// dial, wheel, then the Simulation Controls page's, then any other) and
/// scaled to -32768...32767; buttons by their HID number - 1, which is how
/// SDL numbers them under Linux, so a wheel's buttons read the same on both.
///
/// Logitech's wheels start in a compatibility mode (046d:c294, 200 degrees,
/// a few buttons). Linux's hid-logitech driver switches them to their own
/// mode; here the app sends the same command when it finds the Driving Force
/// GT or G29 there, told apart by the device's version number as the driver
/// does (the Driving Force GT reports 0x13xx, for example 0x1322). The wheel
/// then reconnects as itself (c29a, c24f): 900 degrees, separate pedals,
/// every button.
enum WheelAction: Int, CaseIterable, Identifiable {
    case shiftUp, shiftDown, paddleUp, paddleDown, view1, view2, view3, view4, coin, start, handbrake, pause

    var id: Int { rawValue }
    /// The setup's key, as on Linux (wheel.h, kWheelActionKeys).
    var key: String {
        ["shift_up", "shift_down", "paddle_up", "paddle_down", "view1", "view2", "view3", "view4",
         "coin", "start", "handbrake", "pause"][rawValue]
    }
    var name: String {
        ["Shift up", "Shift down", "Paddle up", "Paddle down", "View 1", "View 2", "View 3", "View 4",
         "Coin", "Start", "Hand brake", "Pause menu"][rawValue]
    }
}

/// A wheel's setup, kept per model (USB vendor and product) in the user
/// defaults, as the same key=value lines as the Linux app's
/// <data>/wheels/<vvvv>-<pppp> file.
struct WheelSetup: Equatable {
    var steerAxis = 0, steerCenter = 0
    var gasAxis = -1, gasRest = 0, gasFull = 0 // -1: not calibrated yet
    var brakeAxis = -1, brakeRest = 0, brakeFull = 0
    var lock = 900   // degrees the wheel turns lock to lock
    var range = 270  // degrees of that which are the game's full lock, close to a cabinet's wheel
    var deadzone = 0 // percent of full lock around the centre that counts as straight
    /// How progressive the steering is, 0...100: 0 straight (linear), 100 a
    /// cubic curve; at 50 the centre is half as quick as linear.
    var curve = 50
    /// Self-centring, 0...100: how strongly the wheel's motor pulls it back
    /// to the centre, as a cabinet's spring does (0 off).
    var centring = 50
    var buttons = [Int](repeating: -1, count: WheelAction.allCases.count)

    var pedalsSet: Bool { gasAxis >= 0 && brakeAxis >= 0 }

    /// The defaults for a wheel model. `axes` are the wheel's axes' HID
    /// usages (page << 16 | usage) in their numbered order, to find the
    /// pedals by name where the wheel reports them as Y and Z (or Rz).
    static func defaults(vendor: Int, product: Int, axes: [Int] = []) -> WheelSetup {
        var s = WheelSetup()
        let generic = kHIDPage_GenericDesktop << 16
        if vendor == 0x046d {
            switch product {
            case 0xc294: s.lock = 200 // Driving Force (EX), or a wheel still in that mode
            case 0xc295, 0xca03: s.lock = 240 // Momo
            default: break // Driving Force Pro and GT, G25, G27, G29, G920, G923, PRO: 900
            }
        }
        s.range = min(s.range, s.lock)
        if vendor == 0x046d && product == 0xc29a {
            // The Driving Force GT (evtest under Linux, 2026-11-03): 1-4 the
            // face buttons, 5/6 the paddles (R1/L1), 9 Select, 10 Start,
            // 13/14 the shifter, 21 PS (numbered from 0 here). Its pedals rest
            // at the top of their travel.
            s.buttons = [12, 13, 4, 5, 0, 1, 2, 3, 8, 9, -1, 20]
            let gd = { (usage: Int) -> Int? in axes.firstIndex(of: generic | usage) }
            s.steerAxis = gd(kHIDUsage_GD_X) ?? 0
            if let gas = gd(kHIDUsage_GD_Y), let brake = gd(kHIDUsage_GD_Z) ?? gd(kHIDUsage_GD_Rz) {
                (s.gasAxis, s.gasRest, s.gasFull) = (gas, 32767, -32768)
                (s.brakeAxis, s.brakeRest, s.brakeFull) = (brake, 32767, -32768)
            } // otherwise Calibrate finds them
        }
        return s
    }

    static func key(vendor: Int, product: Int) -> String { String(format: "wheel.%04x-%04x", vendor, product) }

    static func load(vendor: Int, product: Int, axes: [Int] = []) -> WheelSetup {
        var s = defaults(vendor: vendor, product: product, axes: axes)
        guard let text = UserDefaults.standard.string(forKey: key(vendor: vendor, product: product)) else { return s }
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let v = Int(pair[1]) else { continue }
            switch pair[0] {
            case "steer_axis": s.steerAxis = v
            case "steer_center": s.steerCenter = v
            case "gas_axis": s.gasAxis = v
            case "gas_rest": s.gasRest = v
            case "gas_full": s.gasFull = v
            case "brake_axis": s.brakeAxis = v
            case "brake_rest": s.brakeRest = v
            case "brake_full": s.brakeFull = v
            case "lock": s.lock = max(90, min(1080, v))
            case "range": s.range = max(30, min(1080, v))
            case "deadzone": s.deadzone = max(0, min(20, v))
            case "curve": s.curve = max(0, min(100, v))
            case "centring": s.centring = max(0, min(100, v))
            default:
                if let a = WheelAction.allCases.first(where: { $0.key == pair[0] }) { s.buttons[a.rawValue] = v }
            }
        }
        s.range = min(s.range, s.lock)
        return s
    }

    func save(vendor: Int, product: Int) {
        var text = "steer_axis=\(steerAxis)\nsteer_center=\(steerCenter)\ngas_axis=\(gasAxis)\ngas_rest=\(gasRest)\ngas_full=\(gasFull)\n"
        text += "brake_axis=\(brakeAxis)\nbrake_rest=\(brakeRest)\nbrake_full=\(brakeFull)\n"
        text += "lock=\(lock)\nrange=\(range)\ndeadzone=\(deadzone)\ncurve=\(curve)\ncentring=\(centring)\n"
        for a in WheelAction.allCases where buttons[a.rawValue] >= 0 { text += "\(a.key)=\(buttons[a.rawValue])\n" }
        UserDefaults.standard.set(text, forKey: Self.key(vendor: vendor, product: product))
    }

    static func reset(vendor: Int, product: Int) { UserDefaults.standard.removeObject(forKey: key(vendor: vendor, product: product)) }
}

/// The connected wheel, its axes and buttons as last reported. HID calls
/// arrive on the main run loop; the game may read on its own thread, so the
/// values sit behind a lock.
final class Wheel: ObservableObject {
    static let shared = Wheel()

    @Published private(set) var name: String? // nil: no wheel
    @Published var setup = WheelSetup()
    /// The wheel's motor can self-centre it (a Logitech force-feedback wheel).
    @Published private(set) var canCentre = false
    private(set) var vendor = 0, product = 0
    /// The axes' HID usages (page << 16 | usage), in their numbered order.
    private(set) var axisUsages: [Int] = []

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private let lock = NSLock()
    private var axisIndex: [IOHIDElementCookie: (index: Int, min: Int, max: Int)] = [:]
    private var axes: [Int] = []
    private var pressed = Set<Int>()
    private var hat = -1 // the d-pad: 0 up, 1 up-right ... 7 up-left, -1 centred
    private var current = WheelSetup() // `setup`, for the game's thread
    /// When the mode switch was last sent to a wheel at a USB location, so a
    /// wheel that ignores it is not sent it again and again.
    private var switchedAt: [Int: Date] = [:]
    /// The next button pressed, for setting the wheel's buttons in Settings (nil: not listening).
    var onButton: ((Int) -> Void)?

    private init() {
        let wheelLike: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, wheelLike as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<Wheel>.fromOpaque(ctx).takeUnretainedValue().matched(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<Wheel>.fromOpaque(ctx).takeUnretainedValue().removed(dev)
        }, me)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<Wheel>.fromOpaque(ctx).takeUnretainedValue().input(value)
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Starts watching for wheels (the first use of `shared` does it).
    static func start() { _ = shared }

    private static func int(_ dev: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(dev, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    /// Logitech's wheels by USB product (SDL's list of wheels, SDL_IsJoystickWheel).
    private static let logitechWheels: Set<Int> = [0xc24f, 0xc260, 0xc261, 0xc262, 0xc266, 0xc267, 0xc268, 0xc269, 0xc26d, 0xc26e,
                                                   0xc272, 0xc294, 0xc295, 0xc298, 0xc299, 0xc29a, 0xc29b, 0xca03]
    /// The ones whose motor takes Logitech's classic autocentre command
    /// (hid-lg4ff.c: lg4ff_set_autocenter_default): Driving Force (EX), Pro
    /// and GT, G25, G27, G29. Not the Momo (another command) nor the G920,
    /// G923 and PRO (HID++).
    private static let classicCentring: Set<Int> = [0xc294, 0xc298, 0xc299, 0xc29a, 0xc29b, 0xc24f]

    private func matched(_ dev: IOHIDDevice) {
        let v = Self.int(dev, kIOHIDVendorIDKey), p = Self.int(dev, kIOHIDProductIDKey)
        guard device == nil, v == 0x046d, Self.logitechWheels.contains(p) else { return }
        if p == 0xc294, switchToNativeMode(dev) { return } // it comes back as itself
        lock.lock()
        device = dev // read under the lock by state() on the game's thread
        lock.unlock()
        vendor = v
        product = p
        var map: [IOHIDElementCookie: (index: Int, min: Int, max: Int)] = [:]
        var usages: [Int] = []
        var described: [String] = []
        var start: [Int] = []
        if let elements = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            let order = [kHIDUsage_GD_X, kHIDUsage_GD_Y, kHIDUsage_GD_Z, kHIDUsage_GD_Rx, kHIDUsage_GD_Ry, kHIDUsage_GD_Rz,
                         kHIDUsage_GD_Slider, kHIDUsage_GD_Dial, kHIDUsage_GD_Wheel]
            let axesFound = elements.compactMap { e -> (rank: Int, e: IOHIDElement)? in
                let type = IOHIDElementGetType(e)
                guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Axis else { return nil }
                let page = Int(IOHIDElementGetUsagePage(e)), usage = Int(IOHIDElementGetUsage(e))
                guard page != kHIDPage_Button, IOHIDElementGetLogicalMax(e) - IOHIDElementGetLogicalMin(e) >= 3 else { return nil }
                if page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Hatswitch { return nil }
                if page == kHIDPage_GenericDesktop, let i = order.firstIndex(of: usage) { return (i, e) }
                if page == kHIDPage_Simulation { return (100 + usage, e) } // steering, accelerator, brake, clutch
                return (100_000 + Int(IOHIDElementGetCookie(e)), e) // anything else, a vendor's own pedals for one
            }.sorted { $0.rank < $1.rank }
            for (i, a) in axesFound.enumerated() {
                let page = Int(IOHIDElementGetUsagePage(a.e)), usage = Int(IOHIDElementGetUsage(a.e))
                let lo = IOHIDElementGetLogicalMin(a.e), hi = IOHIDElementGetLogicalMax(a.e)
                map[IOHIDElementGetCookie(a.e)] = (i, lo, hi)
                usages.append(page << 16 | usage)
                // Where it is now: HID reports a value only when it changes, and
                // a pedal at rest may not change for a while.
                let now = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
                defer { now.deallocate() }
                var raw = (lo + hi) / 2
                if IOHIDDeviceGetValue(dev, a.e, now) == kIOReturnSuccess {
                    raw = IOHIDValueGetIntegerValue(now.pointee.takeUnretainedValue())
                }
                start.append(hi > lo ? Int((Double(raw - lo) / Double(hi - lo) * 65535).rounded()) - 32768 : 0)
                described.append(String(format: "%ld: page %02lx usage %02lx, %ld...%ld", i, page, usage, lo, hi))
            }
        }
        let version = Self.int(dev, kIOHIDVersionNumberKey)
        NSLog("Arcade Foundry: wheel %04lx:%04lx version %04lx, axes [%@]", v, p, version, described.joined(separator: "; "))
        lock.lock()
        axisIndex = map
        axes = start
        pressed = []
        hat = -1
        lock.unlock()
        axisUsages = usages
        canCentre = Self.classicCentring.contains(p)
        setup = WheelSetup.load(vendor: v, product: p, axes: usages)
        name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "Wheel"
        publishSetup()
        applyTurn()
        applyCentring()
    }

    /// Logitech's command to leave compatibility mode, for the wheels whose
    /// version number says what they are (hid-lg4ff.c:
    /// lg4ff_identify_multimode_wheel and its ext09 mode switches). False
    /// when it isn't one of them, or the wheel would not take it.
    private func switchToNativeMode(_ dev: IOHIDDevice) -> Bool {
        let version = Self.int(dev, kIOHIDVersionNumberKey)
        let mode: [UInt8]
        if version & 0xfff8 == 0x1350 { mode = [0xf8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00] }      // G29
        else if version & 0xff00 == 0x1300 { mode = [0xf8, 0x09, 0x03, 0x01, 0x00, 0x00, 0x00] } // Driving Force GT
        else { return false }
        let location = Self.int(dev, kIOHIDLocationIDKey)
        if let last = switchedAt[location], Date().timeIntervalSince(last) < 10 {
            NSLog("Arcade Foundry: wheel %04lx is still in compatibility mode; using it as it is", version)
            return false
        }
        switchedAt[location] = Date()
        _ = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        for report in [[0xf8, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00] as [UInt8], mode] {
            let r = Self.send(dev, report)
            if r != kIOReturnSuccess {
                NSLog("Arcade Foundry: wheel mode switch failed (0x%x); using compatibility mode", r)
                return false
            }
        }
        NSLog("Arcade Foundry: wheel %04lx switched to its own mode; it reconnects as itself", version)
        return true
    }

    /// An output report to the wheel (Logitech's commands are 7 bytes, no report ID).
    private static func send(_ dev: IOHIDDevice, _ report: [UInt8]) -> IOReturn {
        report.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count) }
    }

    /// Sets the self-centring spring to the setup's strength: Logitech's
    /// autocentre command, worked out as hid-lg4ff.c's
    /// lg4ff_set_autocenter_default does for a strength of 0...0xffff.
    func applyCentring() {
        guard let device, canCentre else { return }
        let strength = max(0, min(100, setup.centring))
        guard strength > 0 else {
            _ = Self.send(device, [0xf5, 0, 0, 0, 0, 0, 0]) // the spring off
            return
        }
        let m = 0xffff * strength / 100
        var a = m <= 0xaaaa ? 0x0c * m : 0x0c * 0xaaaa + 0x06 * (m - 0xaaaa)
        let b = m <= 0xaaaa ? 0x80 * m : 0x80 * 0xaaaa + 0xff * (m - 0xaaaa)
        a >>= 1 // every wheel here but the Momo
        let k = UInt8(min(255, a / 0xaaaa)), c = UInt8(min(255, b / 0xaaaa))
        let r1 = Self.send(device, [0xfe, 0x0d, k, k, c, 0, 0])
        let r2 = Self.send(device, [0x14, 0, 0, 0, 0, 0, 0]) // the spring on
        if r1 != kIOReturnSuccess || r2 != kIOReturnSuccess {
            NSLog("Arcade Foundry: wheel self-centring failed (0x%x, 0x%x)", r1, r2)
        }
    }

    /// The wheels that take Logitech's turn-range command (hid-lg4ff.c:
    /// lg4ff_set_range_g25, for the G25, G27, Driving Force GT and G29).
    private static let settableTurn: Set<Int> = [0xc299, 0xc29a, 0xc29b, 0xc24f]

    /// Sets how far the wheel itself turns lock to lock to the setup's Wheel
    /// turns. Linux's driver does this when the wheel connects (900); on the
    /// Mac nothing does, and the wheel keeps its own 200 degrees, so the
    /// game reached full lock at about 30 degrees each side.
    func applyTurn() {
        guard let device, Self.settableTurn.contains(product) else { return }
        let turn = max(40, min(900, setup.lock))
        let r = Self.send(device, [0xf8, 0x81, UInt8(turn & 0xff), UInt8(turn >> 8), 0, 0, 0])
        if r != kIOReturnSuccess { NSLog("Arcade Foundry: wheel turn range failed (0x%x)", r) }
    }

    /// At quit: the spring off, as the wheel starts.
    func letGo() {
        guard let device, canCentre else { return }
        _ = Self.send(device, [0xf5, 0, 0, 0, 0, 0, 0])
    }

    private func removed(_ dev: IOHIDDevice) {
        guard let device, CFEqual(dev, device) else { return }
        lock.lock()
        self.device = nil
        axisIndex = [:]
        axes = []
        pressed = []
        hat = -1
        lock.unlock()
        name = nil
        canCentre = false
    }

    private func input(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value)
        guard let device, CFEqual(IOHIDElementGetDevice(e), device) else { return }
        let v = IOHIDValueGetIntegerValue(value)
        let page = Int(IOHIDElementGetUsagePage(e)), usage = Int(IOHIDElementGetUsage(e))
        if page == kHIDPage_Button {
            let b = usage - 1
            lock.lock()
            let was = pressed.contains(b)
            if v != 0 { pressed.insert(b) } else { pressed.remove(b) }
            lock.unlock()
            if v != 0 && !was, let onButton { onButton(b) }
            return
        }
        if page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Hatswitch {
            let lo = IOHIDElementGetLogicalMin(e), hi = IOHIDElementGetLogicalMax(e)
            lock.lock()
            hat = (lo...hi).contains(v) && hi - lo == 7 ? v - lo : -1 // out of range: the null state, centred
            lock.unlock()
            return
        }
        lock.lock()
        if let a = axisIndex[IOHIDElementGetCookie(e)], a.max > a.min {
            axes[a.index] = Int((Double(v - a.min) / Double(a.max - a.min) * 65535).rounded()) - 32768
        }
        lock.unlock()
    }

    /// The setup in force for the game's thread; call after changing `setup`.
    func publishSetup() {
        lock.lock()
        current = setup
        lock.unlock()
    }

    /// Keeps a changed setup: in force now, and saved for the wheel's model.
    func saveSetup() {
        setup.range = min(setup.range, setup.lock)
        publishSetup()
        guard name != nil else { return }
        setup.save(vendor: vendor, product: product)
        applyTurn()
        applyCentring()
    }

    func resetSetup() {
        WheelSetup.reset(vendor: vendor, product: product)
        setup = WheelSetup.defaults(vendor: vendor, product: product, axes: axisUsages)
        publishSetup()
        applyTurn()
        applyCentring()
    }

    // MARK: Reading it (any thread)

    struct State {
        var connected = false
        var steer: Float = 0, gas: Float = 0, brake: Float = 0
        var held = Set<WheelAction>()
    }

    func axis(_ a: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return a >= 0 && a < axes.count ? axes[a] : 0
    }

    var allAxes: [Int] {
        lock.lock(); defer { lock.unlock() }
        return axes
    }

    /// The buttons held now, numbered from 0.
    var heldButtons: [Int] {
        lock.lock(); defer { lock.unlock() }
        return pressed.sorted()
    }

    func state() -> State {
        lock.lock()
        let s = current, ax = axes, down = pressed, on = device != nil
        lock.unlock()
        var out = State()
        guard on else { return out }
        out.connected = true
        func at(_ a: Int) -> Int { a >= 0 && a < ax.count ? ax[a] : 0 }
        out.steer = Self.steer(at(s.steerAxis), s)
        func pedal(_ a: Int, _ rest: Int, _ full: Int) -> Float {
            guard a >= 0, full != rest else { return 0 }
            let t = Float(at(a) - rest) / Float(full - rest)
            return t < 0.03 ? 0 : min(1, (t - 0.03) / 0.94) // a little slack at the top, where a pedal rests
        }
        out.gas = pedal(s.gasAxis, s.gasRest, s.gasFull)
        out.brake = pedal(s.brakeAxis, s.brakeRest, s.brakeFull)
        for a in WheelAction.allCases where s.buttons[a.rawValue] >= 0 && down.contains(s.buttons[a.rawValue]) { out.held.insert(a) }
        return out
    }

    /// -1 full left ... +1 full right, as Linux's Wheel::steer: the wheel's
    /// whole turn either side of where it rests, scaled so the steering range
    /// is full lock, then the dead zone, then the curve.
    static func steer(_ v: Int, _ s: WheelSetup) -> Float {
        let c = max(-16384, min(16383, s.steerCenter))
        let n = v >= c ? Float(v - c) / Float(32767 - c) : Float(v - c) / Float(c + 32768)
        let out = max(-1, min(1, n * Float(s.lock) / Float(max(s.range, 30))))
        let dz = Float(s.deadzone) / 100
        guard abs(out) > dz else { return 0 }
        let x = (abs(out) - dz) / (1 - dz), k = Float(s.curve) / 100
        let shaped = (1 - k) * x + k * x * x * x // gentle near the centre, quicker towards full lock
        return out < 0 ? -shaped : shaped
    }

    /// The wheel's d-pad and buttons as a gamepad's, for the library and the
    /// menus (MenuPad), as the Linux app's wheel_as_pad: Logitech's
    /// PlayStation layout, HID buttons 1-4 Cross, Square, Circle, Triangle
    /// (A, X, B, Y), 5/6 R1/L1, 7/8 R2/L2, 9 Select (Options), 10 Start
    /// (Menu). Nil with no wheel.
    func menuPad() -> MenuPad? {
        lock.lock()
        let down = pressed, h = hat, on = device != nil
        lock.unlock()
        guard on else { return nil }
        var pad = MenuPad()
        if h >= 0 {
            // 0 up, 1 up-right, 2 right, 3 down-right, 4 down, 5 down-left, 6 left, 7 up-left
            let xs: [Float] = [0, 1, 1, 1, 0, -1, -1, -1], ys: [Float] = [1, 1, 0, -1, -1, -1, 0, 1]
            pad.moveX = xs[h]
            pad.moveY = ys[h]
        }
        pad.a = down.contains(0)
        pad.buttonX = down.contains(1)
        pad.b = down.contains(2)
        pad.buttonY = down.contains(3)
        pad.r1 = down.contains(4)
        pad.l1 = down.contains(5)
        pad.r2 = down.contains(6)
        pad.l2 = down.contains(7)
        pad.options = down.contains(8)
        pad.menu = down.contains(9)
        return pad
    }
}
#endif
