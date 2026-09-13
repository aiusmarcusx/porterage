import Foundation

/// The MTP/PTP command set, limited to what this app actually issues.
enum PTPOperation: UInt16 {
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case getDeviceInfo = 0x1001
    case moveObject = 0x1019
    case setObjectPropValue = 0x9804
    case getObjectPropList = 0x9805
    /// Android's own extensions. They are what make resuming an interrupted copy possible.
    case getPartialObject64 = 0x95C1
    case sendPartialObject = 0x95C2
    case truncateObject = 0x95C3
    case beginEditObject = 0x95C4
    case endEditObject = 0x95C5
}

enum PTPProperty: UInt32 {
    case storageID = 0xDC01
    case objectFormat = 0xDC02
    case objectSize = 0xDC04
    case filename = 0xDC07
    case dateModified = 0xDC09
    case parent = 0xDC0B
}

enum PTPResponseCode: UInt16 {
    case ok = 0x2001
    case sessionAlreadyOpen = 0x201E
    case storeFull = 0x200C
    case accessDenied = 0x200F
    case invalidObjectHandle = 0x2009
    case specificationByGroupUnsupported = 0xA808
}

struct PTPReply {
    let code: UInt16
    let params: [UInt32]
    let data: [UInt8]

    var isOK: Bool { code == PTPResponseCode.ok.rawValue }
}

struct PTPError: LocalizedError {
    let operation: PTPOperation
    let code: UInt16
    var errorDescription: String? {
        String(format: "The phone refused command %04X (code %04X).", operation.rawValue, code)
    }
}

/// One MTP session over one claimed USB interface.
///
/// Not thread-safe by design: the phone answers one command at a time, so callers serialise on a
/// single queue rather than paying for locks on every transfer.
final class PTPSession {
    static let allObjects: UInt32 = 0xFFFF_FFFF
    static let rootFolder: UInt32 = 0xFFFF_FFFF

