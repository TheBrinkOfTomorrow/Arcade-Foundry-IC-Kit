import Foundation

/// A Lindbergh or Chihiro game folder as one file: <set>.tar, a plain tar of the
/// folder that holds disk0 (or the Chihiro game's XBE), so it can sit in iCloud Drive or on the ROM
/// server like a ROM set and come down to an iPad or Apple TV. Made with
/// Add ROM (iCloud Drive on), `scripts/pack_lindbergh.py`, or
/// `tar -cf hotd4a.tar -C <folder with the games> hotd4a`. Unpacked into
/// ROMs/<set>/, where the core reads it; the set's name as the tar's top
/// folder is optional.
enum GamePackage {
    static let ext = "tar"

    // MARK: Unpacking

    /// Unpacks a tar as it arrives (a download) or from a file, into
    /// ROMs/<set>/. Anything outside the game folder ("..", absolute paths)
    /// is refused.
    final class Unpacker {
        private let set: String
        private let staging: URL
        private var header = Data()
        private var file: FileHandle?
        private var remaining: UInt64 = 0  // bytes of the current entry still to come
        private var padding: UInt64 = 0    // zero bytes after it, to the next 512
        private var longName: String?      // from a GNU 'L' entry or a pax header, for the next entry
        private var longLink: String?
        private var paxSize: UInt64?
        private var collecting: Data?      // an 'L', 'K' or 'x' entry's data
        private var collectingType: UInt8 = 0
        private var ended = false
        private(set) var bytes: UInt64 = 0

        init(set: String) throws {
            self.set = set
            staging = Storage.roms.appendingPathComponent("\(set).unpacking", isDirectory: true)
            let fm = FileManager.default
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }

        deinit { try? file?.close() }

