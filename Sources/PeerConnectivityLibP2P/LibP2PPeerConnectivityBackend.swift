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
    /// Maximum number of bytes accumulated for a single inbound message.
    ///
    /// Yamux fragments writes into window-sized frames (256 KB by default), so an
    /// inbound message must be reassembled by reading until end-of-stream. This cap
    /// bounds memory usage during reassembly; oversized messages fail with
    /// `PeerConnectivityError.messageTooLarge`.
    private static let maxInboundMessageBytes = 16 * 1024 * 1024

    private static let logger = Logger(label: "swift-peer-connectivity.libp2p")

    public let capabilities: PeerConnectivityCapabilities
    public nonisolated var events: AsyncStream<PeerConnectivityEvent> {
        eventBroadcaster.subscribe()
    }

    private let node: Node
    private let messageProtocolID: String
    private let resourceProtocolID: String
    private let eventBroadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private var tasks: [Task<Void, Never>] = []

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
        await node.handle(messageProtocolID) { [eventBroadcaster] context in
            await Self.handleMessageStream(context: context, eventBroadcaster: eventBroadcaster)
        }
        await node.handle(resourceProtocolID) { [eventBroadcaster] context in
            await Self.handleResourceStream(context: context, eventBroadcaster: eventBroadcaster)
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
            eventBroadcaster.emit(.error(error))
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
        return PeerConnectivityPeer(peerID: peerID)
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
            try await stream.write(bytes)
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
        case .connectionError(_, let error),
             .listenError(_, let error),
             .outgoingConnectionError(peer: _, error: let error):
            eventBroadcaster.emit(.error(error))
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

    private static func handleMessageStream(
        context: StreamContext,
        eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>
    ) async {
        do {
            let bytes = try await readMessage(from: context.stream)
            eventBroadcaster.emit(.messageReceived(
                bytes,
                from: PeerConnectivityPeer(peerID: context.remotePeer)
            ))
        } catch {
            eventBroadcaster.emit(.error(error))
        }
        // Always release the stream so the muxer can drop its stream entry.
        // `defer` cannot await, so the close runs after the do/catch instead.
        await closeReportingFailure(context.stream, label: "inbound message stream")
    }

    /// Reads a complete message by accumulating chunks until end-of-stream.
    ///
    /// Yamux fragments writes into window-sized frames (256 KB by default), so a
    /// single `read()` may return only the first fragment of a larger message.
    private static func readMessage(
        from stream: MuxedStream,
        maxBytes: Int = maxInboundMessageBytes
    ) async throws -> ByteBuffer {
        var output = ByteBuffer()
        while true {
            var chunk: ByteBuffer
            do {
                chunk = try await stream.read()
            } catch {
                // `MuxedStream` exposes no typed end-of-stream signal: after the
                // remote half-closes its write side and the buffer drains, read()
                // throws an error that is indistinguishable from other failures at
                // this layer (the Yamux error type is internal to the muxer module).
                // Data already accumulated means the remote sent a payload and we
                // reached its FIN, so deliver it; an empty accumulation means the
                // stream failed before any payload arrived, so propagate the error.
                if output.readableBytes > 0 {
                    return output
                }
                throw error
            }
            guard output.readableBytes + chunk.readableBytes <= maxBytes else {
                throw PeerConnectivityError.messageTooLarge(maxBytes)
            }
            output.writeBuffer(&chunk)
        }
    }

    private static func handleResourceStream(
        context: StreamContext,
        eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>
    ) async {
        do {
            let buffer = try await readResourceEnvelope(from: context.stream)
            let resource = try LibP2PResourceCodec.materializeResource(from: buffer)
            eventBroadcaster.emit(.resourceReceived(
                resource,
                from: PeerConnectivityPeer(peerID: context.remotePeer)
            ))
        } catch {
            eventBroadcaster.emit(.error(error))
        }
        // Always release the stream so the muxer can drop its stream entry.
        // `defer` cannot await, so the close runs after the do/catch instead.
        await closeReportingFailure(context.stream, label: "inbound resource stream")
    }

    /// Closes a stream whose handler has no caller to propagate errors to.
    ///
    /// Close failures are logged instead of being silently swallowed.
    private static func closeReportingFailure(_ stream: MuxedStream, label: String) async {
        do {
            try await stream.close()
        } catch {
            logger.warning("Failed to close \(label): \(error)")
        }
    }

    /// Resets a stream after a send failure.
    ///
    /// The caller propagates the original I/O error; a reset failure is logged
    /// instead of being silently swallowed.
    private static func resetReportingFailure(_ stream: MuxedStream, label: String) async {
        do {
            try await stream.reset()
        } catch {
            logger.warning("Failed to reset \(label): \(error)")
        }
    }

    private static func readResourceEnvelope(
        from stream: MuxedStream,
        maxBytes: Int = 100 * 1024 * 1024
    ) async throws -> ByteBuffer {
        var output = ByteBuffer()

        while true {
            if let totalLength = try LibP2PResourceCodec.expectedTotalLength(
                in: output,
                maxPayloadBytes: maxBytes
            ) {
                if output.readableBytes == totalLength {
                    return output
                }
                if output.readableBytes > totalLength {
                    throw PeerConnectivityError.invalidResource
                }
            }

            do {
                var chunk = try await stream.read()
                if chunk.readableBytes == 0 {
                    throw PeerConnectivityError.invalidResource
                }
                guard output.readableBytes + chunk.readableBytes <= maxBytes + 16 * 1024 else {
                    throw PeerConnectivityError.resourceTooLarge(maxBytes)
                }
                output.writeBuffer(&chunk)
            } catch {
                if let peerConnectivityError = error as? PeerConnectivityError {
                    throw peerConnectivityError
                }
                if output.readableBytes == 0 {
                    throw error
                }
                throw PeerConnectivityError.invalidResource
            }
        }
    }

    /// Writes the resource envelope (header + payload) to the stream.
    ///
    /// Stream lifecycle (close/reset) is owned by the caller. The file handle is
    /// closed exactly once: in the catch block on failure, or after the do block
    /// on success — never both, since the success-path close runs only when the
    /// do block did not throw.
    private static func writeResource(_ resource: PeerResource, to stream: MuxedStream) async throws {
        let handle = try FileHandle(forReadingFrom: resource.url)
        do {
            let size = try resourceSize(at: resource.url)
            try await stream.write(LibP2PResourceCodec.header(for: resource.name, size: size))
            while true {
                let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                if data.isEmpty {
                    break
                }
                var chunk = ByteBuffer()
                chunk.writeBytes(data)
                try await stream.write(chunk)
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

    private static func resourceSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PeerConnectivityError.invalidResource
        }
        return size.uint64Value
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
