@preconcurrency import Foundation
import NIOCore
import PeerConnectivity
import Synchronization

#if canImport(MultipeerConnectivity)
@preconcurrency import MultipeerConnectivity
#endif

#if canImport(MultipeerConnectivity)
public actor MultipeerConnectivityBackend:
    PeerConnectivityBackend,
    PeerConnectivityDiscoveryControlling,
    PeerConnectivityInvitationHandling,
    PeerConnectivityJoining,
    PeerConnectivityStateProviding
{
    public let capabilities: PeerConnectivityCapabilities = [
        .nearbyDiscovery,
        .messageSend,
        .streamMultiplexing,
        .resourceTransfer,
        .backgroundLimited,
        .invitation
    ]

    public nonisolated var events: AsyncStream<PeerConnectivityEvent> {
        eventBroadcaster.subscribe()
    }

    private let serviceType: String
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let delegate: MultipeerDelegate
    private let eventBroadcaster = PeerConnectivityEventBroadcaster<PeerConnectivityEvent>()
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?

    public init(serviceType: String, displayName: String) {
        self.serviceType = serviceType
        self.localPeerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.delegate = MultipeerDelegate(session: session, eventBroadcaster: eventBroadcaster)
        self.session.delegate = delegate
    }

    /// Prepares the backend for use.
    ///
    /// To keep `start()` semantics consistent with the libp2p backend, this does
    /// NOT implicitly begin browsing or advertising. The `MCSession` is created
    /// at init, so there is no further preparation needed. Callers must invoke
    /// `startBrowsing()` / `startAdvertising()` explicitly, which keeps the
    /// session's `isBrowsing` / `isAdvertising` flags accurate.
    public func start() async throws {}

    public func startBrowsing() async throws {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
        browser.delegate = delegate
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    public func stopBrowsing() async {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    public func startAdvertising() async throws {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = delegate
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
    }

    public func stopAdvertising() async {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    public func shutdown() async throws {
        await stopBrowsing()
        await stopAdvertising()
        session.disconnect()
        delegate.removeAllPeers()
        eventBroadcaster.shutdown()
    }

    public func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer {
        guard case .native(let peerID) = endpoint,
              let peer = delegate.peer(withID: peerID) else {
            throw PeerConnectivityError.unsupportedEndpoint(endpoint)
        }
        try await invite(
            MultipeerPeerCodec.peer(from: peer),
            context: nil,
            timeout: .seconds(30)
        )
        return try MultipeerPeerCodec.peer(from: peer)
    }

    public func disconnect(from peer: PeerConnectivityPeer) async throws {
        throw PeerConnectivityError.unsupportedOperation("disconnect individual Multipeer peer")
    }

    public func invite(
        _ peer: PeerConnectivityPeer,
        context: ByteBuffer?,
        timeout: Duration
    ) async throws {
        guard let browser else {
            throw PeerConnectivityError.unsupportedOperation("invite requires browsing")
        }
        guard let target = delegate.peer(withID: peer.id) else {
            throw PeerConnectivityError.peerIdentityRequired
        }
        let contextData = context.map { Data($0.readableBytesView) }
        browser.invitePeer(
            target,
            to: session,
            withContext: contextData,
            timeout: Self.timeInterval(from: timeout)
        )
    }

    public func join(_ peer: PeerConnectivityPeer) async throws -> PeerConnectivityPeer {
        try await invite(peer, context: nil, timeout: .seconds(30))
        return peer
    }

    public func localPeer() async throws -> PeerConnectivityPeer {
        try MultipeerPeerCodec.peer(from: localPeerID)
    }

    public func connectedPeers() async throws -> [PeerConnectivityPeer] {
        try session.connectedPeers.map { peerID in
            try MultipeerPeerCodec.peer(from: peerID)
        }
    }

    public func send(
        _ bytes: ByteBuffer,
        to peer: PeerConnectivityPeer,
        mode: PeerSendMode
    ) async throws {
        let target = try connectedPeerID(for: peer)
        let mcMode: MCSessionSendDataMode = mode == .reliable ? .reliable : .unreliable
        try session.send(Data(bytes.readableBytesView), toPeers: [target], with: mcMode)
    }

    public func openChannel(
        to peer: PeerConnectivityPeer,
        protocol protocolID: String
    ) async throws -> any PeerConnectivityChannel {
        let target = try connectedPeerID(for: peer)
        let stream = try session.startStream(withName: protocolID, toPeer: target)
        return MultipeerConnectivityChannel(
            peer: peer,
            protocolID: protocolID,
            input: nil,
            output: stream
        )
    }

    /// Resolve a `PeerConnectivityPeer` to the `MCPeerID` instance that is
    /// currently in `session.connectedPeers`.
    ///
    /// `MCPeerID` uses an internal UUID for equality; instances obtained from
    /// `foundPeer` and from `didReceiveInvitation` are not equal even when they
    /// represent the same logical peer. Multipeer's `connectedPeers` retains
    /// only the instance from the actual handshake, so we have to ask the
    /// session itself, by `displayName`, instead of trusting whatever instance
    /// our delegate happens to have cached.
    private func connectedPeerID(for peer: PeerConnectivityPeer) throws -> MCPeerID {
        if let match = session.connectedPeers.first(where: { $0.displayName == peer.displayName }) {
            return match
        }
        throw PeerConnectivityError.peerIdentityRequired
    }

    public func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {
        guard let target = delegate.peer(withID: peer.id) else {
            throw PeerConnectivityError.peerIdentityRequired
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ResourceTransferCompletion(continuation: continuation)
            let progress = session.sendResource(at: resource.url, withName: resource.name, toPeer: target) { [eventBroadcaster] error in
                if let error {
                    eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(
                        operation: .outboundResource,
                        peer: peer,
                        error: error
                    )))
                    completion.resume(throwing: error)
                } else {
                    completion.resume()
                }
            }
            if progress == nil {
                completion.resume(throwing: PeerConnectivityError.unsupportedOperation("resource transfer"))
            }
        }
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

}

private final class ResourceTransferCompletion: Sendable {
    private let state: Mutex<CompletionState>

    private struct CompletionState: Sendable {
        var didResume = false
        let continuation: CheckedContinuation<Void, Error>
    }

    init(continuation: CheckedContinuation<Void, Error>) {
        self.state = Mutex(CompletionState(continuation: continuation))
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.didResume else { return nil }
            state.didResume = true
            return state.continuation
        }
        continuation?.resume()
    }

    func resume(throwing error: any Error) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.didResume else { return nil }
            state.didResume = true
            return state.continuation
        }
        continuation?.resume(throwing: error)
    }
}

