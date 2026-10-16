import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// How screenshots are stored on disk: HEIC (JPEG if HEIC isn't available), capped resolution, no alpha.
/// Text labels are stored separately as data, so each chart image is kept only once.
enum ImageCompression {
    enum Quality: String, CaseIterable, Identifiable {
        case high, balanced, smallest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .high: return "High quality"
            case .balanced: return "Balanced"
            case .smallest: return "Smallest files"
            }
        }
        var value: Double {
            switch self {
            case .high: return 0.85
            case .balanced: return 0.7
            case .smallest: return 0.55
            }
        }
    }

    /// Longest side in pixels; 0 keeps the original size.
    static let maxSizeOptions = [0, 3840, 2560, 1920]

    static var quality: Quality {
        Quality(rawValue: UserDefaults.standard.string(forKey: "imageQuality") ?? "") ?? .balanced
    }

    static var maxPixels: Int {
        let v = UserDefaults.standard.object(forKey: "imageMaxPixels") as? Int
        return v ?? 2560
    }

    // MARK: Encoding

    static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Redraws into an opaque sRGB bitmap (dropping alpha), scaled so the longest side is at most `maxPixels`.
    static func prepared(_ cg: CGImage, maxPixels: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let k = maxPixels > 0 ? min(1, Double(maxPixels) / Double(max(w, h))) : 1
        let tw = max(1, Int((Double(w) * k).rounded())), th = max(1, Int((Double(h) * k).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    static func encode(_ cg: CGImage, as type: UTType, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
        return out as Data
    }

    /// Compressed bytes and the file extension to use.
    static func compress(_ cg: CGImage, quality: Double = quality.value, maxPixels: Int = maxPixels) -> (data: Data, ext: String)? {
        guard let img = prepared(cg, maxPixels: maxPixels) else { return nil }
        if let heic = encode(img, as: .heic, quality: quality) { return (heic, "heic") }
        if let jpg = encode(img, as: .jpeg, quality: min(0.92, quality + 0.1)) { return (jpg, "jpg") }
        return nil
    }

    static func compress(_ image: NSImage) -> (data: Data, ext: String)? {
        guard let cg = cgImage(from: image) else { return nil }
        return compress(cg)
    }

    // MARK: Reading

    static func cgImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// A small, fast thumbnail without decoding the full image.
    static func thumbnail(at url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Disk usage

    static func folderSize(_ url: URL) -> (bytes: Int64, files: Int) {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return (0, 0)
        }
        var total: Int64 = 0, count = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            count += 1
        }
        return (total, count)
    }

    static func freeDiskSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
