import Foundation
import NIOCore
import NIOFoundationCompat
import P2P
import P2PCore
import P2PMuxYamux
import PeerConnectivity
import PeerConnectivityLibP2P
import PeerConnectivityNetwork
import P2PSecurityNoise
import P2PSecurityPlaintext
import P2PTransportMemory
import P2PTransportTCP
import Testing

@Suite("PeerConnectivity E2E Tests")
struct PeerConnectivityE2ETests {
    @Test(.timeLimit(.minutes(1)))
    func libp2pMessageSendE2E() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-message-e2e")
        let server = makeMemoryNode(hub: hub, listenAddress: serverAddress)
        let client = makeMemoryNode(hub: hub)
        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.events.makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let serverPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))
        var message = ByteBuffer()
        message.writeString("robot-message")
        try await clientSession.send(message, to: serverPeer)

        var received = try await nextMessageReceived(from: &serverEvents)
        #expect(received.readString(length: received.readableBytes) == "robot-message")

        try await clientSession.shutdown()
        try await serverSession.shutdown()
        hub.reset()
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pNamedStreamE2E() async throws {
        let hub = MemoryHub()
        let protocolID = "/peer-connectivity/e2e/echo/1.0.0"
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-stream-e2e")
        let server = makeMemoryNode(hub: hub, listenAddress: serverAddress)
        let client = makeMemoryNode(hub: hub)

        await server.handle(protocolID) { context in
            do {
                let request = try await context.stream.read()
                try await context.stream.write(request)
                try await context.stream.closeWrite()
            } catch {
                assertionFailure("Echo stream handler failed: \(error)")
            }
        }

        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)

        try await serverSession.start()
        try await clientSession.start()

        let serverPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))
        let channel = try await clientSession.openStream(named: protocolID, to: serverPeer)
        var request = ByteBuffer()
        request.writeString("stream-body")
        try await channel.write(request)

        var response = try await channel.read()
        #expect(response.readString(length: response.readableBytes) == "stream-body")

        try await channel.close()
        try await clientSession.shutdown()
        try await serverSession.shutdown()
        hub.reset()
    }

    @Test(.timeLimit(.minutes(1)))
    func networkTCPTransportInteroperatesWithTCPTransportE2E() async throws {
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let server = try Node(
            listenAddresses: [listenAddress],
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let client = try Node(
            transports: [TCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )

        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.events.makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let boundAddresses = await server.listenAddresses()
        guard let boundAddress = boundAddresses.first(where: { $0.tcpPort != 0 }) else {
            Issue.record("expected bound TCP listen address")
            try await clientSession.shutdown()
            try await serverSession.shutdown()
            return
        }

        let serverPeer = try await clientSession.connect(to: .libp2p(boundAddress.description))
        var message = ByteBuffer()
        message.writeString("network-to-tcp")
        try await clientSession.send(message, to: serverPeer)

        var received = try await nextMessageReceived(from: &serverEvents)
        #expect(received.readString(length: received.readableBytes) == "network-to-tcp")

        try await clientSession.shutdown()
        try await serverSession.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func tcpTransportInteroperatesWithNetworkTCPTransportE2E() async throws {
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let server = try Node(
            listenAddresses: [listenAddress],
            transports: [TCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let client = try Node(
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )

        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.events.makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let boundAddresses = await server.listenAddresses()
        guard let boundAddress = boundAddresses.first(where: { $0.tcpPort != 0 }) else {
            Issue.record("expected bound TCP listen address")
            try await clientSession.shutdown()
            try await serverSession.shutdown()
            return
        }

        let serverPeer = try await clientSession.connect(to: .libp2p(boundAddress.description))
        var message = ByteBuffer()
        message.writeString("tcp-to-network")
        try await clientSession.send(message, to: serverPeer)

        var received = try await nextMessageReceived(from: &serverEvents)
        #expect(received.readString(length: received.readableBytes) == "tcp-to-network")

        try await clientSession.shutdown()
        try await serverSession.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func networkTCPTransportInteroperatesWithItselfE2E() async throws {
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let server = try Node(
            listenAddresses: [listenAddress],
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let client = try Node(
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )

        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.events.makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let boundAddresses = await server.listenAddresses()
        guard let boundAddress = boundAddresses.first(where: { $0.tcpPort != 0 }) else {
            Issue.record("expected bound Network TCP listen address")
            try await clientSession.shutdown()
            try await serverSession.shutdown()
            return
        }

        let serverPeer = try await clientSession.connect(to: .libp2p(boundAddress.description))
        var message = ByteBuffer()
        message.writeString("network-to-network")
        try await clientSession.send(message, to: serverPeer)

        var received = try await nextMessageReceived(from: &serverEvents)
        #expect(received.readString(length: received.readableBytes) == "network-to-network")

        try await clientSession.shutdown()
        try await serverSession.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func networkTCPTransportNamedStreamE2E() async throws {
        let protocolID = "/peer-connectivity/network/echo/1.0.0"
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let server = try Node(
            listenAddresses: [listenAddress],
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let client = try Node(
            transports: [NetworkTCPTransport()],
            security: [NoiseUpgrader()],
            muxers: [YamuxMuxer()]
        )

        await server.handle(protocolID) { context in
            do {
                let request = try await context.stream.read()
                try await context.stream.write(request)
                try await context.stream.closeWrite()
            } catch {
                assertionFailure("Network echo stream handler failed: \(error)")
            }
        }

        let serverSession = PeerConnectivitySession.libp2p(node: server)
        let clientSession = PeerConnectivitySession.libp2p(node: client)

        try await serverSession.start()
        try await clientSession.start()

        let boundAddresses = await server.listenAddresses()
        guard let boundAddress = boundAddresses.first(where: { $0.tcpPort != 0 }) else {
            Issue.record("expected bound Network TCP listen address")
            try await clientSession.shutdown()
            try await serverSession.shutdown()
            return
        }

        let serverPeer = try await clientSession.connect(to: .libp2p(boundAddress.description))
        let channel = try await clientSession.openStream(named: protocolID, to: serverPeer)
        var request = ByteBuffer()
        request.writeString("network-stream-body")
        try await channel.write(request)

        var response = try await channel.read()
        #expect(response.readString(length: response.readableBytes) == "network-stream-body")

        try await channel.close()
        try await clientSession.shutdown()
        try await serverSession.shutdown()
    }

    private func makeMemoryNode(hub: MemoryHub, listenAddress: Multiaddr? = nil) -> Node {
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

    private func nextMessageReceived(
        from iterator: inout AsyncStream<PeerConnectivityEvent>.Iterator
    ) async throws -> ByteBuffer {
        while let event = await iterator.next() {
            if case .messageReceived(let bytes, _) = event {
                return bytes
            }
            if case .error(let error) = event {
                throw error
            }
        }
        throw PeerConnectivityE2EError.streamEnded
    }
}

private enum PeerConnectivityE2EError: Error {
    case streamEnded
}
