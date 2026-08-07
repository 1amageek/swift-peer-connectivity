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
    /// An error surfaced by the backend.
    ///
    /// The error is carried inside a `PeerConnectivityErrorEvent` envelope so
    /// callers can attribute it to a specific operation and, when known, a peer,
    /// instead of receiving an untyped, unattributed `any Error`.
    case error(PeerConnectivityErrorEvent)
}

/// The operation a backend was performing when an error was surfaced.
///
/// Used to attribute `PeerConnectivityEvent.error` so callers can distinguish,
/// for example, an inbound-message decode failure from an outbound resource
/// transfer failure.
public enum PeerConnectivityOperation: Sendable, Hashable {
    case start
    case listen
    case connect
    case inboundMessage
    case inboundResource
    case outboundResource
    case discovery
    case other(String)
}

/// A typed envelope attaching context (operation kind and, when known, peer) to
/// an error surfaced through `PeerConnectivityEvent.error`.
///
/// Equality compares only the structured context (operation and peer); the
/// underlying `error` is not `Equatable`, so it is excluded from `==`.
public struct PeerConnectivityErrorEvent: Error, Sendable, Equatable {
    public let operation: PeerConnectivityOperation
    public let peer: PeerConnectivityPeer?
    public let error: any Error

    public init(
        operation: PeerConnectivityOperation,
        peer: PeerConnectivityPeer? = nil,
        error: any Error
    ) {
        self.operation = operation
        self.peer = peer
        self.error = error
    }

    public static func == (lhs: PeerConnectivityErrorEvent, rhs: PeerConnectivityErrorEvent) -> Bool {
        lhs.operation == rhs.operation && lhs.peer == rhs.peer
    }
}

public enum PeerConnectivityError: Error, Sendable, Equatable {
    case missingCapabilities(PeerConnectivityCapabilities)
    case unsupportedEndpoint(PeerConnectivityEndpoint)
    case peerIdentityRequired
    case channelUnavailable
    case channelClosed
    case invalidResource
    case resourceTooLarge(Int)
    case messageTooLarge(Int)
    case backendStopped
    case unsupportedOperation(String)
    /// One or more required listen addresses were missing for an operation that
    /// advertises an inbound capability (e.g. `enableBonjour` with no listen
    /// address to announce).
    case listenAddressRequired(String)
    /// Reading an inbound transfer ended before the framed payload was complete.
    ///
    /// Surfaced instead of delivering a truncated payload as a complete message.
    case incompleteMessage(expected: Int, received: Int)
    /// An inbound read exceeded its idle timeout and the stream was closed.
    case readTimeout
}

/// The outcome of attempting to send to a single peer in a multi-peer send.
public struct PeerSendOutcome: Sendable {
    public let peer: PeerConnectivityPeer
    public let error: (any Error)?

    public var succeeded: Bool { error == nil }

    public init(peer: PeerConnectivityPeer, error: (any Error)? = nil) {
        self.peer = peer
        self.error = error
    }
}

/// Aggregated result of a multi-peer send.
///
/// A multi-peer `send` attempts every peer (it never aborts mid-batch) and
/// reports per-peer outcomes. When at least one peer fails, `send` throws a
/// `PeerSendError` carrying this aggregate so the caller can see exactly which
/// peers succeeded and which failed — there is no silent partial success.
public struct PeerSendError: Error, Sendable {
    public let outcomes: [PeerSendOutcome]

    public init(outcomes: [PeerSendOutcome]) {
        self.outcomes = outcomes
    }

    public var succeeded: [PeerConnectivityPeer] {
        outcomes.filter { $0.succeeded }.map { $0.peer }
    }

    public var failed: [PeerSendOutcome] {
        outcomes.filter { !$0.succeeded }
    }
}
