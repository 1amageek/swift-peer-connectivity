import Foundation
import P2PCore
import P2PDiscovery

#if canImport(Network)
@preconcurrency import Network
#endif

public enum NetworkBonjourTXTCodec {
    public static func dictionary(
        peerID: PeerID,
        addresses: [Multiaddr],
        agentVersion: String
    ) -> [String: String] {
        var dictionary: [String: String] = [
            "agent": agentVersion
        ]

        for (index, address) in addresses.enumerated() {
            let addressWithPeer: Multiaddr
            if address.hasPeerID {
                addressWithPeer = address
            } else {
                do {
                    addressWithPeer = try address.appending(.p2p(peerID))
                } catch {
                    continue
                }
            }

            if index == 0 {
                dictionary["dnsaddr"] = addressWithPeer.description
            }
            dictionary["dnsaddr.\(index)"] = addressWithPeer.description
        }

        return dictionary
    }

    public static func candidate(
        serviceName: String,
        txt: [String: String],
        observer: PeerID
    ) throws -> ScoredCandidate {
        let addresses = txt
            .filter { key, _ in key == "dnsaddr" || key.hasPrefix("dnsaddr.") }
            .sorted { $0.key < $1.key }
            .compactMap { _, value -> Multiaddr? in
                do {
                    return try Multiaddr(value)
                } catch {
                    return nil
                }
            }

        let peerID: PeerID
        if let peerFromAddress = addresses.compactMap(\.peerID).first {
            peerID = peerFromAddress
        } else {
            peerID = try PeerID(string: serviceName)
        }

        var seenAddressDescriptions = Set<String>()
        let normalized = try addresses.compactMap { address -> Multiaddr? in
            if address.hasPeerID {
                guard seenAddressDescriptions.insert(address.description).inserted else {
                    return nil
                }
                return address
            }
            let addressWithPeerID = try address.appending(.p2p(peerID))
            guard seenAddressDescriptions.insert(addressWithPeerID.description).inserted else {
                return nil
            }
            return addressWithPeerID
        }

        return ScoredCandidate(
            peerID: peerID,
            addresses: normalized,
            score: normalized.isEmpty ? 0.2 : 0.9
        )
    }

    #if canImport(Network)
    public static func txtRecord(
        peerID: PeerID,
        addresses: [Multiaddr],
        agentVersion: String
    ) -> NWTXTRecord {
        NWTXTRecord(dictionary(peerID: peerID, addresses: addresses, agentVersion: agentVersion))
    }

    public static func dictionary(from record: NWTXTRecord) -> [String: String] {
        record.dictionary
    }
    #endif
}
