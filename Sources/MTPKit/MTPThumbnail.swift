import Foundation

public extension MTPDevice {
    /// A small preview of a photo, or nil when neither route on the phone can produce one.
    ///
    /// Two routes, in this order:
    ///
    ///  1. `GetThumb`. Measured at 14 ms per photo — but it is **not** a thumbnail service. It hands
    ///     back the thumbnail already embedded in the file's EXIF header and nothing else, which is
    ///     why it works for camera photos and fails for screenshots and downloaded images. (Proven
    ///     by copying a camera photo off the phone and back on under a new name: the copy served a
    ///     thumbnail immediately, so neither the folder nor the phone's media library matters.)
    ///  2. Read the first 64 KiB ourselves and pull the embedded thumbnail out. 9 ms per photo, and
    ///     it finds thumbnails in files where route 1 reports nothing.
    ///
    /// Files with no embedded thumbnail at all — roughly 15% of a real phone, mostly screenshots —
    /// return nil here and need the full image fetched and scaled on the Mac.
    func thumbnail(for entry: MTPEntry) async throws -> Data? {
        try await perform { session, _ in
            if let bytes = try? session.thumbnail(of: entry.id), !bytes.isEmpty {
                return Data(bytes)
            }
            let ask = UInt32(Swift.min(UInt64(65536), Swift.max(entry.size, 1)))
            guard let header = try? session.read(object: entry.id, offset: 0, count: ask), !header.isEmpty else {
                return nil
            }
            return Self.embeddedThumbnail(in: Data(header))
        }
    }

    /// Finds the JPEG hiding inside a JPEG: the EXIF thumbnail starts at the second SOI marker and
    /// ends at the matching EOI.
    static func embeddedThumbnail(in header: Data) -> Data? {
        let bytes = [UInt8](header)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var start: Int?
        var index = 2
        while index + 1 < bytes.count {
            if bytes[index] == 0xFF, bytes[index + 1] == 0xD8 {
                start = index
                break
            }
            index += 1
        }
        guard let start else { return nil }
        var end = start + 2
        while end + 1 < bytes.count {
            if bytes[end] == 0xFF, bytes[end + 1] == 0xD9 {
                return header.subdata(in: start ..< (end + 2))
            }
            end += 1
        }
        return nil
    }
}
