import SwiftUI
import UIKit

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
