import BikeDashCore
import SwiftUI
import UIKit

/// The music bar's background, taken from the album cover's colours.
enum ArtworkTint {
    static func color(for image: UIImage) -> Color? {
        guard let dominant = ArtworkColor.dominant(pixels(of: image)) else { return nil }
        let background = ArtworkColor.background(for: dominant)
        return Color(red: background.red, green: background.green, blue: background.blue)
    }

    /// The cover shrunk to `size` x `size` pixels.
    private static func pixels(of image: UIImage, size: Int = 24) -> [RGB] {
        guard let cgImage = image.cgImage else { return [] }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            RGB(
                red: Double(bytes[index]) / 255,
                green: Double(bytes[index + 1]) / 255,
                blue: Double(bytes[index + 2]) / 255
            )
        }
    }

    /// Demo mode: a made-up cover, purple to pink with a white disc.
    static func demoCover() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { context in
            let colors = [
                UIColor(red: 0.36, green: 0.12, blue: 0.62, alpha: 1).cgColor,
                UIColor(red: 0.93, green: 0.30, blue: 0.50, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 300, y: 300), options: [])
            }
            UIColor(white: 1, alpha: 0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 95, y: 95, width: 110, height: 110))
        }
    }
}
