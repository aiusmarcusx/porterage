import Foundation

/// One file or folder on the phone.
public struct MTPEntry: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let isFolder: Bool
    public let size: UInt64
    public let modified: Date?

    /// MIUI exposes its own trash over MTP as `.trashed-<deadline>-<original name>`; those are not
    /// files the user put there, so the browser keeps them out of sight by default.
    public var isHiddenByPhone: Bool {
        name.hasPrefix(".")
    }

    /// Names differing only in case collide on the phone's filesystem and silently overwrite each
    /// other, and the same name can arrive in two different Unicode spellings, so every comparison
    /// between a Mac name and a phone name has to go through this.
    public var comparisonKey: String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Folders first, then files, each alphabetically the way the Finder orders them.
    public static func displayOrder(_ left: MTPEntry, _ right: MTPEntry) -> Bool {
        left.isFolder == right.isFolder
            ? left.name.localizedStandardCompare(right.name) == .orderedAscending
            : left.isFolder
    }

    public var isPhoto: Bool {
        ["jpg", "jpeg", "heic", "png", "webp", "gif"].contains((name as NSString).pathExtension.lowercased())
    }
}

public struct MTPStorage: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let capacity: UInt64
    public let free: UInt64
}

/// What the app should be telling the user right now. Each case maps to one measured signature —
/// see NOTES.md for how each was reproduced on real hardware.
public enum MTPStatus: Equatable, Sendable {
    /// Looking for a phone, or waiting for one to be plugged in.
    case searching
    /// Nothing on the USB bus that speaks MTP. Either no cable, or the phone is set to
    /// "No data transfer" / "Photo transfer (PTP)" instead of "File transfer".
    case noDevice
    /// The session opens but the phone refuses to hand out its storage: it is locked.
    case locked
    /// Another program is holding the phone's USB interface.
    case busy
    /// Connected, storage readable, ready to work.
    case ready(MTPStorage)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum MTPError: LocalizedError {
    case notConnected
    case phoneLocked
    case call(String, Int32)
    case notEnoughSpace(needed: UInt64, free: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a phone."
        case .phoneLocked:
            return "The phone is locked. Unlock it and try again."
        case let .call(what, code):
            return "\(what) failed (code \(code))."
        case let .notEnoughSpace(needed, free):
            let f = ByteCountFormatter.string(fromByteCount: Int64(needed - free), countStyle: .file)
            return "The phone needs \(f) more free space."
        }
    }
}
