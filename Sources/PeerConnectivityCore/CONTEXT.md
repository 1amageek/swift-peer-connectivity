# PeerConnectivityCore — CONTEXT
Scope/role: the Embedded-clean value-type wire codec for resource transfers. Owns only the header framing; the async stream loop, file I/O, and chunk transfer live in the `PeerConnectivityLibP2P` adapter.
Last reviewed: 2026-06-25

`ResourceFrameCodec` is the byte-currency boundary for a resource transfer.
Read this before changing the header format or the parse logic: the framing
is a wire contract shared with the adapter and with any interoperating peer,
and the parsing rules are deliberately strict so a partial or hostile frame
can never be accepted as a complete header.

## Contracts (the load-bearing rules)
- This module is a pure value-type codec over `[UInt8]`. The header body is
  `"<name>\0<size>\0"`: the resource name, a NUL, the decimal payload byte
  count, a NUL. The length prefix is owned by the muxer
  (`read/writeLengthPrefixedMessage`), NOT by this codec.
- The codec encodes/parses only the FIRST frame's body. Everything stateful —
  stream loop, chunk frames, file I/O — stays in `PeerConnectivityLibP2P`.
- Parse failures are reported as the typed `ResourceFrameError`; the adapter
  maps them onto its public `PeerConnectivityError.invalidResource`, so the
  host-facing error surface stays stable while the typed cases stay precise.

## Invariants (must hold; tests guard them)
- The trailing NUL after `<size>` is REQUIRED: a header missing it is rejected
  (`missingSizeSeparator`), so a truncated header is never accepted as complete.
- The name is decoded lossy (U+FFFD substitution) — a malformed name never
  fails the transfer; the size token is decoded strictly (`decodeUTF8Strict`)
  and parsed as a non-negative base-10 integer, rejecting any non-digit,
  leading sign, empty token, or overflow (`invalidSize` / `emptySize`).
- An empty name is rejected (`missingNameSeparator` requires `nameEnd > 0`).
- `decodeMaterialized` additionally requires the remaining payload length to
  equal the declared size, failing closed with `payloadSizeMismatch` — sizes
  are never trusted to match silently.

## Embedded constraints (do not regress)
- No Foundation, no NIO, no `any`, no `Mutex`, no `ContinuousClock`, no key
  paths. UTF-8 decoding reuses `LibP2PCore.decodeUTF8Strict`. This module is
  part of the dual-build (host + Embedded) Embedded-clean core.

## Wire protocol notes
- Header body: `"<name>\0<size>\0"`. `<size>` is the exact payload byte count
  in decimal; both fields are NUL-terminated. The codec only frames this header
  body — chunk framing and the outer length prefix are out of scope here.

## Build
```bash
# Host build (default)
swift build

# Embedded build (matches the embedded-branch wiring)
P2P_CORE_EMBEDDED=1 swift build --target PeerConnectivityCore -c release
```
