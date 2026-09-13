import Foundation

/// A thin, synchronous handle on the raw MTP layer, for the `mtpcheck` diagnostics tool.
///
/// The app itself does not use this — it needs the queued, long-lived session in `MTPDevice`. This
/// is deliberately the simplest thing that can talk to a phone, so that when something is wrong it
/// is obvious whether the fault is in the MTP layer or in everything built on top of it.
public final class MTPProbe {
    private let link: USBLink
    private let session: PTPSession
    private var storage: MTPStorage?

    public init() throws {
        link = try USBLink()
        session = PTPSession(link: link)
    }

    @discardableResult
    public func connect() throws -> MTPStorage {
        try link.connect()
        try session.open()
        guard let first = try session.storages().first else {
            throw MTPError.phoneLocked  // storage list comes back empty while the screen is locked
        }
        storage = first
        return first
    }

    public func list(path: String) throws -> [MTPEntry] {
        try session.entries(in: try resolve(path))
    }

    /// Turns "DCIM/Camera" into the handle of that folder.
    public func resolve(_ path: String) throws -> UInt32 {
        var current = PTPSession.rootFolder
        for part in path.split(separator: "/") {
            let children = try session.entries(in: current)
            guard let match = children.first(where: {
                $0.isFolder && $0.comparisonKey == String(part).precomposedStringWithCanonicalMapping.lowercased()
            }) else {
                throw MTPError.call("Find folder \(part)", 0)
            }
            current = match.id
        }
        return current
    }

    // Synchronous wrappers so the diagnostics tool can run a whole round trip top to bottom.

    public func createFolder(named name: String, in parent: UInt32) throws -> UInt32 {
        try session.createFile(named: name, in: parent, storage: storage?.id ?? 0, size: 0, isFolder: true)
    }

    public func upload(_ url: URL, named name: String, into parent: UInt32) throws -> UInt32 {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
            .uint64Value ?? 0
        let handle = try session.createFile(named: name, in: parent, storage: storage?.id ?? 0, size: size)
        try session.sendObject(from: url, size: size, onProgress: { _ in }, isCancelled: { false })
        return handle
    }

    public func download(_ handle: UInt32, size: UInt64, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? file.close() }
        var offset: UInt64 = 0
        while offset < size {
            let ask = UInt32(Swift.min(UInt64(PTPSession.sliceSize), size - offset))
            let slice = try session.read(object: handle, offset: offset, count: ask)
            if slice.isEmpty { break }
            file.write(Data(slice))
            offset += UInt64(slice.count)
        }
    }

    public func rename(_ entry: MTPEntry, to name: String) throws {
        var payload = [UInt8]()
        payload.append(mtpString: name.precomposedStringWithCanonicalMapping)
        _ = try session.require(.setObjectPropValue, [entry.id, PTPProperty.filename.rawValue], payload: payload)
    }

    public func thumbnail(of entry: MTPEntry) throws -> Data? {
        if let bytes = try? session.thumbnail(of: entry.id), !bytes.isEmpty { return Data(bytes) }
        let ask = UInt32(Swift.min(UInt64(65536), Swift.max(entry.size, 1)))
        guard let header = try? session.read(object: entry.id, offset: 0, count: ask) else { return nil }
        return MTPDevice.embeddedThumbnail(in: Data(header))
    }

    /// Empties a folder before removing it; the phone refuses to delete one that still has contents.
    public func deleteRecursively(_ entry: MTPEntry) throws {
        if entry.isFolder {
            for child in try session.entries(in: entry.id) { try deleteRecursively(child) }
        }
        try session.delete(object: entry.id)
    }

    public func disconnect() {
        session.close()
        link.close()
    }
}
