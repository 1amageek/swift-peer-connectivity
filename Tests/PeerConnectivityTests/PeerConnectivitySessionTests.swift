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
        var iterator = session.subscribe().makeAsyncIterator()

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

    // MARK: - events / subscribe semantics (Finding 1)

    @Test(.timeLimit(.minutes(1)))
    func subscribeDeliversEventsToMultipleIndependentSubscribers() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)

        // Two independent subscribers created BEFORE emitting must each observe
        // the event: subscribe() honors the multi-consumer (broadcaster) contract.
        var first = session.subscribe().makeAsyncIterator()
        var second = session.subscribe().makeAsyncIterator()

        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")
        backend.emit(.peerConnected(peer))

        guard case .peerConnected(let firstPeer)? = await first.next() else {
            Issue.record("first subscriber missed event")
            return
        }
        guard case .peerConnected(let secondPeer)? = await second.next() else {
            Issue.record("second subscriber missed event")
            return
        }
        #expect(firstPeer == peer)
        #expect(secondPeer == peer)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscribeCreatedAfterEmissionMissesPriorEvents() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)

        // Document the contract: a subscription only observes events emitted
        // AFTER it is created. An event emitted before subscribing is not
        // replayed; the later event is the first one seen.
        let early = PeerConnectivityPeer(id: "early", displayName: "Early")
        backend.emit(.peerConnected(early))

        var iterator = session.subscribe().makeAsyncIterator()
        let late = PeerConnectivityPeer(id: "late", displayName: "Late")
        backend.emit(.peerConnected(late))

        guard case .peerConnected(let received)? = await iterator.next() else {
            Issue.record("expected the post-subscribe event")
            return
        }
        #expect(received == late)
    }

    // MARK: - Multi-peer send partial-failure aggregation (Finding 2)

    @Test(.timeLimit(.minutes(1)))
    func multiPeerSendAttemptsAllPeersAndAggregatesPartialFailure() async throws {
        let peers = [
            PeerConnectivityPeer(id: "peer-a", displayName: "Peer A"),
            PeerConnectivityPeer(id: "peer-b", displayName: "Peer B"),
            PeerConnectivityPeer(id: "peer-c", displayName: "Peer C")
        ]
        let backend = FakePeerConnectivityBackend(
            capabilities: [.messageSend],
            failingPeerIDs: ["peer-b"]
        )
        let session = PeerConnectivitySession(backend: backend)

        var buffer = ByteBuffer()
        buffer.writeString("hello")

        do {
            try await session.send(buffer, to: peers)
            Issue.record("multi-peer send unexpectedly reported full success despite a failing peer")
        } catch let error as PeerSendError {
            // No mid-batch abort: every peer was attempted, so the failure after
            // peer-b must not stop peer-c.
            #expect(backend.sentPeerIDs() == ["peer-a", "peer-c"])
            #expect(Set(error.succeeded.map { $0.id }) == ["peer-a", "peer-c"])
            #expect(error.failed.map { $0.peer.id } == ["peer-b"])
            #expect(error.outcomes.count == 3)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func multiPeerSendSucceedsSilentlyWhenAllPeersSucceed() async throws {
        let peers = [
            PeerConnectivityPeer(id: "peer-a", displayName: "Peer A"),
            PeerConnectivityPeer(id: "peer-b", displayName: "Peer B")
        ]
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)

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
    func advertisingFailsWhenBackendCannotControlDiscoverySeparately() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.nearbyDiscovery])
        let session = PeerConnectivitySession(backend: backend)

        do {
            try await session.startAdvertising()
            Issue.record("startAdvertising unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .unsupportedOperation("startAdvertising"))
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
    func shutdownAfterAdvertisingOnlyForwardsToBackend() async throws {
        let backend = FakeDiscoveryControllingBackend()
        let session = PeerConnectivitySession(backend: backend)

        try await session.startAdvertising()
        try await session.shutdown()

        #expect(backend.startAdvertisingCount() == 1)
        #expect(backend.shutdownCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopBrowsingPreventsShutdownFromForwardingToBackend() async throws {
        let backend = FakeDiscoveryControllingBackend()
        let session = PeerConnectivitySession(backend: backend)

        try await session.startBrowsing()
        await session.stopBrowsing()
        try await session.shutdown()

        #expect(backend.startBrowsingCount() == 1)
        #expect(backend.stopBrowsingCount() == 1)
        #expect(backend.shutdownCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func readmeStyleUsageFlowJoinsDiscoveredPeerAndSendsMessage() async throws {
        let discoveredPeer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")
        let backend = FakeUsageBackend(discoveredPeer: discoveredPeer)
        let session = PeerConnectivitySession(backend: backend)
        var iterator = session.subscribe().makeAsyncIterator()

        try session.require([.nearbyDiscovery, .messageSend])
        try await session.startBrowsing()
        try await session.startAdvertising()

        guard case .peerDiscovered(let peer, _)? = await iterator.next() else {
            Issue.record("expected peerDiscovered event")
            return
        }

        let connectedPeer = try await session.join(peer)
        var message = ByteBuffer()
        message.writeString("hello")
        try await session.send(message, to: connectedPeer)

        #expect(backend.startBrowsingCount() == 1)
        #expect(backend.startAdvertisingCount() == 1)
        #expect(backend.joinedPeerIDs() == ["peer-a"])
        #expect(backend.sentPeerIDs() == ["peer-a"])
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
    func joinPrefersBackendJoinOverEndpointDialing() async throws {
        let backend = FakeJoiningBackend()
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(
            id: "peer-a",
            displayName: "Peer A",
            endpoints: [.native("peer-a")]
        )

        let joinedPeer = try await session.join(peer)

        #expect(joinedPeer.id == "peer-a")
        #expect(backend.joinedPeerIDs() == ["peer-a"])
        #expect(backend.connectedEndpoints().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func joinUsesInvitationWhenPeerHasNoEndpoint() async throws {
        let backend = FakeInvitationBackend()
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")

        let joinedPeer = try await session.join(peer)

        #expect(joinedPeer == peer)
        #expect(backend.invitedPeerIDs() == ["peer-a"])
    }

    @Test(.timeLimit(.minutes(1)))
    func joinFailsWhenPeerHasNoEndpointAndBackendCannotInvite() async throws {
        let backend = FakePeerConnectivityBackend(capabilities: [.messageSend])
        let session = PeerConnectivitySession(backend: backend)
        let peer = PeerConnectivityPeer(id: "peer-a", displayName: "Peer A")

        do {
            _ = try await session.join(peer)
            Issue.record("join unexpectedly succeeded")
        } catch let error as PeerConnectivityError {
            #expect(error == .unsupportedOperation("join"))
        }
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
    func libp2pResourceCodecParsesHeaderFrameRoundTrip() throws {
        let frame = LibP2PResourceCodec.header(for: "payload.txt", size: 11)
        let header = try LibP2PResourceCodec.parseHeaderFrame(frame)

        #expect(header.name == "payload.txt")
        #expect(header.size == 11)
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecRejectsHeaderFrameWithoutSizeTerminator() throws {
        var frame = ByteBuffer()
        frame.writeString("payload.txt")
        frame.writeInteger(UInt8(0))
        // Size field is present but not terminated by the trailing separator.
        frame.writeString("11")

        do {
            _ = try LibP2PResourceCodec.parseHeaderFrame(frame)
            Issue.record("header parse unexpectedly accepted unterminated size field")
        } catch let error as PeerConnectivityError {
            #expect(error == .invalidResource)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func libp2pResourceCodecRejectsNonDecimalSize() throws {
        var frame = ByteBuffer()
        frame.writeString("payload.txt")
        frame.writeInteger(UInt8(0))
        frame.writeBytes([0xC3, 0x28])
        frame.writeInteger(UInt8(0))

        do {
            _ = try LibP2PResourceCodec.parseHeaderFrame(frame)
            Issue.record("header parse unexpectedly accepted a non-decimal size field")
        } catch let error as PeerConnectivityError {
            #expect(error == .invalidResource)
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
        var serverEvents = serverSession.subscribe().makeAsyncIterator()

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

    // MARK: - connect(to:) round-trips through join (Finding 8)

    @Test(.timeLimit(.minutes(1)))
    func libp2pConnectReturnsPeerThatRoundTripsThroughJoin() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-roundtrip")
        let server = makeLibP2PNode(hub: hub, listenAddress: serverAddress)
        let client = makeLibP2PNode(hub: hub)
        let serverSession = PeerConnectivitySession.libp2p(
            node: server,
            capabilities: [.libp2pInterop, .inboundListening, .messageSend, .streamMultiplexing]
        )
        let clientSession = PeerConnectivitySession.libp2p(node: client)

        try await serverSession.start()
        try await clientSession.start()

        // connect(to:) must return a peer carrying the dialed address as an
        // endpoint, otherwise a later join cannot reach the same node.
        let connectedPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))
        #expect(!connectedPeer.endpoints.isEmpty)

        // Round-trip: joining the returned peer must reach the same server using
        // only the endpoints carried on the peer.
        let rejoinedPeer = try await clientSession.join(connectedPeer)
        #expect(rejoinedPeer.id == connectedPeer.id)

        try await clientSession.shutdown()
        try await serverSession.shutdown()
        hub.reset()
    }

    // MARK: - Inbound truncation surfaces as a typed failure (Finding 5)

    @Test(.timeLimit(.minutes(1)))
    func libp2pInboundTruncationSurfacesAsTypedFailureNotCompleteMessage() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-truncation")
        let server = makeLibP2PNode(hub: hub, listenAddress: serverAddress)
        let client = makeLibP2PNode(hub: hub)
        let serverSession = PeerConnectivitySession.libp2p(
            node: server,
            capabilities: [.libp2pInterop, .inboundListening, .messageSend, .streamMultiplexing]
        )
        let clientSession = PeerConnectivitySession.libp2p(node: client)
        var serverEvents = serverSession.subscribe().makeAsyncIterator()

        try await serverSession.start()
        try await clientSession.start()

        let serverPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))

        // Open the message protocol directly and write a malformed length-prefixed
        // frame: a varint length claiming 100 bytes followed by only 5 bytes, then
        // close. The receiver must reject this as a typed failure rather than
        // delivering the 5 bytes as a complete message.
        let channel = try await clientSession.openChannel(
            to: serverPeer,
            protocol: "/peer-connectivity/message/1.0.0"
        )
        var frame = ByteBuffer()
        frame.writeInteger(UInt8(100)) // single-byte varint = length 100
        frame.writeString("short")     // only 5 of the 100 promised bytes
        try await channel.write(frame)
        try await channel.close()

        // The next non-trivial event must be an error attributed to inbound
        // message handling — never a messageReceived carrying the truncated bytes.
        var sawError = false
        while let event = await serverEvents.next() {
            if case .messageReceived = event {
                Issue.record("truncated frame was delivered as a complete message")
                break
            }
            if case .error(let errorEvent) = event {
                #expect(errorEvent.operation == .inboundMessage)
                sawError = true
                break
            }
        }
        #expect(sawError)

        try await clientSession.shutdown()
        try await serverSession.shutdown()
        hub.reset()
    }

    // MARK: - Inbound handler honors cancellation / released on shutdown (Finding 6)

    @Test(.timeLimit(.minutes(1)))
    func libp2pInboundHandlerReleasedOnShutdownWhenPeerStalls() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "peer-connectivity-stall")
        let server = makeLibP2PNode(hub: hub, listenAddress: serverAddress)
        let client = makeLibP2PNode(hub: hub)
        let backend = LibP2PPeerConnectivityBackend(
            node: server,
            capabilities: [.libp2pInterop, .inboundListening, .messageSend, .streamMultiplexing]
        )
        let serverSession = PeerConnectivitySession(backend: backend)
        let clientSession = PeerConnectivitySession.libp2p(node: client)

        try await serverSession.start()
        try await clientSession.start()

        let serverPeer = try await clientSession.connect(to: .libp2p(serverAddress.description))

        // Open the message stream but never send a complete frame: the server's
        // inbound handler blocks on read(). The handler task must be tracked.
        let channel = try await clientSession.openChannel(
            to: serverPeer,
            protocol: "/peer-connectivity/message/1.0.0"
        )
        var partial = ByteBuffer()
        partial.writeInteger(UInt8(50)) // promise 50 bytes, send nothing more
        try await channel.write(partial)

        // Give the server time to register the inbound handler task.
        try await Task.sleep(for: .milliseconds(200))
        let inFlight = await backend.inboundTaskCountForTesting()
        #expect(inFlight >= 1)

        // shutdown() must cancel the tracked inbound handler so it is released
        // deterministically rather than pinned by the stalled read.
        try await serverSession.shutdown()
        let afterShutdown = await backend.inboundTaskCountForTesting()
        #expect(afterShutdown == 0)

        try await clientSession.shutdown()
        hub.reset()
    }

    // MARK: - enableBonjour capability honesty (Finding 3)

    @Test(.timeLimit(.minutes(1)))
    func appleNetworkLibP2PRejectsBonjourWithoutListenAddress() throws {
        do {
            _ = try PeerConnectivitySession.appleNetworkLibP2P(
                configuration: AppleNetworkLibP2PConfiguration(
                    listenAddresses: [],
                    enableBonjour: true
                )
            )
            Issue.record("appleNetworkLibP2P unexpectedly accepted enableBonjour with no listen address")
        } catch let error as PeerConnectivityError {
            guard case .listenAddressRequired = error else {
                Issue.record("expected listenAddressRequired, got \(error)")
                return
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appleNetworkLibP2PAdvertisesBonjourOnlyWithListenAddress() throws {
        let listenAddress = try Multiaddr("/ip4/127.0.0.1/tcp/0")
        let session = try PeerConnectivitySession.appleNetworkLibP2P(
            configuration: AppleNetworkLibP2PConfiguration(
                listenAddresses: [listenAddress],
                enableBonjour: true
            )
        )

        // With a listen address present, advertising .bonjourDiscovery is honest
        // (the node can both browse and announce).
        #expect(session.capabilities.contains(.bonjourDiscovery))
        #expect(session.capabilities.contains(.inboundListening))
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
            if case .error(let errorEvent) = event {
                throw errorEvent.error
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

    /// Peer ids whose `send` should throw, to exercise partial-failure paths.
    private let failingPeerIDs: Set<String>

    init(
        capabilities: PeerConnectivityCapabilities,
        local: PeerConnectivityPeer = PeerConnectivityPeer(id: "local", displayName: "Local"),
        connectedPeers: [PeerConnectivityPeer] = [],
        failingPeerIDs: Set<String> = []
    ) {
        self.capabilities = capabilities
        self.local = local
        self.connectedPeerValues = connectedPeers
        self.failingPeerIDs = failingPeerIDs
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
        if failingPeerIDs.contains(peer.id) {
            throw PeerConnectivityError.channelClosed
        }
        sentPeers.withLock { $0.append(peer.id) }
    }

    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel {
        openedProtocols.withLock { $0.append(protocolID) }
        return FakePeerConnectivityChannel(peer: peer, protocolID: protocolID)
    }

    func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {}
}

private final class FakeJoiningBackend: PeerConnectivityBackend, PeerConnectivityJoining, Sendable {
    let capabilities: PeerConnectivityCapabilities = [.messageSend]
    private let broadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private let joinedPeers = Mutex<[String]>([])
    private let connected = Mutex<[PeerConnectivityEndpoint]>([])

    var events: AsyncStream<PeerConnectivityEvent> {
        broadcaster.subscribe()
    }

    func joinedPeerIDs() -> [String] {
        joinedPeers.withLock { $0 }
    }

    func connectedEndpoints() -> [PeerConnectivityEndpoint] {
        connected.withLock { $0 }
    }

    func start() async throws {}
    func shutdown() async throws {
        broadcaster.shutdown()
    }

    func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer {
        joinedPeers.withLock { $0.append(peer.id) }
        return peer
    }

    func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        connected.withLock { $0.append(endpoint) }
        return PeerConnectivityPeer(id: "connected", displayName: "Connected")
    }

    func disconnect(from peer: PeerConnectivityPeer) async throws {}
    func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws {}

    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel {
        FakePeerConnectivityChannel(peer: peer, protocolID: protocolID)
    }

    func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {}
}

private final class FakeInvitationBackend: PeerConnectivityBackend, PeerConnectivityInvitationHandling, Sendable {
    let capabilities: PeerConnectivityCapabilities = [.invitation]
    private let broadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private let invitedPeers = Mutex<[String]>([])

    var events: AsyncStream<PeerConnectivityEvent> {
        broadcaster.subscribe()
    }

    func invitedPeerIDs() -> [String] {
        invitedPeers.withLock { $0 }
    }

    func start() async throws {}
    func shutdown() async throws {
        broadcaster.shutdown()
    }

    func invite(_ peer: PeerConnectivityPeer, context: ByteBuffer?, timeout: Duration) async throws {
        invitedPeers.withLock { $0.append(peer.id) }
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

private final class FakeUsageBackend:
    PeerConnectivityBackend,
    PeerConnectivityDiscoveryControlling,
    PeerConnectivityJoining,
    Sendable
{
    let capabilities: PeerConnectivityCapabilities = [.nearbyDiscovery, .messageSend]
    private let broadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private let discoveredPeer: PeerConnectivityPeer
    private let state = Mutex(UsageState())

    private struct UsageState: Sendable {
        var startBrowsing = 0
        var startAdvertising = 0
        var joinedPeers: [String] = []
        var sentPeers: [String] = []
    }

    var events: AsyncStream<PeerConnectivityEvent> {
        broadcaster.subscribe()
    }

    init(discoveredPeer: PeerConnectivityPeer) {
        self.discoveredPeer = discoveredPeer
    }

    func startBrowsingCount() -> Int {
        state.withLock { $0.startBrowsing }
    }

    func startAdvertisingCount() -> Int {
        state.withLock { $0.startAdvertising }
    }

    func joinedPeerIDs() -> [String] {
        state.withLock { $0.joinedPeers }
    }

    func sentPeerIDs() -> [String] {
        state.withLock { $0.sentPeers }
    }

    func start() async throws {}
    func shutdown() async throws {
        broadcaster.shutdown()
    }

    func startBrowsing() async throws {
        state.withLock { $0.startBrowsing += 1 }
        broadcaster.emit(.peerDiscovered(discoveredPeer, endpoints: discoveredPeer.endpoints))
    }

    func stopBrowsing() async {}

    func startAdvertising() async throws {
        state.withLock { $0.startAdvertising += 1 }
    }

    func stopAdvertising() async {}

    func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer {
        state.withLock { $0.joinedPeers.append(peer.id) }
        return peer
    }

    func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        throw PeerConnectivityError.unsupportedEndpoint(endpoint)
    }

    func disconnect(from peer: PeerConnectivityPeer) async throws {}

    func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws {
        state.withLock { $0.sentPeers.append(peer.id) }
    }

    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel {
        FakePeerConnectivityChannel(peer: peer, protocolID: protocolID)
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

    func stopBrowsingCount() -> Int {
        counters.withLock { $0.stopBrowsing }
    }

    func startAdvertisingCount() -> Int {
        counters.withLock { $0.startAdvertising }
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
