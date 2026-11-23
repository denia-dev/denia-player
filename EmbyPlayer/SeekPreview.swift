import SwiftUI
import ImageIO

/// Roku BIF v0: timestamps are multiples of the LE multiplier at byte 16
/// (zero means 1000 ms). The last index entry is a sentinel, not a frame.
struct SeekBIF {
    private let data: Data
    private let frames: [(time: Double, range: Range<Int>)]

    init?(_ data: Data) {
        guard data.count >= 72, data.starts(with: [0x89, 0x42, 0x49, 0x46, 13, 10, 26, 10]) else { return nil }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        let count = word(12), scale = word(16)
        guard word(8) == 0, count > 0, count <= min(100_000, (data.count - 72) / 8),
              word(64 + count * 8) == 0xffffffff else { return nil }
        var entries: [(Double, Range<Int>)] = []
        for i in 0..<count {
            let p = 64 + i * 8, start = word(p + 4), end = word(p + 12)
            let time = Double(word(p)) * Double(scale == 0 ? 1000 : scale) / 1000
            guard start >= 72 + count * 8, end > start, end <= data.count,
                  time >= (entries.last?.0 ?? 0) else { return nil }
            entries.append((time, start..<end))
        }
        self.data = data
        frames = entries
    }

    func index(at seconds: Double) -> Int? {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time <= seconds { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    func image(at index: Int) -> CGImage? {
        let range = frames[index].range
        guard range.count <= 1024 * 1024,
              let src = CGImageSourceCreateWithData(data.subdata(in: range) as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ] as CFDictionary)
    }
}

/// Stays mounted for the playback session; never request anything until the
/// first scrub. Only one index download per session, even when no BIF exists.
struct SeekPreview: View {
    let itemID: String
    let client: EmbyClient?
    let scrubbing: Bool
    let seconds: Double
    let label: String
    @State private var requested = false
    @State private var archive: SeekBIF?
    @State private var rendered: (Int, CGImage)?

    var body: some View {
        let index = scrubbing ? archive?.index(at: seconds) : nil
        ZStack {
            if scrubbing {
                VStack(spacing: 4) {
                    if let index, let rendered, rendered.0 == index {
                        Image(decorative: rendered.1, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: 148, maxHeight: 84)
                    }
                    Text(label).font(.caption.monospacedDigit()).foregroundStyle(.white)
                }
                .padding(6).background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: scrubbing, initial: true) { _, active in if active { requested = true } }
        .task(id: requested) {
            guard requested, let client else { return }
            let loaded = try? await client.seekArchive(itemID: itemID)
            if !Task.isCancelled { archive = loaded }
        }
        .task(id: index) {
            guard let index, let archive else { return }
            if rendered?.0 != index { rendered = archive.image(at: index).map { (index, $0) } }
        }
    }
}
