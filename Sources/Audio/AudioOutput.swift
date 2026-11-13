import AVFoundation
import os

/// Interleaved stereo samples handed from the game thread to the audio
/// thread. Fixed capacity; a full buffer drops the oldest samples.
final class SampleRing: @unchecked Sendable {
    private var buf: [Float]
    private var head = 0, count = 0
    private let lock = OSAllocatedUnfairLock()

    init(frames: Int) { buf = [Float](repeating: 0, count: 2 * frames) }

    var bufferedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return count / 2
    }

    func write(_ p: UnsafePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let n = 2 * frames, cap = buf.count
        for i in 0..<n {
            if count == cap { head = (head + 1) % cap; count -= 1 } // full: drop the oldest
            buf[(head + count) % cap] = p[i]
            count += 1
        }
    }

    /// Fills `frames` frames of left/right, zeros where nothing is buffered.
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, gain: Float) {
        lock.lock(); defer { lock.unlock() }
        let cap = buf.count
        for f in 0..<frames {
            if count >= 2 {
                left[f] = buf[head] * gain
                right[f] = buf[(head + 1) % cap] * gain
                head = (head + 2) % cap
                count -= 2
            } else {
                left[f] = 0
                right[f] = 0
            }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        head = 0
        count = 0
    }
}

/// The core's two sound streams, each at its own rate, played through
/// AVAudioEngine: one source node per stream, mixed (and resampled to the
/// device) by the engine's mixer, at equal gain as the core asks.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private(set) var rings: [SampleRing?] = [] // by stream
    private var nodes: [AVAudioSourceNode] = []
    private let gainBits = OSAllocatedUnfairLock(initialState: Float(0.8))

    var volume: Float {
        get { gainBits.withLock { $0 } }
        set { gainBits.withLock { $0 = newValue } }
    }

    /// rates: the core's audio_rate for each stream (0 = no stream).
    func start(rates: [Double]) {
        stop()
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        for rate in rates {
            guard rate > 0 else { rings.append(nil); continue }
            let ring = SampleRing(frames: Int(rate / 4)) // a quarter second
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { rings.append(nil); continue }
            let gain = gainBits
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard abl.count >= 2, let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                ring.read(left: l, right: r, frames: Int(frameCount), gain: gain.withLock { $0 })
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            rings.append(ring)
            nodes.append(node)
        }
        if !nodes.isEmpty { try? engine.start() }
    }

    func stop() {
        engine.stop()
        for n in nodes { engine.detach(n) }
        nodes.removeAll()
        rings.removeAll()
    }

    func pause() { engine.pause() }
    func resume() { if !nodes.isEmpty { try? engine.start() } }

    deinit { stop() }
}
