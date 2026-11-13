import CoreGraphics
import Foundation
import SwiftUI

/// How the picture fills the view.
enum ScreenAspect: String, CaseIterable {
    case original // the cabinet's shape: 4:3 (wider when the core widens it), Lindbergh's own size
    case stretch  // the whole view
    case integer  // the original shape at a whole multiple of the game's lines, so every line is as tall

    var title: String {
        switch self {
        case .original: "Original shape"
        case .stretch: "Stretch to fill"
        case .integer: "Whole-number scale"
        }
    }
}

/// What the picture is drawn through.
enum ScreenEffect: String, CaseIterable {
    case none
    case scanlines // dark gaps between the game's lines
    case crt       // scanlines, a curved tube, the shadow mask and a glow

    var title: String {
        switch self {
        case .none: "None"
        case .scanlines: "Scanlines"
        case .crt: "CRT"
        }
    }
}

/// The screen settings (issue #24): one set for every game
/// (SettingKey.screenLook) and, optionally, a game's own
/// ("screenLook.<romset>"; absent or empty: the global set). Stored as a
/// short string ("aspect=original,effect=crt,smooth=1,zoom=1,x=0,y=0") so
/// @AppStorage can hold it.
struct ScreenLook: Equatable, RawRepresentable {
    var aspect = ScreenAspect.original
    var effect = ScreenEffect.none
    var smooth = true
    var zoom = 1.0   // the picture's size, 0.8...1.2 (below 1 for TVs that crop the edges)
    var shiftX = 0.0 // the picture's centre moved by a share of the view, -0.1...0.1; right and down
    var shiftY = 0.0

    static let zooms = 0.8...1.2
    static let shifts = -0.1...0.1

