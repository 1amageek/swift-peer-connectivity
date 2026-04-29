import Foundation
import P2PCore
import P2PDiscovery

#if canImport(Network)
@preconcurrency import Network
#endif

public actor NetworkBonjourDiscovery: DiscoveryService {
    public let localPeerID: PeerID

    private let configuration: NetworkBonjourConfiguration
    private let observationsBroadcaster = EventBroadcaster<PeerObservation>()
    private var knownCandidates: [PeerID: ScoredCandidate] = [:]
    private var sequenceNumber: UInt64 = 0
    private var isShutdown = false

    #if canImport(Network)
    private var browser: NWBrowser?
    private var listener: NWListener?
    #endif

    public nonisolated var observations: AsyncStream<PeerObservation> {
        observationsBroadcaster.subscribe()
    }

    public init(
        localPeerID: PeerID,
        configuration: NetworkBonjourConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
    }

    public func startBrowsing() async throws {
        #if canImport(Network)
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: configuration.serviceType, domain: configuration.domain),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            Task {
                await self?.handle(changes: changes)
            }
        }
        self.browser = browser
        browser.start(queue: DispatchQueue(label: "swift-libp2p.bonjour.browser"))
        #else
        throw NetworkBonjourDiscoveryError.unavailable
        #endif
    }

    public func announce(addresses: [Multiaddr]) async throws {
        #if canImport(Network)
        guard listener == nil else { return }
        let port = addresses.compactMap(\.tcpPort).first ?? 0
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkBonjourDiscoveryError.invalidPort(port)
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.service = NWListener.Service(
            name: localPeerID.description,
            type: configuration.serviceType,
            domain: configuration.domain,
            txtRecord: NetworkBonjourTXTCodec.txtRecord(
                peerID: localPeerID,
                addresses: addresses,
                agentVersion: configuration.agentVersion
            )
        )
        self.listener = listener
        listener.start(queue: DispatchQueue(label: "swift-libp2p.bonjour.advertiser"))
        #else
        throw NetworkBonjourDiscoveryError.unavailable
        #endif
    }

    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        if let candidate = knownCandidates[peer] {
            return [candidate]
        }
        return []
    }

    public nonisolated func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        let source = observationsBroadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await observation in source where observation.subject == peer {
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func collectKnownPeers() async -> [PeerID] {
        Array(knownCandidates.keys)
    }

    public func shutdown() async throws {
        guard !isShutdown else { return }
        isShutdown = true
        observationsBroadcaster.shutdown()
        #if canImport(Network)
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        #endif
        knownCandidates.removeAll()
    }

    #if canImport(Network)
    private func handle(changes: Set<NWBrowser.Result.Change>) async {
        for change in changes {
            switch change {
            case .added(let result):
                await add(result)
            case .changed(old: _, new: let new, flags: _):
                await add(new)
            case .removed(let result):
                await remove(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func add(_ result: NWBrowser.Result) async {
        guard let serviceName = serviceName(from: result.endpoint) else {
            return
        }

        let candidate: ScoredCandidate
        do {
            candidate = try NetworkBonjourTXTCodec.candidate(
                serviceName: serviceName,
                txt: txtDictionary(from: result.metadata),
                observer: localPeerID
            )
        } catch {
            return
        }

        guard candidate.peerID != localPeerID else { return }
        knownCandidates[candidate.peerID] = candidate
        emitObservation(subject: candidate.peerID, kind: .announcement, hints: candidate.addresses)
    }

    private func remove(_ result: NWBrowser.Result) async {
        guard let serviceName = serviceName(from: result.endpoint) else {
            return
        }

        let peerID: PeerID
        do {
            peerID = try PeerID(string: serviceName)
        } catch {
            return
        }
        knownCandidates.removeValue(forKey: peerID)
        emitObservation(subject: peerID, kind: .unreachable, hints: [])
    }

    private func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case .service(let name, _, _, _) = endpoint else {
            return nil
        }
        return name
    }

    private func txtDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case .bonjour(let record) = metadata else {
            return [:]
        }
        return NetworkBonjourTXTCodec.dictionary(from: record)
    }
    #endif

    private func emitObservation(
        subject: PeerID,
        kind: PeerObservation.Kind,
        hints: [Multiaddr]
    ) {
        sequenceNumber += 1
        observationsBroadcaster.emit(PeerObservation(
            subject: subject,
            observer: localPeerID,
            kind: kind,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        ))
    }
}

public enum NetworkBonjourDiscoveryError: Error, Sendable, Equatable {
    case unavailable
    case invalidPort(UInt16)
}
