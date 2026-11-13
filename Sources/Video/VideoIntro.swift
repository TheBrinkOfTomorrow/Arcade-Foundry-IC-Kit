#if os(macOS)
import Accelerate
import AVFoundation

/// A screen recording of the app (the library, the game's page, Play) to
/// open a game's video with (issue #145): any movie AVFoundation reads, an
/// iPad's or a Mac's, turned the right way up and fitted whole into the
/// video's frame on black. Read once, front to back.
final class VideoIntro {
    let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    private let width: Int, height: Int
    private(set) var frame: [UInt32] // the newest frame read, the video's size
    private(set) var time = -1.0 // its time in the recording, or -1 before the first

    init(url: URL, width: Int, height: Int) throws {
        let asset = AVURLAsset(url: url)
        let (tracks, length, composition) = try Self.wait {
            (try await asset.loadTracks(withMediaType: .video),
             try await asset.load(.duration),
             try await AVVideoComposition.videoComposition(withPropertiesOf: asset))
        }
        guard let track = tracks.first else { throw CoreError.failed("\(url.lastPathComponent) has no picture") }
        self.width = width
        self.height = height
        duration = length.seconds
        frame = [UInt32](repeating: 0xff00_0000, count: width * height)
        reader = try AVAssetReader(asset: asset)
        // The composition applies the track's turn (an iPad recorded on its
        // side), which a plain track output leaves out.
        output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CoreError.failed("Can't read \(url.lastPathComponent)") }
    }

    /// AVFoundation's async loads, waited for: a video job runs on its own
    /// thread, front to back, so nothing else waits on this one.
    private static func wait<T>(_ load: @escaping @Sendable () async throws -> T) throws -> T {
        let box = LoadBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await load()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    /// Reads on to the frame showing at `t` seconds; false past the end.
    func advance(to t: Double) -> Bool {
        while time < t {
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            fit(image)
        }
        return true
    }

    private func fit(_ image: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let s = min(Double(width) / Double(w), Double(height) / Double(h))
        let pw = min(width, Int((Double(w) * s).rounded())), ph = min(height, Int((Double(h) * s).rounded()))
        let px = (width - pw) / 2, py = (height - ph) / 2
        frame.withUnsafeMutableBufferPointer { out in
            for i in out.indices { out[i] = 0xff00_0000 }
            var from = vImage_Buffer(data: CVPixelBufferGetBaseAddress(image), height: vImagePixelCount(h), width: vImagePixelCount(w),
                                     rowBytes: CVPixelBufferGetBytesPerRow(image))
            var to = vImage_Buffer(data: out.baseAddress! + py * width + px, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: width * 4)
            vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            for y in py..<(py + ph) {
                for x in px..<(px + pw) { out[y * width + x] |= 0xff00_0000 }
            }
        }
    }
}

/// Carries a load's result back to the waiting thread.
private final class LoadBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
#endif
