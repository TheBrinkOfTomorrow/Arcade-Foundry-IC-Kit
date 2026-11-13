#if os(macOS)
import Accelerate
import AppKit

/// What every gameplay video shows over the game (issue #146): the game's
/// name with its system and year in the lower left, and the Arcade Foundry:
/// Insert Coin logo in the upper right. Drawn once, laid over each frame.
final class VideoCaption {
    static let site = "arcadefoundryinsertcoin.com"
    static let channel = "youtube.com/@ArcadeFoundryInsertCoin"

    private var pixels: [UInt32] // premultiplied BGRA, the frame's size
    private let width: Int, height: Int

    /// "Sega Model 2B · 1996" from the catalog: the board from the game's
    /// details when they name a revision of it (or a classic 2D board: "Sega
    /// X Board · 1987", "Sega System 32 · 1992"), the year they start with.
    static func subtitle(_ game: GameInfo) -> String {
        var board = "Sega \(game.platform.name)"
        if let r = game.detail.range(of: #"Model [123][A-C]?\b|Out Run board|X Board|System 32|Hang-On board"#, options: .regularExpression) { board = "Sega \(game.detail[r])" }
        let year = game.detail.prefix { $0.isNumber }
        return [board, String(year)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    init(width: Int, height: Int, title: String?, subtitle: String?, logo: Bool) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let h = CGFloat(height), margin = h * 0.05
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = h * 0.006
            shadow.shadowOffset = NSSize(width: 0, height: -h * 0.002)

            // Lower left (Core Graphics counts up from the bottom), over a
            // dark band fading up, so it reads on a white screen too.
            if title != nil || subtitle != nil {
                let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      colors: [NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1])!
                ctx.drawLinearGradient(band, start: .zero, end: CGPoint(x: 0, y: h * 0.25), options: [])
            }
            var y = margin
            if let subtitle, !subtitle.isEmpty {
                let s = NSAttributedString(string: subtitle, attributes: [
                    .font: NSFont.systemFont(ofSize: h * 0.03, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9), .shadow: shadow,
                ])
                s.draw(at: CGPoint(x: margin, y: y))
                y += s.size().height
            }
            if let title, !title.isEmpty {
                NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: h * 0.05, weight: .bold),
                    .foregroundColor: NSColor.white, .shadow: shadow,
                ]).draw(at: CGPoint(x: margin, y: y))
            }

            // Upper right.
            if logo, let image = NSImage(named: "Logo"), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let lh = h * 0.12, lw = lh * CGFloat(cg.width) / CGFloat(cg.height)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.002), blur: h * 0.006, color: NSColor.black.withAlphaComponent(0.7).cgColor)
                let rect = CGRect(x: CGFloat(width) - margin - lw, y: h - margin * 0.6 - lh, width: lw, height: lh)
                ctx.draw(cg, in: rect)
                ctx.restoreGState()
                // The website and the YouTube channel a little under it,
                // right-aligned with it, on a dark backing so they read on
                // a white screen too.
                let lines = [(Self.site, 0.022, NSFont.Weight.semibold), (Self.channel, 0.018, NSFont.Weight.medium)].map { text, size, weight in
                    NSAttributedString(string: text, attributes: [
                        .font: NSFont.systemFont(ofSize: h * size, weight: weight),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.9), .shadow: shadow,
                    ])
                }
                let pad = h * 0.008, top = rect.minY - h * 0.014
                let textWidth = lines.map { $0.size().width }.max()!, textHeight = lines.map { $0.size().height }.reduce(0, +)
                let backing = CGRect(x: rect.maxX - textWidth, y: top - textHeight, width: textWidth, height: textHeight)
                    .insetBy(dx: -pad, dy: -h * 0.003)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.addPath(CGPath(roundedRect: backing, cornerWidth: pad, cornerHeight: pad, transform: nil))
                ctx.fillPath()
                var y = top
                for line in lines {
                    let size = line.size()
                    y -= size.height
                    line.draw(at: CGPoint(x: rect.maxX - size.width, y: y))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The end of every video: on black, the logo, the website and the
    /// YouTube channel, centred. Opaque BGRA, `width` x `height`.
    static func endCard(width: Int, height: Int) -> [UInt32] {
        var pixels = [UInt32](repeating: 0xff00_0000, count: width * height)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let w = CGFloat(width), h = CGFloat(height)
            var y = h * 0.30
            for (text, size, weight) in [(channel, 0.035, NSFont.Weight.medium), (site, 0.05, NSFont.Weight.bold)] {
                let s = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: h * size, weight: weight), .foregroundColor: NSColor.white,
                ])
                let sz = s.size()
                s.draw(at: CGPoint(x: (w - sz.width) / 2, y: y))
                y += sz.height + h * 0.01
            }
            if let image = NSImage(named: "Logo"), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let lh = h * 0.3, lw = lh * CGFloat(cg.width) / CGFloat(cg.height)
                ctx.draw(cg, in: CGRect(x: (w - lw) / 2, y: y + h * 0.03, width: lw, height: lh))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return pixels
    }

    /// Lays the caption over a frame of the same size (BGRA, `rowBytes` a row).
    func draw(over base: UnsafeMutableRawPointer, rowBytes: Int) {
        pixels.withUnsafeMutableBytes { buf in
            var top = vImage_Buffer(data: buf.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var frame = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            vImagePremultipliedAlphaBlend_BGRA8888(&top, &frame, &frame, vImage_Flags(kvImageNoFlags))
        }
    }
}
#endif
