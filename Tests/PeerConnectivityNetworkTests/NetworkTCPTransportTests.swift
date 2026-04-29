import NIOCore
import NIOFoundationCompat
import P2PCore
import P2PTransport
import PeerConnectivityNetwork
import Testing

@Suite("Network TCP Transport Tests")
struct NetworkTCPTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func loopbackReadWrite() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))
        let connection = try await transport.dial(listener.localAddress)
        let accepted = try await listener.accept()

        var outbound = ByteBuffer()
        outbound.writeString("hello-network")
        try await connection.write(outbound)

        var inbound = try await accepted.read()
        #expect(inbound.readString(length: inbound.readableBytes) == "hello-network")

        try await connection.close()
        try await accepted.close()
        try await listener.close()
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func dnsLocalhostDialReadWrite() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))
        let port = try #require(listener.localAddress.tcpPort)
        let connection = try await transport.dial(try Multiaddr("/dns/localhost/tcp/\(port)"))
        let accepted = try await listener.accept()

        var outbound = ByteBuffer()
        outbound.writeString("hello-dns")
        try await connection.write(outbound)

        var inbound = try await accepted.read()
        #expect(inbound.readString(length: inbound.readableBytes) == "hello-dns")

        try await connection.close()
        try await accepted.close()
        try await listener.close()
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func ipv6LoopbackReadWrite() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "::1", port: 0))
        let connection = try await transport.dial(listener.localAddress)
        let accepted = try await listener.accept()

        var outbound = ByteBuffer()
        outbound.writeString("hello-ipv6")
        try await connection.write(outbound)

        var inbound = try await accepted.read()
        #expect(inbound.readString(length: inbound.readableBytes) == "hello-ipv6")

        try await connection.close()
        try await accepted.close()
        try await listener.close()
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func largePayloadReadWrite() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))
        let connection = try await transport.dial(listener.localAddress)
        let accepted = try await listener.accept()
        let payload = (0..<200_000).map { UInt8($0 % 251) }

        var outbound = ByteBuffer()
        outbound.writeBytes(payload)
        try await connection.write(outbound)

        let received = try await readBytes(count: payload.count, from: accepted)
        #expect(received == payload)

        try await connection.close()
        try await accepted.close()
        try await listener.close()
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptsMultipleConcurrentConnections() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))

        let clients = (0..<3).map { index in
            Task {
                let connection = try await transport.dial(listener.localAddress)
                var outbound = ByteBuffer()
                outbound.writeString("client-\(index)")
                try await connection.write(outbound)
                return connection
            }
        }

        var messages = Set<String>()
        for _ in 0..<clients.count {
            let accepted = try await listener.accept()
            var inbound = try await accepted.read()
            if let message = inbound.readString(length: inbound.readableBytes) {
                messages.insert(message)
            }
            try await accepted.close()
        }

        for client in clients {
            let connection = try await client.value
            try await connection.close()
        }
        try await listener.close()

        #expect(messages == ["client-0", "client-1", "client-2"])
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func supportsTCPMultiaddrs() throws {
        let transport = NetworkTCPTransport()

        #expect(transport.canDial(try Multiaddr("/ip4/127.0.0.1/tcp/4001")))
        #expect(transport.canDial(try Multiaddr("/ip6/::1/tcp/4001")))
        #expect(transport.canDial(try Multiaddr("/dns4/example.com/tcp/4001")))
        #expect(transport.canDial(try Multiaddr("/dns6/example.com/tcp/4001")))
        #expect(transport.canDial(try Multiaddr("/dns/example.com/tcp/4001")))
    }

    @Test(.timeLimit(.minutes(1)))
    func supportsTCPListenMultiaddrs() throws {
        let transport = NetworkTCPTransport()

        #expect(transport.canListen(try Multiaddr("/ip4/127.0.0.1/tcp/4001")))
        #expect(transport.canListen(try Multiaddr("/ip6/::1/tcp/4001")))
        #expect(transport.canListen(try Multiaddr("/dns4/localhost/tcp/4001")))
        #expect(transport.canListen(try Multiaddr("/dns6/localhost/tcp/4001")))
        #expect(transport.canListen(try Multiaddr("/dns/localhost/tcp/4001")))
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingAcceptFailsWhenListenerCloses() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))

        let acceptTask = Task {
            try await listener.accept()
        }
        try await Task.sleep(for: .milliseconds(50))
        try await listener.close()

        do {
            _ = try await acceptTask.value
            Issue.record("accept unexpectedly succeeded")
        } catch {
            #expect(error is TransportError)
        }
        #else
        #expect(Bool(true))
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingReadFailsWhenConnectionCloses() async throws {
        #if canImport(Network)
        let transport = NetworkTCPTransport()
        let listener = try await transport.listen(Multiaddr.tcp(host: "127.0.0.1", port: 0))
        let connection = try await transport.dial(listener.localAddress)
        let accepted = try await listener.accept()

        let readTask = Task {
            try await accepted.read()
        }
        try await Task.sleep(for: .milliseconds(50))
        try await connection.close()

        do {
            _ = try await readTask.value
            Issue.record("read unexpectedly succeeded")
        } catch {
            #expect(error is TransportError)
        }

        try await accepted.close()
        try await listener.close()
        #else
        #expect(Bool(true))
        #endif
    }

    private func readBytes(count: Int, from connection: any RawConnection) async throws -> [UInt8] {
        var received: [UInt8] = []
        while received.count < count {
            let chunk = try await connection.read()
            received.append(contentsOf: chunk.readableBytesView)
        }
        return received
    }
}
