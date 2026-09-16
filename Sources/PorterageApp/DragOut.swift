import AppKit
import Foundation
import MTPKit
import UniformTypeIdentifiers

/// Lets a row be dragged straight into the Finder.
///
/// The file is not fetched when the drag starts — it is fetched when something accepts the drop.
/// That matters here: a drag that began by copying a 20 MB photo off the phone would stall under the
/// cursor for a second before the drag image even appeared.
enum DragOut {
    /// Where lazily-fetched files land before the Finder takes them.
    private static let scratch: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porterage-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func provider(for entry: MTPEntry, device: MTPDevice) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name

        // Folders would need the whole subtree written out; offer files only for now.
        guard !entry.isFolder else { return provider }

        // Plain data, not the type the extension implies: with `public.jpeg` the Finder appends that
        // type's own extension to the suggested name, and "photo.jpg" lands as "photo.jpg.jpeg".
        // Measured on a real drop. The receiving app reads the kind from the name, as it would for
        // any file copied out of the Finder.
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let destination = scratch.appendingPathComponent(entry.name)
            Task {
                do {
                    try await device.download(entry, to: destination) { _, _ in }
                    // `false` keeps ownership here: the receiver copies the file rather than moving
                    // it, so a second drag of the same photo still has something to hand over.
                    completion(destination, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Called when the window closes; the scratch folder can hold whole photo libraries otherwise.
    static func clearScratch() {
        try? FileManager.default.removeItem(at: scratch)
    }
}
