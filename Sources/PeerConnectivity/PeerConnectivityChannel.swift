import NIOCore

public protocol PeerConnectivityChannel: Sendable {
    var peer: PeerConnectivityPeer { get }
    var protocolID: String? { get }

    func read() async throws -> ByteBuffer
    func write(_ bytes: ByteBuffer) async throws
    func close() async throws
}
