import CryptoKit
import Foundation
import MTPKit

// Terminal diagnostics for the MTP layer.
//   mtpcheck               connect, show storage, list the root and DCIM/Camera, with timings
//   mtpcheck <folder>      time that folder instead
//   mtpcheck selftest      full round trip on the phone: create, upload, verify, rename, delete

func stopwatch<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
    let start = Date()
    let value = try work()
    print(String(format: "  %@ — %.2f s", label, Date().timeIntervalSince(start)))
    return value
}

func check(_ passed: Bool, _ label: String) {
    print("  \(passed ? "✅" : "❌") \(label)")
    if !passed { failures += 1 }
}

var failures = 0

/// Writes, reads back and compares a real file, because a transfer that looks fine and quietly
/// corrupts bytes is the one failure mode users cannot detect for themselves.
func selftest(_ probe: MTPProbe) throws {
    let folderName = "porterage-selftest"
    let fileName = "sample.bin"
    let scratch = FileManager.default.temporaryDirectory
    let source = scratch.appendingPathComponent(fileName)
    let readback = scratch.appendingPathComponent("readback.bin")

    var payload = Data(count: 3_000_000)
    payload.withUnsafeMutableBytes { buffer in
        guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
        for index in 0 ..< buffer.count { base[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7) }
    }
    try payload.write(to: source)
    let wanted = SHA256.hash(data: payload)

    let download = try probe.resolve("Download")

    // A leftover folder from an interrupted run would make every check below ambiguous.
    if let old = try probe.list(path: "Download").first(where: { $0.name == folderName }) {
        try probe.deleteRecursively(old)
    }

    let folder = try stopwatch("create folder") { try probe.createFolder(named: folderName, in: download) }
    check(folder != 0, "create folder")

    let handle = try stopwatch("upload 3 MB") {
        try probe.upload(source, named: fileName, into: folder)
    }
    let onPhone = try probe.list(path: "Download/\(folderName)")
    let uploaded = onPhone.first { $0.name == fileName }
    check(uploaded != nil, "file appears on the phone")
    check(uploaded?.size == UInt64(payload.count), "phone reports the right size (\(uploaded?.size ?? 0))")

    try stopwatch("download it back") { try probe.download(handle, size: UInt64(payload.count), to: readback) }
    let got = SHA256.hash(data: try Data(contentsOf: readback))
    check(got == wanted, "SHA-256 matches byte for byte")

    if let uploaded {
        try probe.rename(uploaded, to: "renamed.bin")
        let after = try probe.list(path: "Download/\(folderName)")
        check(after.contains { $0.name == "renamed.bin" }, "renamed")
        check(!after.contains { $0.name == fileName }, "old name is gone")
    }

    if let thumbSource = try probe.list(path: "DCIM/Camera").first(where: { $0.isPhoto && $0.size > 500_000 }) {
        let thumb = try stopwatch("fetch a thumbnail") { try probe.thumbnail(of: thumbSource) }
        check(thumb != nil && thumb!.count > 1000, "thumbnail, \(thumb?.count ?? 0) bytes")
    }

    if let leftover = try probe.list(path: "Download").first(where: { $0.name == folderName }) {
        try probe.deleteRecursively(leftover)
    }
    let cleaned = try probe.list(path: "Download").contains { $0.name == folderName }
    check(!cleaned, "cleaned up, nothing left behind")

    try? FileManager.default.removeItem(at: source)
    try? FileManager.default.removeItem(at: readback)
}

/// Uploads a local directory into a folder on the phone. Used to stage neutral content for
/// screenshots so nobody's real photos end up in marketing material.
func stage(_ probe: MTPProbe, folderName: String, from directory: String) throws {
    let download = try probe.resolve("Download")
    if let old = try probe.list(path: "Download").first(where: { $0.name == folderName }) {
        try probe.deleteRecursively(old)
    }
    let folder = try probe.createFolder(named: folderName, in: download)
    let files = (try FileManager.default.contentsOfDirectory(atPath: directory)).sorted()
    for name in files where !name.hasPrefix(".") {
        _ = try probe.upload(URL(fileURLWithPath: directory).appendingPathComponent(name),
                             named: name, into: folder)
    }
    print("staged \(files.count) files into Download/\(folderName)")
}

func unstage(_ probe: MTPProbe, folderName: String) throws {
    guard let folder = try probe.list(path: "Download").first(where: { $0.name == folderName }) else {
        print("nothing to remove")
        return
    }
    try probe.deleteRecursively(folder)
    print("removed Download/\(folderName)")
}

let argument = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DCIM/Camera"

do {
    let probe = try MTPProbe()
    let storage = try stopwatch("connect + read storage") { try probe.connect() }
    let gib = 1024.0 * 1024 * 1024
    print(String(format: "Storage: %@ — %.2f GiB free of %.2f GiB",
                 storage.name, Double(storage.free) / gib, Double(storage.capacity) / gib))

    if argument == "stage", CommandLine.arguments.count > 3 {
        try stage(probe, folderName: CommandLine.arguments[2], from: CommandLine.arguments[3])
    } else if argument == "unstage", CommandLine.arguments.count > 2 {
        try unstage(probe, folderName: CommandLine.arguments[2])
    } else if argument == "selftest" {
        try selftest(probe)
        print(failures == 0 ? "\nALL PASSED." : "\n\(failures) CHECK(S) FAILED.")
    } else {
        let root = try stopwatch("list the root folder") { try probe.list(path: "") }
        print("Root: \(root.count) items")
        let listed = try stopwatch("list \(argument)") { try probe.list(path: argument) }
        print("\(argument): \(listed.count) items")
        for entry in listed.prefix(3) {
            print("  • \(entry.name)\(entry.isFolder ? "/" : "")  \(entry.size) bytes")
        }
    }
    probe.disconnect()
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
exit(failures == 0 ? 0 : 1)
