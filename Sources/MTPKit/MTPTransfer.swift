import Foundation

/// Shared stop flag for a running transfer. Cheap to poll from the copy loop.
public final class TransferCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct TransferCancelled: Error {}

public extension MTPDevice {
    /// Copies one file off the phone.
    ///
    /// Reads in slices rather than one call, which costs nothing — measured 28,8 MiB/s against 29,4
    /// — and buys three things: progress, a stop that takes effect immediately, and the ability to
    /// pick up an interrupted copy exactly where it stopped.
    ///
    /// The partial copy lives beside the destination as `<name>.part` until it is complete, so an
    /// interrupted run never looks like a finished file.
    func download(
        _ entry: MTPEntry,
        to destination: URL,
        cancel: TransferCancel? = nil,
        progress: @escaping (UInt64, UInt64) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("part")
        try await perform { session, _ in
            let fm = FileManager.default
            var offset: UInt64 = 0

            // Anything already in the .part file is bytes we do not have to ask for again.
            if let existing = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value,
               existing < entry.size {
                offset = existing
            } else {
                fm.createFile(atPath: partial.path, contents: nil)
            }

            guard let handle = FileHandle(forWritingAtPath: partial.path) else {
                throw MTPError.call("Open the file for writing", -1)
            }
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            progress(offset, entry.size)

            while offset < entry.size {
                if cancel?.isCancelled == true { throw TransferCancelled() }
                let ask = UInt32(Swift.min(UInt64(PTPSession.sliceSize), entry.size - offset))
                let slice = try session.read(object: entry.id, offset: offset, count: ask)
                // Stopping here quietly would rename a short file into place as if it were whole.
                guard !slice.isEmpty else { throw MTPError.incomplete(entry.name) }
                // Not `write(_: Data)`: that raises an Objective-C exception when the Mac's disk is
                // full, which Swift cannot catch, so the app would crash instead of reporting it.
                try handle.write(contentsOf: slice)
                offset += UInt64(slice.count)
                progress(offset, entry.size)
            }
            try handle.close()

            _ = try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
            // Dates survive in this direction only; the phone ignores them on the way up.
            if let modified = entry.modified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        }
    }

    /// Copies one file onto the phone, refusing up front when it will not fit.
    ///
    /// The free-space check is ours to make: the phone accepts a file far larger than its remaining
    /// space and only fails once it actually runs out, minutes later. Its reported free space is
    /// exact and updates immediately, so checking first is reliable.
    @discardableResult
    func upload(
        from source: URL,
        named name: String,
        into folder: UInt32,
        cancel: TransferCancel? = nil,
        progress: @escaping (UInt64, UInt64) -> Void
    ) async throws -> UInt32 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let free = await currentFreeSpace(), size > free {
            throw MTPError.notEnoughSpace(needed: size, free: free)
        }
        return try await perform { session, storageID in
            let handle = try session.createFile(named: name, in: folder, storage: storageID, size: size)
            do {
                try session.sendObject(from: source, size: size) { sent in
                    progress(sent, size)
                } isCancelled: {
                    cancel?.isCancelled == true
                }
            } catch {
                // A half-written object is worse than none: the user would see a plausible-looking
                // file that is silently truncated.
                try? session.delete(object: handle)
                throw error
            }
            return handle
        }
    }

    func delete(_ entry: MTPEntry) async throws {
        try await perform { session, _ in try session.deleteTree(entry.id, isFolder: entry.isFolder) }
    }
}
