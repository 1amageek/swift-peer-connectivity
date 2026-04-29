import Foundation
import NIOCore

public struct PeerConnectivityPeer: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let identity: PeerConnectivityPeerIdentity?
    public let endpoints: [PeerConnectivityEndpoint]
    public let metadata: [String: String]

    public init(
        id: String,
        displayName: String,
        identity: PeerConnectivityPeerIdentity? = nil,
        endpoints: [PeerConnectivityEndpoint] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.identity = identity
        self.endpoints = endpoints
        self.metadata = metadata
    }

}

public enum PeerConnectivityPeerIdentity: Sendable, Hashable {
    case backend(kind: String, value: String)
}

public enum PeerConnectivityEndpoint: Sendable, Hashable {
    case libp2p(String)
    case namedService(String)
    case native(String)

    public var libp2pAddress: String? {
        if case .libp2p(let address) = self {
            return address
        }
        return nil
    }
}

public enum PeerSendMode: Sendable, Hashable {
    case reliable
    case unreliable
}

public struct PeerResource: Sendable, Hashable {
    public let url: URL
    public let name: String

    public init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
    }
}

public enum PeerConnectivityEvent: Sendable {
    case peerDiscovered(PeerConnectivityPeer, endpoints: [PeerConnectivityEndpoint])
    case peerLost(PeerConnectivityPeer)
    case peerConnected(PeerConnectivityPeer)
    case peerDisconnected(PeerConnectivityPeer)
    case channelOpened(any PeerConnectivityChannel)
    case messageReceived(ByteBuffer, from: PeerConnectivityPeer)
    case resourceReceived(PeerResource, from: PeerConnectivityPeer)
    case error(any Error)
}

public enum PeerConnectivityError: Error, Sendable, Equatable {
    case missingCapabilities(PeerConnectivityCapabilities)
    case unsupportedEndpoint(PeerConnectivityEndpoint)
    case peerIdentityRequired
    case channelUnavailable
    case channelClosed
    case invalidResource
    case resourceTooLarge(Int)
    case backendStopped
    case unsupportedOperation(String)
}
