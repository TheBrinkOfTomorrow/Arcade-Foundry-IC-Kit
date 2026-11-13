#if os(macOS)
import Combine
import SwiftUI

/// Settings > Wheel and pedals (macOS), as the Linux app's pause menu
/// screen: the live steering and pedals, the steering range, the curve, the
/// wheel's full turn, the dead zone, self-centring, calibration and the
/// wheel's buttons. Changes are kept at once, per wheel model.
struct WheelSettingsSection: View {
    @ObservedObject private var wheel = Wheel.shared
    @StateObject private var calibration = WheelCalibration()
    @State private var live = Wheel.State()
    @State private var held: [Int] = []
    @State private var listening: WheelAction?
    @State private var showButtons = false
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Wheel and pedals") {
            if let name = wheel.name {
                LabeledContent("Wheel", value: name)
                meter("Steering", live.steer, centred: true)
                meter("Gas", live.gas)
                meter("Brake", live.brake)
                if calibration.step != .none {
                    calibrating
                } else {
                    settings
                }
            } else {
                Text("No wheel connected. The Logitech Driving Force GT and G29 work as they are; another Logitech wheel after Calibrate. A G29 needs its switch on PS3.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in
            guard wheel.name != nil else { return }
            live = wheel.state()
            held = wheel.heldButtons
            calibration.tick()
        }
        .onDisappear {
            wheel.onButton = nil
            listening = nil
        }
    }

