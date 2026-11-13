#if os(macOS)
import AVFoundation

/// The core's sound streams (each interleaved stereo at its own rate)
/// resampled to 48 kHz and mixed at equal gain, as AudioOutput plays them,
/// for VideoWriter.
final class SoundMixer {
    private final class Stream {
        let converter: AVAudioConverter
        let input: AVAudioFormat
        var pending: [Float] = []  // samples at the stream's rate, not yet converted
        var out: [Float] = []      // converted, not yet mixed
        var heard = false          // has sent anything (Sega Rally's stream 1 never does)
        init?(rate: Double, to output: AVAudioFormat) {
            guard rate > 0,
                  let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true),
                  let c = AVAudioConverter(from: input, to: output) else { return nil }
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = c
            self.input = input
        }
    }

    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VideoWriter.sampleRate, channels: 2, interleaved: true)!
    private var streams: [Stream?]
    private var mixed: [Float] = []

    init(rates: [Double]) {
        let out = output
        streams = rates.map { Stream(rate: $0, to: out) }
    }

    /// No stream has sent anything yet (the board's boot, a silent game).
    var silent: Bool { !streams.contains { $0?.heard == true } }

    /// Stream `index`'s next interleaved stereo frames.
    func add(_ index: Int, _ samples: UnsafePointer<Float>, frames: Int) {
        guard index < streams.count, let s = streams[index] else { return }
        s.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: frames * 2))
        if frames > 0 { s.heard = true }
    }

    /// Converts what came in, and returns the mix every stream has reached
    /// (interleaved stereo at 48 kHz); `flush` at the end takes the rest.
    func take(flush: Bool = false) -> [Float] {
        let active = streams.compactMap { $0 }.filter(\.heard)
        for s in active { convert(s, flush: flush) }
        guard !active.isEmpty else { return [] }
        let n = flush ? active.map(\.out.count).max()! : active.map(\.out.count).min()!
        var mix = [Float](repeating: 0, count: n)
        for s in active {
            let m = min(n, s.out.count)
            for i in 0..<m { mix[i] += s.out[i] }
            s.out.removeFirst(m)
        }
        return mix
    }

    private func convert(_ s: Stream, flush: Bool) {
        let frames = s.pending.count / 2
        guard frames > 0 || flush else { return }
        let ratio = VideoWriter.sampleRate / s.input.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: s.input, frameCapacity: AVAudioFrameCount(max(frames, 1))),
              let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        s.pending.withUnsafeBufferPointer { src in
            if frames > 0 { inBuf.floatChannelData![0].update(from: src.baseAddress!, count: frames * 2) }
        }
        s.pending.removeAll(keepingCapacity: true)
        var given = false
        var error: NSError?
        s.converter.convert(to: outBuf, error: &error) { _, status in
            if given || frames == 0 {
                status.pointee = flush ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        let n = Int(outBuf.frameLength) * 2
        if n > 0 { s.out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)) }
    }
}
#endif
