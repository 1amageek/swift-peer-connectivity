import P2PCore
import PeerConnectivityBonjour
import Testing

@Suite("Network Bonjour TXT Codec Tests")
struct NetworkBonjourTXTCodecTests {
    @Test(.timeLimit(.minutes(1)))
    func encodesAndDecodesDNSAddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let dictionary = NetworkBonjourTXTCodec.dictionary(
            peerID: peerID,
            addresses: [address],
            agentVersion: "test-agent"
        )

        let candidate = try NetworkBonjourTXTCodec.candidate(
            serviceName: peerID.description,
            txt: dictionary,
            observer: peerID
        )

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses.allSatisfy { $0.hasPeerID })
    }
}
