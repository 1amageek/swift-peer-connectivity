import Synchronization

public final class PeerConnectivityEventBroadcaster<T: Sendable>: Sendable {
    private let state: Mutex<BroadcastState>

    private struct Entry: Sendable {
        let id: UInt64
        let continuation: AsyncStream<T>.Continuation
    }

    private struct BroadcastState: Sendable {
        var entries: [Entry] = []
        var nextID: UInt64 = 0
    }

    public init() {
        self.state = Mutex(BroadcastState())
    }

    deinit {
        let entries = state.withLock { state in
            let entries = state.entries
            state.entries.removeAll()
            return entries
        }
        for entry in entries {
            entry.continuation.finish()
        }
    }

    public func subscribe() -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream()
        let id = state.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID += 1
            state.entries.append(Entry(id: id, continuation: continuation))
            return id
        }

        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                state.entries.removeAll { $0.id == id }
            }
        }
        return stream
    }

    public func emit(_ event: T) {
        let entries = state.withLock { $0.entries }
        for entry in entries {
            entry.continuation.yield(event)
        }
    }

    public func shutdown() {
        let entries = state.withLock { state -> [Entry] in
            let entries = state.entries
            state.entries.removeAll()
            return entries
        }
        for entry in entries {
            entry.continuation.finish()
        }
    }
}
