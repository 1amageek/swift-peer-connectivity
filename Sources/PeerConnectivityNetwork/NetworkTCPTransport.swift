import Foundation
import NIOCore
import P2PCore
import P2PTransport
import Synchronization

#if canImport(Network)
@preconcurrency import Network
#endif

public final class NetworkTCPTransport: Transport, Sendable {
    public var protocols: [[String]] {
        [["ip4", "tcp"], ["ip6", "tcp"], ["dns4", "tcp"], ["dns6", "tcp"], ["dns", "tcp"]]
    }

    public var pathKind: TransportPathKind { .ip }

    public init() {}

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        #if canImport(Network)
        guard let endpoint = NetworkAddressCodec.endpoint(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }
        return try await NetworkTCPConnection.connect(to: endpoint, remoteAddress: address)
        #else
        throw TransportError.unsupportedOperation("Network.framework is unavailable on this platform")
        #endif
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        #if canImport(Network)
        guard let port = address.tcpPort else {
            throw TransportError.unsupportedAddress(address)
        }
        return try await NetworkTCPListener.bind(address: address, port: port)
        #else
        throw TransportError.unsupportedOperation("Network.framework is unavailable on this platform")
        #endif
    }

    public func canDial(_ address: Multiaddr) -> Bool {
        guard address.tcpPort != nil else { return false }
        return NetworkAddressCodec.host(from: address) != nil
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        address.tcpPort != nil && NetworkAddressCodec.host(from: address) != nil
    }
}

private enum NetworkAddressCodec {
    static func host(from address: Multiaddr) -> String? {
        for proto in address.protocols {
            switch proto {
            case .ip4(let value), .ip6(let value), .dns4(let value), .dns6(let value), .dns(let value):
                return value
            default:
                continue
            }
        }
        return nil
    }

    #if canImport(Network)
    static func endpoint(from address: Multiaddr) -> NWEndpoint? {
        guard let host = host(from: address),
              let portValue = address.tcpPort,
              let port = NWEndpoint.Port(rawValue: portValue) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    static func multiaddr(from endpoint: NWEndpoint, fallback: Multiaddr) -> Multiaddr {
        guard case .hostPort(let host, let port) = endpoint else {
            return fallback
        }

        return Multiaddr.tcp(host: String(describing: host), port: port.rawValue)
    }

    static func listenerAddress(from original: Multiaddr, resolvedPort: UInt16) -> Multiaddr {
        guard let host = host(from: original) else {
            return Multiaddr.tcp(host: "0.0.0.0", port: resolvedPort)
        }
        return Multiaddr.tcp(host: host, port: resolvedPort)
    }
    #endif
}

#if canImport(Network)
public final class NetworkTCPConnection: RawConnection, Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let _localAddress: Multiaddr?
    private let _remoteAddress: Multiaddr
    private let state = Mutex(ConnectionState())

    private struct ConnectionState: Sendable {
        var isClosed = false
        var pendingReady: CheckedContinuation<Void, Error>?
    }

    public var localAddress: Multiaddr? { _localAddress }
    public var remoteAddress: Multiaddr { _remoteAddress }

    private init(
        connection: NWConnection,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self._localAddress = localAddress
        self._remoteAddress = remoteAddress
        self.queue = queue
    }

    static func connect(to endpoint: NWEndpoint, remoteAddress: Multiaddr) async throws -> NetworkTCPConnection {
        let queue = DispatchQueue(label: "swift-libp2p.network-tcp.connection")
        let connection = NWConnection(to: endpoint, using: .tcp)
        let wrapped = NetworkTCPConnection(
            connection: connection,
            localAddress: nil,
            remoteAddress: remoteAddress,
            queue: queue
        )
        try await wrapped.start()
        return wrapped
    }

