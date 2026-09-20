import Foundation
import MTPKit

struct TransferJob: Identifiable {
    enum Direction { case fromPhone, toPhone }
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }

    let id = UUID()
    let name: String
    let direction: Direction
    var total: UInt64
    var done: UInt64 = 0
    var state: State = .waiting

    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }
}

/// Runs transfers one at a time. Not a throttle: the app holds a single MTP session, and the phone
/// answers one command at a time, so a queue is what the hardware actually is.
@MainActor
final class TransferQueue: ObservableObject {
    @Published private(set) var jobs: [TransferJob] = []
    @Published private(set) var currentSpeed: Double = 0  // bytes per second
    @Published private(set) var isRunning = false

    private let device: MTPDevice
    private var pending: [(TransferJob, () async throws -> Void)] = []
    private var cancelFlag = TransferCancel()
    private var activeStart: Date?

    init(device: MTPDevice) {
        self.device = device
    }

    var activeJob: TransferJob? { jobs.first { $0.state == .running } }
    var remaining: Int { jobs.filter { $0.state == .waiting || $0.state == .running }.count }

    /// Bytes still to move, across the running job and everything queued behind it.
    var bytesRemaining: UInt64 {
        jobs.reduce(0) { total, job in
            switch job.state {
            case .running: return total + (job.total > job.done ? job.total - job.done : 0)
            case .waiting: return total + job.total
            default: return total
            }
        }
    }

    /// Seconds left at the speed measured so far. Pulls from phone and pushes to it run at very
    /// different speeds — roughly 29 MB/s down against 15 MB/s up — so this has to come from the
    /// live measurement rather than any fixed figure.
    var secondsRemaining: Double? {
        guard currentSpeed > 1024, bytesRemaining > 0 else { return nil }
        return Double(bytesRemaining) / currentSpeed
    }

    func clearFinished() {
        jobs.removeAll { job in
            if case .running = job.state { return false }
            if case .waiting = job.state { return false }
            return true
        }
    }

    func cancelAll() {
        cancelFlag.cancel()
        pending.removeAll()
        for index in jobs.indices where jobs[index].state == .waiting {
            jobs[index].state = .cancelled
        }
    }

    // MARK: - Queueing

    func download(_ entries: [(entry: MTPEntry, destination: URL)]) {
        for item in entries {
            var job = TransferJob(name: item.entry.name, direction: .fromPhone, total: item.entry.size)
            let id = job.id
            job.state = .waiting
            jobs.append(job)
            pending.append((job, { [weak self] in
                guard let self else { return }
                try FileManager.default.createDirectory(
                    at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try await self.device.download(item.entry, to: item.destination, cancel: self.cancelFlag) { done, total in
                    Task { @MainActor in self.update(id, done: done, total: total) }
                }
            }))
        }
        pump()
    }

    /// Each file carries its own phone folder, so a dropped folder tree queues as one batch. The name
    /// is separate from the file so "keep both" can land a copy under a free name.
    func upload(_ items: [(url: URL, name: String, folder: UInt32)]) {
        for (url, name, folder) in items {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
                .uint64Value ?? 0
            var job = TransferJob(name: name, direction: .toPhone, total: size)
            let id = job.id
            job.state = .waiting
            jobs.append(job)
            pending.append((job, { [weak self] in
                guard let self else { return }
                try await self.device.upload(
                    from: url, named: name, into: folder, cancel: self.cancelFlag
                ) { done, total in
                    Task { @MainActor in self.update(id, done: done, total: total) }
                }
            }))
        }
        pump()
    }

    // MARK: - Running

    private func pump() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        cancelFlag = TransferCancel()
        Task { await runLoop() }
    }

    private func runLoop() async {
        // A long copy outlasts the Mac's idle timer, and a Mac that sleeps drops the USB session
        // mid-file. This holds it awake while jobs run; closing the lid still puts it to sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Copying files between this Mac and the phone"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        while !pending.isEmpty {
            let (job, work) = pending.removeFirst()
            setState(job.id, .running)
            activeStart = Date()
            do {
                try await work()
                setState(job.id, .done)
            } catch is TransferCancelled {
                setState(job.id, .cancelled)
            } catch {
                setState(job.id, .failed(error.localizedDescription))
                // A file that will not copy is one failed row. A cable that has come out fails every
                // row after it, instantly and identically — measured 21 Sep, 160,512 of them in ten
                // seconds once the phone was unplugged mid-copy. Stop and say so once instead.
                if isConnectionLost(error) {
                    let reason = "Not copied — the phone disconnected part-way through."
                    for (waiting, _) in pending { setState(waiting.id, .failed(reason)) }
                    pending.removeAll()
                }
            }
            activeStart = nil
        }
        isRunning = false
        currentSpeed = 0
        onQueueDrained?()
    }

    /// Called when the last job finishes, so the browser can refresh a folder it just wrote into.
    var onQueueDrained: (() -> Void)?

    private func update(_ id: UUID, done: UInt64, total: UInt64) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].done = done
        if total > 0 { jobs[index].total = total }
        if let start = activeStart {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.5 { currentSpeed = Double(done) / elapsed }
        }
    }

    private func setState(_ id: UUID, _ state: TransferJob.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        if state == .done { jobs[index].done = jobs[index].total }
    }
}
