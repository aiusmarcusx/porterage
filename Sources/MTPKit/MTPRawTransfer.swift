import Foundation

/// Moving bytes over the raw MTP session: reads, writes, thumbnails, deletes, and resuming.
extension PTPSession {
    /// 8 MiB slices — measured at full speed (28,8 MiB/s against 29,4 for one big call) while
    /// keeping a stop responsive and an interrupted copy cheap to resume.
    static let sliceSize: UInt32 = 8 << 20

    // MARK: - Reading

    func read(object handle: UInt32, offset: UInt64, count: UInt32) throws -> [UInt8] {
        let reply = try require(.getPartialObject64, [
            handle,
            UInt32(truncatingIfNeeded: offset),
            UInt32(truncatingIfNeeded: offset >> 32),
            count,
        ])
        return reply.data
    }

    /// The phone's own preview of a photo. It serves the thumbnail embedded in the file's EXIF
    /// header and nothing else, so files without one — screenshots, downloads — come back empty.
    func thumbnail(of handle: UInt32) throws -> [UInt8]? {
        let reply = try send(.getThumb, [handle])
        return reply.isOK && !reply.data.isEmpty ? reply.data : nil
    }

    func delete(object handle: UInt32) throws {
        try require(.deleteObject, [handle, 0])
    }

    /// Deletes a file, or a folder and everything in it. A folder goes in one command when the phone
    /// allows that; when it refuses, the contents are removed first, deepest first. Which phones need
    /// the second route has not been measured.
    func deleteTree(_ handle: UInt32, isFolder: Bool) throws {
        let reply = try send(.deleteObject, [handle, 0])
        if reply.isOK { return }
        guard isFolder else { throw PTPError(operation: .deleteObject, code: reply.code) }
        for child in try entries(in: handle) {
            try deleteTree(child.id, isFolder: child.isFolder)
        }
        try delete(object: handle)
    }

    // MARK: - Writing

    /// Announces a file and gets back the handle to write into. Returns `(handle, parent)`.
    ///
    /// Note the phone does **not** check free space here: it accepts a declared size far larger than
    /// it can hold and only fails part-way through the data. Callers check first.
    func createFile(named name: String, in parent: UInt32, storage: UInt32, size: UInt64, isFolder: Bool = false) throws -> UInt32 {
        var info = [UInt8]()
        info.append(uint32: storage)
        info.append(uint16: isFolder ? 0x3001 : 0x3000)  // association, or undefined file
        info.append(uint16: 0)  // protection
        // Sizes at or above 4 GiB do not fit this field; 0xFFFFFFFF is the agreed "ask elsewhere".
        info.append(uint32: size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(size))
        info.append(uint16: 0)  // thumb format
        for _ in 0 ..< 5 { info.append(uint32: 0) }  // thumb size/w/h, image w/h
        info.append(uint32: 0)  // image bit depth
        info.append(uint32: parent)
        info.append(uint16: isFolder ? 1 : 0)  // association type
        info.append(uint32: 0)  // association description
        info.append(uint32: 0)  // sequence number
        info.append(mtpString: name)
        info.append(mtpString: "")  // created — the phone overwrites dates with its own clock
        info.append(mtpString: "")  // modified
        info.append(mtpString: "")  // keywords

        let reply = try require(.sendObjectInfo, [storage, parent], payload: info)
        guard reply.params.count >= 3 else { throw PTPError(operation: .sendObjectInfo, code: reply.code) }
        return reply.params[2]
    }

    /// Streams a file into the object just announced by `createFile`.
    ///
    /// The bytes go out in slices straight from disk rather than through one big array, so a 4 GiB
    /// video costs the same memory as a photo. Events are drained between slices — the phone raises
    /// one per object written, and leaving them unread is what wedges MTP after a couple of hundred
    /// files.
    func sendObject(
        from url: URL,
        size: UInt64,
        onProgress: (UInt64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            throw MTPError.call("Open \(url.lastPathComponent)", -1)
        }
        defer { try? file.close() }

        let id = beginTransaction(.sendObject)
        var header = [UInt8]()
        // A data phase of 4 GiB or more cannot state its length in 32 bits; 0xFFFFFFFF says so.
        let declared = size + 12 >= 0xFFFF_FFFF ? UInt32(0xFFFF_FFFF) : UInt32(size + 12)
        header.append(uint32: declared)
        header.append(uint16: 2)  // container type: data
        header.append(uint16: PTPOperation.sendObject.rawValue)
        header.append(uint32: id)
        try writeCommand(.sendObject, params: [], transaction: id)
        try header.withUnsafeBytes { try rawWrite($0) }

        var sent: UInt64 = 0
        while sent < size {
            if isCancelled() { throw TransferCancelled() }
            let want = Int(Swift.min(UInt64(Self.sliceSize), size - sent))
            let slice = file.readData(ofLength: want)
            if slice.isEmpty { break }
            try slice.withUnsafeBytes { try rawWrite($0, timeout: 60_000) }
            sent += UInt64(slice.count)
            onProgress(sent)
            drainEvents()
        }
        let reply = try awaitResponse(.sendObject, timeout: 60_000)
        guard reply.isOK else { throw PTPError(operation: .sendObject, code: reply.code) }
    }

    // MARK: - Resuming

    /// Continues a file the phone already holds part of.
    ///
    /// `GetObjectPropList` reports exactly how many bytes made it across, so a resumed copy starts
    /// at the real boundary rather than a guess. Verified byte-for-byte against SHA-256.
    func resumeSend(
        into handle: UInt32,
        from url: URL,
        startingAt offset: UInt64,
        total: UInt64,
        onProgress: (UInt64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            throw MTPError.call("Open \(url.lastPathComponent)", -1)
        }
        defer { try? file.close() }
        try file.seek(toOffset: offset)

        try require(.beginEditObject, [handle])
        var position = offset
        while position < total {
            if isCancelled() { throw TransferCancelled() }
            let want = Int(Swift.min(UInt64(Self.sliceSize), total - position))
            let slice = file.readData(ofLength: want)
            if slice.isEmpty { break }
            try require(.sendPartialObject, [
                handle,
                UInt32(truncatingIfNeeded: position),
                UInt32(truncatingIfNeeded: position >> 32),
                UInt32(slice.count),
            ], payload: [UInt8](slice), timeout: 60_000)
            position += UInt64(slice.count)
            onProgress(position)
            drainEvents()
        }
        try require(.endEditObject, [handle])
    }
}
