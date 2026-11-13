#if os(macOS)
import SwiftUI

/// The Mac's Help menu (issue #170): during a game, its controls over the
/// pause menu; otherwise the website.
struct HelpCommand: View {
    @FocusedValue(\.gameSession) private var session
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let session {
            Button("\(session.game.title) Controls") {
                session.openMenu()
                session.showControls = true
            }
            .keyboardShortcut("?", modifiers: .command)
        } else {
            Button("Arcade Foundry: Insert Coin Website") {
                if let url = URL(string: "https://\(VideoCaption.site)") { openURL(url) }
            }
        }
    }
}

private struct GameSessionKey: FocusedValueKey {
    typealias Value = GameSession
}

extension FocusedValues {
    /// The game playing in the window (PlayView), for the Help menu.
    var gameSession: GameSession? {
        get { self[GameSessionKey.self] }
        set { self[GameSessionKey.self] = newValue }
    }
}

/// A game's controls on the keyboard and a controller, as Controls reads
/// them (keep the two in step).
enum ControlsHelp {
    struct Line: Hashable {
        let control: String
        let keyboard: String
        let controller: String
    }

    static func lines(for game: GameInfo) -> [Line] {
        game.flight ? flight : game.twin ? twin : game.id == "crtaxihr" ? taxi : game.id == "vcop3" ? gun + change + pedal : game.id == "hotd3" ? grip : game.gunButton ? gun + (game.id == "loffire" ? missile : grenade) : game.gunStart ? gun + action : game.aimsGun ? gun : game.fishing ? fishing
            : game.fighting ? fighting : driving
    }

    /// Every game's cabinet buttons and the pause menu.
    static let cabinet = [
        Line(control: "Coin", keyboard: "5", controller: "Options (Select)"),
        Line(control: "Start", keyboard: "Return", controller: "Menu (Start)"),
        Line(control: "Pause", keyboard: "Esc", controller: "Options and Menu together"),
        Line(control: "Test, Service", keyboard: "F2, F3", controller: "A, B in operator mode"),
    ]

    /// Crazy Taxi High Roller: Drive and Reverse on the shift buttons, JUMP on views 1 and 2.
    private static let taxi = [
        Line(control: "Steer", keyboard: "← →", controller: "Left stick or d-pad"),
        Line(control: "Accelerate", keyboard: "↑", controller: "Right trigger"),
        Line(control: "Brake", keyboard: "↓", controller: "Left trigger"),
        Line(control: "Drive, Reverse", keyboard: "A, Z", controller: "Right, left shoulder"),
        Line(control: "Jump", keyboard: "1 or 2", controller: "A or B"),
    ]
    private static let driving = [
        Line(control: "Steer", keyboard: "← →", controller: "Left stick or d-pad"),
        Line(control: "Accelerate", keyboard: "↑", controller: "Right trigger"),
        Line(control: "Brake", keyboard: "↓", controller: "Left trigger"),
        Line(control: "Gear up, down", keyboard: "A, Z", controller: "Right, left shoulder"),
        Line(control: "Views 1-4", keyboard: "1-4", controller: "A, B, X, Y"),
    ]

    private static let gun = [
        Line(control: "Aim", keyboard: "Mouse", controller: "Right or left stick"),
        Line(control: "Fire", keyboard: "Click or Space", controller: "Right trigger or A"),
        Line(control: "Reload", keyboard: "Right-click", controller: "B"),
        Line(control: "Player 2", keyboard: "", controller: "A second controller"),
    ]
    private static let grenade = [Line(control: "Grenade", keyboard: "Middle-click or G", controller: "X")]
    private static let action = [Line(control: "Action (Start)", keyboard: "Return, middle-click or G", controller: "Menu (Start) or X")]
    private static let grip = gun.map { $0.control == "Reload" ? Line(control: "Reload (grip)", keyboard: $0.keyboard, controller: $0.controller) : $0 }
    private static let change = [Line(control: "Change weapon", keyboard: "Middle-click or G", controller: "X")]
    private static let pedal = [Line(control: "Pedal", keyboard: "F", controller: "Y")]
    private static let missile = [Line(control: "Missile", keyboard: "Middle-click or G", controller: "X")]

    private static let fighting = [
        Line(control: "Move", keyboard: "Arrows", controller: "Left stick or d-pad"),
        Line(control: "Button 1 (punch)", keyboard: "A", controller: "X"),
        Line(control: "Button 2 (kick)", keyboard: "S", controller: "A"),
        Line(control: "Button 3 (guard)", keyboard: "D", controller: "B"),
        Line(control: "Button 4", keyboard: "F", controller: "Y"),
        Line(control: "Player 2", keyboard: "", controller: "A second controller"),
    ]

    private static let flight = [
        Line(control: "Stick", keyboard: "Arrows", controller: "Left stick"),
        Line(control: "Throttle", keyboard: "A opens, Z closes", controller: "Right trigger"),
        Line(control: "Fire", keyboard: "Space", controller: "A or right shoulder"),
        Line(control: "Other buttons", keyboard: "X, C", controller: "B, X"),
        Line(control: "Second trigger", keyboard: "V", controller: "Left shoulder"),
        Line(control: "Views", keyboard: "1-4", controller: "Y"),
        Line(control: "Player 2 start", keyboard: "6", controller: ""),
    ]

    private static let twin = [
        Line(control: "Left lever", keyboard: "W A S D", controller: "Left stick"),
        Line(control: "Left shot, dash", keyboard: "Q, E", controller: "Left trigger, shoulder"),
        Line(control: "Right lever", keyboard: "I J K L", controller: "Right stick"),
        Line(control: "Right shot, dash", keyboard: "U, O", controller: "Right trigger, shoulder"),
    ]

    private static let fishing = [
        Line(control: "Rod", keyboard: "", controller: "Left stick"),
        Line(control: "Reel", keyboard: "", controller: "Right trigger"),
        Line(control: "Line tension", keyboard: "", controller: "Left trigger"),
        Line(control: "Lure", keyboard: "", controller: "D-pad"),
        Line(control: "Cast, select", keyboard: "", controller: "X, A"),
    ]
}

/// The controls card over the pause menu.
struct ControlsCard: View {
    let game: GameInfo
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("\(game.title) Controls").font(.title.bold())
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Keyboard").font(.headline)
                    Text("Controller").font(.headline)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(ControlsHelp.lines(for: game) + ControlsHelp.cabinet, id: \.self) { line in
                    GridRow {
                        Text(line.control).foregroundStyle(.white.opacity(0.7))
                        Text(line.keyboard)
                        Text(line.controller)
                    }
                }
            }
            Text("Controller buttons can be swapped under Controller on the game's page.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            Button("Back to the menu", action: done).keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white)
        .padding(32)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .padding(40)
    }
}
#endif
