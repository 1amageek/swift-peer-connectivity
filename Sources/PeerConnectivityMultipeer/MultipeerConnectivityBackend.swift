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

    public func start() async throws {
        try await startBrowsing()
        try await startAdvertising()
    }

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
        guard let target = delegate.peer(withID: peer.id) else {
            throw PeerConnectivityError.peerIdentityRequired
        }
        let mcMode: MCSessionSendDataMode = mode == .reliable ? .reliable : .unreliable
        try session.send(Data(bytes.readableBytesView), toPeers: [target], with: mcMode)
    }

    public func openChannel(
        to peer: PeerConnectivityPeer,
        protocol protocolID: String
    ) async throws -> any PeerConnectivityChannel {
        guard let target = delegate.peer(withID: peer.id) else {
            throw PeerConnectivityError.peerIdentityRequired
        }
        let stream = try session.startStream(withName: protocolID, toPeer: target)
        return MultipeerConnectivityChannel(
            peer: peer,
            protocolID: protocolID,
            input: nil,
            output: stream
        )
    }

    public func sendResource(_ resource: PeerResource, to peer: PeerConnectivityPeer) async throws {
        guard let target = delegate.peer(withID: peer.id) else {
            throw PeerConnectivityError.peerIdentityRequired
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ResourceTransferCompletion(continuation: continuation)
            let progress = session.sendResource(at: resource.url, withName: resource.name, toPeer: target) { [eventBroadcaster] error in
                if let error {
                    eventBroadcaster.emit(.error(error))
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
    private let peers = Mutex<[String: MCPeerID]>([:])

    init(session: MCSession, eventBroadcaster: PeerConnectivityEventBroadcaster<PeerConnectivityEvent>) {
        self.session = session
        self.eventBroadcaster = eventBroadcaster
    }

    func peer(withID id: String) -> MCPeerID? {
        peers.withLock { $0[id] }
    }

    private func register(_ peerID: MCPeerID) throws -> PeerConnectivityPeer {
        let peer = try MultipeerPeerCodec.peer(from: peerID)
        peers.withLock { $0[peer.id] = peerID }
        return peer
    }

    private func unregister(_ peerID: MCPeerID) throws -> PeerConnectivityPeer {
        let peer = try MultipeerPeerCodec.peer(from: peerID)
        _ = peers.withLock { $0.removeValue(forKey: peer.id) }
        return peer
    }

    func removeAllPeers() {
        peers.withLock { $0.removeAll() }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        do {
            let peer = try register(peerID)
            eventBroadcaster.emit(.peerDiscovered(peer, endpoints: peer.endpoints))
        } catch {
            eventBroadcaster.emit(.error(error))
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        do {
            let peer = try unregister(peerID)
            eventBroadcaster.emit(.peerLost(peer))
        } catch {
            eventBroadcaster.emit(.error(error))
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        eventBroadcaster.emit(.error(error))
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        do {
            _ = try register(peerID)
        } catch {
            eventBroadcaster.emit(.error(error))
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        eventBroadcaster.emit(.error(error))
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            do {
                eventBroadcaster.emit(.peerConnected(try register(peerID)))
            } catch {
                eventBroadcaster.emit(.error(error))
            }
        case .notConnected:
            do {
                eventBroadcaster.emit(.peerDisconnected(try unregister(peerID)))
            } catch {
                eventBroadcaster.emit(.error(error))
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
            eventBroadcaster.emit(.messageReceived(buffer, from: try register(peerID)))
        } catch {
            eventBroadcaster.emit(.error(error))
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        do {
            let peer = try register(peerID)
            eventBroadcaster.emit(.channelOpened(MultipeerConnectivityChannel(
                peer: peer,
                protocolID: streamName,
                input: stream,
                output: nil
            )))
        } catch {
            eventBroadcaster.emit(.error(error))
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
        if let error {
            eventBroadcaster.emit(.error(error))
        } else if let localURL {
            do {
                eventBroadcaster.emit(.resourceReceived(
                    PeerResource(url: localURL, name: resourceName),
                    from: try register(peerID)
                ))
            } catch {
                eventBroadcaster.emit(.error(error))
            }
        }
    }
}

public final class MultipeerConnectivityChannel: PeerConnectivityChannel {
    public let peer: PeerConnectivityPeer
    public let protocolID: String?

    private let lock = Mutex(())
    nonisolated(unsafe) private let input: InputStream?
    nonisolated(unsafe) private let output: OutputStream?

    public init(
        peer: PeerConnectivityPeer,
        protocolID: String?,
        input: InputStream?,
        output: OutputStream?
    ) {
        self.peer = peer
        self.protocolID = protocolID
        self.input = input
        self.output = output
        self.input?.open()
        self.output?.open()
    }

    public func read() async throws -> ByteBuffer {
        try lock.withLock { _ in
            guard let input else {
                throw PeerConnectivityError.channelUnavailable
            }

            var storage = [UInt8](repeating: 0, count: 64 * 1024)
            let count = input.read(&storage, maxLength: storage.count)
            if count > 0 {
                return ByteBuffer(bytes: storage.prefix(count))
            }
            if let error = input.streamError {
                throw error
            }
            throw PeerConnectivityError.channelClosed
        }
    }

    public func write(_ bytes: ByteBuffer) async throws {
        try lock.withLock { _ in
            guard let output else {
                throw PeerConnectivityError.channelUnavailable
            }

            let storage = Array(bytes.readableBytesView)
            var written = 0
            while written < storage.count {
                let count = storage.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return 0
                    }
                    return output.write(
                        baseAddress.advanced(by: written).assumingMemoryBound(to: UInt8.self),
                        maxLength: storage.count - written
                    )
                }
                if count > 0 {
                    written += count
                    continue
                }
                if let error = output.streamError {
                    throw error
                }
                throw PeerConnectivityError.channelClosed
            }
        }
    }

    public func close() async throws {
        lock.withLock { _ in
            input?.close()
            output?.close()
        }
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
