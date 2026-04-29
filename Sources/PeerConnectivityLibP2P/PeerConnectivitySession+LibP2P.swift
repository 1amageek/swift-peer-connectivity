import P2P
import P2PCore
import PeerConnectivityBonjour
import P2PMuxYamux
import PeerConnectivity
import P2PSecurityNoise
import PeerConnectivityNetwork

public struct AppleNetworkLibP2PConfiguration: Sendable {
    public var keyPair: KeyPair
    public var listenAddresses: [Multiaddr]
    public var enableBonjour: Bool
    public var bonjour: NetworkBonjourConfiguration

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        enableBonjour: Bool = false,
        bonjour: NetworkBonjourConfiguration = .default
    ) {
        self.keyPair = keyPair
        self.listenAddresses = listenAddresses
        self.enableBonjour = enableBonjour
        self.bonjour = bonjour
    }
}

public extension PeerConnectivitySession {
    static func libp2p(
        node: Node,
        capabilities: PeerConnectivityCapabilities? = nil
    ) -> PeerConnectivitySession {
        PeerConnectivitySession(
            backend: LibP2PPeerConnectivityBackend(node: node, capabilities: capabilities)
        )
    }

    static func appleNetworkLibP2P(
        configuration: AppleNetworkLibP2PConfiguration = AppleNetworkLibP2PConfiguration()
    ) throws -> PeerConnectivitySession {
        let node: Node
        if configuration.enableBonjour {
            let discovery = NetworkBonjourDiscovery(
                localPeerID: configuration.keyPair.peerID,
                configuration: configuration.bonjour
            )
            node = try Node(
                keyPair: configuration.keyPair,
                listenAddresses: configuration.listenAddresses,
                transports: [NetworkTCPTransport()],
                security: [NoiseUpgrader()],
                muxers: [YamuxMuxer()]
            ) {
                Discovery(discovery).onStart { service in
                    try await service.startBrowsing()
                }
            }
        } else {
            node = try Node(
                keyPair: configuration.keyPair,
                listenAddresses: configuration.listenAddresses,
                transports: [NetworkTCPTransport()],
                security: [NoiseUpgrader()],
                muxers: [YamuxMuxer()]
            )
        }

        var capabilities: PeerConnectivityCapabilities = [
            .libp2pInterop,
            .messageSend,
            .streamMultiplexing,
            .resourceTransfer,
            .backgroundLimited
        ]
        if !configuration.listenAddresses.isEmpty {
            capabilities.insert(.inboundListening)
        }
        if configuration.enableBonjour {
            capabilities.insert(.bonjourDiscovery)
        }

        return PeerConnectivitySession(
            backend: LibP2PPeerConnectivityBackend(
                node: node,
                capabilities: capabilities
            )
        )
    }
}
