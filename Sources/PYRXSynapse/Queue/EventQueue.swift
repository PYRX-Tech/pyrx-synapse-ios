//
//  EventQueue.swift
//  PYRXSynapse
//
//  Disk-backed bounded FIFO queue for events that cannot be sent
//  immediately. Drains to `POST /v1/events` with exponential backoff. All
//  state is serialised through an `actor` — concurrent `enqueue` / drain
//  calls cannot interleave.
//
//  Persistence model
//  =================
//
//    Path: <Caches>/com.pyrx.synapse/event_queue.jsonl
//
//    Format: JSONL — one `QueuedEvent` per line. Whole file is rewritten
//    on every mutation (enqueue, drop, attempt-bump). For the queue sizes
//    we target (≤ 1000 events, ~500 bytes each → ≤ 500 KB) a full rewrite
//    is faster and simpler than maintaining an append-only log with
//    compaction. If a future PR needs higher throughput, the swap point
//    is `persist(events:)` below.
//
//    Crash-safety: writes via `Data.write(to:options:.atomic)` so a crash
//    mid-write leaves the previous file intact. We accept that an event
//    enqueued but not yet persisted may be lost on a hard kill — the
//    alternative (fsync-per-event) is too expensive for the modest
//    durability guarantee this queue claims.
//
//  Bounding
//  ========
//
//    `maxQueueSize` is enforced on enqueue. On overflow we drop the OLDEST
//    event(s) — FIFO eviction — so the queue always reflects the most
//    recent user activity. This matches the browser SDK's
//    `MAX_QUEUE_SIZE` overflow behavior.
//
//  Retry policy
//  ============
//
//    On drain failure:
//
//      * Transport error (no HTTP response: DNS, timeout, etc.) — retain
//        the event, schedule next attempt after exponential backoff.
//
//      * HTTP 4xx — DROP the event and log a warning. 4xx means the event
//        is malformed (bad shape, bad external_id, schema validation
//        failure). Infinite retry of a malformed event would block every
//        good event behind it indefinitely.
//
//      * HTTP 5xx — retain the event, schedule next attempt after
//        exponential backoff.
//
//    Backoff schedule: 1s, 2s, 4s, 8s, 16s, then capped at 60s. Counter
//    resets on the first successful drain.
//
//  Drain triggers
//  ==============
//
//    1. Explicit call from `EventsManager.enqueue(...)` after appending a
//       new event — gives near-immediate flush when online.
//    2. Reachability flip from `.unsatisfied` to `.satisfied` (network
//       came back) — fires the drain loop without waiting for the next
//       backoff tick.
//    3. SDK init (`Pyrx.initialize(config:)`) calls `drainNow()` once
//       so events accumulated while the app was killed flush on relaunch.
//
//  Concurrency
//  ===========
//
//    The actor-protected state is `events: [QueuedEvent]` + a single
//    `drainTask: Task<Void, Never>?`. `enqueue` and `drainNow` both
//    re-use the same in-flight task — only one drain is ever running at
//    once across the SDK.
//

import Foundation

// MARK: - Filesystem seam

/// File-system seam — production binds to a real `URL` under `<Caches>`;
/// tests bind to a per-test temp directory.
protocol QueueFileStore: Sendable {
    /// Read all persisted lines. Returns an empty array if the file does
    /// not exist yet (cold start).
    func read() throws -> Data?

    /// Atomically replace the queue file with `data`. `data` may be empty
    /// (queue drained to nothing); in that case the file is truncated to
    /// 0 bytes rather than deleted, so future writes do not race against
    /// directory creation.
    func write(_ data: Data) throws
}

/// Concrete `QueueFileStore` backed by a file under `<Caches>/com.pyrx.synapse`.
/// Creates the parent directory on first write.
final class FileSystemQueueStore: QueueFileStore, @unchecked Sendable {
    private let fileURL: URL
    private let directoryURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.fileManager = fileManager
    }

    /// Convenience initializer that resolves the standard production path:
    /// `<Caches>/com.pyrx.synapse/event_queue.jsonl`.
    convenience init() throws {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = caches.appendingPathComponent("com.pyrx.synapse", isDirectory: true)
        let file = dir.appendingPathComponent("event_queue.jsonl")
        self.init(fileURL: file)
    }

    func read() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func write(_ data: Data) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Clock seam (for backoff tests)

