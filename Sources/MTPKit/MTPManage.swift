import Foundation

/// Checks a name against what the phone will actually accept, before anything is written.
///
/// Every rule here came from feeding a real phone deliberately awkward names (NOTES.md). The
/// case-insensitive clash is the important one: the phone's filesystem ignores case while MTP does
/// not, so "Report.txt" and "report.txt" both appear in the listing while sharing one file on
/// disk — the second write silently destroys the first.
public enum MTPName {
    /// Characters a FAT-derived filesystem refuses. The phone rejects the write outright.
    static let forbidden: Set<Character> = [":", "?", "*", "\"", "<", ">", "|", "\\", "/"]

    public enum Problem: LocalizedError {
        case empty
        case forbiddenCharacter(Character)
        case tooLong
        case clashesIgnoringCase(String)
        case exists

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "The name can't be empty."
            case let .forbiddenCharacter(character):
                return "The phone won't accept \(character) in a file name."
            case .tooLong:
                return "That name is too long for the phone."
            case let .clashesIgnoringCase(existing):
                return """
                The phone already has “\(existing)”. Its storage treats upper and lower case as \
                the same name, so this would overwrite that file without warning.
                """
            case .exists:
                return "The phone already has a file with this name."
            }
        }
    }

    /// Returns the reason the name cannot be used, or nil when it is fine.
    /// `excluding` is the object being renamed, so a file does not clash with itself.
    public static func problem(with name: String, among entries: [MTPEntry], excluding: UInt32? = nil) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        if let bad = trimmed.first(where: { forbidden.contains($0) }) { return .forbiddenCharacter(bad) }
        // The limit is on bytes, not characters — Vietnamese and emoji names hit it much sooner.
        guard trimmed.precomposedStringWithCanonicalMapping.utf8.count < 255 else { return .tooLong }

        let key = trimmed.precomposedStringWithCanonicalMapping.lowercased()
        for entry in entries where entry.id != excluding && entry.comparisonKey == key {
            return entry.name == trimmed ? .exists : .clashesIgnoringCase(entry.name)
        }
        return nil
    }
}

public extension MTPDevice {
    func rename(_ entry: MTPEntry, to newName: String) async throws {
        let name = newName.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        try await perform { session, _ in
            var payload = [UInt8]()
            payload.append(mtpString: name)
            try session.require(.setObjectPropValue, [entry.id, PTPProperty.filename.rawValue], payload: payload)
        }
    }

    @discardableResult
    func createFolder(named name: String, in parent: UInt32) async throws -> UInt32 {
        let clean = name.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        return try await perform { session, storageID in
            try session.createFile(named: clean, in: parent, storage: storageID, size: 0, isFolder: true)
        }
    }

    func move(_ entry: MTPEntry, to parent: UInt32) async throws {
        try await perform { session, storageID in
            _ = try session.require(.moveObject, [entry.id, storageID, parent])
        }
    }
}