    private let link: USBLink
    private var transactionID: UInt32 = 1
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)

    init(link: USBLink) {
        self.link = link
    }

    // MARK: - Transactions

    /// Sends one command, optionally with a data phase in either direction, and returns the reply.
    @discardableResult
    func send(
        _ operation: PTPOperation,
        _ params: [UInt32] = [],
        payload: [UInt8]? = nil,
        timeout: UInt32 = 30_000
    ) throws -> PTPReply {
        let id = beginTransaction(operation)
        try writeCommand(operation, params: params, transaction: id)

        if let payload {
            var container = [UInt8]()
            container.reserveCapacity(12 + payload.count)
            container.append(uint32: UInt32(12 + payload.count))
            container.append(uint16: 2)  // container type: data
            container.append(uint16: operation.rawValue)
            container.append(uint32: id)
            container.append(contentsOf: payload)
            try container.withUnsafeBytes { try link.write($0, timeout: timeout) }
        }

        return try awaitResponse(operation, timeout: timeout)
    }

    /// Claims the next transaction id. `OpenSession` is the one command that must carry zero.
    func beginTransaction(_ operation: PTPOperation) -> UInt32 {
        guard operation != .openSession else { return 0 }
        defer { transactionID &+= 1 }
        return transactionID
    }

    func writeCommand(_ operation: PTPOperation, params: [UInt32], transaction: UInt32) throws {
        precondition(params.count <= 5, "MTP allows at most five parameters")
        var command = [UInt8]()
        command.reserveCapacity(12 + params.count * 4)
        command.append(uint32: UInt32(12 + params.count * 4))
        command.append(uint16: 1)  // container type: command
        command.append(uint16: operation.rawValue)
        command.append(uint32: transaction)
        for param in params { command.append(uint32: param) }
        try command.withUnsafeBytes { try link.write($0) }
    }

    /// Writes straight to the bulk endpoint, for data phases streamed from disk.
    func rawWrite(_ bytes: UnsafeRawBufferPointer, timeout: UInt32 = 10_000) throws {
        try link.write(bytes, timeout: timeout)
    }

    /// Reads whatever the phone sends back: an optional data container, then the response container.
    func awaitResponse(_ operation: PTPOperation, timeout: UInt32) throws -> PTPReply {
        var data = [UInt8]()
        var expected = 0
        var collecting = false

        while true {
            let count = try buffer.withUnsafeMutableBufferPointer { try link.read(into: $0, timeout: timeout) }
            if count == 0 { continue }

            if collecting, data.count < expected {
                let take = min(count, expected - data.count)
                data.append(contentsOf: buffer[0 ..< take])
                continue
            }
            guard count >= 12 else { throw PTPError(operation: operation, code: 0) }

            let length = Int(buffer.uint32(at: 0))
            let type = buffer.uint16(at: 4)
            if type == 2 {
                expected = max(length - 12, 0)
                data.reserveCapacity(expected)
                let take = min(count - 12, expected)
                data.append(contentsOf: buffer[12 ..< 12 + take])
                collecting = true
                continue
            }
            if type == 3 {
                let code = buffer.uint16(at: 6)
                var params: [UInt32] = []
                var offset = 12
                while offset + 4 <= min(count, length) {
                    params.append(buffer.uint32(at: offset))
                    offset += 4
                }
                return PTPReply(code: code, params: params, data: data)
            }
        }
    }

    /// Same as `send`, but turns a refusal into a thrown error.
    @discardableResult
    func require(
        _ operation: PTPOperation,
        _ params: [UInt32] = [],
        payload: [UInt8]? = nil,
        timeout: UInt32 = 30_000
    ) throws -> PTPReply {
        let reply = try send(operation, params, payload: payload, timeout: timeout)
        guard reply.isOK else { throw PTPError(operation: operation, code: reply.code) }
        return reply
    }

    // MARK: - Session lifecycle

    /// Opens the session, resetting the interface once if the phone refuses — which it reliably does
    /// on the first attempt after the cable is plugged in.
    func open() throws {
        let reply = try? send(.openSession, [1], timeout: 5_000)
        if let reply, reply.isOK || reply.code == PTPResponseCode.sessionAlreadyOpen.rawValue { return }
        link.reset()
        Thread.sleep(forTimeInterval: 0.3)
        let second = try send(.openSession, [1], timeout: 5_000)
        guard second.isOK || second.code == PTPResponseCode.sessionAlreadyOpen.rawValue else {
            throw PTPError(operation: .openSession, code: second.code)
        }
    }

    func close() {
        _ = try? send(.closeSession, timeout: 2_000)
    }

    /// Empties the phone's event queue. Must be called regularly during writes.
    func drainEvents() {
        var scratch = [UInt8](repeating: 0, count: 64)
        while scratch.withUnsafeMutableBufferPointer({ link.readEvent(into: $0) }) > 0 {}
    }
}

// MARK: - Little-endian helpers
//
// MTP is little-endian throughout, and these show up in every parser below.

extension Array where Element == UInt8 {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    mutating func append(uint64 value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }

    /// MTP strings: one byte of length in UTF-16 units, then UTF-16LE including a trailing NUL.
    mutating func append(mtpString value: String) {
        // Inside an extension on [UInt8], bare `Array` and `min` resolve to this type's own members.
        let units: [UInt16] = value.utf16.map { $0 }
        guard !units.isEmpty else { return append(0) }
        append(UInt8(Swift.min(units.count + 1, 255)))
        for unit in units.prefix(254) { append(uint16: unit) }
        append(uint16: 0)
    }

    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for index in 0 ..< 4 { value |= UInt32(self[offset + index]) << (8 * UInt32(index)) }
        return value
    }

    func uint64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for index in 0 ..< 8 { value |= UInt64(self[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    /// Reads an MTP string and advances `offset` past it.
    func mtpString(at offset: inout Int) -> String {
        guard offset < count else { return "" }
        let units = Int(self[offset])
        offset += 1
        guard units > 0 else { return "" }
        var scalars = [UInt16]()
        scalars.reserveCapacity(units)
        for index in 0 ..< units {
            let position = offset + index * 2
            guard position + 2 <= count else { break }
            let unit = uint16(at: position)
            if unit == 0 { break }
            scalars.append(unit)
        }
        offset += units * 2
        return String(decoding: scalars, as: UTF16.self)
    }
}