/// Sleep seam — production sleeps via `Task.sleep`; tests inject a no-op
/// implementation so unit tests do not actually pause for 1+ seconds.
protocol QueueClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemClock: QueueClock {
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

// MARK: - EventQueue

/// Disk-backed, bounded, retrying event queue. One instance per SDK.
///
/// Construction is cheap — no I/O until the first `enqueue` / `drainNow`.
/// The first `drainNow()` performs a lazy load from disk so events that
/// were enqueued in a previous app session are picked up on relaunch.
actor EventQueue {

    // MARK: - Dependencies

    private let httpClient: HTTPClient
    private let store: QueueFileStore
    private let logger: PyrxLogger
    private let clock: QueueClock
    private let maxQueueSize: Int

    // MARK: - State

    /// In-memory mirror of the on-disk queue. Loaded lazily on first use.
    private var events: [QueuedEvent] = []

    /// Tracks whether we have read the on-disk file at least once.
    private var loaded = false

    /// Single in-flight drain task. `enqueue` / `drainNow` await this
    /// rather than starting a parallel drain.
    private var drainTask: Task<Void, Never>?

    /// Exponential-backoff retry counter. Reset to 0 on success.
    private var consecutiveFailures = 0

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Tunables (exposed for tests)

    /// Maximum events POSTed in a single drain pass. The wire endpoint is
    /// single-event today (no batch endpoint on `/v1/events`), so this is
    /// the maximum number of sequential POSTs per drain. Capped at 100 to
    /// keep one drain bounded — anything beyond waits for the next trigger.
    nonisolated static var maxPerDrain: Int { 100 }

    /// Exponential backoff schedule. `consecutiveFailures` indexes into this
    /// array; values past the end clamp to the final value (60s cap).
    nonisolated static var backoffNanos: [UInt64] {
        [
            1_000_000_000,   // 1s
            2_000_000_000,   // 2s
            4_000_000_000,   // 4s
            8_000_000_000,   // 8s
            16_000_000_000,  // 16s
            60_000_000_000,  // 60s cap
        ]
    }

    /// Maximum retries the FIRST event may consume within a single drain
    /// pass before we yield to the next trigger. Keeps one bad event from
    /// monopolising drain time when transient errors persist.
    nonisolated static var maxRetriesPerPass: Int { 6 }

    // MARK: - Init

    init(
        httpClient: HTTPClient,
        store: QueueFileStore,
        maxQueueSize: Int,
        logger: PyrxLogger = .shared,
        clock: QueueClock = SystemClock()
    ) {
        self.httpClient = httpClient
        self.store = store
        self.maxQueueSize = max(1, maxQueueSize) // refuse zero — that disables queueing entirely
        self.logger = logger
        self.clock = clock
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API (actor-isolated)

    /// Append `event` to the queue, persist, and trigger a drain. The
    /// caller does NOT await the drain — `enqueue` returns as soon as the
    /// event is durably on disk.
    ///
    /// Returns the number of events on disk AFTER the enqueue + bound
    /// enforcement (so tests can assert FIFO eviction without reading the
    /// file back).
    @discardableResult
    func enqueue(_ event: QueuedEvent) async throws -> Int {
        try await loadIfNeeded()
        events.append(event)

        // Enforce bound — drop OLDEST to keep most-recent activity.
        if events.count > maxQueueSize {
            let overflow = events.count - maxQueueSize
            events.removeFirst(overflow)
            logger.warning("EventQueue overflow — dropped \(overflow) oldest event(s)")
        }

        try persist()

        // Kick a drain — non-blocking, fire-and-forget.
        startDrainIfIdle()

        return events.count
    }

    /// Drain now and wait for the in-flight pass to complete. Used by
    /// `Pyrx.initialize` to ensure pre-existing events get a shot at
    /// flushing on cold start.
    func drainNow() async {
        try? await loadIfNeeded()
        startDrainIfIdle()
        await drainTask?.value
    }

    /// Bind a `Reachability` source. On every `.satisfied` transition the
    /// queue triggers a drain. The subscription survives for the queue's
    /// lifetime — `EventQueue` outlives `Reachability` because both are
    /// owned by `Pyrx`.
    func bindReachability(_ reachability: Reachability) {
        let stream = reachability.start()
        Task { [weak self] in
            for await status in stream {
                guard let self else { break }
                if status == .satisfied {
                    await self.drainNow()
                }
            }
        }
    }

    /// In-memory event count — used by tests to assert size without going
    /// to disk. Exposed via `internal` for test target visibility.
    var count: Int { events.count }

    // MARK: - Private — drain loop

    private func startDrainIfIdle() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainLoop()
            await self?.clearDrainTask()
        }
    }

    private func clearDrainTask() {
        drainTask = nil
    }

