import CUSB
import Foundation

/// The USB half of the connection: finds the phone, claims its MTP interface, and moves bytes.
///
/// This exists instead of libmtp because libmtp marks every Android device as unable to do
/// `GetObjectPropList` and offers no way to clear that from outside the library, which costs a
/// folder listing 3,2 s where the raw command takes 0,23 s. Talking to the interface ourselves also
/// drops the Homebrew dependency, so the app can actually ship.
final class USBLink {
    enum Failure: LocalizedError {
        case noLibusb(Int32)
        case notFound
        case heldByAnother
        case openFailed(Int32)
        case transfer(String, Int32)

        var errorDescription: String? {
            switch self {
            case .noLibusb: return "Could not start USB."
            case .notFound: return "No phone found in file transfer mode."
            case .heldByAnother: return "Another program is holding the phone."
            case .openFailed: return "Could not open a connection to the phone."
            case let .transfer(what, code): return "\(what) hit a USB error (\(code))."
            }
        }
    }

    /// One context for the life of the process. libusb is built to be started once, and tearing it
    /// down has its own hazard: `libusb_exit` was caught hanging inside `darwin_exit`, waiting on the
    /// hotplug thread, which would have frozen the session queue for good. Searching for a phone
    /// opened and closed a context every three seconds.
    private static let shared: OpaquePointer? = {
        var context: OpaquePointer?
        return libusb_init(&context) == 0 ? context : nil
    }()

    private(set) var handle: OpaquePointer?
    private var interfaceNumber: Int32 = -1
    private(set) var bulkIn: UInt8 = 0
    private(set) var bulkOut: UInt8 = 0
    /// Where the phone announces new objects. Left unread it fills up, and the phone slows to a
    /// crawl and then wedges — see NOTES.md.
    private(set) var eventIn: UInt8 = 0
    private(set) var productName = ""
    /// True when the claimed interface is the standard still-image class rather than Android's
    /// vendor-specific "MTP" one. PTP cameras share that class, so the caller has to ask the device
    /// what it speaks.
    private(set) var isStillImageClass = false
    /// Bulk-out packet size, 512 at high speed. See `PTPSession.finishDataPhase`.
    private(set) var packetSize = 512

    private static let appleVendorID: UInt16 = 0x05AC

    init() throws {
        guard Self.shared != nil else { throw Failure.noLibusb(-1) }
    }

    deinit { close() }

    // MARK: - Finding the phone

