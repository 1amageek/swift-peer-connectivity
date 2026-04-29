import Foundation

public struct PeerConnectivityCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let libp2pInterop = PeerConnectivityCapabilities(rawValue: 1 << 0)
    public static let nearbyDiscovery = PeerConnectivityCapabilities(rawValue: 1 << 1)
    public static let bonjourDiscovery = PeerConnectivityCapabilities(rawValue: 1 << 2)
    public static let inboundListening = PeerConnectivityCapabilities(rawValue: 1 << 3)
    public static let messageSend = PeerConnectivityCapabilities(rawValue: 1 << 4)
    public static let streamMultiplexing = PeerConnectivityCapabilities(rawValue: 1 << 5)
    public static let resourceTransfer = PeerConnectivityCapabilities(rawValue: 1 << 6)
    public static let relay = PeerConnectivityCapabilities(rawValue: 1 << 7)
    public static let backgroundLimited = PeerConnectivityCapabilities(rawValue: 1 << 8)
    public static let invitation = PeerConnectivityCapabilities(rawValue: 1 << 9)
}
