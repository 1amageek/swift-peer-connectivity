import Foundation
import Logging
import NIOCore
import P2P
import P2PCore
import P2PDiscovery
import P2PMux
import PeerConnectivity

/// A `PeerConnectivityBackend` implementation backed by a libp2p `Node`.
///
/// - Important: This backend takes exclusive ownership of `node.events`.
///   `Node` follows the single-consumer `EventEmitting` pattern, so no other
///   component may consume the node's event stream while this backend is in use.
public actor LibP2PPeerConnectivityBackend: PeerConnectivityBackend, PeerConnectivityJoining, PeerConnectivityStateProviding {
    /// Maximum number of bytes accepted for a single inbound message.
    private static let maxInboundMessageBytes = 16 * 1024 * 1024

    /// Maximum number of bytes accepted for an inbound resource payload.
    private static let maxInboundResourceBytes = 100 * 1024 * 1024

    /// Idle timeout applied to each inbound `read()`. A stalled peer that sends
    /// no data within this window has its stream closed instead of pinning the
    /// handler task and a muxer stream indefinitely.
    private static let inboundReadIdleTimeout: Duration = .seconds(60)

    /// Maximum number of concurrent inbound resource transfers. Bounds memory
    /// and file-handle pressure under load.
    private static let maxConcurrentInboundResources = 8

    private static let logger = Logger(label: "swift-peer-connectivity.libp2p")

    public let capabilities: PeerConnectivityCapabilities
    public nonisolated var events: AsyncStream<PeerConnectivityEvent> {
        eventBroadcaster.subscribe()
    }

    private let node: Node
    private let messageProtocolID: String
    private let resourceProtocolID: String
    private nonisolated let eventBroadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()

    /// Tasks monitoring node events and discovery observations.
    private var tasks: [Task<Void, Never>] = []

    /// Tracks in-flight inbound handler work so `shutdown()` can cancel it
    /// deterministically. `read()` loops honor cancellation, so cancelling these
    /// tasks releases their muxer streams promptly.
    private let inboundTasks = InboundTaskRegistry()

    /// Limits concurrent inbound resource transfers.
    private let resourceSemaphore = AsyncSemaphore(value: maxConcurrentInboundResources)

    public init(
        node: Node,
        capabilities: PeerConnectivityCapabilities? = nil,
        messageProtocolID: String = "/peer-connectivity/message/1.0.0",
        resourceProtocolID: String = "/peer-connectivity/resource/1.0.0"
    ) {
        self.node = node
        self.capabilities = capabilities ?? Self.defaultCapabilities(for: node)
        self.messageProtocolID = messageProtocolID
        self.resourceProtocolID = resourceProtocolID
    }

    public func start() async throws {
        let inboundTasks = self.inboundTasks
        let resourceSemaphore = self.resourceSemaphore

        await node.handle(messageProtocolID) { [eventBroadcaster] context in
            await Self.runInboundHandler(registry: inboundTasks) {
                await Self.handleMessageStream(context: context, eventBroadcaster: eventBroadcaster)
            }
        }
        await node.handle(resourceProtocolID) { [eventBroadcaster] context in
            await Self.runInboundHandler(registry: inboundTasks) {
                do {
                    try await resourceSemaphore.withPermit {
                        await Self.handleResourceStream(context: context, eventBroadcaster: eventBroadcaster)
                    }
                } catch {
                    // The only error `withPermit` throws is `CancellationError`,
                    // raised when this task was cancelled while queued for a
                    // permit (backend shutdown). The handler body never ran, so
                    // its stream was never closed — release it here so the muxer
                    // drops the stream entry, then unwind quietly. Cancellation
                    // is propagated as a deliberate teardown, not swallowed as a
                    // successful transfer.
                    await Self.closeReportingFailure(context.stream, label: "inbound resource stream (cancelled while queued)")
                }
            }
        }

        // Capture the stream synchronously before spawning the task. `node.events`
        // is backed by a single-consumer EventChannel that drops events emitted
        // before its stream getter is first accessed; deferring the access to the
        // task body would race with `node.start()` and lose early events.
        let nodeEvents = node.events
        tasks.append(Task { [eventBroadcaster] in
            for await event in nodeEvents {
                Self.emit(nodeEvent: event, eventBroadcaster: eventBroadcaster)
            }
        })

        if let discovery = node.configuration.discovery {
            // Subscribe synchronously before spawning the task for the same reason
            // as `node.events` above: observations emitted between `node.start()`
            // and the task body running would otherwise be lost.
            let observations = discovery.observations
            tasks.append(Task { [eventBroadcaster] in
                for await observation in observations {
                    let endpoints = observation.hints.map { address in
                        PeerConnectivityEndpoint.libp2p(address.description)
                    }
                    let peer = PeerConnectivityPeer(peerID: observation.subject, endpoints: endpoints)
                    switch observation.kind {
                    case .announcement, .reachable:
                        eventBroadcaster.emit(.peerDiscovered(peer, endpoints: endpoints))
                    case .unreachable:
                        eventBroadcaster.emit(.peerLost(peer))
                    }
                }
            })
        }

        do {
            try await node.start()
        } catch {
            // Roll back the partial start: cancel the monitoring tasks spawned above
            // and finish the event stream so subscribers of a backend that never
            // started do not hang on `for await`.
            for task in tasks {
                task.cancel()
            }
            tasks.removeAll()
            await inboundTasks.cancelAll()
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .start, error: error)))
            eventBroadcaster.shutdown()
            throw error
        }
    }

    public func shutdown() async throws {
        // Finish the event stream even when node shutdown throws, so subscribers
        // iterating `events` always terminate.
        defer { eventBroadcaster.shutdown() }
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        // Cancel in-flight inbound handler work so their read loops unwind and
        // release their muxer streams before the node tears down.
        await inboundTasks.cancelAll()
        try await node.shutdown()
    }

    public func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        guard case .libp2p(let addressValue) = endpoint else {
            throw PeerConnectivityError.unsupportedEndpoint(endpoint)
        }
        let address: Multiaddr
        do {
            address = try Multiaddr(addressValue)
        } catch {
            throw PeerConnectivityError.unsupportedEndpoint(endpoint)
        }
        let peerID = try await node.connect(to: address)
        // Carry the dialed address into the returned peer's endpoints so the peer
        // round-trips through `join`/`connect`: re-joining a returned peer must
        // reach the same address, even when the dialed address omitted the peer
        // ID component.
        let endpoints = Self.endpoints(forDialed: address, peerID: peerID)
        return PeerConnectivityPeer(peerID: peerID, endpoints: endpoints)
    }

    /// Produces the endpoints to attach to a peer returned from a successful dial.
    ///
    /// The dialed address is normalized to include the resolved peer ID so a
    /// later `join` reaches the same node deterministically.
    private static func endpoints(forDialed address: Multiaddr, peerID: PeerID) -> [PeerConnectivityEndpoint] {
        if address.hasPeerID {
            return [.libp2p(address.description)]
        }
        do {
            let withPeer = try address.appending(.p2p(peerID))
            return [.libp2p(withPeer.description)]
        } catch {
            return [.libp2p(address.description)]
        }
    }

    public func disconnect(from peer: PeerConnectivityPeer) async throws {
        let peerID = try Self.peerID(from: peer)
        await node.disconnect(from: peerID)
    }

    public func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer {
        guard let endpoint = peer.endpoints.first else {
            throw PeerConnectivityError.unsupportedOperation("join")
        }
        return try await connect(to: endpoint)
    }

    public func localPeer() async throws -> PeerConnectivityPeer {
        PeerConnectivityPeer(peerID: await node.peerID)
    }

    public func connectedPeers() async throws -> [PeerConnectivityPeer] {
        let peers = await node.connectedPeers
        return peers.map { peerID in
            PeerConnectivityPeer(peerID: peerID)
        }
    }

    public func send(
        _ bytes: ByteBuffer,
        to peer: PeerConnectivityPeer,
        mode: PeerSendMode
    ) async throws {
        let peerID = try Self.peerID(from: peer)
        let stream = try await node.newStream(to: peerID, protocol: messageProtocolID)
        do {
            // Length-prefix the message so the receiver can detect truncation:
            // an incomplete frame is a typed failure, never a complete message.
            try await stream.writeLengthPrefixedMessage(bytes)
        } catch {
            await Self.resetReportingFailure(stream, label: "outbound message stream")
            throw error
        }
        // Full close (not just closeWrite) so the muxer releases its stream entry
        // on our side; the remote releases its entry when it observes the FIN.
        try await stream.close()
    }

    public func openChannel(
        to peer: PeerConnectivityPeer,
        protocol protocolID: String
    ) async throws -> any PeerConnectivityChannel {
        let peerID = try Self.peerID(from: peer)
        let stream = try await node.newStream(to: peerID, protocol: protocolID)
        return LibP2PPeerConnectivityChannel(peer: peer, stream: stream)
    }

    public func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {
        let peerID = try Self.peerID(from: peer)

        let stream = try await node.newStream(to: peerID, protocol: resourceProtocolID)
        do {
            try await Self.writeResource(resource, to: stream)
        } catch {
            await Self.resetReportingFailure(stream, label: "outbound resource stream")
            throw error
        }
        // Full close (not just closeWrite) so the muxer releases its stream entry
        // on our side; the remote releases its entry when it observes the FIN.
        try await stream.close()
    }

    private static func emit(
        nodeEvent: NodeEvent,
        eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>
    ) {
        switch nodeEvent {
        case .peerConnected(let peerID):
            eventBroadcaster.emit(.peerConnected(PeerConnectivityPeer(peerID: peerID)))
        case .peerDisconnected(let peerID):
            eventBroadcaster.emit(.peerDisconnected(PeerConnectivityPeer(peerID: peerID)))
        case .connectionError(let peerID, let error),
             .outgoingConnectionError(peer: let peerID, error: let error):
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(
                operation: .connect,
                peer: peerID.map { PeerConnectivityPeer(peerID: $0) },
                error: error
            )))
        case .listenError(_, let error):
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .listen, error: error)))
        default:
            break
        }
    }

    private static func defaultCapabilities(for node: Node) -> PeerConnectivityCapabilities {
        var capabilities: PeerConnectivityCapabilities = [
            .libp2pInterop,
            .messageSend,
            .streamMultiplexing,
            .resourceTransfer
        ]
        if !node.configuration.listenAddresses.isEmpty {
            capabilities.insert(.inboundListening)
        }
        return capabilities
    }

    /// Runs an inbound handler body inside a tracked, cancellable task and awaits
    /// it, so the node holds the stream until the body completes while
    /// `shutdown()` can still cancel the body deterministically.
    private static func runInboundHandler(
        registry: InboundTaskRegistry,
        _ body: @escaping @Sendable () async -> Void
    ) async {
        let task = Task { await body() }
        let id = await registry.register(task)
        await task.value
        await registry.remove(id)
    }

    private static func handleMessageStream(
        context: StreamContext,
        eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>
    ) async {
        let peer = PeerConnectivityPeer(peerID: context.remotePeer)
        do {
            let bytes = try await readMessage(from: context.stream)
            eventBroadcaster.emit(.messageReceived(bytes, from: peer))
        } catch is CancellationError {
            // Backend shutdown: unwind quietly, then release the stream below.
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(
                operation: .inboundMessage,
                peer: peer,
                error: error
            )))
        }
        // Always release the stream so the muxer can drop its stream entry.
        // `defer` cannot await, so the close runs after the do/catch instead.
        await closeReportingFailure(context.stream, label: "inbound message stream")
    }

    /// Reads a single length-prefixed message, honoring cancellation and an idle
    /// read timeout. Truncation surfaces as a typed `StreamMessageError`/
    /// `incompleteMessage` rather than being delivered as a complete message.
    private static func readMessage(
        from stream: MuxedStream,
        maxBytes: Int = maxInboundMessageBytes
    ) async throws -> ByteBuffer {
        try Task.checkCancellation()
        return try await withIdleTimeout(stream: stream) {
            try await stream.readLengthPrefixedMessage(maxSize: UInt64(maxBytes))
        }
    }

    private static func handleResourceStream(
        context: StreamContext,
        eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>
    ) async {
        let peer = PeerConnectivityPeer(peerID: context.remotePeer)
        do {
            let resource = try await receiveResource(from: context.stream)
            eventBroadcaster.emit(.resourceReceived(resource, from: peer))
        } catch is CancellationError {
            // Backend shutdown: unwind quietly, then release the stream below.
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(
                operation: .inboundResource,
                peer: peer,
                error: error
            )))
        }
        // Always release the stream so the muxer can drop its stream entry.
        // `defer` cannot await, so the close runs after the do/catch instead.
        await closeReportingFailure(context.stream, label: "inbound resource stream")
    }

    /// Streams an inbound resource directly to a temp file as chunks arrive.
    ///
    /// Only the header is held in memory; payload chunks are appended to disk so
    /// memory is bounded regardless of resource size. The header carries the
    /// exact payload size, so a stream that ends early is reported as
    /// `incompleteMessage` and the partial file is removed — never delivered.
    private static func receiveResource(
        from stream: MuxedStream,
        maxBytes: Int = maxInboundResourceBytes
    ) async throws -> PeerResource {
        try Task.checkCancellation()

        let headerBuffer = try await withIdleTimeout(stream: stream) {
            try await stream.readLengthPrefixedMessage(maxSize: UInt64(LibP2PResourceCodec.maxHeaderBytes))
        }
        let header = try LibP2PResourceCodec.parseHeaderFrame(headerBuffer)
        guard header.size <= maxBytes else {
            throw PeerConnectivityError.resourceTooLarge(maxBytes)
        }

        let fileURL = try LibP2PResourceCodec.destinationURL(for: header.name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        var received = 0
        do {
            while received < header.size {
                try Task.checkCancellation()
                var chunk = try await withIdleTimeout(stream: stream) {
                    try await stream.readLengthPrefixedMessage(maxSize: UInt64(LibP2PResourceCodec.maxChunkBytes))
                }
                let count = chunk.readableBytes
                guard count > 0 else {
                    throw PeerConnectivityError.incompleteMessage(expected: header.size, received: received)
                }
                guard received + count <= header.size else {
                    throw PeerConnectivityError.invalidResource
                }
                if let bytes = chunk.readBytes(length: count) {
                    try handle.write(contentsOf: Data(bytes))
                }
                received += count
            }
            try handle.close()
        } catch {
            do {
                try handle.close()
            } catch let closeError {
                logger.warning("Failed to close inbound resource file handle: \(closeError)")
            }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch let removeError {
                logger.warning("Failed to remove partial inbound resource file: \(removeError)")
            }
            // A read failure mid-transfer is truncation: surface it as a typed
            // failure rather than delivering a partial file.
            if error is CancellationError || error is PeerConnectivityError {
                throw error
            }
            throw PeerConnectivityError.incompleteMessage(expected: header.size, received: received)
        }

        return PeerResource(url: fileURL, name: header.name)
    }

    /// Runs an inbound `read`-based operation under an idle timeout: if it does
    /// not complete within `inboundReadIdleTimeout`, the stream is reset and a
    /// `readTimeout` is thrown.
    private static func withIdleTimeout<R: Sendable>(
        stream: MuxedStream,
        _ operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        try await withThrowingTaskGroup(of: R.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: inboundReadIdleTimeout)
                throw PeerConnectivityError.readTimeout
            }
            do {
                guard let result = try await group.next() else {
                    throw PeerConnectivityError.readTimeout
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if case PeerConnectivityError.readTimeout = error {
                    await resetReportingFailure(stream, label: "timed-out inbound stream")
                }
                throw error
            }
        }
    }

    /// Closes a stream whose handler has no caller to propagate errors to.
    private static func closeReportingFailure(_ stream: MuxedStream, label: String) async {
        do {
            try await stream.close()
        } catch {
            logger.warning("Failed to close \(label): \(error)")
        }
    }

    /// Resets a stream after a send failure. The caller propagates the original
    /// I/O error; a reset failure is logged instead of being silently swallowed.
    private static func resetReportingFailure(_ stream: MuxedStream, label: String) async {
        do {
            try await stream.reset()
        } catch {
            logger.warning("Failed to reset \(label): \(error)")
        }
    }

    /// Writes the resource as length-prefixed frames: a header frame followed by
    /// payload chunk frames.
    ///
    /// File reads are performed off the cooperative pool (`Task.detached`) so a
    /// large resource does not occupy a cooperative thread with blocking file
    /// I/O. Stream lifecycle (close/reset) is owned by the caller. The file
    /// handle is closed exactly once.
    private static func writeResource(_ resource: PeerResource, to stream: MuxedStream) async throws {
        let handle = try FileHandle(forReadingFrom: resource.url)
        do {
            let size = try resourceSize(at: resource.url)
            try await stream.writeLengthPrefixedMessage(
                LibP2PResourceCodec.header(for: resource.name, size: size)
            )
            while true {
                try Task.checkCancellation()
                let data = try await readChunk(from: handle, upToCount: 64 * 1024)
                if data.isEmpty {
                    break
                }
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await stream.writeLengthPrefixedMessage(buffer)
            }
        } catch {
            do {
                try handle.close()
            } catch let closeError {
                // The original write error is propagated below; the close failure
                // is logged instead of being silently swallowed.
                logger.warning("Failed to close resource file handle after write failure: \(closeError)")
            }
            throw error
        }
        try handle.close()
    }

    /// Reads up to `count` bytes from `handle` off the cooperative pool.
    private static func readChunk(from handle: FileHandle, upToCount count: Int) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try handle.read(upToCount: count) ?? Data()
        }.value
    }

    private static func resourceSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PeerConnectivityError.invalidResource
        }
        return size.uint64Value
    }

    /// Number of in-flight inbound handler tasks. Exposed for tests to verify
    /// deterministic teardown on `shutdown()`.
    func inboundTaskCountForTesting() async -> Int {
        await inboundTasks.count
    }

    private static func peerID(from peer: PeerConnectivityPeer) throws -> PeerID {
        guard case .backend(kind: "libp2p", value: let value)? = peer.identity else {
            throw PeerConnectivityError.peerIdentityRequired
        }

        do {
            return try PeerID(string: value)
        } catch {
            throw PeerConnectivityError.peerIdentityRequired
        }
    }

}

