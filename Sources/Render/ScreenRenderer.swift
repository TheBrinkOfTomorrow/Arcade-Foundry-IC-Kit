import MetalKit

/// Shows the core's screen: each frame's pixels go into a Metal texture,
/// drawn as one quad placed by the screen settings (ScreenLook: shape, size,
/// position) and through their effect (scanlines, CRT).
final class ScreenRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState, linear: MTLSamplerState
    private var texture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private var shownSurface: CVMetalTexture? // keeps `texture` alive while it is a core's buffer
    var look = ScreenLook()
    var squarePixels = false // a Lindbergh screen: shown at its own shape
    /// Where the picture was last drawn, as shares of the view (0...1, top-left origin).
    private(set) var picture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The vertex shader's placement and the fragment shader's effect.
    private struct Place { var scale: SIMD2<Float>; var offset: SIMD2<Float> }
    private struct Effect { var texSize: SIMD2<Float>; var outSize: SIMD2<Float>; var mode: Int32 }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Place { float2 scale; float2 offset; };
    struct Effect { float2 texSize; float2 outSize; int mode; };

    vertex VOut screen_vertex(uint vid [[vertex_id]], constant Place &p [[buffer(0)]]) {
        const float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VOut o;
        o.pos = float4(corner[vid] * p.scale + p.offset, 0, 1);
        o.uv = float2((corner[vid].x + 1) * 0.5, (1 - corner[vid].y) * 0.5);
        return o;
    }

    fragment float4 screen_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                                    constant Effect &e [[buffer(0)]]) {
        float2 uv = in.uv;
        if (e.mode == 0) return float4(tex.sample(s, uv).rgb, 1);
        float edge = 1;
        if (e.mode == 2) { // the tube's curve, its darker corners
            float2 c = uv * 2 - 1;
            c *= 1 + float2(0.04, 0.055) * (c.yx * c.yx);
            uv = c * 0.5 + 0.5;
            if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
            float2 px = min(uv, 1 - uv) * e.outSize;
            edge = smoothstep(0.0, 10.0, min(px.x, px.y)) * (1 - 0.12 * dot(c, c));
        }
        float3 col = tex.sample(s, uv).rgb;
        float2 texel = 1 / e.texSize;
        if (e.mode == 2) { // glow: bright parts bleed a little
            float3 blur = (tex.sample(s, uv + float2(texel.x * 1.5, 0)).rgb + tex.sample(s, uv - float2(texel.x * 1.5, 0)).rgb +
                           tex.sample(s, uv + float2(0, texel.y * 1.5)).rgb + tex.sample(s, uv - float2(0, texel.y * 1.5)).rgb) * 0.25;
            col += 0.18 * blur * blur;
        }
        // Scanlines: dark between the game's lines, a bright line's beam
        // wider; faded out when a line is under two display pixels tall.
        float lines = clamp(e.outSize.y / e.texSize.y - 1.0, 0.0, 1.0);
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        float beam = pow(sin(fract(uv.y * e.texSize.y) * M_PI_F), mix(1.6, 0.6, lum));
        col *= mix(1.0, mix(0.4, 1.15, beam), lines);
        if (e.mode == 2) { // the shadow mask: red, green and blue stripes, where there is room for them
            float columns = clamp(e.outSize.x / e.texSize.x - 1.5, 0.0, 1.0);
            int stripe = int(in.pos.x) % 3;
            float3 mask = stripe == 0 ? float3(1, 0.72, 0.72) : stripe == 1 ? float3(0.72, 1, 0.72) : float3(0.72, 0.72, 1);
            col *= mix(float3(1), mask * 1.2, columns);
        }
        return float4(saturate(col * edge), 1);
    }
    """

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "screen_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "screen_fragment")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .nearest; s.magFilter = .nearest
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let n = device.makeSamplerState(descriptor: s) else { return nil }
        s.minFilter = .linear; s.magFilter = .linear
        guard let l = device.makeSamplerState(descriptor: s) else { return nil }
        nearest = n
        linear = l
    }

    /// Shows a core's screen given as its GPU buffer (BGRA, GameCore.screenSurface): no copy.
    func show(_ surface: CVPixelBuffer) {
        if textureCache == nil { CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) }
        guard let cache = textureCache else { return }
        var made: CVMetalTexture?
        let w = CVPixelBufferGetWidth(surface), h = CVPixelBufferGetHeight(surface)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, surface, nil, .bgra8Unorm, w, h, 0, &made) == kCVReturnSuccess,
              let made, let tex = CVMetalTextureGetTexture(made) else { return }
        shownSurface = made
        texture = tex
    }

    /// Copies the core's screen (BGRA, width x height) into the texture.
    func upload(_ pixels: UnsafePointer<UInt32>, width: Int, height: Int) {
        if shownSurface != nil { // back from a core's buffer to a texture of our own
            shownSurface = nil
            texture = nil
        }
        if texture?.width != width || texture?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
        }
        texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                         withBytes: pixels, bytesPerRow: width * 4)
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let tex = texture {
            let size = view.drawableSize
            let r = look.rect(in: size, width: tex.width, height: tex.height, squarePixels: squarePixels)
            let w = max(size.width, 1), h = max(size.height, 1)
            picture = CGRect(x: r.minX / w, y: r.minY / h, width: r.width / w, height: r.height / h)
            var place = Place(scale: SIMD2(Float(r.width / w), Float(r.height / h)),
                              offset: SIMD2(Float(r.midX / w * 2 - 1), Float(1 - r.midY / h * 2)))
            var effect = Effect(texSize: SIMD2(Float(tex.width), Float(tex.height)),
                                outSize: SIMD2(Float(r.width), Float(r.height)),
                                mode: look.effect == .crt ? 2 : look.effect == .scanlines ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&place, length: MemoryLayout<Place>.stride, index: 0)
            enc.setFragmentBytes(&effect, length: MemoryLayout<Effect>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(look.smooth ? linear : nearest, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
