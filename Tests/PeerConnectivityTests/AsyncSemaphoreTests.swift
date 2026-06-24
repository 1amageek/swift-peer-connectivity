import Foundation
import Synchronization
import Testing
@testable import PeerConnectivityLibP2P

/// Regression tests for `AsyncSemaphore`'s cancellation discipline.
///
/// The original implementation parked waiters in a plain
/// `[CheckedContinuation<Void, Never>]` with no cancellation handling: a task
/// cancelled while queued was never removed and never resumed, so it hung
/// forever and leaked its continuation. These tests pin the fix: a
/// cancelled-while-queued acquirer throws `CancellationError` promptly, its slot
/// is freed, a still-waiting acquirer is woken in its place (never the cancelled
/// one), and normal acquire/release still bounds concurrency to the permit cap.
@Suite("AsyncSemaphore Cancellation")
struct AsyncSemaphoreTests {
    /// Tracks the maximum number of bodies running concurrently, so a test can
    /// assert the semaphore never exceeds its permit cap.
    private final class ConcurrencyGauge: Sendable {
        private struct State {
            var current = 0
            var peak = 0
        }
        private let state = Mutex(State())

        func enter() {
            state.withLock { s in
                s.current += 1
                s.peak = max(s.peak, s.current)
            }
        }

        func leave() {
            state.withLock { $0.current -= 1 }
        }

        var peak: Int { state.withLock { $0.peak } }
    }

    /// A cancelled-while-queued acquirer throws `CancellationError` promptly
    /// instead of hanging, and a subsequent release wakes a different,
    /// still-waiting acquirer — proving the cancelled waiter was removed from the
    /// queue rather than left to be (wrongly) woken.
    @Test(.timeLimit(.minutes(1)))
    func cancelledWhileQueuedThrowsAndFreesSlot() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        // Hold the single permit with a body that blocks until we let it finish.
        let holderRunning = SignalBox()
        let releaseHolder = SignalBox()
        let holder = Task {
            try await semaphore.withPermit {
                holderRunning.signal()
                await releaseHolder.wait()
            }
        }
        await holderRunning.wait()

        // First waiter: queued behind the holder. It must be the one woken when
        // the holder releases — NOT the cancelled waiter below.
        let firstWaiterAcquired = SignalBox()
        let releaseFirstWaiter = SignalBox()
        let firstWaiter = Task {
            try await semaphore.withPermit {
                firstWaiterAcquired.signal()
                await releaseFirstWaiter.wait()
            }
        }

        // Second waiter: also queued. This is the one we cancel while parked.
        let cancelledWaiterEntered = SignalBox()
        let cancelledWaiter = Task {
            cancelledWaiterEntered.signal()
            try await semaphore.withPermit {
                Issue.record("cancelled waiter's body must never run")
            }
        }

        // Give both waiters time to actually park inside the semaphore. There is
        // no public hook to observe queue depth, so yield generously.
        await cancelledWaiterEntered.wait()
        for _ in 0..<50 { await Task.yield() }

        // Cancel the parked waiter: it must throw CancellationError promptly.
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }

        // The holder releases its permit. The freed permit must go to the FIRST
        // waiter (still queued), proving the cancelled waiter was removed and is
        // not woken in its place. If the cancelled waiter had stayed in the queue
        // and been woken instead, firstWaiterAcquired would never signal and this
        // would time out.
        releaseHolder.signal()
        try await holder.value
        await firstWaiterAcquired.wait()

        // Let the first waiter finish so the task tree drains cleanly.
        releaseFirstWaiter.signal()
        try await firstWaiter.value
    }

    /// Normal acquire/release bounds concurrency to the permit cap: with cap N
    /// and M > N tasks contending, no more than N bodies ever run at once, and
    /// every (uncancelled) task completes.
    @Test(.timeLimit(.minutes(1)))
    func boundsConcurrencyToPermitCap() async throws {
        let cap = 3
        let total = 12
        let semaphore = AsyncSemaphore(value: cap)
        let gauge = ConcurrencyGauge()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    try await semaphore.withPermit {
                        gauge.enter()
                        // Brief overlap window so contention is real.
                        for _ in 0..<5 { await Task.yield() }
                        gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(gauge.peak <= cap)
        #expect(gauge.peak >= 1)
    }

    /// A task cancelled *before* it reaches the suspension (permit unavailable)
    /// still throws `CancellationError` rather than taking a permit it cannot
    /// release — the `Task.isCancelled` fast path inside the continuation.
    @Test(.timeLimit(.minutes(1)))
    func alreadyCancelledTaskThrowsWithoutTakingPermit() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        // Exhaust the only permit and keep it held.
        let holderRunning = SignalBox()
        let releaseHolder = SignalBox()
        let holder = Task {
            try await semaphore.withPermit {
                holderRunning.signal()
                await releaseHolder.wait()
            }
        }
        await holderRunning.wait()

        // A task that is already cancelled before it tries to acquire must throw
        // and must NOT consume the permit (there is none) or get stuck.
        let preCancelled = Task {
            try await semaphore.withPermit {
                Issue.record("body must not run for an already-cancelled task")
            }
        }
        preCancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await preCancelled.value
        }

        // The held permit can still be released and re-acquired normally,
        // proving the cancelled task left the permit accounting intact.
        releaseHolder.signal()
        try await holder.value

        let acquiredAfter = SignalBox()
        try await semaphore.withPermit {
            acquiredAfter.signal()
        }
        #expect(acquiredAfter.isSignalled)
    }
}

/// A one-shot async signal: `wait()` suspends until `signal()` is called. Used
/// to coordinate the precise interleavings these cancellation tests require.
private final class SignalBox: Sendable {
    private struct State {
        var signalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { s in
            guard !s.signalled else { return [] }
            s.signalled = true
            let pending = s.waiters
            s.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadySignalled: Bool = state.withLock { s in
                if s.signalled {
                    return true
                }
                s.waiters.append(continuation)
                return false
            }
            if alreadySignalled {
                continuation.resume()
            }
        }
    }

    var isSignalled: Bool { state.withLock { $0.signalled } }
}
