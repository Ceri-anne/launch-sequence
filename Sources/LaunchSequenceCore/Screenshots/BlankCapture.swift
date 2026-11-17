import CoreGraphics
import Foundation
import ImageIO

/// Spots a capture taken before the app drew anything: a screen that's nearly one colour.
public enum BlankCapture {
    /// True when more than `threshold` of the sampled pixels are within `tolerance` (per
    /// channel, 0–255) of the most common colour. The top `ignoreTop` of the image, where the
    /// status bar is, isn't counted. Data that isn't a readable image isn't blank.
    public static func isBlank(_ data: Data, threshold: Double = 0.99, tolerance: Int = 10, ignoreTop: Double = 0.07, sampleWidth: Int = 300) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { return false }
        let width = min(image.width, sampleWidth)
        let height = max(1, image.height * width / image.width)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Nearest-neighbour sampling, so thin text isn't averaged into the background.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        // Row 0 of the bitmap is the top of the image.
        let firstRow = min(height - 1, Int(Double(height) * ignoreTop))
        var counts: [UInt32: Int] = [:]
        for y in firstRow..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                counts[UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]), default: 0] += 1
            }
        }
        guard let common = counts.max(by: { $0.value < $1.value })?.key else { return false }
        let (r, g, b) = (Int(common >> 16 & 0xFF), Int(common >> 8 & 0xFF), Int(common & 0xFF))
        var near = 0, total = 0
        for (colour, n) in counts {
            total += n
            let dr = abs(Int(colour >> 16 & 0xFF) - r), dg = abs(Int(colour >> 8 & 0xFF) - g), db = abs(Int(colour & 0xFF) - b)
            if max(dr, dg, db) <= tolerance { near += n }
        }
        return Double(near) / Double(total) > threshold
    }
}
