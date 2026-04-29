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

    @Test(.timeLimit(.minutes(1)))
    func dictionaryAddsPeerIDToEveryAddress() throws {
        let peerID = KeyPair.generateEd25519().peerID
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip6/::1/tcp/4002")
        ]

        let dictionary = NetworkBonjourTXTCodec.dictionary(
            peerID: peerID,
            addresses: addresses,
            agentVersion: "test-agent"
        )

        let candidate = try NetworkBonjourTXTCodec.candidate(
            serviceName: peerID.description,
            txt: dictionary,
            observer: peerID
        )

        #expect(dictionary["agent"] == "test-agent")
        #expect(dictionary["dnsaddr"] == dictionary["dnsaddr.0"])
        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses.allSatisfy { $0.peerID == peerID })
    }

    @Test(.timeLimit(.minutes(1)))
    func candidateDeduplicatesRepeatedAddresses() throws {
        let peerID = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001").appending(.p2p(peerID))
        let txt = [
            "dnsaddr": address.description,
            "dnsaddr.0": address.description,
            "dnsaddr.1": address.description
        ]

        let candidate = try NetworkBonjourTXTCodec.candidate(
            serviceName: peerID.description,
            txt: txt,
            observer: peerID
        )

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses == [address])
    }

    @Test(.timeLimit(.minutes(1)))
    func candidateFallsBackToServiceNameWhenTXTContainsNoAddress() throws {
        let peerID = KeyPair.generateEd25519().peerID

        let candidate = try NetworkBonjourTXTCodec.candidate(
            serviceName: peerID.description,
            txt: ["agent": "test-agent"],
            observer: peerID
        )

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.isEmpty)
        #expect(candidate.score == 0.2)
    }

    @Test(.timeLimit(.minutes(1)))
    func candidateIgnoresInvalidDNSAddrValues() throws {
        let peerID = KeyPair.generateEd25519().peerID
        let valid = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let candidate = try NetworkBonjourTXTCodec.candidate(
            serviceName: peerID.description,
            txt: [
                "dnsaddr": "not-a-multiaddr",
                "dnsaddr.1": valid.description
            ],
            observer: peerID
        )

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses.first?.peerID == peerID)
    }
}
