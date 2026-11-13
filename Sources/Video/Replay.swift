import Foundation

/// A game played back from its controls (issue #145): the game's set and
/// core version, the saves it booted with, and every frame's afcore_input
/// from the first. Playing the same inputs through the same core version
/// from the same saves gives the same game, so a replay recorded on any
/// device can be rendered to a video on the Mac (VideoJob).
///
/// File (.afreplay): "AFRP", a little-endian UInt32 header length, the
/// header as JSON, then the inputs, zlib-compressed: one afcore_input
/// (header.inputSize bytes) per frame, in order.
struct Replay {
    static let ext = "afreplay"
    private static let magic = Data("AFRP".utf8)

    struct Header: Codable {
        var format = 1
        var romset: String
        var title: String
        var coreVersion: UInt32 // afcore_api.core_version
        var frameHz: Double
        var inputSize: Int      // sizeof(afcore_input) when recorded
        var recorded: Date
        var device: String
        var appVersion: String
        var saves: [String: Data] // the save folder's files when the game booted, by name
    }

    var header: Header
    /// Every frame's input, header.inputSize bytes each.
    var inputs: Data

    var frames: Int { header.inputSize > 0 ? inputs.count / header.inputSize : 0 }
    var seconds: Double { Double(frames) / header.frameHz }

    /// Frame `i`'s input as this app's afcore_input: a shorter one from an
    /// older app reads as zeros past its end.
    func input(_ i: Int) -> afcore_input {
        var input = afcore_input()
        let n = min(header.inputSize, MemoryLayout<afcore_input>.size)
        withUnsafeMutableBytes(of: &input) { dst in
            inputs.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[(i * header.inputSize)..<(i * header.inputSize + n)]))
            }
        }
        input.size = UInt32(MemoryLayout<afcore_input>.size)
        return input
    }

    func write(to url: URL) throws {
        var data = Self.magic
        let json = try JSONEncoder().encode(header)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(try (inputs as NSData).compressed(using: .zlib) as Data)
        try data.write(to: url, options: .atomic)
    }

    init(header: Header, inputs: Data) {
        self.header = header
        self.inputs = inputs
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 8, data.prefix(4) == Self.magic else { throw CoreError.failed("\(url.lastPathComponent) is not a replay") }
        let length = data.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard data.count >= 8 + length else { throw CoreError.failed("\(url.lastPathComponent) is cut short") }
        header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<(8 + length)))
        guard header.format == 1 else { throw CoreError.failed("\(url.lastPathComponent) is a newer replay format: update the app") }
        inputs = try (data.subdata(in: (8 + length)..<data.count) as NSData).decompressed(using: .zlib) as Data
    }

    /// The files in `dir` (a game's saves), by name.
    static func files(in dir: URL) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var files: [String: Data] = [:]
        for name in names where !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let data = try? Data(contentsOf: url) else { continue }
            files[name] = data
        }
        return files
    }

    /// Writes `files` into `dir`, made empty first.
    static func restore(_ files: [String: Data], to dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent((name as NSString).lastPathComponent))
        }
    }
}
