import Foundation
import simd

/// One eye for GameCore.renderEyes: from the game camera's space to the
/// eye's, in metres (x right, y up, z forward, as afcore_eye), and the eye's
/// field of view as tangents (left and down negative).
struct StereoEye {
    var view = matrix_identity_float4x4
    var tanLeft: Float = -1, tanRight: Float = 1, tanDown: Float = -1, tanUp: Float = 1
    var width = 512, height = 512
}

/// The eyes the core drew for one frame: each width x height BGRA, plus the
/// HUD alone (496 x 384, alpha 0 see-through) when head-tracked.
struct StereoImages {
    var left = [UInt32](), right = [UInt32]()
    var width = 0, height = 0
    var hud = [UInt32]()
}

/// The core's stereo (afcore.h 4.15, render_eyes) for Swift.
extension GameCore {
    /// Whether this core can draw its scene for two eyes. Cores built for
    /// an older interface stop short of the stereo fields.
    var hasStereo: Bool {
        let api = library.api.pointee
        guard let end = MemoryLayout<afcore_api>.offset(of: \afcore_api.stereo_scale) else { return false }
        return Int(api.size) >= end + MemoryLayout<Float>.size && api.render_eyes != nil
    }

    /// Metres per game unit, the core's guess (1 when it has none).
    var stereoScale: Float {
        guard hasStereo else { return 1 }
        let s = library.api.pointee.stereo_scale
        return s > 0 ? s : 1
    }

    /// Two eyes beside the game's camera (the original screen as a window):
    /// each the screen's size, HUD included. Nil on a 2D screen.
    func renderPair(ipd: Float = 0.063, convergence: Float = 10, scale: Float = 0) -> StereoImages? {
        var s = afcore_stereo()
        s.size = UInt32(MemoryLayout<afcore_stereo>.size)
        s.mode = Int32(AFCORE_STEREO_PAIR)
        s.world_scale = scale
        s.ipd = ipd
        s.convergence = convergence
        return render(&s, withHUD: false)
    }

    /// Two head-tracked eyes; the HUD comes apart. Nil on a 2D screen.
    func renderHead(_ eyes: [StereoEye], scale: Float = 0) -> StereoImages? {
        guard eyes.count == 2 else { return nil }
        var s = afcore_stereo()
        s.size = UInt32(MemoryLayout<afcore_stereo>.size)
        s.mode = Int32(AFCORE_STEREO_HEAD)
        s.world_scale = scale
        withUnsafeMutableBytes(of: &s.eye) { raw in
            let out = raw.bindMemory(to: afcore_eye.self)
            for i in 0..<2 {
                var e = afcore_eye()
                let m = eyes[i].view
                withUnsafeMutableBytes(of: &e.view) { v in
                    let f = v.bindMemory(to: Float.self)
                    for c in 0..<4 {
                        for r in 0..<4 { f[c * 4 + r] = m[c][r] } // column-major, as simd keeps it
                    }
                }
                e.tan_left = eyes[i].tanLeft
                e.tan_right = eyes[i].tanRight
                e.tan_down = eyes[i].tanDown
                e.tan_up = eyes[i].tanUp
                e.width = Int32(eyes[i].width)
                e.height = Int32(eyes[i].height)
                out[i] = e
            }
        }
        return render(&s, withHUD: true)
    }

    private func render(_ s: inout afcore_stereo, withHUD: Bool) -> StereoImages? {
        let api = library.api.pointee
        guard hasStereo, let render = api.render_eyes, let eye = api.eye_screen else { return nil }
        guard render(core, &s) != 0 else { return nil }
        var images = StereoImages()
        for i in 0..<2 {
            var w: Int32 = 0, h: Int32 = 0
            guard let p = eye(core, Int32(i), &w, &h) else { return nil }
            let pixels = [UInt32](UnsafeBufferPointer(start: p, count: Int(w) * Int(h)))
            if i == 0 { images.left = pixels } else { images.right = pixels }
            (images.width, images.height) = (Int(w), Int(h))
        }
        if withHUD, let hud = api.hud_screen {
            var w: Int32 = 0, h: Int32 = 0
            if let p = hud(core, &w, &h) { images.hud = [UInt32](UnsafeBufferPointer(start: p, count: Int(w) * Int(h))) }
        }
        return images
    }
}