    @ViewBuilder private var settings: some View {
        Stepper("Steering range: \(wheel.setup.range)°", value: value(\.range), in: 30...max(30, wheel.setup.lock), step: 10)
        Text("How far to turn for the game's full lock. A cabinet's wheel turns about 270 degrees.")
            .font(.caption).foregroundStyle(.secondary)
        Stepper("Steering curve: \(wheel.setup.curve)%", value: value(\.curve), in: 0...100, step: 10)
        Text("0% steers in a straight line; more is gentler near the centre and quicker towards full lock.")
            .font(.caption).foregroundStyle(.secondary)
        Stepper("Wheel turns: \(wheel.setup.lock)°", value: value(\.lock), in: 90...1080, step: 10)
        Text("The wheel's own turn lock to lock: 900 for the Driving Force GT and G29.")
            .font(.caption).foregroundStyle(.secondary)
        Stepper("Dead zone: \(wheel.setup.deadzone)%", value: value(\.deadzone), in: 0...20)
        Text("How much around the centre counts as straight ahead.")
            .font(.caption).foregroundStyle(.secondary)
        if wheel.canCentre {
            Stepper(wheel.setup.centring == 0 ? "Self-centring: off" : "Self-centring: \(wheel.setup.centring)%",
                    value: value(\.centring), in: 0...100, step: 10)
            Text("How strongly the wheel pulls itself back to the centre, like a cabinet's spring (0 is off).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Self-centring", value: "Not on this wheel")
        }
        LabeledContent(wheel.setup.pedalsSet ? "Calibration" : "Calibration (not done yet)") {
            Button("Calibrate") { calibration.start() }
        }
        DisclosureGroup("Wheel buttons", isExpanded: $showButtons) {
            ForEach(WheelAction.allCases) { action in
                LabeledContent(action.name) {
                    HStack {
                        Text(buttonText(action)).foregroundStyle(listening == action ? Color.accentColor : .secondary)
                        Button(listening == action ? "Cancel" : "Set") { listen(action) }
                        Button("Clear") {
                            wheel.setup.buttons[action.rawValue] = -1
                            wheel.saveSetup()
                        }
                        .disabled(wheel.setup.buttons[action.rawValue] < 0)
                    }
                }
            }
            Text(held.isEmpty ? "Choose Set, then press the wheel's button for it." : "Held now: " + held.map { String($0 + 1) }.joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Reset this wheel", role: .destructive) { wheel.resetSetup() }
        Text("Forgets this wheel's calibration, buttons and settings.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var calibrating: some View {
        Text(calibration.step.instructions)
        if calibration.step == .rest {
            Text("Then choose Next, or press a wheel button.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if calibration.step == .rest {
                Button("Next") { calibration.restDone() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Cancel", role: .cancel) { calibration.cancel() }
        }
    }

    private func buttonText(_ action: WheelAction) -> String {
        if listening == action { return "Press a wheel button" }
        let b = wheel.setup.buttons[action.rawValue]
        return b < 0 ? "–" : "Button \(b + 1)"
    }

    /// The next wheel button pressed becomes `action`'s (or Set again cancels).
    private func listen(_ action: WheelAction) {
        if listening == action {
            listening = nil
            wheel.onButton = nil
            return
        }
        listening = action
        wheel.onButton = { b in
            DispatchQueue.main.async {
                wheel.setup.buttons[action.rawValue] = b
                wheel.saveSetup()
                listening = nil
                wheel.onButton = nil
            }
        }
    }

    /// A setting that is kept as soon as it changes.
    private func value(_ key: WritableKeyPath<WheelSetup, Int>) -> Binding<Int> {
        Binding(get: { wheel.setup[keyPath: key] }, set: {
            wheel.setup[keyPath: key] = $0
            wheel.saveSetup()
        })
    }

    /// A bar from -1...1 (centred) or 0...1.
    private func meter(_ name: String, _ v: Float, centred: Bool = false) -> some View {
        LabeledContent(name) {
            GeometryReader { g in
                let w = g.size.width, f = CGFloat(max(-1, min(1, v)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).stroke(Color.secondary)
                    Rectangle().fill(Color.accentColor)
                        .frame(width: centred ? abs(f) * w / 2 : max(0, f) * w)
                        .offset(x: centred ? w / 2 + min(0, f) * w / 2 : 0)
                }
            }
            .frame(width: 180, height: 10)
        }
    }
}

/// Wheel and pedals over the pause menu, as the Linux app's pause-menu
/// screen: up and down choose a row, left and right change it, A (or
/// Return) chooses, B (or Escape) goes back, with a wheel's d-pad and
/// buttons, a gamepad or the keyboard; the mouse works too. GameSession
/// passes it the menu's commands (handle) while it is open.
final class WheelPanelModel: ObservableObject {
    enum Row: CaseIterable { case range, curve, lock, deadzone, centring, calibrate, buttons, reset, back }

    @Published var row = Row.range
    /// In the wheel buttons list: which action is highlighted (nil: not in it).
    @Published var buttonRow: Int?
    @Published private(set) var listening: WheelAction?
    @Published var confirmReset = false
    let calibration = WheelCalibration()
    /// After a wheel button is learned: nothing more until it is let go, so
    /// the same press doesn't also choose a row.
    private var waitRelease = false
    private let wheel = Wheel.shared
    private var forward: AnyCancellable?

    init() {
        forward = calibration.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var rows: [Row] { Row.allCases.filter { $0 != .centring || wheel.canCentre } }

    func open() {
        row = .range
        buttonRow = nil
        confirmReset = false
    }

    /// The pause menu closed: stop learning a button or calibrating.
    func close() {
        stopListening()
        if calibration.step != .none { calibration.cancel() }
        buttonRow = nil
        confirmReset = false
    }

    /// Each refresh while it shows (from the view's timer).
    func tick() {
        calibration.tick()
        if waitRelease && wheel.heldButtons.isEmpty { waitRelease = false }
    }

    /// One menu command; false to go back to the pause menu.
    func handle(_ command: Controls.MenuCommand) -> Bool {
        if waitRelease { return true }
        guard wheel.name != nil else { return command != .select && command != .close }
        if calibration.step != .none {
            switch command {
            case .select: calibration.restDone()
            case .close: calibration.cancel()
            default: break
            }
            return true
        }
        if listening != nil {
            // B or Escape stops waiting, unless it is a wheel button (that one is learned).
            if command == .close && wheel.heldButtons.isEmpty { stopListening() }
            return true
        }
        if let i = buttonRow {
            let actions = WheelAction.allCases
            switch command {
            case .up: buttonRow = max(0, i - 1)
            case .down: buttonRow = min(actions.count - 1, i + 1)
            case .select: listen(actions[i])
            case .clear, .left: clearButton(actions[i])
            case .close: buttonRow = nil
            case .right: break
            }
            return true
        }
        if confirmReset {
            if command == .select { wheel.resetSetup() }
            confirmReset = false
            return true
        }
        let list = rows, at = list.firstIndex(of: row) ?? 0
        switch command {
        case .up: row = list[max(0, at - 1)]
        case .down: row = list[min(list.count - 1, at + 1)]
        case .left: change(row, by: -1)
        case .right: change(row, by: 1)
        case .select: return choose(row)
        case .close: return false
        case .clear: break
        }
        return true
    }

    /// A, Return or a click on a row; false for Back.
    @discardableResult func choose(_ r: Row) -> Bool {
        row = r
        switch r {
        case .calibrate: calibration.start(wheelButtonGoesOn: false) // A or Return goes on here
        case .buttons: buttonRow = 0
        case .reset: confirmReset = true
        case .back: return false
        default: change(r, by: 1)
        }
        return true
    }

    /// One step left (-1) or right (1) on a setting's row, kept at once.
    func change(_ r: Row, by step: Int) {
        var s = wheel.setup
        switch r {
        case .range: s.range = max(30, min(max(30, s.lock), s.range + 10 * step))
        case .curve: s.curve = max(0, min(100, s.curve + 10 * step))
        case .lock: s.lock = max(90, min(1080, s.lock + 10 * step))
        case .deadzone: s.deadzone = max(0, min(20, s.deadzone + step))
        case .centring: s.centring = max(0, min(100, s.centring + 10 * step))
        default: return
        }
        wheel.setup = s
        wheel.saveSetup()
    }

    func value(_ r: Row) -> String {
        let s = wheel.setup
        switch r {
        case .range: return "\(s.range)°"
        case .curve: return "\(s.curve)%"
        case .lock: return "\(s.lock)°"
        case .deadzone: return "\(s.deadzone)%"
        case .centring: return s.centring == 0 ? "Off" : "\(s.centring)%"
        case .calibrate: return s.pedalsSet ? "" : "Not done yet"
        default: return ""
        }
    }

    static func name(_ r: Row) -> String {
        switch r {
        case .range: "Steering range"
        case .curve: "Steering curve"
        case .lock: "Wheel turns"
        case .deadzone: "Dead zone"
        case .centring: "Self-centring"
        case .calibrate: "Calibrate"
        case .buttons: "Wheel buttons"
        case .reset: "Reset this wheel"
        case .back: "Back"
        }
    }

    static func help(_ r: Row) -> String {
        switch r {
        case .range: "How far to turn for the game's full lock. A cabinet's wheel turns about 270 degrees."
        case .curve: "0% steers in a straight line; more is gentler near the centre and quicker towards full lock."
        case .lock: "The wheel's own turn lock to lock: 900 for the Driving Force GT and G29."
        case .deadzone: "How much around the centre counts as straight ahead."
        case .centring: "How strongly the wheel pulls itself back to the centre, like a cabinet's spring."
        case .calibrate: "Finds the steering and the pedals: follow the steps."
        case .buttons: "Which wheel button does what."
        case .reset: "Forgets this wheel's calibration, buttons and settings."
        case .back: ""
        }
    }

    func buttonText(_ action: WheelAction) -> String {
        if listening == action { return "Press a wheel button" }
        let b = wheel.setup.buttons[action.rawValue]
        return b < 0 ? "–" : "Button \(b + 1)"
    }

    /// The next wheel button pressed becomes `action`'s.
    func listen(_ action: WheelAction) {
        if listening == action { stopListening(); return }
        listening = action
        wheel.onButton = { [weak self] b in
            DispatchQueue.main.async {
                guard let self, self.listening == action else { return }
                self.wheel.setup.buttons[action.rawValue] = b
                self.wheel.saveSetup()
                self.stopListening()
                self.waitRelease = true
            }
        }
    }

    func clearButton(_ action: WheelAction) {
        wheel.setup.buttons[action.rawValue] = -1
        wheel.saveSetup()
    }

    private func stopListening() {
        if listening != nil { wheel.onButton = nil }
        listening = nil
    }
}

/// The pause menu's Wheel and pedals screen (WheelPanelModel).
struct WheelPanel: View {
    @ObservedObject var model: WheelPanelModel
    let done: () -> Void
    @ObservedObject private var wheel = Wheel.shared
    @State private var live = Wheel.State()
    @State private var held: [Int] = []
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wheel and pedals").font(.largeTitle.bold())
            if let name = wheel.name {
                Text(name).foregroundStyle(.white.opacity(0.7))
                meter("Steering", live.steer, centred: true)
                meter("Gas", live.gas)
                meter("Brake", live.brake)
                if model.calibration.step != .none {
                    calibrating
                } else if model.buttonRow != nil {
                    buttons
                } else {
                    rows
                }
            } else {
                Text("No wheel connected. The Logitech Driving Force GT and G29 work as they are; another Logitech wheel after Calibrate. A G29 needs its switch on PS3.")
                    .foregroundStyle(.white.opacity(0.7))
                hint("A or B: back")
            }
        }
        .foregroundStyle(.white)
        .frame(width: 560, alignment: .leading)
        .padding(32)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .onReceive(timer) { _ in
            model.tick()
            guard wheel.name != nil else { return }
            live = wheel.state()
            held = wheel.heldButtons
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.rows, id: \.self) { r in
                let on = model.row == r
                HStack {
                    Text(WheelPanelModel.name(r)).font(.title3.weight(.semibold))
                    Spacer()
                    if isSetting(r) {
                        Button { model.row = r; model.change(r, by: -1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain)
                        Text(model.value(r)).monospacedDigit().frame(minWidth: 56)
                        Button { model.row = r; model.change(r, by: 1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain)
                    } else {
                        Text(model.value(r)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 14)
                .background(on ? Color.accentColor : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { if !isSetting(r) && !model.choose(r) { done() } else { model.row = r } }
            }
            if model.confirmReset {
                HStack {
                    Text("Reset this wheel? A: yes, any other button: no.").foregroundStyle(.yellow)
                    Button("Yes") { _ = model.handle(.select) }
                    Button("No") { _ = model.handle(.close) }
                }
            } else {
                Text(WheelPanelModel.help(model.row)).font(.callout).foregroundStyle(.white.opacity(0.7))
                    .frame(minHeight: 40, alignment: .topLeading)
            }
            hint("Up and down choose, left and right change, A chooses, B goes back")
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(WheelAction.allCases.enumerated()), id: \.offset) { i, action in
                let on = model.buttonRow == i
                HStack {
                    Text(action.name)
                    Spacer()
                    Text(model.buttonText(action))
                        .foregroundStyle(model.listening == action ? Color.yellow : .white.opacity(0.8))
                }
                .padding(.vertical, 5).padding(.horizontal, 14)
                .background(on ? Color.accentColor : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { model.buttonRow = i; model.listen(action) }
            }
            Text(held.isEmpty ? "A: set (then press the wheel's button), X or Delete: clear, B: back"
                              : "Held now: " + held.map { String($0 + 1) }.joined(separator: " "))
                .font(.callout).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var calibrating: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.calibration.step.instructions).font(.title3)
            hint(model.calibration.step == .rest ? "A or Return: next, B: cancel" : "B: cancel")
        }
    }

    private func isSetting(_ r: WheelPanelModel.Row) -> Bool {
        [.range, .curve, .lock, .deadzone, .centring].contains(r)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.white.opacity(0.5))
    }

    /// A bar from -1...1 (centred) or 0...1.
    private func meter(_ name: String, _ v: Float, centred: Bool = false) -> some View {
        HStack {
            Text(name).frame(width: 80, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width, f = CGFloat(max(-1, min(1, v)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: centred ? abs(f) * w / 2 : max(0, f) * w)
                        .offset(x: centred ? w / 2 + min(0, f) * w / 2 : 0)
                }
            }
            .frame(height: 10)
        }
    }
}

/// Calibration, as the Linux app's (wheel_tick): let go of everything (the
/// resting values), turn the wheel (its axis and centre), press the gas,
/// press the brake. Each pedal is the axis pushed past half its travel; its
/// furthest value is fully pressed, and it counts once let go.
final class WheelCalibration: ObservableObject {
    enum Step {
        case none, rest, turn, gas, brake

        var instructions: String {
            switch self {
            case .none: ""
            case .rest: "Centre the wheel and let go of it and the pedals."
            case .turn: "Turn the wheel a good way to either side."
            case .gas: "Press the gas pedal all the way down, then let it go."
            case .brake: "Press the brake pedal all the way down, then let it go."
            }
        }
    }

    @Published private(set) var step = Step.none
    private var rest: [Int] = []
    private var found = -1, peak = 0
    private let wheel = Wheel.shared

    /// wheelButtonGoesOn: any wheel button ends the first step (Settings,
    /// with the mouse); off in the pause menu, where A goes on and B cancels.
    func start(wheelButtonGoesOn: Bool = true) {
        step = .rest
        if wheelButtonGoesOn {
            wheel.onButton = { [weak self] _ in DispatchQueue.main.async { self?.restDone() } }
        }
    }

    func restDone() {
        guard step == .rest else { return }
        wheel.onButton = nil
        rest = wheel.allAxes
        found = -1
        step = .turn
    }

    func cancel() {
        wheel.onButton = nil
        step = .none
        wheel.setup = WheelSetup.load(vendor: wheel.vendor, product: wheel.product, axes: wheel.axisUsages) // as it was
        wheel.publishSetup()
    }

    func tick() {
        guard step == .turn || step == .gas || step == .brake else { return }
        let now = wheel.allAxes, n = min(now.count, rest.count)
        if step == .turn {
            // The axis turned furthest from where it rested, once past a quarter of its travel.
            var best = -1, far = 16384 / 2
            for a in 0..<n where abs(now[a] - rest[a]) > far { (best, far) = (a, abs(now[a] - rest[a])) }
            if best >= 0 {
                wheel.setup.steerAxis = best
                wheel.setup.steerCenter = rest[best]
                found = -1
                step = .gas
            }
            return
        }
        // A pedal: not the steering's axis, nor (for the brake) the gas's.
        if found < 0 {
            for a in 0..<n where a != wheel.setup.steerAxis && !(step == .brake && a == wheel.setup.gasAxis) {
                if abs(now[a] - rest[a]) > 32768 / 2 {
                    found = a
                    peak = now[a]
                    break
                }
            }
            return
        }
        guard found < n else { found = -1; return }
        let v = now[found]
        if abs(v - rest[found]) > abs(peak - rest[found]) { peak = v }
        if abs(v - rest[found]) > 32768 / 8 { return } // still pressed
        if step == .gas {
            (wheel.setup.gasAxis, wheel.setup.gasRest, wheel.setup.gasFull) = (found, rest[found], peak)
            step = .brake
        } else {
            (wheel.setup.brakeAxis, wheel.setup.brakeRest, wheel.setup.brakeFull) = (found, rest[found], peak)
            step = .none
            wheel.saveSetup()
        }
        found = -1
    }
}
#endif
