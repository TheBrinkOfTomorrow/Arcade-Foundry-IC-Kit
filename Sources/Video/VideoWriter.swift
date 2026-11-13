#if os(macOS)
import Accelerate
import AVFoundation
import CoreVideo

/// Writes a game's screens and sound to an MP4 for YouTube (issue #145):
/// 16:9 at 1080p or 2160p, 60 frames a second, H.264 or HEVC, AAC 48 kHz
/// stereo. Each screen is shown in its cabinet shape (ScreenLook's
/// .original), sharp: blown up by whole pixels past the size it shows at,
/// then scaled down to it, so pixels stay square-edged without uneven rows.
/// Used from one thread; offline, so it waits for the encoder rather than
/// dropping anything.
final class VideoWriter {
    static let fps: Int32 = 60
    static let sampleRate = 48_000.0

    let width: Int, height: Int
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let sound: Bool
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let squarePixels: Bool
    private var framesOut: Int64 = 0
    private var samplesOut: Int64 = 0
    private var big = [UInt32]() // the screen blown up by whole pixels
    private let audioFormat: CMAudioFormatDescription
    /// Laid over every frame (the game's name, the logo), if any.
    var caption: VideoCaption?

    /// `lines`: 1080 or 2160. `squarePixels`: the screen shows at its own
    /// shape (Lindbergh), not 4:3.
    /// `sound`: false writes no sound track (for music added in editing).
    init(url: URL, lines: Int, hevc: Bool, squarePixels: Bool, sound: Bool = true) throws {
        self.sound = sound
        height = lines
        width = lines * 16 / 9
        self.squarePixels = squarePixels
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // YouTube's recommended bitrates for 60 fps SDR uploads, with room.
        let bitrate = lines > 1080 ? 60_000_000 : 16_000_000
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.fps / 2), // YouTube: a closed GOP of half the frame rate
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 320_000, // the AAC encoder's most for 48 kHz stereo (YouTube asks for 384)
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        // Offline, the writer holds the picture back until the encoded
        // sound passes it, and the AAC encoder's lookahead keeps it short:
        // it stops after a second. Real time it doesn't wait for the sound.
        audio.expectsMediaDataInRealTime = true

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        audioFormat = fmt!

        writer.add(video)
        if sound { writer.add(audio) }
        guard writer.startWriting() else { throw writer.error ?? CoreError.failed("Could not start the video") }
        writer.startSession(atSourceTime: .zero)
    }

    /// The video so far, in seconds.
    var seconds: Double { Double(framesOut) / Double(Self.fps) }

    /// The next video frame: `pixels` (0xAARRGGBB, `w` x `h`) in its shape, letterboxed.
    func addFrame(_ pixels: UnsafePointer<UInt32>, _ w: Int, _ h: Int) throws {
        wait(video)
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CoreError.failed("The video stopped") }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { throw CoreError.failed("No video frame buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        draw(pixels, w, h, into: buffer)
        caption?.draw(over: CVPixelBufferGetBaseAddress(buffer)!, rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        if fade < 1 { dim(CVPixelBufferGetBaseAddress(buffer)!, rowBytes: CVPixelBufferGetBytesPerRow(buffer), level: fade) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: framesOut, timescale: Self.fps)) else {
            throw writer.error ?? CoreError.failed("The video stopped")
        }
        framesOut += 1
    }

    /// A frame already the video's size (an end card), dimmed to `level`
    /// (1 as it is, 0 black), without the caption.
    func addStill(_ pixels: [UInt32], level: Float = 1) throws {
        wait(video)
        guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CoreError.failed("The video stopped") }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let buffer = out else { throw CoreError.failed("No video frame buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!, rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeBufferPointer { src in
            for y in 0..<height { (base + y * rowBytes).copyMemory(from: src.baseAddress! + y * width, byteCount: width * 4) }
        }
        if level < 1 { dim(base, rowBytes: rowBytes, level: level) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: framesOut, timescale: Self.fps)) else {
            throw writer.error ?? CoreError.failed("The video stopped")
        }
        framesOut += 1
    }

    /// Fades frames to black: `fade` 1 as they are, 0 black (the end of the game, before the end card).
    var fade: Float = 1

    private func dim(_ base: UnsafeMutableRawPointer, rowBytes: Int, level: Float) {
        let k = UInt32(max(0, min(1, level)) * 256)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let p = row[x]
                let rb = (((p & 0x00ff_00ff) * k) >> 8) & 0x00ff_00ff, g = (((p & 0x0000_ff00) * k) >> 8) & 0x0000_ff00
                row[x] = 0xff00_0000 | rb | g
            }
        }
    }

    /// The sound so far, in seconds.
    var audioSeconds: Double { Double(samplesOut) / Self.sampleRate }

    /// Interleaved stereo float samples at 48 kHz, after the ones before.
    func addAudio(_ samples: [Float]) throws {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        guard sound else { samplesOut += Int64(frames); return }
        wait(audio)
        let bytes = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block else { throw CoreError.failed("No sound buffer") }
        CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: CMTime(value: samplesOut, timescale: CMTimeScale(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample, audio.append(sample) else { throw writer.error ?? CoreError.failed("The sound stopped") }
        samplesOut += Int64(frames)
    }

    func finish() throws {
        video.markAsFinished()
        if sound { audio.markAsFinished() }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CoreError.failed("The video did not finish") }
    }

    func cancel() { writer.cancelWriting() }

    private func wait(_ input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(1000) }
    }

    /// The screen into `buffer`: black, then the picture centred in its shape.
    private func draw(_ pixels: UnsafePointer<UInt32>, _ w: Int, _ h: Int, into buffer: CVPixelBuffer) {
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { memset_pattern4(base + y * rowBytes, [UInt32(0xff00_0000)], width * 4) }
        let pic = ScreenLook().rect(in: CGSize(width: width, height: height), width: w, height: h, squarePixels: squarePixels)
        let pw = min(width, Int(pic.width.rounded())), ph = min(height, Int(pic.height.rounded()))
        let px = (width - pw) / 2, py = (height - ph) / 2

        // Whole-pixel blow-up to at least the picture's size.
        let kx = max(1, (pw + w - 1) / w), ky = max(1, (ph + h - 1) / h)
        let bw = w * kx, bh = h * ky
        if big.count != bw * bh { big = [UInt32](repeating: 0, count: bw * bh) }
        big.withUnsafeMutableBufferPointer { out in
            let o = out.baseAddress!
            for y in 0..<h {
                let row = o + y * ky * bw
                let src = pixels + y * w
                if kx == 1 {
                    row.update(from: src, count: w)
                } else {
                    for x in 0..<w { (row + x * kx).initialize(repeating: src[x], count: kx) }
                }
                for r in 1..<max(ky, 1) { (row + r * bw).update(from: row, count: bw) }
            }
            var from = vImage_Buffer(data: o, height: vImagePixelCount(bh), width: vImagePixelCount(bw), rowBytes: bw * 4)
            var to = vImage_Buffer(data: base + py * rowBytes + px * 4, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: rowBytes)
            if bw == pw && bh == ph {
                vImageCopyBuffer(&from, &to, 4, vImage_Flags(kvImageNoFlags))
            } else {
                vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        // The cores' alpha is not always opaque: the video has none.
        for y in py..<(py + ph) {
            let row = (base + y * rowBytes + px * 4).assumingMemoryBound(to: UInt32.self)
            for x in 0..<pw { row[x] |= 0xff00_0000 }
        }
    }
}
#endif
