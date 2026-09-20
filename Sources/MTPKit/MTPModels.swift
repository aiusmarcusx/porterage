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
    /// Nothing on the USB bus that speaks MTP. Either no cable, a charge-only cable, or the phone is
    /// set to "No data transfer".
    case noDevice
    /// A device answers as a camera: an Android phone set to "Transfer photos (PTP)" presents the
    /// same interface class as MTP but leaves the MTP extension out of its device info.
    case photoMode
    /// The session opens but the phone hands back no storage. Measured causes, in that order: the
    /// screen is locked, or the phone has not attached its storage to the cable — which happened on
    /// an unlocked phone after switching USB modes back and forth, until File transfer was picked
    /// again. The app names both rather than blaming the lock.
    case noStorage
    /// Another program is holding the phone's USB interface.
    case busy
    /// The phone's MTP interface is ours but it will not start a session, even after a USB reset —
    /// the wedged state that only unplugging the cable clears.
    case unresponsive
    /// Connected, storage readable, ready to work.
    case ready(MTPStorage)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Whether an error means the phone has gone, rather than one command having failed.
///
/// The difference matters to anything running a queue: a file that will not copy is one failed row,
/// but a cable that has come out fails every row that follows it, instantly and identically, and
/// saying so 300 times is not information.
public func isConnectionLost(_ error: Error) -> Bool {
    if let mtp = error as? MTPError {
        switch mtp {
        case .notConnected, .phoneLocked: return true
        default: return false
        }
    }
    // Every USB failure reaching this point is the link itself, not the file.
    return String(describing: type(of: error)).contains("Failure")
}

public enum MTPError: LocalizedError {
    case notConnected
    case phoneLocked
    case call(String, Int32)
    case notEnoughSpace(needed: UInt64, free: UInt64)
    case incomplete(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to a phone."
        case .phoneLocked:
            return "The phone isn't sharing its storage. Unlock the screen, or pick File transfer again on the phone."
        case let .call(what, code):
            return "\(what) failed (code \(code))."
        case let .notEnoughSpace(needed, free):
            let f = ByteCountFormatter.string(fromByteCount: Int64(needed - free), countStyle: .file)
            return "The phone needs \(f) more free space."
        case let .incomplete(name):
            return "The phone stopped sending “\(name)” before the end. What arrived is kept, and copying it again continues from there."
        }
    }
}