private enum MultipeerPeerCodec {
    static func identifier(from peerID: MCPeerID) throws -> String {
        let data = try NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true)
        return data.base64EncodedString()
    }

    static func peer(from peerID: MCPeerID) throws -> PeerConnectivityPeer {
        let identifier = try identifier(from: peerID)
        return PeerConnectivityPeer(
            id: identifier,
            displayName: peerID.displayName,
            identity: .backend(kind: "multipeer", value: identifier),
            endpoints: [.native(identifier)]
        )
    }
}

private final class MultipeerDelegate: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    let session: MCSession
    let eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>

    /// `MCPeerID` instances whose lifetime is tied to a connection state.
    ///
    /// An entry is added only when a peer is discovered by the browser (so it can
    /// be invited) or becomes connected, and removed when it is lost or
    /// disconnected. Data/stream/resource callbacks do NOT add entries — they
    /// derive a `PeerConnectivityPeer` directly from the `MCPeerID` they already
    /// hold — so a peer that merely sends bytes cannot pin an entry forever.
    private let registry = Mutex<Registry>(Registry())

    private struct Registry: Sendable {
        /// Peers found by the browser, removed on `lostPeer`.
        var discovered: [String: MCPeerID] = [:]
        /// Peers in the `.connected` state, removed on `.notConnected`.
        var connected: [String: MCPeerID] = [:]
    }

    init(session: MCSession, eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>) {
        self.session = session
        self.eventBroadcaster = eventBroadcaster
    }

    /// Looks up an `MCPeerID` known from discovery or an active connection.
    func peer(withID id: String) -> MCPeerID? {
        registry.withLock { $0.discovered[id] ?? $0.connected[id] }
    }

    func removeAllPeers() {
        registry.withLock { registry in
            registry.discovered.removeAll()
            registry.connected.removeAll()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        do {
            let peer = try MultipeerPeerCodec.peer(from: peerID)
            registry.withLock { $0.discovered[peer.id] = peerID }
            eventBroadcaster.emit(.peerDiscovered(peer, endpoints: peer.endpoints))
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .discovery, error: error)))
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        do {
            let peer = try MultipeerPeerCodec.peer(from: peerID)
            registry.withLock { _ = $0.discovered.removeValue(forKey: peer.id) }
            eventBroadcaster.emit(.peerLost(peer))
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .discovery, error: error)))
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .discovery, error: error)))
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Accept the invitation. The peer is registered only once it reaches the
        // `.connected` state (in `didChange`), so a declined or never-completed
        // handshake does not leak a registry entry.
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .discovery, error: error)))
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            do {
                let peer = try MultipeerPeerCodec.peer(from: peerID)
                registry.withLock { $0.connected[peer.id] = peerID }
                eventBroadcaster.emit(.peerConnected(peer))
            } catch {
                eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .connect, error: error)))
            }
        case .notConnected:
            do {
                let peer = try MultipeerPeerCodec.peer(from: peerID)
                registry.withLock { _ = $0.connected.removeValue(forKey: peer.id) }
                eventBroadcaster.emit(.peerDisconnected(peer))
            } catch {
                eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .connect, error: error)))
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        do {
            let peer = try MultipeerPeerCodec.peer(from: peerID)
            eventBroadcaster.emit(.messageReceived(buffer, from: peer))
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .inboundMessage, error: error)))
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        do {
            let peer = try MultipeerPeerCodec.peer(from: peerID)
            eventBroadcaster.emit(.channelOpened(MultipeerConnectivityChannel(
                peer: peer,
                protocolID: streamName,
                input: stream,
                output: nil
            )))
        } catch {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .inboundMessage, error: error)))
        }
    }

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        let peer: PeerConnectivityPeer
        do {
            peer = try MultipeerPeerCodec.peer(from: peerID)
        } catch {
            // The peer identity could not be derived; surface that as the error
            // (along with any transfer error) without peer attribution.
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(operation: .inboundResource, error: error)))
            return
        }

        if let error {
            eventBroadcaster.emit(.error(PeerConnectivityErrorEvent(
                operation: .inboundResource,
                peer: peer,
                error: error
            )))
        } else if let localURL {
            eventBroadcaster.emit(.resourceReceived(
                PeerResource(url: localURL, name: resourceName),
                from: peer
            ))
        }
    }
}

