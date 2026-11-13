import GameController

/// A controller as the library and the menus read it: the connected
/// gamepad and, on the Mac, a steering wheel's d-pad and buttons as a
/// gamepad's (Wheel.menuPad), so a wheel alone can choose and start a game.
/// Nil when there is neither.
struct MenuPad {
    var moveX: Float = 0, moveY: Float = 0 // the d-pad and left stick together; up is positive
    var a = false, b = false, buttonX = false, buttonY = false
    var l1 = false, r1 = false, l2 = false, r2 = false
    var menu = false, options = false

    static func read() -> MenuPad? {
        var pad: MenuPad?
        if let gp = GCController.current?.extendedGamepad ?? GCController.controllers().compactMap(\.extendedGamepad).first {
            pad = MenuPad(moveX: gp.dpad.xAxis.value + gp.leftThumbstick.xAxis.value,
                          moveY: gp.dpad.yAxis.value + gp.leftThumbstick.yAxis.value,
                          a: gp.buttonA.isPressed, b: gp.buttonB.isPressed,
                          buttonX: gp.buttonX.isPressed, buttonY: gp.buttonY.isPressed,
                          l1: gp.leftShoulder.isPressed, r1: gp.rightShoulder.isPressed,
                          l2: gp.leftTrigger.isPressed, r2: gp.rightTrigger.isPressed,
                          menu: gp.buttonMenu.isPressed, options: gp.buttonOptions?.isPressed == true)
        }
        #if os(macOS)
        if let wheel = Wheel.shared.menuPad() {
            pad = pad.map { $0.with(wheel) } ?? wheel
        }
        #endif
        return pad
    }

    /// Both held together: either's buttons, their moves added.
    func with(_ o: MenuPad) -> MenuPad {
        MenuPad(moveX: moveX + o.moveX, moveY: moveY + o.moveY, a: a || o.a, b: b || o.b,
                buttonX: buttonX || o.buttonX, buttonY: buttonY || o.buttonY,
                l1: l1 || o.l1, r1: r1 || o.r1, l2: l2 || o.l2, r2: r2 || o.r2,
                menu: menu || o.menu, options: options || o.options)
    }
}