        func feed(_ data: Data) throws {
            bytes += UInt64(data.count)
            var at = data.startIndex
            while at < data.endIndex && !ended {
                if remaining > 0 {
                    let n = Int(min(UInt64(data.endIndex - at), remaining))
                    let chunk = data[at..<(at + n)]
                    if collecting != nil { collecting!.append(chunk) } else { try file?.write(contentsOf: chunk) }
                    remaining -= UInt64(n)
                    at += n
                    if remaining == 0 { try endEntry() }
                } else if padding > 0 {
                    let n = Int(min(UInt64(data.endIndex - at), padding))
                    padding -= UInt64(n)
                    at += n
                } else {
                    let n = min(data.endIndex - at, 512 - header.count)
                    header.append(data[at..<(at + n)])
                    at += n
                    if header.count == 512 {
                        try startEntry(header)
                        header.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        /// Checks the game arrived whole and puts it in place of an older one.
        func finish() throws {
            try? file?.close()
            file = nil
            let fm = FileManager.default
            let mark = Storage.folderMark(set) // disk0, or a Chihiro game's XBE
            guard remaining == 0, fm.fileExists(atPath: staging.appendingPathComponent(mark).path) else {
                try? fm.removeItem(at: staging)
                throw CoreError.failed(remaining > 0 ? "\(set).\(GamePackage.ext) ended early (the download was cut off?)"
                                                     : "\(set).\(GamePackage.ext) has no \(mark): pack the game folder that holds \(mark)")
            }
            let dst = Storage.roms.appendingPathComponent(set, isDirectory: true)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: staging, to: dst)
        }

        func cancel() {
            try? file?.close()
            file = nil
            try? FileManager.default.removeItem(at: staging)
        }

        private func startEntry(_ h: Data) throws {
            if h.allSatisfy({ $0 == 0 }) { ended = true; return } // the end blocks
            let b = [UInt8](h)
            let sum = b.enumerated().reduce(0) { $0 + Int($1.offset >= 148 && $1.offset < 156 ? 32 : $1.element) }
            guard sum == Int(Self.octal(b[148..<156])) else { throw CoreError.failed("\(set).\(GamePackage.ext) is not a tar file") }
            let type = b[156]
            var size = Self.number(b[124..<136])
            if let s = paxSize, type != UInt8(ascii: "x"), type != UInt8(ascii: "g") { size = s }
            remaining = size
            padding = (512 - size % 512) % 512
            switch type {
            case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"):
                collecting = Data()
                collectingType = type
            case UInt8(ascii: "g"):
                collecting = Data() // a global pax header: read and ignored
                collectingType = type
            default:
                let name = longName ?? Self.path(b)
                let link = longLink ?? Self.string(b[157..<257])
                longName = nil
                longLink = nil
                paxSize = nil
                let mode = Int(Self.octal(b[100..<108]))
                try create(name: name, type: type, link: link, mode: mode)
            }
            if remaining == 0 { try endEntry() }
        }

        private func endEntry() throws {
            if let data = collecting {
                collecting = nil
                let text = String(decoding: data, as: UTF8.self)
                switch collectingType {
                case UInt8(ascii: "L"): longName = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                case UInt8(ascii: "K"): longLink = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                case UInt8(ascii: "x"):
                    // "<length> <key>=<value>\n" records
                    for record in text.split(separator: "\n") {
                        guard let space = record.firstIndex(of: " "), let eq = record.firstIndex(of: "=") else { continue }
                        let key = record[record.index(after: space)..<eq], value = String(record[record.index(after: eq)...])
                        if key == "path" { longName = value }
                        if key == "linkpath" { longLink = value }
                        if key == "size" { paxSize = UInt64(value) }
                    }
                default: break
                }
            } else {
                try? file?.close()
                file = nil
            }
        }

        private func create(name: String, type: UInt8, link: String, mode: Int) throws {
            // The game folder's own path: "./" and the set's name in front are dropped.
            var parts = name.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
            if let first = parts.first, Storage.names(set).contains(first.lowercased()) { parts.removeFirst() }
            guard !name.hasPrefix("/"), !parts.contains("..") else {
                throw CoreError.failed("\(set).\(GamePackage.ext) has a file outside the game folder: \(name)")
            }
            let fm = FileManager.default
            if parts.isEmpty || parts.contains(where: GamePackage.isMetadata) { // the top folder itself, or Finder's
                file = nil
                return
            }
            let url = parts.reduce(staging) { $0.appendingPathComponent($1) }
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // A symbolic link earlier in the tar must not lead a file out of the game folder.
            guard parent.resolvingSymlinksInPath().path.hasPrefix(staging.resolvingSymlinksInPath().path) else {
                throw CoreError.failed("\(set).\(GamePackage.ext) has a file outside the game folder: \(name)")
            }
            switch type {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                file = nil
            case UInt8(ascii: "2"):
                try? fm.removeItem(at: url)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: link)
                file = nil
            case UInt8(ascii: "1"): // a hard link: a copy of the file it names
                var target = link.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
                if let first = target.first, Storage.names(set).contains(first.lowercased()) { target.removeFirst() }
                guard !target.contains("..") else { throw CoreError.failed("\(set).\(GamePackage.ext): bad link \(link)") }
                try? fm.removeItem(at: url)
                try fm.copyItem(at: target.reduce(staging) { $0.appendingPathComponent($1) }, to: url)
                file = nil
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                try? fm.removeItem(at: url)
                // Always writable by us: a read-only file (0444) is still written here.
                guard fm.createFile(atPath: url.path, contents: nil,
                                    attributes: [.posixPermissions: (mode & 0o777 == 0 ? 0o644 : mode & 0o777) | 0o200]) else {
                    throw CoreError.failed("Could not write \(url.path)")
                }
                file = try FileHandle(forWritingTo: url)
            default: // devices, FIFOs: not part of a game
                file = nil
            }
        }

        private static func string(_ b: ArraySlice<UInt8>) -> String {
            String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
        }

        private static func path(_ b: [UInt8]) -> String {
            let name = string(b[0..<100])
            let ustar = string(b[257..<263]).hasPrefix("ustar")
            let prefix = ustar ? string(b[345..<500]) : ""
            return prefix.isEmpty ? name : prefix + "/" + name
        }

        private static func octal(_ b: ArraySlice<UInt8>) -> UInt64 {
            var v: UInt64 = 0
            for c in b {
                if c == 0 || c == 32 { if v > 0 { break } else { continue } }
                guard c >= 48 && c <= 55 else { break }
                v = v * 8 + UInt64(c - 48)
            }
            return v
        }

        /// A size: octal, or GNU's base-256 for files over 8 GB.
        private static func number(_ b: ArraySlice<UInt8>) -> UInt64 {
            guard let first = b.first, first & 0x80 != 0 else { return octal(b) }
            return b.dropFirst().reduce(UInt64(first & 0x7f)) { $0 << 8 | UInt64($1) }
        }
    }

    /// macOS's own files, not the game's: AppleDouble "._" files (which
    /// macOS tar and non-Mac volumes add beside each file), __MACOSX and
    /// .DS_Store.
    static func isMetadata(_ name: String) -> Bool {
        name.hasPrefix("._") || name == "__MACOSX" || name == ".DS_Store"
    }

    /// Unpacks a <set>.tar file on this device into ROMs/<set>/.
    static func unpack(file: URL, set: String) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let unpacker = try Unpacker(set: set)
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try unpacker.feed(chunk)
            }
            try unpacker.finish()
        } catch {
            unpacker.cancel()
            throw error
        }
    }

    // MARK: Packing

    /// Writes the game folder `folder` (the one holding disk0, or a Chihiro game's XBE) as a tar at
    /// `out`, with `set` as its top folder.
    static func pack(_ folder: URL, set: String, to out: URL) throws {
        let fm = FileManager.default
        // the game folder is often a link to where the game was unpacked
        let folder = folder.resolvingSymlinksInPath()
        let root = folder.standardizedFileURL.path
        let mark = Storage.folderMark(set)
        guard fm.fileExists(atPath: folder.appendingPathComponent(mark).path) else {
            throw CoreError.failed("\(folder.lastPathComponent) has no \(mark): pick the game folder that holds \(mark)")
        }
        fm.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.write(contentsOf: entry(name: set + "/", type: "5", size: 0, mode: 0o755))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        let base = folder.standardizedFileURL.pathComponents.count
        for case let url as URL in walk {
            if isMetadata(url.lastPathComponent) {
                if url.lastPathComponent == "__MACOSX" { walk.skipDescendants() }
                continue
            }
            let rel = url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let name = set + "/" + rel
            let values = try url.resourceValues(forKeys: Set(keys))
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
            var file = url
            if values.isSymbolicLink == true {
                // a relative link that stays in the game folder stays a link; any
                // other link to a file is packed as the file itself
                let link = try fm.destinationOfSymbolicLink(atPath: url.path)
                let target = url.resolvingSymlinksInPath()
                if !link.hasPrefix("/") && target.standardizedFileURL.path.hasPrefix(root + "/") {
                    try handle.write(contentsOf: entry(name: name, type: "2", size: 0, mode: mode, link: link))
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else {
                    throw CoreError.failed("\(rel) is a link to a folder outside the game folder: copy that folder in instead")
                }
                file = target
            }
            if values.isDirectory == true && file == url {
                try handle.write(contentsOf: entry(name: name + "/", type: "5", size: 0, mode: mode))
            } else {
                var size = UInt64(values.fileSize ?? 0)
                if file != url {
                    size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
                }
                try handle.write(contentsOf: entry(name: name, type: "0", size: size, mode: mode))
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                var written: UInt64 = 0
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                    written += UInt64(chunk.count)
                }
                guard written == size else { throw CoreError.failed("\(rel) changed while it was packed") }
                if size % 512 != 0 { try handle.write(contentsOf: Data(count: Int(512 - size % 512))) }
            }
        }
        try handle.write(contentsOf: Data(count: 1024))
    }

    /// One entry's header: a pax header first when the name, link or size
    /// does not fit ustar's fields.
    private static func entry(name: String, type: Character, size: UInt64, mode: Int, link: String = "") -> Data {
        var records = ""
        func record(_ key: String, _ value: String) {
            let body = " \(key)=\(value)\n"
            var len = body.utf8.count + 1
            while String(len).count + body.utf8.count != len { len += 1 }
            records += "\(len)\(body)"
        }
        if name.utf8.count > 100 { record("path", name) }
        if link.utf8.count > 100 { record("linkpath", link) }
        if size > 0o77777777777 { record("size", String(size)) }
        var out = Data()
        if !records.isEmpty {
            let data = Data(records.utf8)
            out += header(name: "PaxHeaders/" + String(name.suffix(80)), type: "x", size: UInt64(data.count), mode: 0o644, link: "")
            out += data
            if data.count % 512 != 0 { out += Data(count: 512 - data.count % 512) }
        }
        out += header(name: name, type: type, size: size > 0o77777777777 ? 0 : size, mode: mode, link: link)
        return out
    }

    private static func header(name: String, type: Character, size: UInt64, mode: Int, link: String) -> Data {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ at: Int, _ len: Int) {
            for (i, c) in s.utf8.prefix(len).enumerated() { b[at + i] = c }
        }
        func octal(_ v: UInt64, _ at: Int, _ len: Int) {
            put(String(String(v, radix: 8).suffix(len - 1)).leftPadded(to: len - 1), at, len - 1)
        }
        put(String(name.utf8.suffix(100).map { Character(UnicodeScalar($0)) }), 0, 100)
        octal(UInt64(mode & 0o7777), 100, 8)
        octal(0, 108, 8)
        octal(0, 116, 8)
        octal(size, 124, 12)
        octal(UInt64(Date().timeIntervalSince1970), 136, 12)
        put(String(type), 156, 1)
        put(link, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)
        for i in 148..<156 { b[i] = 32 }
        let sum = b.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPadded(to: 6), 148, 6)
        b[154] = 0
        b[155] = 32
        return Data(b)
    }
}

private extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

/// How far each download has got, for the library's "Downloading… 42%".
@MainActor final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published private(set) var fraction: [String: Double] = [:]
    /// What the core's ROM check found for each set downloaded this session.
    @Published private(set) var checks: [String: RomCheck] = [:]
    @Published private(set) var checking: Set<String> = []

    func set(_ set: String, _ f: Double?) {
        fraction[set] = f
    }

    func startCheck(_ set: String) {
        checks[set] = nil
        checking.insert(set)
    }

    func finishCheck(_ set: String, _ result: RomCheck?) {
        checking.remove(set)
        checks[set] = result
    }

    /// "Downloading…", with how much when the size is known, then "Checking…".
    func label(_ set: String) -> String {
        if checking.contains(set) { return "Checking…" }
        guard let f = fraction[set] else { return "Downloading…" }
        return String(format: "Downloading… %.0f%%", f * 100)
    }

    /// The problem the ROM check found in a downloaded set, if any.
    func problem(_ set: String) -> String? {
        if case .bad(let why) = checks[set] { return why }
        return nil
    }

    /// What to tell the user once `set` has downloaded.
    func downloaded(_ set: String) -> String {
        switch checks[set] {
        case .good?: return "Downloaded \(set): every file checks out."
        case .bad(let why)?: return "Downloaded \(set), but it does not match the set the core needs (\(why)). It may be a bad dump or another version: get another copy."
        case .unchecked(let why)?: return "Downloaded \(set) (not checked: \(why))."
        case nil: return "Downloaded \(set)."
        }
    }
}

/// Downloads <set>.tar from the ROM server, unpacking it as it arrives (so
/// an Apple TV never holds the game twice).
final class PackageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable { // its delegate queue is serial
    private let set: String
    private let unpacker: GamePackage.Unpacker
    private var expected: Int64 = -1
    private var shown = -1.0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    private init(set: String) throws {
        self.set = set
        unpacker = try GamePackage.Unpacker(set: set)
    }

    static func run(_ url: URL, set: String) async throws {
        let d = try PackageDownload(set: set)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = RomServer.session.configuration.timeoutIntervalForRequest
        let session = URLSession(configuration: config, delegate: d, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.addOperation {
                d.continuation = c
                session.dataTask(with: url).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            failure = CoreError.failed("\(response.url?.absoluteString ?? set): not on the server")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try unpacker.feed(data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        if expected > 0 {
            let f = Double(unpacker.bytes) / Double(expected)
            if f - shown >= 0.01 {
                shown = f
                let set = self.set
                Task { @MainActor in Downloads.shared.set(set, f) }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result = failure ?? error
        if result == nil {
            do { try unpacker.finish() } catch { result = error }
        } else {
            unpacker.cancel()
        }
        let set = self.set
        Task { @MainActor in Downloads.shared.set(set, nil) }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
}
