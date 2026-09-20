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

    struct PendingUpload {
        var plan: UploadPlan
        /// Items from the same drop that were left out, shown alongside the question.
        let notice: String?
    }

    typealias DownloadItem = (entry: MTPEntry, destination: URL)

    struct PendingDownload {
        let work: [DownloadItem]
        /// Every folder the copy needs on the Mac, parents first, empty ones included.
        let folders: [URL]
        /// Names already present on this Mac where the copies would land.
        let clashes: [String]
    }

    @Published private(set) var status: MTPStatus = .searching
    @Published private(set) var entries: [MTPEntry] = []
    @Published private(set) var isLoading = false
    /// Reading both sides and creating folders before a copy is queued, which can take a moment.
    @Published private(set) var isPreparingCopy = false
    @Published private(set) var errorText: String?
    /// Breadcrumb from the storage root down to the folder on screen.
    @Published private(set) var path: [MTPEntry] = []
    @Published var showsHiddenFiles = false
    @Published var selection: Set<MTPEntry.ID> = []
    /// Where a Shift-click measures its range from: the last row clicked without Shift, the way the
    /// Finder anchors one. Cleared whenever the rows underneath it change, because a range measured
    /// from a row that is no longer on screen would select an arbitrary stretch of the new folder.
    @Published var selectionAnchor: MTPEntry.ID?
    @Published var searchText = ""
    @Published var sortField: SortField = .name
    @Published var sortAscending = true
    /// Set when an upload is waiting on the user to say what to do about duplicate names.
    @Published var pendingUpload: PendingUpload?
    /// Set when a copy to the Mac is waiting on the user to say what to do about files already there.
    @Published var pendingDownload: PendingDownload?

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
        selectionAnchor = nil
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
                if let anchor = selectionAnchor, !found.contains(where: { $0.id == anchor }) {
                    selectionAnchor = nil
                }
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

    /// What one click does, as the Finder does it.
    ///
    /// Kept pure and separate from the view so it can be tested without a window or a phone: every
    /// case below is a unit test in `Tests/PorterageAppTests`. The rules are the platform's, not
    /// this app's invention — plain click replaces and anchors, ⌘ toggles one row and re-anchors,
    /// Shift takes the run between the anchor and the row, and ⌘⇧ adds that run to what is already
    /// selected. A Shift-click with nothing anchored, or anchored to a row that has since gone,
    /// falls back to a plain click rather than selecting a guess.
    /// `nonisolated` because it touches no state: it is a function of its arguments alone, which is
    /// what lets the checks call it without a main-actor hop or a live browser.
    nonisolated static func selection(
        from current: Set<MTPEntry.ID>,
        anchor: MTPEntry.ID?,
        clicking id: MTPEntry.ID,
        in order: [MTPEntry.ID],
        extending: Bool,
        togglingOne: Bool
    ) -> (selection: Set<MTPEntry.ID>, anchor: MTPEntry.ID?) {
        if extending, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let run = order[min(from, to) ... max(from, to)]
            // ⌘⇧ adds the run; ⇧ alone replaces the selection with it. The anchor does not move, so
            // a second Shift-click re-measures from the same row instead of creeping down the list.
            return (togglingOne ? current.union(run) : Set(run), anchor)
        }
        if togglingOne {
            var next = current
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            return (next, id)
        }
        return ([id], id)
    }

    /// Applies one click to the live state.
    func click(_ id: MTPEntry.ID, extending: Bool, togglingOne: Bool) {
        let (next, anchor) = Self.selection(
            from: selection, anchor: selectionAnchor, clicking: id,
            in: visibleEntries.map(\.id), extending: extending, togglingOne: togglingOne
        )
        selection = next
        selectionAnchor = anchor
    }

    func selectAll() {
        selection = Set(visibleEntries.map(\.id))
        selectionAnchor = visibleEntries.first?.id
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

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
        selectionAnchor = nil
        reload()
        return failures.isEmpty ? nil : "Could not delete: \(failures.joined(separator: ", "))"
    }

    // MARK: - Copying

    /// Queues the selection for copying into `folder` on the Mac, walking sub-folders as it goes.
    /// Stops to ask when files of those names are already there. Returns what went wrong, if anything.
    func downloadSelection(to folder: URL) async -> String? {
        let picked = selectedEntries
        guard !picked.isEmpty else { return nil }
        isPreparingCopy = true
        defer { isPreparingCopy = false }
        var work: [DownloadItem] = []
        var folders: [URL] = []
        do {
            for entry in picked {
                try await collect(entry, into: folder, appendingTo: &work, folders: &folders)
            }
        } catch {
            // Copying the folders that could be read would end in "copied" over an incomplete set,
            // and the user would take the Mac's copy for the whole thing.
            return "\(error.localizedDescription) Nothing was copied."
        }
        // Two phone names can land on one Mac name — the Mac ignores case, and the phone keeps NFC and
        // NFD spellings apart — so later ones take a free name instead of overwriting the first.
        work = withFreeNames(work) { _ in false }
        // A folder cannot go where the Mac keeps a file of that name, and renaming the folder would
        // scatter its contents, so this is the one case the copy refuses outright.
        if let blocked = folders.first(where: { FileManager.default.fileExists(atPath: $0.path) && !Self.isFolder(at: $0) }) {
            return "“\(blocked.lastPathComponent)” on this Mac is a file, so the folder of that name on the phone has nowhere to go. Rename or move it and copy again. Nothing was copied."
        }
        let clashes = work.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
        if clashes.isEmpty {
            make(folders)
            transfers.download(work)
        } else {
            pendingDownload = PendingDownload(work: work, folders: folders, clashes: clashes.map(\.destination.lastPathComponent))
        }
        return nil
    }

    /// Folders are created up front, so a folder that is empty on the phone is empty here rather than
    /// missing. `TransferQueue` still creates the parents of each file it copies.
    private func make(_ folders: [URL]) {
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func resolvePendingDownload(_ choice: ClashChoice) {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        let fm = FileManager.default
        make(pending.folders)
        switch choice {
        case .skip:
            let missing = pending.work.filter { !fm.fileExists(atPath: $0.destination.path) }
            if !missing.isEmpty { transfers.download(missing) }
        case .replace:
            // Replace means files. A folder on the Mac with the same name is never deleted to make
            // room; that copy lands beside it under a free name.
            transfers.download(withFreeNames(pending.work) { Self.isFolder(at: $0) })
        case .keepBoth:
            transfers.download(withFreeNames(pending.work) { fm.fileExists(atPath: $0.path) })
        }
    }

    /// Gives each item a destination no earlier item in the batch has taken, as "name (2).ext" — the
    /// same pattern Keep Both uses on the phone. `rename` moves an item off its name even when unused.
    private func withFreeNames(_ work: [DownloadItem], renaming rename: (URL) -> Bool) -> [DownloadItem] {
        let fm = FileManager.default
        var used = Set<String>()
        return work.map { item in
            var destination = item.destination
            if used.contains(Self.pathKey(destination)) || rename(destination) {
                let folder = destination.deletingLastPathComponent()
                let base = (destination.lastPathComponent as NSString).deletingPathExtension
                let ext = destination.pathExtension
                var counter = 2
                repeat {
                    let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                    destination = folder.appendingPathComponent(candidate)
                    counter += 1
                } while used.contains(Self.pathKey(destination)) || fm.fileExists(atPath: destination.path)
            }
            used.insert(Self.pathKey(destination))
            return (item.entry, destination)
        }
    }

    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isFolder(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private struct UnreadableFolder: LocalizedError {
        let name: String
        let reason: Error
        var errorDescription: String? { "Couldn't read “\(name)” on the phone: \(reason.localizedDescription)" }
    }

    /// Depth-first walk that turns a selection into a flat list of files plus where each one lands,
    /// and the folders to create, parents first.
    private func collect(
        _ entry: MTPEntry,
        into folder: URL,
        appendingTo work: inout [DownloadItem],
        folders: inout [URL]
    ) async throws {
        guard entry.isFolder else {
            work.append((entry, folder.appendingPathComponent(entry.name)))
            return
        }
        let sub = folder.appendingPathComponent(entry.name)
        folders.append(sub)
        let children: [MTPEntry]
        do {
            children = try await device.children(of: entry.id)
        } catch {
            throw UnreadableFolder(name: entry.name, reason: error)
        }
        for child in children where !child.isHiddenByPhone {
            try await collect(child, into: sub, appendingTo: &work, folders: &folders)
        }
    }

    /// Plans a drop of files and folders into the folder on screen, then starts it — or pauses for an
    /// answer when names are already taken. Returns what to tell the user, if anything.
    func upload(_ urls: [URL]) async -> String? {
        let folder = currentFolder
        isPreparingCopy = true
        defer { isPreparingCopy = false }

        let plan: UploadPlan
        do {
            // Read fresh rather than trusting `entries`: a drop straight after opening a folder lands
            // before its listing does, and an empty list would wave every clash through.
            let contents = try await device.children(of: folder)
            plan = try await UploadPlan.make(dropping: urls, into: folder, holding: contents) { [device] handle in
                try await device.children(of: handle)
            }
        } catch {
            return "\(error.localizedDescription) Nothing was copied."
        }

        // The phone ignores case, so "Report.txt" and "report.txt" dropped together would land on one
        // file, the second silently replacing the first.
        if !plan.collisions.isEmpty {
            return """
            \(plan.collisions.map { "“\($0)”" }.joined(separator: ", ")) would land on the phone under one \
            name, because it treats upper and lower case as the same. Rename one and drop them again. \
            Nothing was copied.
            """
        }

        let notice = plan.leftOut.isEmpty ? nil : "Not copied:\n" + plan.leftOut.joined(separator: "\n")
        guard !plan.isEmpty else { return notice }
        if plan.clashes.isEmpty {
            return await start(plan, deleting: [], notice: notice)
        }
        pendingUpload = PendingUpload(plan: plan, notice: notice)
        return nil
    }

    func resolvePendingUpload(_ choice: ClashChoice) async -> String? {
        guard var pending = pendingUpload else { return nil }
        pendingUpload = nil
        isPreparingCopy = true
        defer { isPreparingCopy = false }
        let deletions = pending.plan.resolve(choice)
        return await start(pending.plan, deleting: deletions, notice: pending.notice)
    }

    /// Checks space for the whole drop, clears what Replace replaces, creates the new folders parents
    /// first, then queues the files.
    private func start(_ plan: UploadPlan, deleting deletions: [MTPEntry], notice: String?) async -> String? {
        let files = plan.files.filter { !$0.skipped }
        // The per-file check in `MTPDevice.upload` would let a big drop fill the phone and fail
        // part-way; this refuses it before anything is written.
        let needed = files.reduce(0) { $0 + $1.size }
        if let free = await device.currentFreeSpace() {
            let available = free + deletions.reduce(0) { $0 + $1.size }
            if needed > available {
                return MTPError.notEnoughSpace(needed: needed, free: available).localizedDescription + " Nothing was copied."
            }
        }

        for entry in deletions {
            try? await device.delete(entry)
        }

        var created: [Int: UInt32] = [:]
        func handle(for parent: UploadPlan.Parent) -> UInt32? {
            switch parent {
            case let .existing(handle): return handle
            case let .new(index): return created[index]
            }
        }
        for (index, folder) in plan.folders.enumerated() where !folder.skipped {
            guard let parent = handle(for: folder.parent) else { continue }
            do {
                created[index] = try await device.createFolder(named: folder.name, in: parent)
            } catch {
                if !created.isEmpty { reload() }
                return "Couldn't create “\(folder.path)” on the phone: \(error.localizedDescription) No files were copied."
            }
        }
        if !created.isEmpty { reload() }

        transfers.upload(files.compactMap { file in
            handle(for: file.parent).map { (url: file.url, name: file.name, folder: $0) }
        })
        return notice
    }
}
