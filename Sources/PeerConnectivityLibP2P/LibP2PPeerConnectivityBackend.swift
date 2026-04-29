import Foundation
import NIOCore
import P2P
import P2PCore
import P2PDiscovery
import P2PMux
import PeerConnectivity

public actor LibP2PPeerConnectivityBackend: PeerConnectivityBackend, PeerConnectivityJoining, PeerConnectivityStateProviding {
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

        tasks.append(Task { [node, eventBroadcaster] in
            for await event in node.events {
                Self.emit(nodeEvent: event, eventBroadcaster: eventBroadcaster)
            }
        })

        if let discovery = node.configuration.discovery {
            tasks.append(Task { [eventBroadcaster] in
                for await observation in discovery.observations {
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
            eventBroadcaster.emit(.error(error))
            throw error
        }
    }

    public func shutdown() async throws {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        try await node.shutdown()
        eventBroadcaster.shutdown()
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
        try await stream.write(bytes)
        try await stream.closeWrite()
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
        try await Self.writeResource(resource, to: stream)
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
            let bytes = try await context.stream.read()
            eventBroadcaster.emit(.messageReceived(
                bytes,
                from: PeerConnectivityPeer(peerID: context.remotePeer)
            ))
        } catch {
            eventBroadcaster.emit(.error(error))
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
            try handle.close()
            try await stream.closeWrite()
        } catch {
            do {
                try handle.close()
            } catch let closeError {
                assertionFailure("LibP2P resource file close failed: \(closeError)")
            }
            throw error
        }
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
