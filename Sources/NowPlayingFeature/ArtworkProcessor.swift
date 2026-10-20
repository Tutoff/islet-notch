import AppKit
import ImageIO

struct RGBColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
}

/// A downsampled artwork plus its accent color. CGImage is immutable, so sharing it is safe.
struct ProcessedArtwork: @unchecked Sendable {
    let image: CGImage
    let accent: RGBColor?
}

/// Downsampling, accent color extraction and the (rare, on-demand) artwork download.
enum ArtworkProcessor {
    /// 2× the largest display size (≈ 78 pt in the open island).
    static let maxPixelSize = 160

    /// Ephemeral, cache-less: nothing is written to disk and nothing lingers in memory.
    private static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }()

    /// Decodes straight to a ≤ 160 px thumbnail (JPEGs are decoded subsampled, the full-size bitmap
    /// is never materialised) and computes the accent color. Call off the main thread.
    static func process(_ data: Data) -> ProcessedArtwork? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return ProcessedArtwork(image: image, accent: accentColor(of: image))
        }
    }

    /// Fetches the first URL that yields a decodable image. Completion runs on a background queue.
    ///
    /// One session per request, invalidated once its task ends: that closes the connection right away. A kept-alive
    /// connection lingers for ~100 s, and with a network content filter installed (corporate Macs) its stats
    /// timer wakes the app every second or so meanwhile.
    static func download(_ urls: [URL], completion: @escaping @Sendable (ProcessedArtwork?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        let remaining = Array(urls.dropFirst())
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: request) { data, response, error in
            if error == nil,
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let data, data.count < 8_000_000,
               let processed = process(data) {
                completion(processed)
            } else {
                download(remaining, completion: completion)
            }
        }.resume()
    }

    // MARK: Accent color

    /// Picks the dominant vivid hue of the artwork, then lifts it so it reads on pure black.
    static func accentColor(of image: CGImage) -> RGBColor? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let binCount = 12
        var binWeight = [Double](repeating: 0, count: binCount)
        var binSum = [RGBColor](repeating: RGBColor(red: 0, green: 0, blue: 0), count: binCount)
        var average = RGBColor(red: 0, green: 0, blue: 0)
        var opaqueCount = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.1 else { continue }
            let color = RGBColor(red: Double(pixels[index]) / 255 / alpha,
                                 green: Double(pixels[index + 1]) / 255 / alpha,
                                 blue: Double(pixels[index + 2]) / 255 / alpha)
            average.red += color.red; average.green += color.green; average.blue += color.blue
            opaqueCount += 1

            let (hue, saturation, brightness) = hsb(color)
            guard saturation > 0.2, brightness > 0.2 else { continue }
            let weight = saturation * brightness * brightness
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            binWeight[bin] += weight
            binSum[bin].red += color.red * weight
            binSum[bin].green += color.green * weight
            binSum[bin].blue += color.blue * weight
        }
        guard opaqueCount > 0 else { return nil }

        // Dominant hue, smoothed with its neighbours so a hue split across two bins still wins.
        var bestBin = 0
        var bestScore = 0.0
        for bin in 0..<binCount {
            let score = binWeight[bin]
                + 0.5 * binWeight[(bin + 1) % binCount]
                + 0.5 * binWeight[(bin + binCount - 1) % binCount]
            if score > bestScore { bestScore = score; bestBin = bin }
        }

        let base: RGBColor
        // Need a meaningful amount of colour (≈ 4 % of the pixels fully vivid), otherwise it's a neutral cover.
        if bestScore > Double(side * side) * 0.04, binWeight[bestBin] > 0 {
            let weight = binWeight[bestBin]
            base = RGBColor(red: binSum[bestBin].red / weight,
                            green: binSum[bestBin].green / weight,
                            blue: binSum[bestBin].blue / weight)
        } else {
            base = RGBColor(red: average.red / opaqueCount, green: average.green / opaqueCount, blue: average.blue / opaqueCount)
        }
        return boosted(base)
    }

    /// Bright, saturated version of `color` that stays legible on black.
    static func boosted(_ color: RGBColor) -> RGBColor {
        var (hue, saturation, brightness) = hsb(color)
        if saturation < 0.15 {
            // Neutral artwork: a soft, barely tinted white.
            saturation = min(saturation, 0.08)
            brightness = 0.92
        } else {
            saturation = min(1, max(saturation * 1.2, 0.5))
            brightness = max(brightness, 0.9)
        }
        var result = rgb(hue: hue, saturation: saturation, brightness: brightness)
        // Deep blues/purples stay too dark on black even at full brightness: wash them out a bit.
        while luminance(result) < 0.32, saturation > 0.3 {
            saturation -= 0.08
            result = rgb(hue: hue, saturation: saturation, brightness: brightness)
        }
        return result
    }

    private static func luminance(_ c: RGBColor) -> Double {
        0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }

    static func hsb(_ c: RGBColor) -> (Double, Double, Double) {
        let maxValue = max(c.red, c.green, c.blue)
        let minValue = min(c.red, c.green, c.blue)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == c.red {
                hue = ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == c.green {
                hue = (c.blue - c.red) / delta + 2
            } else {
                hue = (c.red - c.green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue > 0 ? delta / maxValue : 0
        return (hue, saturation, maxValue)
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGBColor {
        let h = (hue - floor(hue)) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBColor(red: r + m, green: g + m, blue: b + m)
    }
}
