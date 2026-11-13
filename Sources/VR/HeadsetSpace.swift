#if os(macOS)
import ARKit
import CompositorServices
import Metal
import SwiftUI
import simd

/// The game in an Apple Vision Pro, rendered by this Mac (macOS 26's
/// RemoteImmersiveSpace): Compositor Services gives a drawable per display
/// frame with each eye's pose, ARKit the head's.
///
/// Full view: every display frame asks the game's thread to draw the next
/// game frame from the head's newest pose (StereoBridge); the newest eyes it
/// drew are shown with the pose they were drawn for, so the system corrects
/// for the head having moved since. The HUD is a panel ahead of the seat.
/// Cabinet: a screen 2 m ahead showing a stereo pair (or the flat screen when
/// the game is on a 2D screen, or its core has no stereo).
struct HeadsetSpace: CompositorContent {
    @Environment(\.remoteDeviceIdentifier) private var deviceID

    var body: some CompositorContent {
        CompositorLayer(configuration: HeadsetConfiguration()) { layerRenderer in
            let session = deviceID.map { ARKitSession(device: $0) }
            HeadsetRenderer.start(layerRenderer, arSession: session)
        }
    }
}

struct HeadsetConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.isFoveationEnabled = false
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
    }
}

/// The render loop, on a thread of its own.
final class HeadsetRenderer {
    private let layer: LayerRenderer
    private let arSession: ARKitSession?
    private let world = WorldTrackingProvider()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let opaque: MTLRenderPipelineState, blended: MTLRenderPipelineState
    private let depthTest: MTLDepthStencilState, noDepth: MTLDepthStencilState
    private let sampler: MTLSamplerState

    private var eyeTextures: [MTLTexture?] = [nil, nil]
    private var screenTexture: MTLTexture?, hudTexture: MTLTexture?
    private var frameSeen = 0
    private var shown = StereoBridge.Frame()
    /// The head's pose each request was made with, by tag (recent ones).
    private var anchors: [UInt64: DeviceAnchor] = [:]
    private var nextTag: UInt64 = 1
    /// Where the game's camera sits in the room: the head's place and
    /// heading when the view opened or was last recentred.
    private var seat: simd_float4x4?
    private var recentreSeen = 0

