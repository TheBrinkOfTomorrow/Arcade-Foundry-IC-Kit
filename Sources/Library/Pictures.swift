import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Each game's pictures in the library (#352 for the order):
/// - the player's own: the screen kept with "Use this screen as the
///   picture" in the pause menu, or an image picked in the game's settings
///   (Pictures/Own/<romset>.png);
/// - the app's: a screen from the game, taken by itself after half a minute
///   of the first play (Pictures/<romset>.png).
/// The card shows the player's own, else the downloaded art (GameArt), else
/// the app's. Beside the saves, 4:3; not backed up, since playing makes a
/// new one. Pictures from before #352 were all in Pictures/, and count as
/// the app's.
enum Pictures {
    static func url(_ romset: String) -> URL {
        Storage.root.appendingPathComponent("Pictures/\(romset).png")
    }

    static func ownURL(_ romset: String) -> URL {
        Storage.root.appendingPathComponent("Pictures/Own/\(romset).png")
    }

    /// The app's screen from the game.
    static func exists(_ romset: String) -> Bool { FileManager.default.fileExists(atPath: url(romset).path) }

    /// The player's own picture.
    static func hasOwn(_ romset: String) -> Bool { FileManager.default.fileExists(atPath: ownURL(romset).path) }

    /// Loaded images and the file dates they were loaded at, by path.
    private static var cache: [String: (date: Date, image: CGImage)] = [:]

    /// An image file, loaded again when it changes; nil when there is none.
    static func load(_ file: URL) -> CGImage? {
        let key = file.path
        guard let date = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date else {
            cache[key] = nil
            return nil
        }
        if let hit = cache[key], hit.date == date { return hit.image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache[key] = (date, image)
        return image
    }

    /// The app's screen from the game.
    static func image(_ romset: String) -> CGImage? { load(url(romset)) }

    /// Seconds of play before the app takes its screen: 30, or 150 on
    /// Lindbergh and Chihiro, which are still loading at half a minute
    /// (Sega Race TV's INITIALIZE STEP screen).
    static func screenAfter(_ platform: Platform) -> Double {
        platform == .lindbergh || platform == .chihiro ? 150 : 30
    }

    /// Removes the app's screen from the game (the game page's button); the
    /// next play takes another.
    static func removeScreen(_ romset: String) { try? FileManager.default.removeItem(at: url(romset)) }

    /// The player's own picture.
    static func ownImage(_ romset: String) -> CGImage? { load(ownURL(romset)) }

    /// What the game's card shows: the player's own picture, else the
    /// downloaded title screen (or in-game shot), else the app's screen,
    /// else the downloaded flyer. For the boards MAME can't run (Lindbergh,
    /// Chihiro) the flyer comes before the app's screen, which is only for
    /// a game with no flyer.
    @MainActor static func card(_ romset: String) -> CGImage? {
        let art = GameArt.shared
        if GameArt.noMAMEScreens.contains(romset) {
            return ownImage(romset) ?? art.cardFlyer(romset) ?? image(romset)
        }
        return ownImage(romset) ?? art.cardImage(romset) ?? image(romset) ?? art.cardFlyer(romset)
    }

    /// The card shows the app's screen from the game (the game page can remove it).
    @MainActor static func cardIsScreen(_ romset: String) -> Bool {
        guard exists(romset), !hasOwn(romset) else { return false }
        if GameArt.noMAMEScreens.contains(romset) { return GameArt.shared.cardFlyer(romset) == nil }
        return GameArt.shared.cardImage(romset) == nil
    }

    /// The game's screen (BGRA, GameCore.screen) as its picture, redrawn
    /// at 4:3 with square pixels (the board's are not): the player's own
    /// (`own`, from the pause menu) or the app's.
    static func save(_ romset: String, own: Bool, pixels: UnsafePointer<UInt32>, width: Int, height: Int) {
        let data = Data(bytes: pixels, count: width * height * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let screen = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        write(screen, to: own ? ownURL(romset) : url(romset), size: (height * 4 / 3, height))
    }

    /// The same at 4:3 into any file (a save state's picture, SaveStates).
    static func save(pixels: UnsafePointer<UInt32>, width: Int, height: Int, to file: URL) {
        let data = Data(bytes: pixels, count: width * height * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let screen = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        write(screen, to: file, size: (height * 4 / 3, height))
    }

    /// An image file the user picked (any size: shown filling a 4:3 card).
    static func use(_ file: URL, for romset: String) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        write(image, to: ownURL(romset), longest: 1024) // so a photo doesn't fill the disk
    }

    /// The player's own picture goes: the card shows the downloaded art or
    /// the app's screen again.
    static func removeOwn(_ romset: String) {
        try? FileManager.default.removeItem(at: ownURL(romset))
        cache[ownURL(romset).path] = nil
    }

    /// `image` at most `longest` pixels across or down.
    static func write(_ image: CGImage, to file: URL, longest: Int) {
        let scale = min(1, Double(longest) / Double(max(image.width, image.height)))
        write(image, to: file, size: (Int(Double(image.width) * scale), Int(Double(image.height) * scale)))
    }

    private static func write(_ image: CGImage, to file: URL, size: (Int, Int)) {
        let (w, h) = size
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, scaled, nil)
        CGImageDestinationFinalize(dest)
        cache[file.path] = nil
    }
}
