import Foundation
import NIOCore
import NIOFoundationCompat
import P2P
import P2PCore
import P2PMuxYamux
import PeerConnectivity
import P2PSecurityPlaintext
import P2PTransportMemory
import Synchronization
import Testing
@testable import PeerConnectivityLibP2P

#if canImport(MultipeerConnectivity)
import PeerConnectivityMultipeer
#endif

@Suite("PeerConnectivity Session Tests")
struct PeerConnectivitySessionTests {
    @Test(.timeLimit(.minutes(1)))
    func requireCapabilitiesReportsMissingValues() throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)

        do {
            try session.require([.messageSend, .libp2pInterop])
            Issue.record("require unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .missingCapabilities(.libp2pInterop))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func forwardsBackendEvents() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)
        var iterator = session.events.makeAsyncIterator()

        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")
        backend.emit(.peerConnected(peer))

        if case .peerConnected(let received)? = await iterator.next() {
            #expect(received == peer)
        } else {
            Issue.record("expected peerConnected event")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func simpleSendCanTargetMultiplePeers() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)
        let peers = [
            PeerConnectivityPeer(id: "peer-a", displayName: "Peer A"),
            PeerConnectivityPeer(id: "peer-b", displayName: "Peer B")
        ]

        var buffer = ByteBuffer()
        buffer.writeString("hello")
        try await session.send(buffer, to: peers)

        #expect(backend.sentPeerIDs() == ["peer-a", "peer-b"])
    }

    @Test(.timeLimit(.minutes(1)))
    func openStreamUsesNamedStreamAlias() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.streamMultiplexing])
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")

        let channel = try await session.openStream(named: "chat", to: peer)

        #expect(channel.protocolID == "chat")
        #expect(backend.openedProtocolIDs() == ["chat"])
    }

    @Test(.timeLimit(.minutes(1)))
    func exposesLocalAndConnectedPeersWithoutBackendDetails() async throws {
        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend], connectedPeers: [peer])
        let session = PeerConnectivitySession(backend: backend)

        let localPeer = try await session.localPeer()
        let connectedPeers = try await session.connectedPeers()

        #expect(localPeer.id == "local")
        #expect(connectedPeers == [peer])
    }

    @Test(.timeLimit(.minutes(1)))
    func inviteReportsMissingCapabilityWhenBackendDoesNotSupportInvitations() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.nearbyDiscovery])
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")

        do {
            try await session.invite(peer)
            Issue.record("invite unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .missingCapabilities(.invitation))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func browsingFailsWhenBackendCannotControlDiscoverySeparately() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.nearbyDiscovery])
        let session = PeerConnectivitySession(backend: backend)

        do {
            try await session.startBrowsing()
            Issue.record("startBrowsing unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .unsupportedOperation("startBrowsing"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownAfterBrowsingOnlyForwardsToBackend() async throws {
        let backend = FakeDiscoveryControllingBackend()
        let session = PeerConnectivitySession(backend: backend)

        try await session.startBrowsing()
        try await session.shutdown()

        #expect(backend.startBrowsingCount() == 1)
        #expect(backend.shutdownCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func joinUsesDiscoveredEndpointWithoutExposingBackendDetails() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(
            id: "peer-a",
            displayName: "Peer A",
            endpoints: [.native("peer-a")]
        )

        let joinedPeer = try await session.join(peer)

        #expect(joinedPeer.id == "fake")
        #expect(backend.connectedEndpoints() == [.native("peer-a")])
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pDefaultCapabilitiesDoNotOverstateRelayOrInboundListening() throws {
        let node = try Node()
        let session = PeerConnectivitySession.libp2p(node: node)

        #expect(session.capabilities.contains(.libp2pInterop))
        #expect(session.capabilities.contains(.messageSend))
        #expect(session.capabilities.contains(.resourceTransfer))
        #expect(!session.capabilities.contains(.relay))
        #expect(!session.capabilities.contains(.inboundListening))
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pDefaultCapabilitiesReflectConfiguredListenAddresses() throws {
        let node = try Node(listenAddresses: [Multiaddr.memory(id: "peer-connectivity-listen")])
        let session = PeerConnectivitySession.libp2p(node: node)

        #expect(session.capabilities.contains(.inboundListening))
        #expect(!session.capabilities.contains(.relay))
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pExplicitCapabilitiesArePreserved() throws {
        let node = try Node()
        let session = PeerConnectivitySession.libp2p(
            node: node,
            capabilities: [.libp2pInterop, .inboundListening, .relay]
        )

        #expect(session.capabilities.contains(.libp2pInterop))
        #expect(session.capabilities.contains(.inboundListening))
        #expect(session.capabilities.contains(.relay))
        #expect(!session.capabilities.contains(.resourceTransfer))
    }

    @Test(.timeLimit(.minutes(1)))
    func appleNetworkLibP2PCapabilitiesReflectListenConfiguration() throws {
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let session = try PeerConnectivitySession.appleNetworkLibP2P(
            configuration: AppleNetworkLibP2PConfiguration(listenAddresses: [listenAddress])
        )

        #expect(session.capabilities.contains(.libp2pInterop))
        #expect(session.capabilities.contains(.inboundListening))
        #expect(!session.capabilities.contains(.relay))
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecMaterializesReceivedResource() throws {
        var buffer = LibP2PResourceCodec.header(for: "../unsafe name.txt", size: 13)
        buffer.writeString("resource-body")

        let resource = try LibP2PResourceCodec.materializeResource(from: buffer)
        defer {
            do {
                try FileManager.default.removeItem(at: resource.url)
            } catch {
                Issue.record("cleanup failed: \(error)")
            }
        }

        let data = try Data(contentsOf: resource.url)
        #expect(resource.name == "../unsafe name.txt")
        #expect(String(decoding: data, as: UTF8.self) == "resource-body")
        #expect(resource.url.lastPathComponent.contains("unsafe_name.txt"))
        #expect(!resource.url.lastPathComponent.contains(".."))
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecRejectsMissingNameSeparator() throws {
        var buffer = ByteBuffer()
        buffer.writeString("missing-separator")

        do {
            _ = try LibP2PResourceCodec.materializeResource(from: buffer)
            Issue.record("resource codec unexpectedly accepted invalid payload")
        } catch let error as PeerConnectivityError {
            #expect(error == .invalidResource)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecRejectsTruncatedPayload() throws {
        var buffer = LibP2PResourceCodec.header(for: "payload.txt", size: 20)
        buffer.writeString("short")

        do {
            _ = try LibP2PResourceCodec.materializeResource(from: buffer)
            Issue.record("resource codec unexpectedly accepted truncated payload")
        } catch let error as PeerConnectivityError {
            #expect(error == .invalidResource)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecRejectsOversizedPayloadAdvertisement() throws {
        let buffer = LibP2PResourceCodec.header(for: "payload.txt", size: 11)

        do {
            _ = try LibP2PResourceCodec.expectedTotalLength(in: buffer, maxPayloadBytes: 10)
            Issue.record("resource codec unexpectedly accepted oversized payload advertisement")
        } catch let error as PeerConnectivityError {
            #expect(error == .resourceTooLarge(10))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pBackendEmitsReceivedResources() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-resource")
        let server = makeLibP2PNode(hub: hub, listenAddress: serverAddress)
        let client = makeLibP2PNode(hub: hub)
        let serverSession = PeerConnectivitySession.libp2p(
            node: server,
            capabilities: [
                .libp2pInterop,
                .inboundListening,
                .messageSend,
                .streamMultiplexing,
                .resourceTransfer
            ]
        )
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.events.makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-connectivity-source-\(UUID().uuidString).txt")
        try Data("resource-body".utf8).write(to: sourceURL)

        let serverPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))
        try await clientSession.sendResource(PeerResource(url: sourceURL, name: "payload.txt"), to: serverPeer)

        let resource = try await nextResourceReceived(from: &serverEvents)
        let data = try Data(contentsOf: resource.url)
        #expect(resource.name == "payload.txt")
        #expect(String(decoding: data, as: UTF8.self) == "resource-body")

        try await clientSession.shutdown()
        try await serverSession.shutdown()
        hub.reset()
        cleanup(url: sourceURL)
        cleanup(url: resource.url)
    }

    #if canImport(MultipeerConnectivity)
    @Test(.timeLimit(.minutes(1)))
    func multipeerCapabilitiesIncludeStreamsWithoutLibP2PInterop() {
        let session = PeerConnectivitySession.multipeer(serviceType: "p2ptest", displayName: "test-peer")

        #expect(session.capabilities.contains(.nearbyDiscovery))
        #expect(session.capabilities.contains(.invitation))
        #expect(session.capabilities.contains(.streamMultiplexing))
        #expect(!session.capabilities.contains(.libp2pInterop))
    }

    @Test(.timeLimit(.minutes(1)))
    func multipeerLocalPeerKeepsIdentitySeparateFromDisplayName() async throws {
        let session = PeerConnectivitySession.multipeer(serviceType: "p2ptest", displayName: "test-peer")

        let peer = try await session.localPeer()

        #expect(peer.displayName == "test-peer")
        #expect(peer.id != peer.displayName)
        #expect(peer.identity == .backend(kind: "multipeer", value: peer.id))
        #expect(peer.endpoints == [.native(peer.id)])
    }

    @Test(.timeLimit(.minutes(1)))
    func multipeerInviteFailsWhenBrowsingHasNotStarted() async throws {
        let session = PeerConnectivitySession.multipeer(serviceType: "p2ptest", displayName: "test-peer")
        let peer = PeerConnectivityPeer(id: "peer", displayName: "Peer")

        do {
            try await session.invite(peer)
            Issue.record("invite unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .unsupportedOperation("invite requires browsing"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func multipeerIndividualDisconnectIsExplicitlyUnsupported() async throws {
        let session = PeerConnectivitySession.multipeer(serviceType: "p2ptest", displayName: "test-peer")
        let peer = PeerConnectivityPeer(id: "peer", displayName: "Peer")

        do {
            try await session.disconnect(from: peer)
            Issue.record("disconnect unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .unsupportedOperation("disconnect individual Multipeer peer"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func multipeerChannelReadsFromInputStream() async throws {
        let peer = PeerConnectivityPeer(id: "peer", displayName: "Peer")
        let input = InputStream(data: Data("stream-body".utf8))
        let channel = MultipeerConnectivityChannel(
            peer: peer,
            protocolID: "test-protocol",
            input: input,
            output: nil
        )

        var buffer = try await channel.read()
        #expect(buffer.readString(length: buffer.readableBytes) == "stream-body")
        try await channel.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func multipeerChannelWritesToOutputStream() async throws {
        let peer = PeerConnectivityPeer(id: "peer", displayName: "Peer")
        let output = OutputStream.toMemory()
        let channel = MultipeerConnectivityChannel(
            peer: peer,
            protocolID: "test-protocol",
            input: nil,
            output: output
        )

        var buffer = ByteBuffer()
        buffer.writeString("outbound-body")
        try await channel.write(buffer)
        try await channel.close()

        let data = output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data
        #expect(data.map { String(decoding: $0, as: UTF8.self) } == "outbound-body")
    }
    #endif

    private func makeLibP2PNode(hub: MemoryHub, listenAddress: Multiaddr? = nil) -> Node {
        var listenAddresses: [Multiaddr] = []
        if let listenAddress {
            listenAddresses.append(listenAddress)
        }

        return Node(configuration: NodeConfiguration(
            listenAddresses: listenAddresses,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: .init(
                limits: .development,
                reconnectionPolicy: .disabled,
                idleTimeout: .seconds(300)
            ),
            healthCheck: nil
        ))
    }

    private func nextResourceReceived(
        from iterator: inout AsyncStream<PeerConnectivityEvent>.Iterator
    ) async throws -> PeerResource {
        while let event = await iterator.next() {
            if case .resourceReceived(let resource, _) = event {
                return resource
            }
            if case .error(let error) = event {
                throw error
            }
        }
        throw PeerConnectivityTestError.streamEnded
    }

    private func cleanup(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("cleanup failed: \(error)")
        }
    }
}

private final class FakePeerConnectivityBackend: PeerConnectivityBackend, PeerConnectivityStateProviding, Sendable {
    let capabilities: PeerConnectivityCapabilities
    private let broadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private let sentPeers = Mutex<[String]>([])
    private let openedProtocols = Mutex<[String]>([])
    private let connected = Mutex<[PeerConnectivityEndpoint]>([])
    private let local: PeerConnectivityPeer
    private let connectedPeerValues: [PeerConnectivityPeer]

    var events: AsyncStream<PeerConnectivityEvent> {
        broadcaster.subscribe()
    }

    init(
        capabilities: PeerConnectivityCapabilities,
        local: PeerConnectivityPeer = PeerConnectivityPeer(id: "local", displayName: "Local"),
        connectedPeers: [PeerConnectivityPeer] = []
    ) {
        self.capabilities = capabilities
        self.local = local
        self.connectedPeerValues = connectedPeers
    }

    func emit(_ event: PeerConnectivityEvent) {
        broadcaster.emit(event)
    }

    func sentPeerIDs() -> [String] {
        sentPeers.withLock { $0 }
    }

    func openedProtocolIDs() -> [String] {
        openedProtocols.withLock { $0 }
    }

    func connectedEndpoints() -> [PeerConnectivityEndpoint] {
        connected.withLock { $0 }
    }

    func start() async throws {}
    func shutdown() async throws {}

    func localPeer() async throws -> PeerConnectivityPeer {
        local
    }

    func connectedPeers() async throws -> [PeerConnectivityPeer] {
        connectedPeerValues
    }

    func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        connected.withLock { $0.append(endpoint) }
        return PeerConnectivityPeer(id: "fake", displayName: "Fake")
    }

    func disconnect(from peer: PeerConnectivityPeer) async throws {}

    func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws {
        sentPeers.withLock { $0.append(peer.id) }
    }

    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel {
        openedProtocols.withLock { $0.append(protocolID) }
        return FakePeerConnectivityChannel(peer: peer, protocolID: protocolID)
    }

    func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {}
}

private final class FakeDiscoveryControllingBackend: PeerConnectivityBackend, PeerConnectivityDiscoveryControlling, Sendable {
    let capabilities: PeerConnectivityCapabilities = [.nearbyDiscovery]
    private let broadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private let counters = Mutex(Counters())

    private struct Counters: Sendable {
        var startBrowsing = 0
        var stopBrowsing = 0
        var startAdvertising = 0
        var stopAdvertising = 0
        var shutdown = 0
    }

    var events: AsyncStream<PeerConnectivityEvent> {
        broadcaster.subscribe()
    }

    func startBrowsingCount() -> Int {
        counters.withLock { $0.startBrowsing }
    }

    func shutdownCount() -> Int {
        counters.withLock { $0.shutdown }
    }

    func start() async throws {}

    func shutdown() async throws {
        counters.withLock { $0.shutdown += 1 }
        broadcaster.shutdown()
    }

    func startBrowsing() async throws {
        counters.withLock { $0.startBrowsing += 1 }
    }

    func stopBrowsing() async {
        counters.withLock { $0.stopBrowsing += 1 }
    }

    func startAdvertising() async throws {
        counters.withLock { $0.startAdvertising += 1 }
    }

    func stopAdvertising() async {
        counters.withLock { $0.stopAdvertising += 1 }
    }

    func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        throw PeerConnectivityError.unsupportedEndpoint(endpoint)
    }

    func disconnect(from peer: PeerConnectivityPeer) async throws {}

    func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws {}

    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel {
        throw PeerConnectivityError.channelUnavailable
    }

    func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {}
}

private struct FakePeerConnectivityChannel: PeerConnectivityChannel {
    let peer: PeerConnectivityPeer
    let protocolID: String?

    func read() async throws -> ByteBuffer {
        throw PeerConnectivityError.channelClosed
    }

    func write(_ bytes: ByteBuffer) async throws {}
    func close() async throws {}
}

private enum PeerConnectivityTestError: Error {
    case streamEnded
}
