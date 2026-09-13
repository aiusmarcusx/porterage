import AppKit
import Foundation
import MTPKit

/// Everything the browser window needs to draw itself, kept on the main actor.
@MainActor
final class PhoneBrowser: ObservableObject {
    enum SortField: String, CaseIterable, Identifiable {
        case name, size, date
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .date: return "Date"
            }
        }
    }

    /// What to do when a file being copied up has a name the phone already holds.
    enum ClashChoice { case skip, replace, keepBoth }

    struct PendingUpload {
        let urls: [URL]
        let clashes: [String]
        let folder: UInt32
    }

    @Published private(set) var status: MTPStatus = .searching
    @Published private(set) var entries: [MTPEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// Breadcrumb from the storage root down to the folder on screen.
    @Published private(set) var path: [MTPEntry] = []
    @Published var showsHiddenFiles = false
    @Published var selection: Set<MTPEntry.ID> = []
    @Published var searchText = ""
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    /// Set when an upload is waiting on the user to say what to do about duplicate names.
    @Published var pendingUpload: PendingUpload?

    let transfers: TransferQueue
    let thumbnails: ThumbnailStore

    private let device = MTPDevice()

    var currentFolder: UInt32 { path.last?.id ?? MTPDevice.rootFolder }
    var currentFolderName: String {
        if let last = path.last { return last.name }
        if case let .ready(storage) = status { return storage.name }
        return "Phone"
    }

    var visibleEntries: [MTPEntry] {
        var list = showsHiddenFiles ? entries : entries.filter { !$0.isHiddenByPhone }
        let needle = searchText.trimmingCharacters(in: .whitespaces).folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: .current
        )
        if !needle.isEmpty {
            list = list.filter {
                $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .contains(needle)
            }
        }
        return list.sorted(by: inOrder)
    }

    /// Folders always lead, whatever the sort — they are navigation, not content.
    private func inOrder(_ left: MTPEntry, _ right: MTPEntry) -> Bool {
        if left.isFolder != right.isFolder { return left.isFolder }
        let ascending: Bool
        switch sortField {
        case .name: ascending = left.name.localizedStandardCompare(right.name) == .orderedAscending
        case .size: ascending = left.size < right.size
        case .date: ascending = (left.modified ?? .distantPast) < (right.modified ?? .distantPast)
        }
        return sortAscending ? ascending : !ascending
    }

    var hiddenCount: Int { entries.filter(\.isHiddenByPhone).count }
    var selectedEntries: [MTPEntry] { visibleEntries.filter { selection.contains($0.id) } }

    init() {
        transfers = TransferQueue(device: device)
        thumbnails = ThumbnailStore(device: device)
        device.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.apply(status) }
        }
        transfers.onQueueDrained = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        device.start()
    }

    private func apply(_ new: MTPStatus) {
        let wasReady = status.isReady
        status = new
        if new.isReady, !wasReady {
            path = []
            reload()
        } else if !new.isReady {
            entries = []
        }
    }

    // MARK: - Navigating

    func open(_ entry: MTPEntry) {
        guard entry.isFolder else { return }
        path.append(entry)
        enterFolder()
    }

    /// Jumps back to a breadcrumb step; `nil` means the storage root.
    func navigate(to entry: MTPEntry?) {
        guard let entry else {
            path = []
            return enterFolder()
        }
        guard let index = path.firstIndex(of: entry) else { return }
        path = Array(path.prefix(through: index))
        enterFolder()
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        enterFolder()
    }

    /// Clear first: a big folder takes a moment to list, and leaving the previous folder's rows on
    /// screen makes the app look stuck on the wrong place.
    private func enterFolder() {
        entries = []
        selection = []
        searchText = ""
        thumbnails.reset()
        reload()
    }

    func reload() {
        guard status.isReady else { return }
        isLoading = true
        errorText = nil
        let folder = currentFolder
        Task {
            do {
                let found = try await device.children(of: folder)
                guard folder == currentFolder else { return }  // user moved on while we were listing
                entries = found
                selection = selection.filter { id in found.contains { $0.id == id } }
                thumbnails.load(found.filter { !$0.isHiddenByPhone })
            } catch {
                entries = []
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// A full-size image for the space-bar preview, fetched and scaled on this Mac.
    func previewImage(for entry: MTPEntry) async -> NSImage? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("porterage-full-\(entry.id)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? await device.download(entry, to: scratch) { _, _ in }) != nil,
              let source = CGImageSourceCreateWithURL(scratch as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Hands the Finder a promise for this file; the bytes are fetched only if the drop lands.
    func dragProvider(for entry: MTPEntry) -> NSItemProvider {
        DragOut.provider(for: entry, device: device)
    }

    // MARK: - Selecting

    func selectAll() { selection = Set(visibleEntries.map(\.id)) }
    func clearSelection() { selection = [] }

    // MARK: - Managing

    func createFolder(named name: String) async -> String? {
        if let problem = MTPName.problem(with: name, among: entries) { return problem.localizedDescription }
        do {
            _ = try await device.createFolder(named: name, in: currentFolder)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func rename(_ entry: MTPEntry, to name: String) async -> String? {
        if let problem = MTPName.problem(with: name, among: entries, excluding: entry.id) {
            return problem.localizedDescription
        }
        do {
            try await device.rename(entry, to: name)
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ targets: [MTPEntry]) async -> String? {
        var failures: [String] = []
        for entry in targets {
            do { try await device.delete(entry) } catch { failures.append(entry.name) }
        }
        selection = []
        reload()
        return failures.isEmpty ? nil : "Could not delete: \(failures.joined(separator: ", "))"
    }

    // MARK: - Copying

    /// Queues the selection for copying into `folder` on the Mac, walking sub-folders as it goes.
    func downloadSelection(to folder: URL) {
        let picked = selectedEntries
        guard !picked.isEmpty else { return }
        Task {
            var work: [(entry: MTPEntry, destination: URL)] = []
            for entry in picked {
                await collect(entry, into: folder, appendingTo: &work)
            }
            transfers.download(work)
        }
    }

    /// Depth-first walk that turns a selection into a flat list of files plus where each one lands.
    private func collect(_ entry: MTPEntry, into folder: URL, appendingTo work: inout [(entry: MTPEntry, destination: URL)]) async {
        guard entry.isFolder else {
            work.append((entry, folder.appendingPathComponent(entry.name)))
            return
        }
        let sub = folder.appendingPathComponent(entry.name)
        guard let children = try? await device.children(of: entry.id) else { return }
        for child in children where !child.isHiddenByPhone {
            await collect(child, into: sub, appendingTo: &work)
        }
    }

    /// Starts an upload, pausing for an answer when names collide.
    func upload(_ urls: [URL]) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        let clashes = clashingNames(for: files)
        if clashes.isEmpty {
            transfers.upload(files, into: currentFolder)
        } else {
            pendingUpload = PendingUpload(urls: files, clashes: clashes, folder: currentFolder)
        }
    }

    func resolvePendingUpload(_ choice: ClashChoice) {
        guard let pending = pendingUpload else { return }
        pendingUpload = nil
        let taken = Set(entries.map(\.comparisonKey))

        switch choice {
        case .skip:
            let keep = pending.urls.filter { !taken.contains(key(of: $0.lastPathComponent)) }
            if !keep.isEmpty { transfers.upload(keep, into: pending.folder) }

        case .replace:
            Task {
                for url in pending.urls {
                    let name = key(of: url.lastPathComponent)
                    if let existing = entries.first(where: { $0.comparisonKey == name }) {
                        try? await device.delete(existing)
                    }
                }
                entries = (try? await device.children(of: pending.folder)) ?? entries
                transfers.upload(pending.urls, into: pending.folder)
            }

        case .keepBoth:
            var used = taken
            var renamed: [(URL, String)] = []
            for url in pending.urls {
                var candidate = url.lastPathComponent
                if used.contains(key(of: candidate)) {
                    let base = (candidate as NSString).deletingPathExtension
                    let ext = (candidate as NSString).pathExtension
                    var counter = 2
                    repeat {
                        candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                        counter += 1
                    } while used.contains(key(of: candidate))
                }
                used.insert(key(of: candidate))
                renamed.append((url, candidate))
            }
            transfers.upload(renamed, into: pending.folder)
        }
    }

    private func key(of name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func clashingNames(for urls: [URL]) -> [String] {
        let taken = Set(entries.map(\.comparisonKey))
        return urls.map(\.lastPathComponent).filter { taken.contains(key(of: $0)) }
    }
}
