import Foundation

/// Owns the one MTP session the app keeps open for as long as the phone is plugged in.
///
/// Three rules here are not style choices — each was measured against a real phone and each one
/// breaks the app when ignored (details in NOTES.md):
///
///  1. **One session, held open.** Every new session makes the phone pop up its "Use USB for…"
///     dialog again, and a locked phone refuses to hand out its storage to a new one. (A lock does
///     not spare a running session either — measured 15 Sep, twice.)
///  2. **Drain the phone's event queue.** The phone raises an interrupt event per object written.
///     Leave them unread and pushes decay from 53 ms to 1,1 s per file, then MTP wedges for good
///     after ~211 objects and only a physical replug brings it back.
///  3. **Everything on one serial queue.** The phone answers one command at a time.
public final class MTPDevice: @unchecked Sendable {
    public static let rootFolder = PTPSession.rootFolder

    /// Called on the main queue whenever the connection state changes.
    public var onStatusChange: ((MTPStatus) -> Void)?

    private let queue = DispatchQueue(label: "app.porterage.mtp.session")
    private var link: USBLink?
    private var session: PTPSession?
    private var storage: MTPStorage?
    private var watching = false
    /// Sessions that would not open in a row, on a phone whose interface was claimed.
    private var failedOpens = 0
    /// How many times a command was carried through a dropped session, and how many times one was
    /// attempted at all. Diagnostics only — a gap between the two is a session that went and did not
    /// come back inside the retry window.
    public private(set) var recoveries = 0
    public private(set) var recoveryAttempts = 0
    private var status: MTPStatus = .searching {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            DispatchQueue.main.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    public init() {}

    // MARK: - Connecting

    /// Starts looking for a phone and keeps retrying until one is ready, then stays connected.
    public func start() {
        queue.async { [weak self] in
            guard let self, !self.watching else { return }
            self.watching = true
            self.attachLoop()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.watching = false
            self.closeSession()
            self.status = .searching
        }
    }

    /// A phone that is locked, or not sharing its storage, is a normal state — the user simply has
    /// not got to it yet — so this reports it and keeps waiting rather than treating it as a failure.
    private func attachLoop() {
        guard watching else { return }
        if session != nil {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pollConnected() }
            return
        }
        status = tryAttach()
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.attachLoop() }
    }

    /// Cheap liveness check on an established session; also refreshes free space.
    private func pollConnected() {
        guard watching, let session else { return }
        if let first = try? session.storages().first {
            storage = first
            status = .ready(first)
        } else {
            // The phone stopped answering: the cable went, or it locked before we read storage.
            closeSession()
            status = .searching
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attachLoop() }
    }

    private func tryAttach() -> MTPStatus {
        let candidate: USBLink
        do {
            candidate = try USBLink()
            try candidate.connect()
        } catch USBLink.Failure.heldByAnother {
            failedOpens = 0
            return .busy
        } catch {
            failedOpens = 0
            return .noDevice
        }

        let candidateSession = PTPSession(link: candidate)
        do {
            try candidateSession.open()
            failedOpens = 0
        } catch {
            candidate.close()
            // Its MTP interface is claimed yet no session opens, even after the reset inside open().
            // Once is not enough to say so: a phone plugged in a moment ago may still be starting.
            failedOpens += 1
            return failedOpens >= 2 ? .unresponsive : .searching
        }

        if candidate.isStillImageClass, candidateSession.advertisesMTP() == false {
            candidateSession.close()
            candidate.close()
            return .photoMode
        }

        // A phone that is locked — or has not attached its storage — opens the session happily and
        // then hands back an empty storage list.
        guard let first = try? candidateSession.storages().first, first.capacity > 0 else {
            candidateSession.close()
            candidate.close()
            return .noStorage
        }

        link = candidate
        session = candidateSession
        storage = first
        return .ready(first)
    }

    private func closeSession() {
        session?.close()
        link?.close()
        session = nil
        link = nil
        storage = nil
    }

    // MARK: - Browsing

    public func children(of parent: UInt32) async throws -> [MTPEntry] {
        try await perform { session, _ in try session.entries(in: parent) }
    }

    /// Free space as the phone last reported it. Exact, and it updates the moment a file lands.
    public func currentFreeSpace() async -> UInt64? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in continuation.resume(returning: self?.storage?.free) }
        }
    }

    // MARK: - Plumbing

    /// Runs `body` on the session queue with a live session, or throws a state the UI can explain.
    ///
    /// `retryingOnce` re-runs `body` against a fresh session when the phone threw this one away
    /// mid-command. **Only pass it for work that is safe to run twice.** A download is, because it
    /// resumes from its own `.part` file and so picks up exactly where it stopped; an upload is not,
    /// because a half-written object may still be sitting on the phone under the name the retry
    /// would want.
    func perform<T>(
        retryingOnce: Bool = false,
        _ body: @escaping (PTPSession, UInt32) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: MTPError.notConnected) }
                if self.session == nil || self.storage == nil, retryingOnce, self.mayTryReattach() {
                    // No session at all. Measured 21 Sep by pulling the cable: without this, every
                    // remaining file in a copy failed in the same millisecond, and the failures
                    // queued here so densely that attachLoop — which shares this serial queue —
                    // never got a turn to reconnect. 160,512 of them in ten seconds.
                    self.recoveryAttempts += 1
                    _ = self.reattachForRetry()
                }
                guard let session = self.session, let storage = self.storage else {
                    continuation.resume(throwing: self.status == .noStorage ? MTPError.phoneLocked : MTPError.notConnected)
                    return
                }
                do {
                    let value = try body(session, storage.id)
                    session.drainEvents()
                    continuation.resume(returning: value)
                } catch {
                    session.drainEvents()
                    // A stop the user asked for is not a fault to recover from.
                    guard retryingOnce, !(error is TransferCancelled), self.sessionIsDead() else {
                        continuation.resume(throwing: error)
                        return
                    }
                    self.recoveryAttempts += 1
                    guard self.reattachForRetry(), let fresh = self.session, let storage = self.storage else {
                        continuation.resume(throwing: error)
                        return
                    }
                    do {
                        let value = try body(fresh, storage.id)
                        fresh.drainEvents()
                        self.recoveries += 1
                        continuation.resume(returning: value)
                    } catch {
                        fresh.drainEvents()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Whether the phone has stopped answering this session, as opposed to refusing one command for
    /// a reason of its own. The same liveness question `pollConnected` asks every two seconds.
    private func sessionIsDead() -> Bool {
        guard let session else { return true }
        guard let first = try? session.storages().first, first.capacity > 0 else { return true }
        return false
    }

    /// One reattach attempt per five seconds at most.
    ///
    /// Reattaching costs four seconds when the phone is not there. Paying that for every file of a
    /// long copy would turn a pulled cable into twenty minutes of apparent hanging, so a failure
    /// buys a short silence before the next attempt is allowed.
    private var lastFailedReattach: Date?
    private func mayTryReattach() -> Bool {
        guard let last = lastFailedReattach else { return true }
        return Date().timeIntervalSince(last) > 5
    }

    /// Opens a new session in place, for a retry. Deliberately short: a copy is waiting on it, and a
    /// phone that needs longer than this is not coming back inside one command.
    ///
    /// Measured 20 Sep on a locked phone: three drops in nine minutes, every one of them back on the
    /// first attempt about three seconds later.
    private func reattachForRetry() -> Bool {
        closeSession()
        for attempt in 0 ..< 4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            if case .ready = tryAttach() {
                lastFailedReattach = nil
                return true
            }
        }
        lastFailedReattach = Date()
        status = .searching
        return false
    }
}
