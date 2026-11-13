import Foundation
import MachO

/// The entitlements this app was signed with, read from its own executable,
/// so code can check for a capability before an API that traps without it
/// (CKContainer: SaveSync). Works the same on macOS, iOS and tvOS; macOS's
/// SecTaskCopyValueForEntitlement isn't in the iOS and tvOS SDKs.
///
/// A signed executable keeps them as an XML plist in its code signature
/// (LC_CODE_SIGNATURE: a SuperBlob, big-endian, holding the entitlements
/// blob 0xfade7171). Simulator builds are signed ad hoc and keep them in a
/// `__TEXT,__entitlements` section instead, so that is read too. An
/// executable with neither (unsigned, or ad hoc without entitlements) has
/// none.
enum Entitlements {
    static let current: [String: Any] = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [:] }
        return read(data) ?? [:]
    }()

    /// The iCloud containers the app may use for CloudKit.
    static func cloudKit(_ container: String) -> Bool {
        let services = current["com.apple.developer.icloud-services"]
        let hasCloudKit = (services as? [String])?.contains { $0.hasPrefix("CloudKit") } ?? (services as? String == "*")
        let containers = current["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        return hasCloudKit && containers.contains(container)
    }

    // MARK: - Reading the executable

    /// The entitlements in a Mach-O file, thin or universal.
    static func read(_ data: Data) -> [String: Any]? {
        guard data.count >= 8 else { return nil }
        switch data.u32be(0) {
        case FAT_MAGIC, FAT_MAGIC_64:
            // Universal: every slice is signed with the same entitlements;
            // take the first one that has them.
            let is64 = data.u32be(0) == FAT_MAGIC_64
            let count = Int(data.u32be(4))
            let entry = is64 ? 32 : 20
            for i in 0..<count {
                let at = 8 + i * entry
                guard at + entry <= data.count else { return nil }
                let offset = is64 ? Int(data.u64be(at + 8)) : Int(data.u32be(at + 8))
                let size = is64 ? Int(data.u64be(at + 16)) : Int(data.u32be(at + 12))
                guard offset >= 0, size > 0, offset + size <= data.count else { continue }
                if let e = thin(data.part(offset, size)) { return e }
            }
            return nil
        default:
            return thin(data)
        }
    }

    /// A 64-bit little-endian Mach-O (every platform the kit builds for).
    private static func thin(_ d: Data) -> [String: Any]? {
        guard d.count >= 32, d.u32le(0) == MH_MAGIC_64 else { return nil }
        let ncmds = Int(d.u32le(16))
        var at = 32 // sizeof(mach_header_64)
        var fromSection: [String: Any]?
        for _ in 0..<ncmds {
            guard at + 8 <= d.count else { break }
            let cmd = d.u32le(at), size = Int(d.u32le(at + 4))
            guard size >= 8, at + size <= d.count else { break }
            if cmd == UInt32(LC_CODE_SIGNATURE), size >= 16 {
                let off = Int(d.u32le(at + 8)), len = Int(d.u32le(at + 12))
                if off + len <= d.count, let e = superBlob(d.part(off, len)) { return e }
            } else if cmd == UInt32(LC_SEGMENT_64), size >= 72, d.cString(at + 8, 16) == "__TEXT" {
                // section_64 entries follow the segment_command_64 (72 bytes), 80 bytes each
                let nsects = Int(d.u32le(at + 64))
                for s in 0..<nsects {
                    let sect = at + 72 + s * 80
                    guard sect + 80 <= at + size, d.cString(sect, 16) == "__entitlements" else { continue }
                    let len = Int(d.u64le(sect + 40)), off = Int(d.u32le(sect + 48))
                    if len > 0, off + len <= d.count { fromSection = plist(d.part(off, len)) }
                }
            }
            at += size
        }
        return fromSection
    }

    /// The code signature's SuperBlob (CSMAGIC_EMBEDDED_SIGNATURE).
    private static func superBlob(_ b: Data) -> [String: Any]? {
        guard b.count >= 12, b.u32be(0) == 0xfade0cc0 else { return nil }
        let count = Int(b.u32be(8))
        for i in 0..<count {
            let at = 12 + i * 8
            guard at + 8 <= b.count else { return nil }
            let off = Int(b.u32be(at + 4))
            guard off + 8 <= b.count, b.u32be(off) == 0xfade7171 else { continue } // CSMAGIC_EMBEDDED_ENTITLEMENTS
            let len = Int(b.u32be(off + 4))
            guard len >= 8, off + len <= b.count else { return nil }
            return plist(b.part(off + 8, len - 8))
        }
        return nil
    }

    private static func plist(_ d: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }
}

private extension Data {
    /// Bytes [at, at + count) as a slice of the same storage (no copy: the
    /// executable is mapped, and a Release one is large).
    func part(_ at: Int, _ count: Int) -> Data { self[startIndex + at..<startIndex + at + count] }
    func u32be(_ at: Int) -> UInt32 { self[startIndex + at..<startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func u64be(_ at: Int) -> UInt64 { self[startIndex + at..<startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    func u32le(_ at: Int) -> UInt32 { self[startIndex + at..<startIndex + at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    func u64le(_ at: Int) -> UInt64 { self[startIndex + at..<startIndex + at + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    func cString(_ at: Int, _ max: Int) -> String {
        let bytes = self[startIndex + at..<startIndex + at + max].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
