import Foundation
import MTPKit

/// What to do when a name is already taken where a copy would land.
enum ClashChoice { case skip, replace, keepBoth }

/// Everything one drop onto the phone will do, worked out before anything is written: which folders
/// to create, which files land where, and which names are already taken.
///
/// A dropped folder merges into a folder of the same name already on the phone, so its files are
/// checked against what that folder holds — a clash three levels down gets the same question as one
/// at the top. The phone's storage ignores case, so every comparison goes through `key`.
struct UploadPlan {
    /// Where an item lands: a folder already on the phone, or one this copy creates.
    enum Parent: Hashable {
        case existing(UInt32)
        case new(Int)
    }

    struct Folder {
        var name: String
        let parent: Parent
        let path: String
        var skipped = false
    }

    struct File {
        let url: URL
        var name: String
        let parent: Parent
        let path: String
        let size: UInt64
        var skipped = false
    }

    /// An incoming item whose name the phone already uses in that folder.
    struct Clash {
        enum Item { case file(Int), folder(Int) }
        let item: Item
        let existing: MTPEntry
    }

    enum Failure: LocalizedError {
        case unreadableOnMac(String, Error)
        case unreadableOnPhone(String, Error)

        var errorDescription: String? {
            switch self {
            case let .unreadableOnMac(path, error): return "Couldn't read “\(path)” on this Mac: \(error.localizedDescription)"
            case let .unreadableOnPhone(path, error): return "Couldn't read “\(path)” on the phone: \(error.localizedDescription)"
            }
        }
    }

    /// Parents always come before their children, so creating them in order always has a parent.
    private(set) var folders: [Folder] = []
    private(set) var files: [File] = []
    private(set) var clashes: [Clash] = []
    /// Items the phone would refuse, each with the reason. The rest of the drop still goes.
    private(set) var leftOut: [String] = []
    /// Paths that would land under one name in the same phone folder. Any of these refuses the drop.
    private(set) var collisions: [String] = []
    /// Names the phone already uses, per folder the copy writes into.
    private var onPhone: [Parent: Set<String>] = [:]

    var clashPaths: [String] {
        clashes.map { clash in
            switch clash.item {
            case let .file(index): return files[index].path
            case let .folder(index): return folders[index].path
            }
        }
    }

    /// A file meeting a folder, or a folder meeting a file. Replace never deletes one kind to make
    /// room for the other.
    var hasClashOfDifferentKinds: Bool {
        clashes.contains { clash in
            if case .folder = clash.item { return !clash.existing.isFolder }
            return clash.existing.isFolder
        }
    }

    var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Planning

    /// Walks `urls` on this Mac against the phone folder `folder`, which holds `contents`. `list` reads
    /// a phone folder when a dropped folder merges into one.
    static func make(
        dropping urls: [URL],
        into folder: UInt32,
        holding contents: [MTPEntry],
        list: (UInt32) async throws -> [MTPEntry]
    ) async throws -> UploadPlan {
        var plan = UploadPlan()
        try await plan.place(urls, into: .existing(folder), holding: contents, path: "", list: list)
        return plan
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    private mutating func place(
        _ urls: [URL],
        into parent: Parent,
        holding contents: [MTPEntry],
        path: String,
        list: (UInt32) async throws -> [MTPEntry]
    ) async throws {
        onPhone[parent, default: []].formUnion(contents.map(\.comparisonKey))
        var incoming: [String: [String]] = [:]
        let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for url in ordered {
            let name = url.lastPathComponent
            let itemPath = path.isEmpty ? name : path + "/" + name
            // Hidden files are the Mac's own bookkeeping — .DS_Store and the like — not the user's.
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: Set(Self.keys))
            if values?.isSymbolicLink == true {
                leftOut.append("“\(itemPath)” is a symbolic link, which the phone can't hold.")
                continue
            }
            if let problem = MTPName.problem(with: name, among: []) {
                leftOut.append("“\(itemPath)”: \(problem.localizedDescription)")
                continue
            }
            let key = Self.key(name)
            incoming[key, default: []].append(itemPath)
            let existing = contents.first { $0.comparisonKey == key }

            guard values?.isDirectory == true else {
                files.append(File(url: url, name: name, parent: parent, path: itemPath, size: UInt64(values?.fileSize ?? 0)))
                if let existing { clashes.append(Clash(item: .file(files.count - 1), existing: existing)) }
                continue
            }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys)
            } catch {
                throw Failure.unreadableOnMac(itemPath, error)
            }
            if let existing, existing.isFolder {
                let inside: [MTPEntry]
                do {
                    inside = try await list(existing.id)
                } catch {
                    throw Failure.unreadableOnPhone(itemPath, error)
                }
                try await place(children, into: .existing(existing.id), holding: inside, path: itemPath, list: list)
            } else {
                folders.append(Folder(name: name, parent: parent, path: itemPath))
                let index = folders.count - 1
                if let existing { clashes.append(Clash(item: .folder(index), existing: existing)) }
                try await place(children, into: .new(index), holding: [], path: itemPath, list: list)
            }
        }
        collisions += incoming.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    // MARK: - Answering the clash question

    /// Applies the answer, renaming or skipping clashing items. Returns the phone files Replace has to
    /// delete before the copy starts.
    mutating func resolve(_ choice: ClashChoice) -> [MTPEntry] {
        var clashingFiles = Set<Int>(), clashingFolders = Set<Int>()
        for clash in clashes {
            switch clash.item {
            case let .file(index): clashingFiles.insert(index)
            case let .folder(index): clashingFolders.insert(index)
            }
        }
        // Every name that stays put is reserved first, so a renamed item cannot take one of them.
        var used = onPhone
        for (index, folder) in folders.enumerated() where !clashingFolders.contains(index) {
            used[folder.parent, default: []].insert(Self.key(folder.name))
        }
        for (index, file) in files.enumerated() where !clashingFiles.contains(index) {
            used[file.parent, default: []].insert(Self.key(file.name))
        }

        var deletions: [MTPEntry] = []
        for clash in clashes {
            switch (clash.item, choice) {
            case let (.file(index), .skip):
                files[index].skipped = true
            case (.file, .replace) where !clash.existing.isFolder:
                deletions.append(clash.existing)
            case let (.file(index), _):
                files[index].name = Self.freeName(files[index].name, isFolder: false, in: &used[files[index].parent, default: []])
            case let (.folder(index), .skip):
                skipFolder(index)
            case let (.folder(index), _):
                folders[index].name = Self.freeName(folders[index].name, isFolder: true, in: &used[folders[index].parent, default: []])
            }
        }
        return deletions
    }

    /// Skips a new folder and everything planned inside it. Parents precede children, so one pass
    /// forward reaches every descendant.
    private mutating func skipFolder(_ index: Int) {
        folders[index].skipped = true
        for inner in folders.indices where inner > index {
            if case let .new(parent) = folders[inner].parent, folders[parent].skipped { folders[inner].skipped = true }
        }
        for inner in files.indices {
            if case let .new(parent) = files[inner].parent, folders[parent].skipped { files[inner].skipped = true }
        }
    }

    /// "name (2).ext" for files, "name (2)" for folders — the pattern Keep Both uses everywhere.
    private static func freeName(_ name: String, isFolder: Bool, in used: inout Set<String>) -> String {
        let base = isFolder ? name : (name as NSString).deletingPathExtension
        let ext = isFolder ? "" : (name as NSString).pathExtension
        var counter = 2
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        } while used.contains(key(candidate))
        used.insert(key(candidate))
        return candidate
    }
}
