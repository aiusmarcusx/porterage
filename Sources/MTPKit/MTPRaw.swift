import Foundation

/// Reading the phone's storage and folders straight over MTP.
///
/// The whole point of this file is `GetObjectPropList`: instead of asking the phone about each file
/// in turn, it asks for one property across an entire folder in a single command. Measured on a
/// folder of 337 files — 3,2 s the per-file way, 0,23 s this way.
///
/// The phone refuses `propertyCode = 0xFFFFFFFF` ("give me everything") with 0xA801, so each
/// property is its own call and the results are stitched back together by object handle.
extension PTPSession {
    // MARK: - Storage

    func storages() throws -> [MTPStorage] {
        let reply = try require(.getStorageIDs)
        let count = Int(reply.data.uint32(at: 0))
        var result: [MTPStorage] = []
        for index in 0 ..< count {
            let id = reply.data.uint32(at: 4 + index * 4)
            guard let info = try? require(.getStorageInfo, [id]) else { continue }
            let data = info.data
            // storageType(2) filesystemType(2) accessCapability(2) maxCapacity(8) freeSpace(8)
            // freeObjects(4) then the description string.
            var offset = 26
            let description = data.mtpString(at: &offset)
            result.append(MTPStorage(
                id: id,
                name: description.isEmpty ? "Internal storage" : description,
                capacity: data.uint64(at: 6),
                free: data.uint64(at: 14)
            ))
        }
        return result
    }

    /// Whether the device says it speaks MTP rather than plain PTP, or nil when it will not say.
    ///
    /// Android's MTP server (AOSP `MtpServer::doGetDeviceInfo`) sends vendor extension 6 with
    /// "microsoft.com: 1.0; android.com: 1.0;" in File transfer mode, and neither in "Transfer
    /// photos" mode. Taken from that source; not yet measured on the test phone.
    func advertisesMTP() -> Bool? {
        guard let reply = try? require(.getDeviceInfo), reply.data.count >= 9 else { return nil }
        // standardVersion(2) vendorExtensionID(4) vendorExtensionVersion(2) then the description.
        var offset = 8
        let description = reply.data.mtpString(at: &offset)
        return reply.data.uint32(at: 2) == 6 || description.contains("microsoft.com")
    }

    // MARK: - Listing

    /// Lists one folder. `folder` is `PTPSession.rootFolder` for the top level.
    func entries(in folder: UInt32) throws -> [MTPEntry] {
        var names: [UInt32: String] = [:]
        var sizes: [UInt32: UInt64] = [:]
        var dates: [UInt32: Date] = [:]
        var formats: [UInt32: UInt32] = [:]

        for (property, sink) in [
            (PTPProperty.filename, 0), (.objectSize, 1), (.dateModified, 2), (.objectFormat, 3),
        ] as [(PTPProperty, Int)] {
            // The first listing after plugging in waits while the phone indexes everything on it:
            // 17 s for ~34,000 objects on the test phone, so a fuller phone would pass the usual 30 s.
            let reply = try send(.getObjectPropList, [folder, 0, property.rawValue, 0, 1], timeout: 120_000)
            guard reply.isOK else {
                // Some phones only answer proplist for a real folder handle; fall back rather than
                // showing the user an empty folder.
                if property == .filename { return try entriesTheSlowWay(in: folder) }
                continue
            }
            parse(reply.data) { handle, value in
                switch sink {
                case 0: if case let .text(text) = value { names[handle] = text }
                case 1: if case let .number(number) = value { sizes[handle] = number }
                case 2: if case let .text(text) = value, let date = Self.parseDate(text) { dates[handle] = date }
                default: if case let .number(number) = value { formats[handle] = UInt32(truncatingIfNeeded: number) }
                }
            }
        }

        // Measured, not documented: at depth 1 the phone returns the folder you asked about along
        // with its children. Left in, every folder appears inside itself and nests forever.
        names.removeValue(forKey: folder)

        return names.map { handle, name in
            MTPEntry(
                id: handle,
                name: name.precomposedStringWithCanonicalMapping,
                isFolder: formats[handle] == 0x3001,
                size: sizes[handle] ?? 0,
                modified: dates[handle]
            )
        }
        .sorted(by: MTPEntry.displayOrder)
    }

    /// One `GetObjectInfo` per file — what libmtp does. Only used when the fast path is refused.
    private func entriesTheSlowWay(in folder: UInt32) throws -> [MTPEntry] {
        let handles = try require(.getObjectHandles, [Self.allObjects, 0, folder])
        let count = Int(handles.data.uint32(at: 0))
        var result: [MTPEntry] = []
        result.reserveCapacity(count)
        for index in 0 ..< count {
            let handle = handles.data.uint32(at: 4 + index * 4)
            guard let info = try? require(.getObjectInfo, [handle]) else { continue }
            let data = info.data
            // storageID(4) objectFormat(2) protection(2) compressedSize(4) then thumb/image fields,
            // parent at 40, then the filename string at 52.
            var offset = 52
            let name = data.mtpString(at: &offset)
            let created = data.mtpString(at: &offset)
            let modified = data.mtpString(at: &offset)
            _ = created
            result.append(MTPEntry(
                id: handle,
                name: name.precomposedStringWithCanonicalMapping,
                isFolder: data.uint16(at: 4) == 0x3001,
                size: UInt64(data.uint32(at: 8)),
                modified: Self.parseDate(modified)
            ))
        }
        return result.sorted(by: MTPEntry.displayOrder)
    }

    // MARK: - Property list parsing

    private enum PropertyValue {
        case number(UInt64)
        case text(String)
    }

    /// Dataset layout: a count, then that many (handle, property, datatype, value) records.
    private func parse(_ data: [UInt8], each: (UInt32, PropertyValue) -> Void) {
        let count = Int(data.uint32(at: 0))
        var offset = 4
        for _ in 0 ..< count {
            guard offset + 8 <= data.count else { return }
            let handle = data.uint32(at: offset)
            let type = data.uint16(at: offset + 6)
            offset += 8
            switch type {
            case 0x0001, 0x0002:  // INT8, UINT8
                each(handle, .number(UInt64(data[safe: offset] ?? 0)))
                offset += 1
            case 0x0003, 0x0004:  // INT16, UINT16
                each(handle, .number(UInt64(data.uint16(at: offset))))
                offset += 2
            case 0x0005, 0x0006:  // INT32, UINT32
                each(handle, .number(UInt64(data.uint32(at: offset))))
                offset += 4
            case 0x0007, 0x0008:  // INT64, UINT64
                each(handle, .number(data.uint64(at: offset)))
                offset += 8
            case 0xFFFF:  // string
                each(handle, .text(data.mtpString(at: &offset)))
            default:
                return  // unknown width: the rest of the buffer can no longer be trusted
            }
        }
    }

    /// MTP dates look like `20260912T134522`, sometimes with fractional seconds or a zone suffix.
    static func parseDate(_ text: String) -> Date? {
        guard text.count >= 15 else { return nil }
        let digits = text.prefix(15)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = text.hasSuffix("Z") ? TimeZone(identifier: "UTC") : .current
        return formatter.date(from: String(digits))
    }
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? { index >= 0 && index < count ? self[index] : nil }
}