    // Sizes in metres, in the seat's space (x right, y up, -z ahead).
    private static let screenCentre = SIMD3<Float>(0, -0.05, -2.0), screenHalf = SIMD2<Float>(0.8, 0.6)
    private static let hudCentre = SIMD3<Float>(0, -0.3, -1.4), hudHalf = SIMD2<Float>(0.45, 0.35)
    /// Game camera space (z ahead) from ARKit's (z behind), and back.
    private static let flipZ = simd_float4x4(diagonal: SIMD4<Float>(1, 1, -1, 1))

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut quad_vertex(uint vid [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
        const float2 corner[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VOut o;
        o.pos = mvp * float4(corner[vid], 0, 1);
        o.uv = float2((corner[vid].x + 1) * 0.5, (1 - corner[vid].y) * 0.5);
        return o;
    }
    fragment float4 quad_opaque(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(tex.sample(s, in.uv).rgb, 1);
    }
    fragment float4 quad_blended(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    static func start(_ layer: LayerRenderer, arSession: ARKitSession?) {
        guard let renderer = HeadsetRenderer(layer: layer, arSession: arSession) else { return }
        let thread = Thread { renderer.run() }
        thread.name = "Insert Coin headset"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private init?(layer: LayerRenderer, arSession: ARKitSession?) {
        self.layer = layer
        self.arSession = arSession
        device = layer.device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "quad_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "quad_opaque")
            desc.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
            desc.depthAttachmentPixelFormat = layer.configuration.depthFormat
            opaque = try device.makeRenderPipelineState(descriptor: desc)
            desc.fragmentFunction = lib.makeFunction(name: "quad_blended")
            let c = desc.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blended = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .greater // reverse Z: 1 near, 0 far
        d.isDepthWriteEnabled = true
        guard let test = device.makeDepthStencilState(descriptor: d) else { return nil }
        d.depthCompareFunction = .always
        d.isDepthWriteEnabled = false
        guard let none = device.makeDepthStencilState(descriptor: d) else { return nil }
        depthTest = test
        noDepth = none
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: s) else { return nil }
        sampler = linear
    }

    private func run() {
        if let arSession {
            let world = world
            Task { try? await arSession.run([world]) }
        }
        while true {
            switch layer.state {
            case .paused:
                layer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            case .invalidated:
                StereoBridge.shared.setRequest(nil)
                DispatchQueue.main.async { StereoBridge.shared.open = false }
                return
            @unknown default:
                return
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate()
        if let f = StereoBridge.shared.frame(newerThan: frameSeen) {
            frameSeen = f.count
            upload(f)
            shown = f
        }
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        if !drawables.isEmpty, let cmd = queue.makeCommandBuffer() {
            for drawable in drawables { draw(drawable, cmd) }
            cmd.commit()
        }
        frame.endSubmission()
    }

    private func draw(_ drawable: LayerRenderer.Drawable, _ cmd: MTLCommandBuffer) {
        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let anchor = world.state == .running ? world.queryDeviceAnchor(atTimestamp: time) : nil
        let head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        let (view, recentre) = StereoBridge.shared.viewForLoop
        if seat == nil || recentre != recentreSeen {
            seat = Self.seat(from: head)
            recentreSeen = recentre
        }
        let seat = seat!

        // How the next game frame is to be drawn.
        if view == .full {
            let tag = nextTag
            nextTag += 1
            anchors[tag] = anchor
            anchors = anchors.filter { $0.key + 16 > tag }
            StereoBridge.shared.setRequest(.head(eyes: drawable.views.indices.map { eye(drawable, $0, head: head, seat: seat) }, tag: tag))
        } else {
            StereoBridge.shared.setRequest(.pair)
        }

        // What to show: the newest head-tracked eyes with the pose they were
        // drawn for, or the cabinet with the head as it is now.
        if view == .full, shown.head, shown.stereo != nil, let used = anchors[shown.tag] {
            drawable.deviceAnchor = used
            let usedHead = used.originFromAnchorTransform
            for (i, v) in drawable.views.enumerated() {
                guard let enc = encoder(drawable, v, cmd) else { continue }
                if let eye = eyeTextures[min(i, 1)] { quad(enc, eye, matrix_identity_float4x4, opaque, noDepth) }
                if let hud = hudTexture {
                    quad(enc, hud, mvp(drawable, i, v, head: usedHead, seat: seat, centre: Self.hudCentre, half: Self.hudHalf), blended, depthTest)
                }
                enc.endEncoding()
            }
        } else {
            drawable.deviceAnchor = anchor
            let pair = shown.stereo != nil && !shown.head
            for (i, v) in drawable.views.enumerated() {
                guard let enc = encoder(drawable, v, cmd) else { continue }
                if let tex = pair ? eyeTextures[min(i, 1)] : screenTexture {
                    quad(enc, tex, mvp(drawable, i, v, head: head, seat: seat, centre: Self.screenCentre, half: Self.screenHalf), opaque, depthTest)
                }
                enc.endEncoding()
            }
        }
        drawable.encodePresent(commandBuffer: cmd)
    }

    /// The game's view for one eye: from the game camera's space (the seat,
    /// z ahead) to the eye's, and its field of view.
    private func eye(_ drawable: LayerRenderer.Drawable, _ i: Int, head: simd_float4x4, seat: simd_float4x4) -> StereoEye {
        let v = drawable.views[i]
        var e = StereoEye()
        e.view = Self.flipZ * (head * v.transform).inverse * seat * Self.flipZ
        let t = Self.tangents(drawable, i) // left, right, top, bottom
        e.tanLeft = -abs(t[0])
        e.tanRight = abs(t[1])
        e.tanUp = abs(t[2])
        e.tanDown = -abs(t[3])
        // The core draws up to 1024 x 512 an eye on the CPU for now (#61 moves it to the GPU).
        e.height = 512
        e.width = min(1024, max(64, Int((512 * (e.tanRight - e.tanLeft) / (e.tanUp - e.tanDown)).rounded())))
        return e
    }

    private func encoder(_ drawable: LayerRenderer.Drawable, _ v: LayerRenderer.Drawable.View, _ cmd: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let map = v.textureMap
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
        pass.colorAttachments[0].slice = map.sliceIndex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)
        pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
        pass.depthAttachment.slice = map.sliceIndex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setViewport(map.viewport)
        return enc
    }

    private func quad(_ enc: MTLRenderCommandEncoder, _ tex: MTLTexture, _ mvp: simd_float4x4,
                      _ pipeline: MTLRenderPipelineState, _ depth: MTLDepthStencilState) {
        var m = mvp
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depth)
        enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// A rectangle in the seat's space, as one eye sees it.
    private func mvp(_ drawable: LayerRenderer.Drawable, _ i: Int, _ v: LayerRenderer.Drawable.View, head: simd_float4x4,
                     seat: simd_float4x4, centre: SIMD3<Float>, half: SIMD2<Float>) -> simd_float4x4 {
        var model = simd_float4x4(diagonal: SIMD4<Float>(half.x, half.y, 1, 1))
        model.columns.3 = SIMD4<Float>(centre, 1)
        return Self.projection(Self.tangents(drawable, i)) * (head * v.transform).inverse * seat * model
    }

    /// An eye's tangents (left, right, top, bottom), read back from the
    /// compositor's projection (View.tangents is visionOS-only).
    private static func tangents(_ drawable: LayerRenderer.Drawable, _ i: Int) -> SIMD4<Float> {
        let p = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
        return SIMD4<Float>((1 - p.columns.2.x) / p.columns.0.x, (1 + p.columns.2.x) / p.columns.0.x,
                            (1 + p.columns.2.y) / p.columns.1.y, (1 - p.columns.2.y) / p.columns.1.y)
    }

    /// Reverse-Z perspective from an eye's tangents (left, right, top,
    /// bottom), looking down -z.
    private static func projection(_ t: SIMD4<Float>, near: Float = 0.05, far: Float = 100) -> simd_float4x4 {
        let l = abs(t[0]), r = abs(t[1]), top = abs(t[2]), b = abs(t[3])
        var p = simd_float4x4(0)
        p.columns.0.x = 2 / (l + r)
        p.columns.1.y = 2 / (top + b)
        p.columns.2.x = (r - l) / (r + l)
        p.columns.2.y = (top - b) / (top + b)
        p.columns.2.z = near / (far - near)
        p.columns.2.w = -1
        p.columns.3.z = near * far / (far - near)
        return p
    }

    /// The head's place, facing the head's heading, level.
    private static func seat(from head: simd_float4x4) -> simd_float4x4 {
        var ahead = -SIMD3<Float>(head.columns.2.x, 0, head.columns.2.z)
        ahead = simd_length(ahead) > 1e-3 ? simd_normalize(ahead) : SIMD3<Float>(0, 0, -1)
        let x = SIMD3<Float>(-ahead.z, 0, ahead.x), z = -ahead
        return simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(z, 0),
                                       SIMD4<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z, 1)))
    }

    // MARK: Textures

    private func upload(_ f: StereoBridge.Frame) {
        upload(&screenTexture, f.screen, f.screenWidth, f.screenHeight)
        if let s = f.stereo {
            upload(&eyeTextures[0], s.left, s.width, s.height)
            upload(&eyeTextures[1], s.right, s.width, s.height)
            if s.hud.count == 496 * 384 { upload(&hudTexture, s.hud, 496, 384) } else { hudTexture = nil }
        }
    }

    private func upload(_ texture: inout MTLTexture?, _ pixels: [UInt32], _ width: Int, _ height: Int) {
        guard width > 0, height > 0, pixels.count >= width * height else { return }
        if texture?.width != width || texture?.height != height {
            // sRGB: the drawable is sRGB too, so the colours arrive as the game made them.
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
        }
        pixels.withUnsafeBytes {
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                             withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
    }
}

extension LayerRenderer.Clock.Instant.Duration {
    fileprivate var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + nanoseconds / TimeInterval(NSEC_PER_SEC)
    }
}

/// Plays the game in an Apple Vision Pro (the window's toolbar).
struct HeadsetButton: View {
    @ObservedObject private var bridge = StereoBridge.shared
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Environment(\.supportsRemoteScenes) private var supportsRemoteScenes

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Label(bridge.open ? "Leave the headset" : "Play in Apple Vision Pro", systemImage: "visionpro")
        }
        .disabled(!supportsRemoteScenes)
        .help(supportsRemoteScenes ? (bridge.open ? "Close the game in Apple Vision Pro" : "Play in Apple Vision Pro: full view or a cabinet (pause menu)")
              : "This Mac can't show scenes in Apple Vision Pro (macOS 26 and a Vision Pro signed in to the same Apple Account)")
        .onDisappear {
            if bridge.open { Task { await dismissSpace() } }
        }
    }

    @MainActor private func toggle() async {
        if bridge.open {
            await dismissSpace()
            bridge.open = false
            bridge.setRequest(nil)
        } else if case .opened = await openSpace(id: StereoBridge.spaceID) {
            bridge.open = true
        }
    }
}
#endif
