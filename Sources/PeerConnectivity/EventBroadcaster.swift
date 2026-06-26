import Synchronization

public final class PeerConnectivityEventBroadcaster<T: Sendable>: Sendable {
    private let state: Mutex<BroadcastState>
    private let bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy

    private struct Entry: Sendable {
        let id: UInt64
        let continuation: AsyncStream<T>.Continuation
    }

    private struct BroadcastState: Sendable {
        var entries: [Entry] = []
        var nextID: UInt64 = 0
        var isShutdown = false
    }

    private enum SubscribeAction: Sendable {
        case registered(UInt64)
        case finishImmediately
    }

    public init(bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .bufferingNewest(1024)) {
        self.bufferingPolicy = bufferingPolicy
        self.state = Mutex(BroadcastState())
    }

    deinit {
        let entries = state.withLock { state in
            let entries = state.entries
            state.entries.removeAll()
            state.isShutdown = true
            return entries
        }
        for entry in entries {
            entry.continuation.finish()
        }
    }

    public func subscribe() -> AsyncStream<T> {
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: bufferingPolicy)
        let action = state.withLock { state -> SubscribeAction in
            guard !state.isShutdown else { return .finishImmediately }
            let id = state.nextID
            state.nextID += 1
            state.entries.append(Entry(id: id, continuation: continuation))
            return .registered(id)
        }

        switch action {
        case .registered(let id):
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { state in
                    state.entries.removeAll { $0.id == id }
                }
            }
        case .finishImmediately:
            continuation.finish()
        }
        return stream
    }

    public func emit(_ event: T) {
        let entries = state.withLock { state in
            state.isShutdown ? [] : state.entries
        }
        for entry in entries {
            entry.continuation.yield(event)
        }
    }

    public func shutdown() {
        let entries = state.withLock { state -> [Entry] in
            guard !state.isShutdown else { return [] }
            state.isShutdown = true
            let entries = state.entries
            state.entries.removeAll()
            return entries
        }
        for entry in entries {
            entry.continuation.finish()
        }
    }
}