    static func accepted(
        _ connection: NWConnection,
        localAddress: Multiaddr,
        remoteAddress: Multiaddr
    ) -> NetworkTCPConnection {
        let queue = DispatchQueue(label: "swift-libp2p.network-tcp.accepted")
        let wrapped = NetworkTCPConnection(
            connection: connection,
            localAddress: localAddress,
            remoteAddress: remoteAddress,
            queue: queue
        )
        connection.start(queue: queue)
        return wrapped
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shouldStart = state.withLock { state -> Bool in
                guard !state.isClosed else {
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return false
                }
                state.pendingReady = continuation
                return true
            }

            guard shouldStart else { return }

            connection.stateUpdateHandler = { [weak self] nwState in
                self?.handleStateUpdate(nwState)
            }
            connection.start(queue: queue)
        }
    }

    public func read() async throws -> ByteBuffer {
        guard !state.withLock({ $0.isClosed }) else {
            throw TransportError.connectionClosed
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: TransportError.connectionFailed(underlying: error))
                    return
                }
                if isComplete && (data == nil || data?.isEmpty == true) {
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return
                }
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return
                }
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                continuation.resume(returning: buffer)
            }
        }
    }

    public func write(_ data: ByteBuffer) async throws {
        guard !state.withLock({ $0.isClosed }) else {
            throw TransportError.connectionClosed
        }

        let bytes = Data(data.readableBytesView)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.connectionFailed(underlying: error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() async throws {
        let wasOpen = state.withLock { state -> Bool in
            let wasOpen = !state.isClosed
            state.isClosed = true
            if let pending = state.pendingReady {
                state.pendingReady = nil
                pending.resume(throwing: TransportError.connectionClosed)
            }
            return wasOpen
        }

        if wasOpen {
            connection.cancel()
        }
    }

    private func handleStateUpdate(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            resumeReady()
        case .failed(let error):
            resumeReady(throwing: TransportError.connectionFailed(underlying: error))
            markClosed()
        case .cancelled:
            resumeReady(throwing: TransportError.connectionClosed)
            markClosed()
        default:
            break
        }
    }

    private func resumeReady(throwing error: (any Error)? = nil) {
        let pending = state.withLock { state -> CheckedContinuation<Void, Error>? in
            let pending = state.pendingReady
            state.pendingReady = nil
            return pending
        }

        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    private func markClosed() {
        state.withLock { $0.isClosed = true }
    }
}

public final class NetworkTCPListener: Listener, Sendable {
    private let listener: NWListener
    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var localAddress: Multiaddr
        var pendingConnections: [any RawConnection] = []
        var acceptWaiters: [CheckedContinuation<any RawConnection, Error>] = []
        var readyWaiter: CheckedContinuation<Void, Error>?
        var isClosed = false
    }

    public var localAddress: Multiaddr {
        state.withLock { $0.localAddress }
    }

    private init(listener: NWListener, localAddress: Multiaddr) {
        self.listener = listener
        self.state = Mutex(ListenerState(localAddress: localAddress))
    }

    static func bind(address: Multiaddr, port: UInt16) async throws -> NetworkTCPListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.unsupportedAddress(address)
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        let wrapped = NetworkTCPListener(listener: listener, localAddress: address)
        try await wrapped.start(originalAddress: address)
        return wrapped
    }

    private func start(originalAddress: Multiaddr) async throws {
        let queue = DispatchQueue(label: "swift-libp2p.network-tcp.listener")

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            self?.handleStateUpdate(listenerState, originalAddress: originalAddress)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock { $0.readyWaiter = continuation }
            listener.start(queue: queue)
        }
    }

    public func accept() async throws -> any RawConnection {
        try await withCheckedThrowingContinuation { continuation in
            enum AcceptAction {
                case closed
                case ready(any RawConnection)
                case waiting
            }

            let action = state.withLock { state -> AcceptAction in
                if state.isClosed {
                    return .closed
                }
                if !state.pendingConnections.isEmpty {
                    return .ready(state.pendingConnections.removeFirst())
                }
                state.acceptWaiters.append(continuation)
                return .waiting
            }

            switch action {
            case .closed:
                continuation.resume(throwing: TransportError.listenerClosed)
            case .ready(let connection):
                continuation.resume(returning: connection)
            case .waiting:
                break
            }
        }
    }

    public func close() async throws {
        let (waiters, pending) = state.withLock { state -> ([CheckedContinuation<any RawConnection, Error>], [any RawConnection]) in
            state.isClosed = true
            let waiters = state.acceptWaiters
            let pending = state.pendingConnections
            state.acceptWaiters.removeAll()
            state.pendingConnections.removeAll()
            return (waiters, pending)
        }

        for waiter in waiters {
            waiter.resume(throwing: TransportError.listenerClosed)
        }
        for connection in pending {
            do {
                try await connection.close()
            } catch {
                assertionFailure("NetworkTCPListener.close() failed to close pending connection: \(error)")
            }
        }
        listener.cancel()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let local = localAddress
        let remote = NetworkAddressCodec.multiaddr(from: connection.endpoint, fallback: local)
        let wrapped = NetworkTCPConnection.accepted(
            connection,
            localAddress: local,
            remoteAddress: remote
        )

        enum AcceptAction {
            case deliver(CheckedContinuation<any RawConnection, Error>)
            case queue
            case reject
        }

        let action = state.withLock { state -> AcceptAction in
            if state.isClosed {
                return .reject
            }
            if !state.acceptWaiters.isEmpty {
                return .deliver(state.acceptWaiters.removeFirst())
            }
            state.pendingConnections.append(wrapped)
            return .queue
        }

        switch action {
        case .deliver(let waiter):
            waiter.resume(returning: wrapped)
        case .queue:
            break
        case .reject:
            Task {
                do {
                    try await wrapped.close()
                } catch {
                    assertionFailure("NetworkTCPListener rejected connection close failed: \(error)")
                }
            }
        }
    }

    private func handleStateUpdate(_ listenerState: NWListener.State, originalAddress: Multiaddr) {
        switch listenerState {
        case .ready:
            if let port = listener.port {
                state.withLock {
                    $0.localAddress = NetworkAddressCodec.listenerAddress(
                        from: originalAddress,
                        resolvedPort: port.rawValue
                    )
                }
            }
            resumeReady()
        case .failed(let error):
            resumeReady(throwing: TransportError.connectionFailed(underlying: error))
            markClosed()
        case .cancelled:
            resumeReady(throwing: TransportError.listenerClosed)
            markClosed()
        default:
            break
        }
    }

    private func resumeReady(throwing error: (any Error)? = nil) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
            let waiter = state.readyWaiter
            state.readyWaiter = nil
            return waiter
        }

        guard let waiter else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    private func markClosed() {
        let waiters = state.withLock { state -> [CheckedContinuation<any RawConnection, Error>] in
            state.isClosed = true
            let waiters = state.acceptWaiters
            state.acceptWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(throwing: TransportError.listenerClosed)
        }
    }
}
#endif