    init() {}

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        for pair in rawValue.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "aspect": aspect = ScreenAspect(rawValue: kv[1]) ?? aspect
            case "effect": effect = ScreenEffect(rawValue: kv[1]) ?? effect
            case "smooth": smooth = kv[1] != "0"
            case "zoom": zoom = (Double(kv[1]) ?? 1).clamped(to: Self.zooms)
            case "x": shiftX = (Double(kv[1]) ?? 0).clamped(to: Self.shifts)
            case "y": shiftY = (Double(kv[1]) ?? 0).clamped(to: Self.shifts)
            default: break
            }
        }
    }

    var rawValue: String {
        "aspect=\(aspect.rawValue),effect=\(effect.rawValue),smooth=\(smooth ? 1 : 0),zoom=\(zoom),x=\(shiftX),y=\(shiftY)"
    }

    /// The global set before it was first changed: "Smooth pixels" as it was set.
    static var standard: ScreenLook {
        var look = ScreenLook()
        look.smooth = UserDefaults.standard.object(forKey: SettingKey.smooth) as? Bool ?? true
        return look
    }

    static func gameKey(_ romset: String) -> String { "\(SettingKey.screenLook).\(romset)" }

    /// The set a game plays with: its own, or the global one.
    static func resolved(global: String, game: String) -> ScreenLook {
        ScreenLook(rawValue: game) ?? ScreenLook(rawValue: global) ?? .standard
    }

    /// The picture's place in a view of `size`, in the same units, for a
    /// screen of `width` x `height` pixels. `unit`: the view's units per
    /// display pixel (1 for a drawable, 1 / scale for points), so a
    /// whole-number scale lands on display pixels. Lindbergh screens
    /// (`squarePixels`) show at their own shape; the Model 1/2/3 boards'
    /// 496 x 384 at 4:3, a widened or stereo screen keeping that pixel shape;
    /// the classic 2D boards' narrower screens (Out Run's 320 x 224) at 4:3.
    func rect(in size: CGSize, width: Int, height: Int, squarePixels: Bool, unit: CGFloat = 1) -> CGRect {
        let w = CGFloat(max(width, 1)), h = CGFloat(max(height, 1))
        let shape = squarePixels ? w / h : w < 496 ? 4.0 / 3.0 : 4.0 / 3.0 * (w / 496.0)
        func fit() -> CGSize {
            size.width / max(size.height, 1) > shape ? CGSize(width: size.height * shape, height: size.height)
                                                     : CGSize(width: size.width, height: size.width / shape)
        }
        var pic: CGSize
        switch aspect {
        case .original:
            pic = fit()
        case .stretch:
            pic = size
        case .integer:
            let line = h * unit
            let n = min((size.height / line).rounded(.down), (size.width / (line * shape)).rounded(.down))
            pic = n >= 1 ? CGSize(width: n * line * shape, height: n * line) : fit()
        }
        pic.width *= zoom
        pic.height *= zoom
        let cx = size.width * (0.5 + shiftX), cy = size.height * (0.5 + shiftY)
        return CGRect(x: cx - pic.width / 2, y: cy - pic.height / 2, width: pic.width, height: pic.height)
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

/// The controls for one set of screen settings (app settings, a game's page).
struct ScreenLookControls: View {
    @Binding var look: ScreenLook

    var body: some View {
        Picker("Shape", selection: $look.aspect) {
            ForEach(ScreenAspect.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Effect", selection: $look.effect) {
            ForEach(ScreenEffect.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Smooth pixels", isOn: $look.smooth)
        StepRow(title: "Size", value: $look.zoom, step: 0.01, range: ScreenLook.zooms)
        StepRow(title: "Move across", value: $look.shiftX, step: 0.005, range: ScreenLook.shifts)
        StepRow(title: "Move down", value: $look.shiftY, step: 0.005, range: ScreenLook.shifts)
        if look.zoom != 1 || look.shiftX != 0 || look.shiftY != 0 {
            Button("Reset size and position") {
                look.zoom = 1
                look.shiftX = 0
                look.shiftY = 0
            }
        }
        Text("Size below 100% and the moves are for TVs that cut off the picture's edges. Whole-number scale keeps every line of the game the same height, which suits scanlines.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// A value changed a step at a time with − and + (works with the Apple TV remote too).
private struct StepRow: View {
    let title: String
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    #if os(tvOS)
    // Apple TV highlights the whole row white while − or + has the focus:
    // its name and value turn dark then (#261).
    @FocusState private var focus: Bool?
    private var text: Color { focus == nil ? .primary : .black }
    #else
    private var text: Color { .primary }
    #endif

    var body: some View {
        HStack {
            Text(title).foregroundStyle(text)
            Spacer()
            Button { change(-step) } label: { Image(systemName: "minus") }
                .disabled(value <= range.lowerBound)
                #if os(tvOS)
                .focused($focus, equals: false)
                #endif
            Text(label).monospacedDigit().frame(minWidth: 64).foregroundStyle(text)
            Button { change(step) } label: { Image(systemName: "plus") }
                .disabled(value >= range.upperBound)
                #if os(tvOS)
                .focused($focus, equals: true)
                #endif
        }
        #if !os(tvOS)
        .buttonStyle(.borderless)
        #endif
    }

    private var label: String {
        title == "Size" ? String(format: "%.0f%%", value * 100) : String(format: "%+.1f%%", value * 100)
    }

    private func change(_ by: Double) {
        value = ((value + by) / step).rounded() * step
        value = min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A game's own screen settings, on its page.
struct GameScreenSection: View {
    let romset: String
    @AppStorage private var own: String
    @AppStorage(SettingKey.screenLook) private var global = ScreenLook.standard.rawValue

    init(romset: String) {
        self.romset = romset
        _own = AppStorage(wrappedValue: "", ScreenLook.gameKey(romset))
    }

    var body: some View {
        Section("Screen") {
            Toggle("Own screen settings for this game", isOn: Binding(
                get: { !own.isEmpty },
                set: { own = $0 ? (ScreenLook(rawValue: global) ?? .standard).rawValue : "" }))
            if let look = ScreenLook(rawValue: own) {
                ScreenLookControls(look: Binding(get: { look }, set: { own = $0.rawValue }))
            } else {
                Text("Uses the screen settings in Settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