/// A channel over a MultipeerConnectivity byte stream.
///
/// Reads and writes are driven by the stream run-loop / `Stream.Delegate` event
/// model rather than by blocking I/O held under a lock. The input and output
/// streams are independently pumped (`StreamPump`), so a blocked read can never
/// stall a write or a close. No lock is held across blocking I/O — the pumps
/// suspend the caller and resume it from a delegate callback when the stream is
/// ready.
public final class MultipeerConnectivityChannel: PeerConnectivityChannel {
    public let peer: PeerConnectivityPeer
    public let protocolID: String?

    private let inputPump: InputStreamPump?
    private let outputPump: OutputStreamPump?

    public init(
        peer: PeerConnectivityPeer,
        protocolID: String?,
        input: InputStream?,
        output: OutputStream?
    ) {
        self.peer = peer
        self.protocolID = protocolID
        self.inputPump = input.map { InputStreamPump(stream: $0) }
        self.outputPump = output.map { OutputStreamPump(stream: $0) }
    }

    public func read() async throws -> ByteBuffer {
        guard let inputPump else {
            throw PeerConnectivityError.channelUnavailable
        }
        return try await inputPump.read()
    }

    public func write(_ bytes: ByteBuffer) async throws {
        guard let outputPump else {
            throw PeerConnectivityError.channelUnavailable
        }
        try await outputPump.write(bytes)
    }

    public func close() async throws {
        inputPump?.close()
        outputPump?.close()
    }
}
#else
public actor MultipeerConnectivityBackend: PeerConnectivityBackend {
    public let capabilities: PeerConnectivityCapabilities = []
    public nonisolated var events: AsyncStream<PeerConnectivityEvent> { AsyncStream { $0.finish() } }

    public init(serviceType: String, displayName: String) {}
    public func start() async throws { throw PeerConnectivityError.missingCapabilities(.nearbyDiscovery) }
    public func shutdown() async throws {}
    public func connect(to endpoint: PeerConnectivityEndpoint) async throws -> PeerConnectivityPeer { throw PeerConnectivityError.unsupportedEndpoint(endpoint) }
    public func disconnect(from peer: PeerConnectivityPeer) async throws {}
    public func send(_ bytes: ByteBuffer, to peer: PeerConnectivityPeer, mode: PeerSendMode) async throws { throw PeerConnectivityError.missingCapabilities(.messageSend) }
    public func openChannel(to peer: PeerConnectivityPeer, protocol protocolID: String) async throws -> any PeerConnectivityChannel { throw PeerConnectivityError.channelUnavailable }
    public func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws { throw PeerConnectivityError.missingCapabilities(.resourceTransfer) }
}
#endif

public extension PeerConnectivitySession {
    static func multipeer(serviceType: String, displayName: String) -> PeerConnectivitySession {
        PeerConnectivitySession(
            backend: MultipeerConnectivityBackend(serviceType: serviceType, displayName: displayName)
        )
    }
}