/// Tracks in-flight inbound handler tasks so they can be cancelled on teardown.
actor InboundTaskRegistry {
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    func register(_ task: Task<Void, Never>) -> UInt64 {
        let id = nextID
        nextID += 1
        tasks[id] = task
        return id
    }

    func remove(_ id: UInt64) {
        tasks.removeValue(forKey: id)
    }

    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    var count: Int { tasks.count }
}

/// A minimal async counting semaphore for bounding concurrent transfers.
///
/// Implemented with an actor so acquiring suspends (never blocks a thread) when
/// no permits are available.
///
/// Cancellation discipline mirrors `SWIMCluster.resolveProbe`: each suspended
/// waiter is keyed by a unique, monotonically increasing id, and its
/// continuation is resumed exactly once — by EITHER `release()` (success) OR
/// `cancelWaiter` (`CancellationError`), whichever first removes it from
/// `waiters`. The losing path finds the id absent and does nothing. Because the
/// actor serializes every access, this membership check is the exactly-once
/// guard and the two paths cannot race.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID: UInt64 = 0

    init(value: Int) {
        self.permits = value
    }

    /// Suspends until a permit is available or the calling task is cancelled.
    ///
    /// Throws `CancellationError` if the task is cancelled while queued (or was
    /// already cancelled on entry to the suspension); in that case NO permit is
    /// taken, so the caller must NOT release one.
    private func acquire() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    // Already cancelled before we parked: resume immediately and
                    // never enter `waiters`, so `cancelWaiter`/`release` find
                    // nothing to resume.
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Removes and fails the queued waiter `id` with `CancellationError`, exactly
    /// once. If the id is absent (already resumed by `release()`), this is a
    /// no-op — membership in `waiters` is the exactly-once guard.
    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Releases one permit, waking the oldest queued waiter (if any) with
    /// success. The woken waiter is removed by the same membership rule that
    /// `cancelWaiter` honors, so a concurrently cancelled waiter is never woken
    /// in its place.
    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: ())
        } else {
            permits += 1
        }
    }

    /// Runs `body` while holding one permit, releasing it exactly once afterward.
    ///
    /// Throws `CancellationError` if the task is cancelled while queued for a
    /// permit. In that case `acquire()` threw before `defer` was registered, so
    /// no permit is released — there is none to release.
    func withPermit(_ body: @Sendable () async -> Void) async throws {
        try await acquire()
        defer { release() }
        await body()
    }
}

public struct LibP2PPeerConnectivityChannel: PeerConnectivityChannel {
    public let peer: PeerConnectivityPeer
    private let stream: MuxedStream

    public var protocolID: String? {
        stream.protocolID
    }

    public init(peer: PeerConnectivityPeer, stream: MuxedStream) {
        self.peer = peer
        self.stream = stream
    }

    public func read() async throws -> ByteBuffer {
        try await stream.read()
    }

    public func write(_ bytes: ByteBuffer) async throws {
        try await stream.write(bytes)
    }

    public func close() async throws {
        try await stream.close()
    }
}

extension PeerConnectivityPeer {
    init(
        peerID: PeerID,
        endpoints: [PeerConnectivityEndpoint] = [],
        metadata: [String: String] = [:]
    ) {
        self.init(
            id: peerID.description,
            displayName: peerID.shortDescription,
            identity: .backend(kind: "libp2p", value: peerID.description),
            endpoints: endpoints,
            metadata: metadata
        )
    }
}