    /// One drain pass. Pops events FIFO, POSTs each. Bounded by both
    /// `maxPerDrain` (iteration cap so one drain pass cannot starve other
    /// work) and `maxRetriesPerPass` (so a single persistently-failing
    /// event cannot consume the entire iteration budget).
    ///
    /// Outcomes per iteration:
    ///   * .success         → remove from queue, persist, reset failure counter
    ///   * .dropMalformed   → remove from queue, persist, warn (do NOT reset
    ///                        failure counter — a 4xx flood must not
    ///                        artificially shorten the backoff window for
    ///                        subsequent transient failures)
    ///   * .retry           → bump attempt counter, persist, back off, then
    ///                        either continue this pass (within retry budget)
    ///                        or exit and let the next trigger pick up
    private func drainLoop() async {
        var iterations = 0
        var retriesThisPass = 0

        while !events.isEmpty, iterations < Self.maxPerDrain {
            iterations += 1
            let event = events[0]

            let outcome = await postOne(event)

            switch outcome {
            case .success:
                events.removeFirst()
                try? persist()
                consecutiveFailures = 0
                retriesThisPass = 0 // network recovered — reset per-pass cap

            case .dropMalformed(let statusCode):
                events.removeFirst()
                try? persist()
                logger.warning(
                    "EventQueue dropped event id=\(event.id) name=\(event.eventName) " +
                    "due to HTTP \(statusCode) (malformed event, not retrying)"
                )

            case .retry:
                // Bump attempt counter on the in-place event, persist.
                events[0].attemptCount += 1
                try? persist()

                consecutiveFailures += 1
                retriesThisPass += 1

                // If a single event has burned through the retry budget
                // for this pass, exit — the next trigger (next track call,
                // next reachability change, next launch) will re-enter the
                // drain loop with a fresh budget.
                if retriesThisPass >= Self.maxRetriesPerPass {
                    logger.info(
                        "EventQueue drain paused — \(retriesThisPass) retries this pass exhausted; " +
                        "remaining=\(events.count)"
                    )
                    return
                }

                let backoff = Self.backoffNanos[
                    min(consecutiveFailures - 1, Self.backoffNanos.count - 1)
                ]
                logger.info(
                    "EventQueue retry attempt=\(consecutiveFailures) " +
                    "backoff=\(backoff / 1_000_000_000)s remaining=\(events.count)"
                )
                do {
                    try await clock.sleep(nanoseconds: backoff)
                } catch {
                    // Task was cancelled (e.g., SDK teardown). Exit cleanly
                    // — the events remain on disk for the next drain.
                    return
                }
            }
        }

        if events.isEmpty {
            logger.debug("EventQueue drained — 0 events remaining")
        } else {
            logger.debug("EventQueue drain paused — \(events.count) event(s) remaining")
        }
    }

    /// Result of attempting one event POST.
    private enum DrainOutcome {
        case success
        case dropMalformed(statusCode: Int)
        case retry
    }

    private func postOne(_ event: QueuedEvent) async -> DrainOutcome {
        do {
            let _: EventAcceptedResponse = try await httpClient.post(
                .events,
                body: event.toWireRequest(),
                responseType: EventAcceptedResponse.self
            )
            return .success
        } catch let PyrxError.network(.httpStatus(statusCode, _)) where (400..<500).contains(statusCode) {
            return .dropMalformed(statusCode: statusCode)
        } catch {
            return .retry
        }
    }

    // MARK: - Private — persistence

    /// Load the queue from disk if we have not done so yet. No-op on
    /// repeat calls within the actor's lifetime.
    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        loaded = true

        guard let data = try store.read(), !data.isEmpty else {
            events = []
            return
        }

        // JSONL: split on newline, decode each line. Lines that fail to
        // decode are dropped with a warning (corrupted persistence is
        // recoverable — we'd rather lose one event than wedge the queue).
        let lines = data.split(separator: 0x0A) // newline
        var decoded: [QueuedEvent] = []
        decoded.reserveCapacity(lines.count)
        for line in lines where !line.isEmpty {
            do {
                let event = try decoder.decode(QueuedEvent.self, from: Data(line))
                decoded.append(event)
            } catch {
                logger.warning("EventQueue dropping corrupted line on load: \(error)")
            }
        }
        events = decoded

        if events.count > maxQueueSize {
            let overflow = events.count - maxQueueSize
            events.removeFirst(overflow)
            logger.warning(
                "EventQueue loaded \(events.count + overflow) events but max=\(maxQueueSize)" +
                " — evicted \(overflow) oldest"
            )
            try persist()
        }
    }

    /// Atomically replace the queue file with the current in-memory state.
    private func persist() throws {
        if events.isEmpty {
            try store.write(Data())
            return
        }

        var buffer = Data()
        for event in events {
            let lineData = try encoder.encode(event)
            buffer.append(lineData)
            buffer.append(0x0A) // newline terminator
        }
        try store.write(buffer)
    }
}
