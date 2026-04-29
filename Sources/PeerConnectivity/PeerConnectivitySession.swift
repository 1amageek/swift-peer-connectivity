import NIOCore

public actor PeerConnectivitySession {
    private let backend: any PeerConnectivityBackend
    private var isStarted = false
    private var isBrowsing = false
    private var isAdvertising = false

    public nonisolated var capabilities: PeerConnectivityCapabilities {
        backend.capabilities
    }

    public nonisolated var events: AsyncStream<PeerConnectivityEvent> {
        backend.events
    }

    public init(backend: any PeerConnectivityBackend) {
        self.backend = backend
    }

    public nonisolated func require(_ required: PeerConnectivityCapabilities) throws {
        let missing = required.subtracting(backend.capabilities)
        guard missing.isEmpty else {
            throw PeerConnectivityError.missingCapabilities(missing)
        }
    }

    public func start() async throws {
        guard !isStarted else { return }
        try await backend.start()
        isStarted = true
    }

    public func shutdown() async throws {
        guard isStarted || isBrowsing || isAdvertising else { return }
        try await backend.shutdown()
        isStarted = false
        isBrowsing = false
        isAdvertising = false
    }

    public func startBrowsing() async throws {
        guard let backend = backend as? any PeerConnectivityDiscoveryControlling else {
            throw PeerConnectivityError.unsupportedOperation("startBrowsing")
        }
        try await backend.startBrowsing()
        isBrowsing = true
    }

    public func stopBrowsing() async {
        if let backend = backend as? any PeerConnectivityDiscoveryControlling {
            await backend.stopBrowsing()
        }
        isBrowsing = false
    }

    public func startAdvertising() async throws {
        guard let backend = backend as? any PeerConnectivityDiscoveryControlling else {
            throw PeerConnectivityError.unsupportedOperation("startAdvertising")
        }
        try await backend.startAdvertising()
        isAdvertising = true
    }

    public func stopAdvertising() async {
        if let backend = backend as? any PeerConnectivityDiscoveryControlling {
            await backend.stopAdvertising()
        }
        isAdvertising = false
    }

    public func localPeer() async throws -> PeerConnectivityPeer {
        guard let backend = backend as? any PeerConnectivityStateProviding else {
            throw PeerConnectivityError.unsupportedOperation("localPeer")
        }
        return try await backend.localPeer()
    }

    public func connectedPeers() async throws -> [PeerConnectivityPeer] {
        guard let backend = backend as? any PeerConnectivityStateProviding else {
            throw PeerConnectivityError.unsupportedOperation("connectedPeers")
        }
        return try await backend.connectedPeers()
    }

    public func invite(
        _ peer: PeerConnectivityPeer,
        context: ByteBuffer? = nil,
        timeout: Duration = .seconds(30)
    ) async throws {
        guard let backend = backend as? any PeerConnectivityInvitationHandling else {
            throw PeerConnectivityError.missingCapabilities(.invitation)
        }
        try await backend.invite(peer, context: context, timeout: timeout)
    }

    @discardableResult
    public func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer {
        if let backend = backend as? any PeerConnectivityJoining {
            return try await backend.join(peer)
        }

        if let endpoint = peer.endpoints.first {
            return try await connect(to: endpoint)
        }

        if let backend = backend as? any PeerConnectivityInvitationHandling {
            try await backend.invite(peer, context: nil, timeout: .seconds(30))
            return peer
        }

        throw PeerConnectivityError.unsupportedOperation("join")
    }

    @discardableResult
    public func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        try await backend.connect(to: endpoint)
    }

    public func disconnect(from peer: PeerConnectivityPeer) async throws {
        try await backend.disconnect(from: peer)
    }

    public func send(
        _ bytes: ByteBuffer,
        to peer: PeerConnectivityPeer,
        mode: PeerSendMode = .reliable
    ) async throws {
        try await backend.send(bytes, to: peer, mode: mode)
    }

    public func send(
        _ bytes: ByteBuffer,
        to peers: [PeerConnectivityPeer],
        mode: PeerSendMode = .reliable
    ) async throws {
        for peer in peers {
            try await backend.send(bytes, to: peer, mode: mode)
        }
    }

    public func openChannel(
        to peer: PeerConnectivityPeer,
        protocol protocolID: String
    ) async throws -> any PeerConnectivityChannel {
        try await backend.openChannel(to: peer, protocol: protocolID)
    }

    public func openStream(
        named name: String,
        to peer: PeerConnectivityPeer
    ) async throws -> any PeerConnectivityChannel {
        try await openChannel(to: peer, protocol: name)
    }

    public func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {
        try await backend.sendResource(resource, to: peer)
    }
}
