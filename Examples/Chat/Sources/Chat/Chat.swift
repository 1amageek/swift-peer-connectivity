import Foundation
import NIOCore
import PeerConnectivity
import PeerConnectivityMultipeer

@main
struct Chat {
    static let serviceType = "pc-chat"
    static let nameColumnWidth = 10

    static func main() async throws {
        // Force line-buffered stdout so output is visible when piped to a file or another process.
        setvbuf(stdout, nil, _IOLBF, 0)

        let displayName = CommandLine.arguments.dropFirst().first
            ?? "peer-\(UUID().uuidString.prefix(4))"

        let session = PeerConnectivitySession.multipeer(
            serviceType: serviceType,
            displayName: displayName
        )

        try session.require([.nearbyDiscovery, .messageSend, .invitation])
        let local = try await session.localPeer()

        printHeader(displayName: displayName, serviceType: serviceType)
        try await session.startBrowsing()
        try await session.startAdvertising()

        let inbox = ChatInbox()
        installShutdownHandler(session: session)
        startStdinReader(session: session, inbox: inbox, localName: displayName)

        for await event in session.events {
            switch event {
            case .peerDiscovered(let peer, _):
                print("# discovered \(peer.displayName)")
                // Only one side initiates the invite; the side with the smaller id wins
                // so both peers do not invite each other simultaneously.
                if local.id < peer.id {
                    do {
                        try await session.invite(peer)
                        print("# inviting \(peer.displayName)…")
                    } catch {
                        print("# invite failed: \(error)")
                    }
                }

            case .peerLost(let peer):
                print("# lost \(peer.displayName)")

            case .peerConnected(let peer):
                await inbox.add(peer)
                print("# connected to \(peer.displayName)")

            case .peerDisconnected(let peer):
                await inbox.remove(peer)
                print("# disconnected from \(peer.displayName)")

            case .messageReceived(let bytes, let peer):
                let text = bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes) ?? "<binary>"
                print(formatChatLine(name: peer.displayName, text: text, isOwn: false))

            case .channelOpened, .resourceReceived:
                break

            case .error(let error):
                print("# error: \(error)")
            }
        }
    }

    private static func startStdinReader(
        session: PeerConnectivitySession,
        inbox: ChatInbox,
        localName: String
    ) {
        Task.detached {
            // When stdin is a tty, the terminal echoes the user's input on its own line.
            // After sending we rewrite that line as "[name      ] msg" so it lines up
            // with received messages. When stdin is piped, no echo exists, so we just print.
            let stdinIsTTY = isatty(fileno(stdin)) != 0
            while let line = readLine() {
                guard !line.isEmpty else { continue }

                if line.hasPrefix("/") {
                    await runCommand(line, session: session, inbox: inbox, stdinIsTTY: stdinIsTTY)
                    continue
                }

                let peers = await inbox.snapshot()
                guard !peers.isEmpty else {
                    print("# (no connected peers yet — try /list)")
                    continue
                }
                var buffer = ByteBuffer()
                buffer.writeString(line)
                let formatted = formatChatLine(name: localName, text: line, isOwn: true)
                if stdinIsTTY {
                    // Move up one line, clear it, then print the formatted version in place.
                    print("\u{1b}[1A\r\u{1b}[2K\(formatted)")
                } else {
                    print(formatted)
                }
                // Send per-peer so that a failure to one peer does not prevent
                // delivery to the others, and so that each failure is logged
                // with the failing peer's name.
                for peer in peers {
                    do {
                        try await session.send(buffer, to: peer)
                    } catch {
                        print("# send to \(peer.displayName) failed: \(error)")
                    }
                }
            }
        }
    }

    private static func runCommand(
        _ raw: String,
        session: PeerConnectivitySession,
        inbox: ChatInbox,
        stdinIsTTY: Bool
    ) async {
        let name = raw.dropFirst().split(separator: " ", maxSplits: 1)
            .first.map { $0.lowercased() } ?? ""

        let lines: [String]
        var shouldExit = false

        switch name {
        case "list":
            let peers = await inbox.snapshot()
            if peers.isEmpty {
                lines = ["# no connected peers"]
            } else {
                let names = peers.map(\.displayName).sorted().joined(separator: ", ")
                lines = ["# peers (\(peers.count)): \(names)"]
            }

        case "exit", "quit":
            lines = ["# shutting down…"]
            shouldExit = true

        case "help", "?", "":
            lines = [
                "# /list   show connected peers",
                "# /exit   disconnect and quit",
                "# /help   show this help",
            ]

        default:
            lines = ["# unknown command: /\(name) (try /help)"]
        }

        // In a tty the user's "/cmd" line is still on screen from terminal echo.
        // Replace that line with the first line of the response; subsequent lines
        // print normally below it.
        for (index, text) in lines.enumerated() {
            if index == 0 && stdinIsTTY {
                print("\u{1b}[1A\r\u{1b}[2K\(text)")
            } else {
                print(text)
            }
        }

        if shouldExit {
            try? await session.shutdown()
            exit(0)
        }
    }

    private static func formatChatLine(name: String, text: String, isOwn: Bool) -> String {
        let display = paddedName(name, width: nameColumnWidth)
        let tty = isatty(fileno(stdout)) != 0
        let dim = tty ? "\u{1b}[2m" : ""
        let cyan = tty ? "\u{1b}[36m" : ""
        let yellow = tty ? "\u{1b}[33m" : ""
        let reset = tty ? "\u{1b}[0m" : ""
        let nameColor = isOwn ? yellow : cyan
        return "\(dim)[\(reset)\(nameColor)\(display)\(reset)\(dim)]\(reset) \(text)"
    }

    private static func paddedName(_ name: String, width: Int) -> String {
        if name.count > width {
            return String(name.prefix(width - 1)) + "…"
        }
        return name + String(repeating: " ", count: width - name.count)
    }

    private static func printHeader(displayName: String, serviceType: String) {
        let tty = isatty(fileno(stdout)) != 0
        let bold = tty ? "\u{1b}[1m" : ""
        let dim = tty ? "\u{1b}[2m" : ""
        let cyan = tty ? "\u{1b}[36m" : ""
        let reset = tty ? "\u{1b}[0m" : ""

        let rule = String(repeating: "─", count: 56)
        print(rule)
        print("  \(bold)PeerConnectivity\(reset)  \(dim)·\(reset)  Chat")
        print(rule)
        print("  \(dim)you      \(reset)  \(cyan)\(displayName)\(reset)")
        print("  \(dim)backend  \(reset)  Multipeer Connectivity")
        print("  \(dim)service  \(reset)  \(serviceType)")
        print(rule)
        print("  \(dim)type a line  ·  /help for commands  ·  Ctrl+C to quit\(reset)")
        print()
    }

    private static func installShutdownHandler(session: PeerConnectivitySession) {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        source.setEventHandler {
            Task {
                print("\n# shutting down…")
                try? await session.shutdown()
                exit(0)
            }
        }
        source.resume()
        // Retain the source for the lifetime of the process.
        Self.signalSource = source
    }

    nonisolated(unsafe) private static var signalSource: DispatchSourceSignal?
}

actor ChatInbox {
    // Multipeer can produce several PeerConnectivityPeer instances with the
    // same displayName but different ids (one per MCPeerID instance). We
    // deduplicate by displayName so a stale instance does not stay in the
    // send list after the live connection has been replaced.
    private var peers: [String: PeerConnectivityPeer] = [:]

    func add(_ peer: PeerConnectivityPeer) {
        peers[peer.displayName] = peer
    }

    func remove(_ peer: PeerConnectivityPeer) {
        // Only forget this displayName if the entry still points at the peer
        // instance that is going away — otherwise a late .peerDisconnected for
        // a stale instance would erase the live one.
        if peers[peer.displayName]?.id == peer.id {
            peers.removeValue(forKey: peer.displayName)
        }
    }

    func snapshot() -> [PeerConnectivityPeer] {
        Array(peers.values)
    }
}
