import Foundation

/// An sRGB colour with channels from 0 to 1.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Perceived brightness, 0 to 1.
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// How colourful it is: 0 for greys.
    var chroma: Double {
        max(red, green, blue) - min(red, green, blue)
    }
}

/// Picks the now-playing bar's background from the album cover.
public enum ArtworkColor {
    /// The cover's most prominent colourful shade, or its plain average when
    /// it's mostly grey. Nil without pixels.
    public static func dominant(_ pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        var weights: [Int: Double] = [:]
        var sums: [Int: (red: Double, green: Double, blue: Double, count: Double)] = [:]
        for pixel in pixels {
            let brightness = max(pixel.red, pixel.green, pixel.blue)
            guard pixel.chroma >= 0.15, brightness >= 0.15 else { continue }
            let key = bucket(pixel)
            weights[key, default: 0] += pixel.chroma
            var sum = sums[key] ?? (red: 0, green: 0, blue: 0, count: 0)
            sum.red += pixel.red
            sum.green += pixel.green
            sum.blue += pixel.blue
            sum.count += 1
            sums[key] = sum
        }
        guard let best = weights.max(by: { $0.value < $1.value })?.key, let sum = sums[best] else {
            return average(pixels)
        }
        return RGB(red: sum.red / sum.count, green: sum.green / sum.count, blue: sum.blue / sum.count)
    }

    /// Darkens a colour, keeping its hue, so white text on it stays readable.
    public static func background(for color: RGB, maxLuminance: Double = 0.28) -> RGB {
        let luminance = color.luminance
        guard luminance > maxLuminance else { return color }
        let scale = maxLuminance / luminance
        return RGB(red: color.red * scale, green: color.green * scale, blue: color.blue * scale)
    }

    /// 8 levels per channel, so similar shades land together.
    private static func bucket(_ pixel: RGB) -> Int {
        func level(_ value: Double) -> Int { min(7, max(0, Int(value * 8))) }
        return level(pixel.red) << 6 | level(pixel.green) << 3 | level(pixel.blue)
    }

    private static func average(_ pixels: [RGB]) -> RGB {
        let count = Double(pixels.count)
        return RGB(
            red: pixels.reduce(0) { $0 + $1.red } / count,
            green: pixels.reduce(0) { $0 + $1.green } / count,
            blue: pixels.reduce(0) { $0 + $1.blue } / count
        )
    }
}
