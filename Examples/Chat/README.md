# Chat

A minimal command-line chat that demonstrates `PeerConnectivity` over the
Multipeer Connectivity backend. Run it on two or more Macs (or two terminals
on the same Mac) and any line you type is broadcast to every connected peer.

## Run

```sh
cd Examples/Chat

# Terminal 1
swift run Chat alice

# Terminal 2
swift run Chat bob
```

Lines beginning with `#` are status output. Anything else is an outgoing
message. Press Ctrl+C to disconnect.

## What it shows

- `PeerConnectivitySession.multipeer(serviceType:displayName:)` to construct a
  session backed by Multipeer Connectivity.
- `startBrowsing()` + `startAdvertising()` for symmetric discovery.
- Auto-invitation with deterministic ordering (only the peer with the smaller
  id sends the invite, so both sides do not invite each other simultaneously).
- Broadcasting `ByteBuffer` messages with `send(_:to:)`.
- Consuming `session.events` as an `AsyncStream`.

## Notes

- macOS may prompt for "Local Network" access on first launch.
- `serviceType` is `pc-chat` — change it if you want isolated demo runs.