    /// Claims the first interface that speaks MTP: either the standard still-image class, or the
    /// vendor-specific interface Android labels "MTP".
    func connect() throws {
        guard let context = Self.shared else { throw Failure.notFound }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        defer { libusb_free_device_list(list, 1) }
        guard count > 0, let list else { throw Failure.notFound }

        var sawBusy = false
        for index in 0 ..< Int(count) {
            guard let device = list[index] else { continue }
            var descriptor = libusb_device_descriptor()
            guard libusb_get_device_descriptor(device, &descriptor) == 0 else { continue }
            // Never touch an iPhone or iPad plugged in beside the phone: its camera interface has the
            // same class as an MTP one, and claiming it would take it away from Photos.
            guard descriptor.idVendor != Self.appleVendorID else { continue }
            var configPointer: UnsafeMutablePointer<libusb_config_descriptor>?
            guard libusb_get_active_config_descriptor(device, &configPointer) == 0,
                  let config = configPointer else { continue }
            defer { libusb_free_config_descriptor(config) }

            for interfaceIndex in 0 ..< Int(config.pointee.bNumInterfaces) {
                guard let alt = config.pointee.interface[interfaceIndex].altsetting else { continue }
                let descriptor = alt[0]
                let isStillImage = descriptor.bInterfaceClass == 6
                let isVendorMTP = descriptor.bInterfaceClass == 255 && descriptor.bInterfaceSubClass == 255
                guard isStillImage || isVendorMTP else { continue }

                var inEndpoint: UInt8 = 0, outEndpoint: UInt8 = 0, interruptEndpoint: UInt8 = 0
                var outPacket = 512
                for endpointIndex in 0 ..< Int(descriptor.bNumEndpoints) {
                    guard let endpoints = descriptor.endpoint else { continue }
                    let endpoint = endpoints[endpointIndex]
                    let kind = endpoint.bmAttributes & 3
                    let isInput = endpoint.bEndpointAddress & 0x80 != 0
                    if kind == UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue) {
                        if isInput { inEndpoint = endpoint.bEndpointAddress }
                        else {
                            outEndpoint = endpoint.bEndpointAddress
                            outPacket = Int(endpoint.wMaxPacketSize & 0x7FF)
                        }
                    } else if kind == UInt8(LIBUSB_TRANSFER_TYPE_INTERRUPT.rawValue), isInput {
                        interruptEndpoint = endpoint.bEndpointAddress
                    }
                }
                guard inEndpoint != 0, outEndpoint != 0 else { continue }

                var candidate: OpaquePointer?
                guard libusb_open(device, &candidate) == 0, let candidate else { continue }

                // A vendor-specific interface only counts when the phone calls it "MTP"; the same
                // class covers ADB and every other Android debug interface.
                if isVendorMTP, readString(candidate, descriptor.iInterface) != "MTP" {
                    libusb_close(candidate)
                    continue
                }

                let claim = libusb_claim_interface(candidate, Int32(descriptor.bInterfaceNumber))
                if claim != 0 {
                    sawBusy = sawBusy || claim == LIBUSB_ERROR_BUSY.rawValue || claim == LIBUSB_ERROR_ACCESS.rawValue
                    libusb_close(candidate)
                    continue
                }

                handle = candidate
                interfaceNumber = Int32(descriptor.bInterfaceNumber)
                bulkIn = inEndpoint
                bulkOut = outEndpoint
                eventIn = interruptEndpoint
                isStillImageClass = isStillImage
                packetSize = max(outPacket, 1)
                productName = readProduct(candidate, descriptor)
                return
            }
        }
        throw sawBusy ? Failure.heldByAnother : Failure.notFound
    }

    private func readString(_ handle: OpaquePointer, _ index: UInt8) -> String {
        guard index != 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: 128)
        let length = libusb_get_string_descriptor_ascii(handle, index, &buffer, 128)
        guard length > 0 else { return "" }
        return String(decoding: buffer[0 ..< Int(length)], as: UTF8.self)
    }

    private func readProduct(_ handle: OpaquePointer, _: libusb_interface_descriptor) -> String {
        guard let device = libusb_get_device(handle) else { return "" }
        var descriptor = libusb_device_descriptor()
        guard libusb_get_device_descriptor(device, &descriptor) == 0 else { return "" }
        return readString(handle, descriptor.iProduct)
    }

    // MARK: - Moving bytes

    func write(_ bytes: UnsafeRawBufferPointer, timeout: UInt32 = 10_000) throws {
        guard let handle, let base = bytes.baseAddress else { throw Failure.notFound }
        var sent: Int32 = 0
        let pointer = UnsafeMutableRawPointer(mutating: base).assumingMemoryBound(to: UInt8.self)
        let rc = libusb_bulk_transfer(handle, bulkOut, pointer, Int32(bytes.count), &sent, timeout)
        guard rc == 0 else { throw Failure.transfer("Send", rc) }
    }

    /// A zero-length packet: the only way to end a transfer whose last packet came out full.
    func writeZeroLengthPacket(timeout: UInt32 = 10_000) throws {
        guard let handle else { throw Failure.notFound }
        var byte: UInt8 = 0
        var sent: Int32 = 0
        let rc = libusb_bulk_transfer(handle, bulkOut, &byte, 0, &sent, timeout)
        guard rc == 0 else { throw Failure.transfer("Send", rc) }
    }

    /// Returns the number of bytes read into `buffer`.
    func read(into buffer: UnsafeMutableBufferPointer<UInt8>, timeout: UInt32 = 30_000) throws -> Int {
        guard let handle, let base = buffer.baseAddress else { throw Failure.notFound }
        var received: Int32 = 0
        let rc = libusb_bulk_transfer(handle, bulkIn, base, Int32(buffer.count), &received, timeout)
        guard rc == 0 else { throw Failure.transfer("Receive", rc) }
        return Int(received)
    }

    /// MTP's class request for abandoning a transaction part-way through its data phase.
    func cancel(transaction: UInt32) throws {
        guard let handle else { throw Failure.notFound }
        var request: [UInt8] = [0x01, 0x40]  // cancellation code 0x4001
        request.append(uint32: transaction)
        let rc = libusb_control_transfer(handle, 0x21, 0x64, 0, UInt16(interfaceNumber), &request, UInt16(request.count), 5_000)
        guard rc >= 0 else { throw Failure.transfer("Cancel", rc) }
    }

    /// MTP's Get Device Status class request: the phone's response code, 0x2001 once it is ready.
    func deviceStatus() -> UInt16? {
        guard let handle else { return nil }
        var reply = [UInt8](repeating: 0, count: 64)
        let rc = libusb_control_transfer(handle, 0xA1, 0x67, 0, UInt16(interfaceNumber), &reply, UInt16(reply.count), 2_000)
        guard rc >= 4 else { return nil }
        return UInt16(reply[2]) | UInt16(reply[3]) << 8
    }

    /// Drains one pending event, if any. A timeout means there was nothing waiting, which is normal.
    func readEvent(into buffer: UnsafeMutableBufferPointer<UInt8>, timeout: UInt32 = 10) -> Int {
        guard let handle, eventIn != 0, let base = buffer.baseAddress else { return 0 }
        var received: Int32 = 0
        let rc = libusb_interrupt_transfer(handle, eventIn, base, Int32(buffer.count), &received, timeout)
        return rc == 0 ? Int(received) : 0
    }

    /// Last resort when the phone stops answering: the first session after plugging in often needs it.
    func reset() {
        guard let handle else { return }
        libusb_reset_device(handle)
    }

    func close() {
        if let handle {
            if interfaceNumber >= 0 { libusb_release_interface(handle, interfaceNumber) }
            libusb_close(handle)
        }
        handle = nil
        interfaceNumber = -1
    }
}
