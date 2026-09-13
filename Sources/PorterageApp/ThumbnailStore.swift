import AppKit
import Foundation
import MTPKit

/// Fetches previews for the photos in the folder on screen and remembers them.
///
/// Loading is strictly one at a time and in visible order, because the phone answers one command at
/// a time anyway — trying to parallelise would only make the first row arrive later.
///
/// Two passes, because the two routes cost very different amounts:
///
///  1. **Fast pass.** Ask the phone for its thumbnail, then read the first 64 KiB and pull the
///     embedded one out. 9–14 ms per photo, so a folder of 300 fills in about four seconds.
///  2. **Slow pass.** Whatever the fast pass could not produce — screenshots and downloaded images
///     carry no embedded thumbnail — by fetching the whole file and scaling it here. Around 200 ms
///     for a 6 MB photo, so this only runs once every visible tile already has something in it.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [UInt32: NSImage] = [:]
    /// Photos nothing could produce a preview for; they draw a plain icon instead of retrying forever.
    @Published private(set) var unavailable: Set<UInt32> = []

    /// Above this, fetching the whole file to make a preview costs more than the preview is worth.
    private static let slowPassSizeLimit: UInt64 = 40 << 20

    private let device: MTPDevice
    private var queue: [MTPEntry] = []
    private var slowQueue: [MTPEntry] = []
    private var isRunning = false
    private var generation = 0

    init(device: MTPDevice) {
        self.device = device
    }

    /// Called when the folder changes. Drops work for the folder the user just left.
    func load(_ entries: [MTPEntry]) {
        queue = entries.filter { $0.isPhoto && images[$0.id] == nil && !unavailable.contains($0.id) }
        slowQueue = []
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        let mine = generation
        Task { await run(mine) }
    }

    func reset() {
        generation += 1
        queue = []
        slowQueue = []
        images = [:]
        unavailable = []
    }

    private func run(_ mine: Int) async {
        while !queue.isEmpty, mine == generation {
            let entry = queue.removeFirst()
            if let data = try? await device.thumbnail(for: entry), let image = NSImage(data: data) {
                images[entry.id] = image
            } else if entry.size <= Self.slowPassSizeLimit {
                slowQueue.append(entry)
                unavailable.insert(entry.id)  // show an icon now; the slow pass may replace it
            } else {
                unavailable.insert(entry.id)
            }
        }
        while !slowQueue.isEmpty, mine == generation {
            let entry = slowQueue.removeFirst()
            if let image = await fullImagePreview(of: entry) {
                images[entry.id] = image
                unavailable.remove(entry.id)
            }
        }
        isRunning = false
    }

    /// Pulls the whole file and scales it down here. `CGImageSource` decodes only what it needs for
    /// the requested size, so a 12-megapixel photo never becomes a 12-megapixel bitmap in memory.
    private func fullImagePreview(of entry: MTPEntry) async -> NSImage? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("porterage-preview-\(entry.id)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? await device.download(entry, to: scratch) { _, _ in }) != nil else { return nil }
        guard let source = CGImageSourceCreateWithURL(scratch as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
