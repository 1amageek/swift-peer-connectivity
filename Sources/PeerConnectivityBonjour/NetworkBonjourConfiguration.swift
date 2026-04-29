import Foundation

public struct NetworkBonjourConfiguration: Sendable, Equatable {
    public var serviceType: String
    public var domain: String?
    public var agentVersion: String

    public init(
        serviceType: String = "_p2p._tcp",
        domain: String? = nil,
        agentVersion: String = "swift-libp2p/1.0"
    ) {
        self.serviceType = serviceType
        self.domain = domain
        self.agentVersion = agentVersion
    }

    public static let `default` = NetworkBonjourConfiguration()
}
