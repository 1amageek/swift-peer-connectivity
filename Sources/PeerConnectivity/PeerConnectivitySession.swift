import NIOCore

public actor PeerConnectivitySession {
    private let backend: any PeerConnectivityBackend
    private var isStarted = false
    /// Tracks whether `start()` has been attempted, even if it failed.
    ///
    /// A failed `backend.start()` can leave partially acquired resources behind,
    /// so `shutdown()` must reach the backend after any start attempt — not only
    /// after a successful one.
    private var hasAttemptedStart = false
    private var isBrowsing = false
    private var isAdvertising = false

    public nonisolated var capabilities: PeerConnectivityCapabilities {
        backend.capabilities
    }

    /// Subscribes to backend events.
    ///
    /// This is the misuse-resistant access point for the event stream. Each call
    /// returns a NEW independent `AsyncStream`: the backend follows the
    /// `EventBroadcaster` (multi-consumer) convention, so multiple components can
    /// each `for await session.subscribe()` and every subscriber sees every event
    /// emitted after it subscribed.
    ///
    /// - Important: A subscription only observes events emitted AFTER it is
    ///   created. To avoid missing early events, subscribe BEFORE calling
    ///   `start()` / `startBrowsing()` / `startAdvertising()`.
    ///
    /// The method form (rather than a computed property) makes the per-call
    /// cost — minting a new subscriber — explicit at the call site, instead of a
    /// property access that silently creates a fresh subscription each time.
    public nonisolated func subscribe() -> AsyncStream<PeerConnectivityEvent> {
        backend.events
    }

    /// Subscribes to backend events.
    ///
    /// - Warning: Each access creates a NEW subscription, so reading `events`
    ///   twice yields two independent streams and the second misses events the
    ///   first already consumed. Use ``subscribe()`` instead, which names this
    ///   per-call cost explicitly.
    @available(*, deprecated, renamed: "subscribe()", message: "Each access mints a new subscription; use subscribe() to make the per-call cost explicit.")
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
        hasAttemptedStart = true
        try await backend.start()
        isStarted = true
    }

    public func shutdown() async throws {
        guard hasAttemptedStart || isBrowsing || isAdvertising else { return }
        try await backend.shutdown()
        isStarted = false
        hasAttemptedStart = false
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

    /// Sends `bytes` to every peer in `peers`.
    ///
    /// The send is NOT atomic, but it is exhaustive: it attempts every peer and
    /// never aborts mid-batch on the first failure. If one or more peers fail, it
    /// throws `PeerSendError` carrying per-peer outcomes (which peers succeeded
    /// and which failed), so a partial result is reported explicitly rather than
    /// silently. On full success it returns normally.
    ///
    /// Sends run sequentially in `peers` order to preserve a deterministic
    /// per-peer ordering of writes.
    public func send(
        _ bytes: ByteBuffer,
        to peers: [PeerConnectivityPeer],
        mode: PeerSendMode = .reliable
    ) async throws {
        var outcomes: [PeerSendOutcome] = []
        outcomes.reserveCapacity(peers.count)
        for peer in peers {
            do {
                try await backend.send(bytes, to: peer, mode: mode)
                outcomes.append(PeerSendOutcome(peer: peer))
            } catch {
                outcomes.append(PeerSendOutcome(peer: peer, error: error))
            }
        }
        if outcomes.contains(where: { !$0.succeeded }) {
            throw PeerSendError(outcomes: outcomes)
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
