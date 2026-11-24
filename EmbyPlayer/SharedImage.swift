import SwiftUI
import UIKit
import CoreImage

/// One decoded copy of each remote image, shared by every view that
/// asks for it. SwiftUI's AsyncImage fetches and decodes PER INSTANCE:
/// the detail page alone ran the same artwork through the hero plus
/// twenty ambient tiles at three different sizes, so first paint
/// waited on repeated downloads and JPEG decodes, the hero stayed
/// transparent long enough for the previous page to show through, and
/// the push transition flashed and swapped images (builds 88-89).
/// Here the first requester downloads once; every other view - and
/// every later visit - paints the decoded image from memory, in the
/// first frame when it is already cached.
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [NSURL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        let key = url as NSURL
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[key] = task
        lock.unlock()
        let image = await task.value
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    // MARK: - hero blank detection

    /// Hero artwork: nil when the download fails OR the returned
    /// image is a blank placeholder, so the caller can drop the item
    /// from the carousel instead of showing an empty slab.
    func heroImage(for url: URL) async -> UIImage? {
        guard let image = await image(for: url) else { return nil }
        return Self.isVisuallyBlank(image) ? nil : image
    }

    /// True when the image is (near-)uniform in colour, sampled on a
    /// 16x16 downscale. Some servers answer a backdrop request with a
    /// blank image instead of a 404.
    static func isVisuallyBlank(_ image: UIImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage,
              let context = CGContext(data: &pixels, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            minR = min(minR, r); maxR = max(maxR, r)
            minG = min(minG, g); maxG = max(maxG, g)
            minB = min(minB, b); maxB = max(maxB, b)
        }
        return maxR - minR < 6 && maxG - minG < 6 && maxB - minB < 6
    }

    // MARK: - baked ambient blur

    private let ambientCache = NSCache<NSURL, UIImage>()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func ambientCached(_ url: URL) -> UIImage? {
        ambientCache.object(forKey: url as NSURL)
    }

    /// A small pre-blurred copy for ambient background washes. Two
    /// full-screen live .blur() layers crossfading on every carousel
    /// step were the home page's main smoothness cost; a 96px baked
    /// blur scaled back up reads as the same wash and composites for
    /// almost nothing.
    func ambient(for url: URL) async -> UIImage? {
        if let hit = ambientCached(url) { return hit }
        guard let image = await image(for: url) else { return nil }
        let targetWidth: CGFloat = 96
        let scale = targetWidth / max(image.size.width, 1)
        let targetSize = CGSize(width: targetWidth, height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        var result = small
        if let cg = small.cgImage {
            let ci = CIImage(cgImage: cg)
            if let filter = CIFilter(name: "CIGaussianBlur",
                                     parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: 6]),
               let output = filter.outputImage,
               let blurred = Self.ciContext.createCGImage(output, from: ci.extent) {
                result = UIImage(cgImage: blurred)
            }
        }
        ambientCache.setObject(result, forKey: url as NSURL)
        return result
    }

    // MARK: - baked progressive-defocus variants (detail page)

    private let variantCache = NSCache<NSString, UIImage>()

    func ambientVariantCached(_ url: URL, heavy: Bool) -> UIImage? {
        variantCache.object(forKey: (url.absoluteString + (heavy ? "#heavy" : "#light")) as NSString)
    }

    /// The detail page's ambient used to run TWO live Gaussian blurs
    /// (radius 36 + 10, saturation on top) over a 10-tile artwork
    /// stack, in both the fixed and the scrolling layer - four huge
    /// filtered surfaces recomposited on every frame of the zoom
    /// transition and every scroll tick, which is what made entering
    /// a detail page feel stiff. These variants bake the same
    /// progressive defocus (saturation 1.2 + blur, heavy or light)
    /// into a small bitmap once; the layers then composite as plain
    /// textured quads.
    func ambientVariant(for url: URL, heavy: Bool) async -> UIImage? {
        if let hit = ambientVariantCached(url, heavy: heavy) { return hit }
        guard let image = await image(for: url) else { return nil }
        let targetWidth: CGFloat = 480
        let scale = targetWidth / max(image.size.width, 1)
        let targetSize = CGSize(width: targetWidth, height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        var result = small
        if let cg = small.cgImage {
            let ci = CIImage(cgImage: cg).clampedToExtent()
            let saturated = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
            if let filter = CIFilter(name: "CIGaussianBlur",
                                     parameters: [kCIInputImageKey: saturated,
                                                  kCIInputRadiusKey: heavy ? 12.0 : 4.0]),
               let output = filter.outputImage,
               let baked = Self.ciContext.createCGImage(output, from: CIImage(cgImage: cg).extent) {
                result = UIImage(cgImage: baked)
            }
        }
        variantCache.setObject(result, forKey: (url.absoluteString + (heavy ? "#heavy" : "#light")) as NSString)
        return result
    }
}

/// AsyncImage replacement backed by ImageMemoryCache. Renders empty
/// until the image lands (callers layer placeholders underneath);
/// with fadeIn the image crossfades in over whatever is below, and a
/// cache hit paints immediately with no fade.
struct SharedImage: View {
    let url: URL?
    var fill: Bool = true
    var fadeIn: Bool = false

    @State private var uiImage: UIImage?

    init(url: URL?, fill: Bool = true, fadeIn: Bool = false) {
        self.url = url
        self.fill = fill
        self.fadeIn = fadeIn
        _uiImage = State(initialValue: url.flatMap { ImageMemoryCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        .opacity(fadeIn ? (uiImage == nil ? 0 : 1) : 1)
        .animation(fadeIn ? .easeOut(duration: 0.25) : nil, value: uiImage != nil)
        .task(id: url) {
            if uiImage == nil, let url {
                uiImage = await ImageMemoryCache.shared.image(for: url)
            }
        }
    }
}

/// Fill view rendering one baked defocus variant of an image (see
/// ImageMemoryCache.ambientVariant), with a soft fade-in so a detail
/// page's background wash arrives gently instead of popping.
struct AmbientVariantImage: View {
    let url: URL?
    let heavy: Bool

    @State private var uiImage: UIImage?

    init(url: URL?, heavy: Bool) {
        self.url = url
        self.heavy = heavy
        _uiImage = State(initialValue: url.flatMap { ImageMemoryCache.shared.ambientVariantCached($0, heavy: heavy) })
    }

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .opacity(uiImage == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: uiImage != nil)
        .task(id: url) {
            if uiImage == nil, let url {
                uiImage = await ImageMemoryCache.shared.ambientVariant(for: url, heavy: heavy)
            }
        }
    }
}

/// Fill view for ambient backgrounds, backed by the cache's small
/// pre-blurred copies (see ImageMemoryCache.ambient).
struct AmbientImageView: View {
    let url: URL?

    @State private var uiImage: UIImage?

    init(url: URL?) {
        self.url = url
        _uiImage = State(initialValue: url.flatMap { ImageMemoryCache.shared.ambientCached($0) })
    }

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: url) {
            if uiImage == nil, let url {
                uiImage = await ImageMemoryCache.shared.ambient(for: url)
            }
        }
    }
}
