import NIOCore

public protocol PeerConnectivityBackend: Sendable {
    var capabilities: PeerConnectivityCapabilities { get }
    var events: AsyncStream<PeerConnectivityEvent> { get }

    func start() async throws
    func shutdown() async throws
    func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer
    func disconnect(from peer: PeerConnectivityPeer) async throws
    func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws
    func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel
    func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws
}

public protocol PeerConnectivityDiscoveryControlling: Sendable {
    func startBrowsing() async throws
    func stopBrowsing() async
    func startAdvertising() async throws
    func stopAdvertising() async
}

public protocol PeerConnectivityInvitationHandling: Sendable {
    func invite(_ peer: PeerConnectivityPeer, context: ByteBuffer?, timeout: Duration) async throws
}

public protocol PeerConnectivityJoining: Sendable {
    func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer
}

public protocol PeerConnectivityStateProviding: Sendable {
    func localPeer() async throws -> PeerConnectivityPeer
    func connectedPeers() async throws -> [PeerConnectivityPeer]
}
