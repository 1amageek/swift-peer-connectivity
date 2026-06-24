import Foundation
import NIOCore
import PeerConnectivity
import PeerConnectivityCore

/// Wire framing for resource transfers over a libp2p stream.
///
/// The wire format is a sequence of length-prefixed frames (varint length +
/// payload), using the muxer's `read/writeLengthPrefixedMessage` helpers:
///
/// ```
/// [frame] header   : "<name>\0<size>"   (size is the decimal payload byte count)
/// [frame] chunk     : raw payload bytes (one or more frames)
/// [frame] chunk     : ...
/// ```
///
/// The header carries the exact payload size, so the receiver knows precisely
/// how many payload bytes to expect. A stream that ends before `size` payload
/// bytes have arrived is a detectable truncation (`incompleteMessage`), never
/// delivered as a complete resource.
enum LibP2PResourceCodec {
    /// Maximum bytes accepted for a single inbound chunk frame.
    static let maxChunkBytes = 1 * 1024 * 1024

    /// Maximum bytes accepted for the header frame.
    static let maxHeaderBytes = 16 * 1024

    /// Encodes the header frame payload (`"<name>\0<size>\0"`).
    ///
    /// This is the body of the first length-prefixed frame, not including the
    /// length prefix itself. Byte framing is delegated to the Embedded-clean
    /// `PeerConnectivityCore.ResourceFrameCodec`; this shim only wraps the
    /// resulting bytes in a NIO `ByteBuffer` for the muxer write path.
    static func header(for name: String, size: UInt64) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(ResourceFrameCodec.encodeHeader(name: name, size: size))
        return buffer
    }

    /// The parsed header of a resource frame.
    ///
    /// Re-exported from the Embedded-clean core so the adapter's call sites and
    /// tests keep referring to `LibP2PResourceCodec.ResourceHeader`.
    typealias ResourceHeader = ResourceFrameCodec.ResourceHeader

    /// Parses a header frame payload, requiring the trailing separator after the
    /// size so a partial header is never accepted.
    ///
    /// Delegates byte parsing to the Embedded-clean core and maps its typed
    /// framing error onto the public `PeerConnectivityError.invalidResource`,
    /// preserving the adapter's host-facing error surface.
    static func parseHeaderFrame(_ buffer: ByteBuffer) throws -> ResourceHeader {
        let bytes = Array(buffer.readableBytesView)
        do {
            return try ResourceFrameCodec.decodeHeader(bytes)
        } catch {
            throw PeerConnectivityError.invalidResource
        }
    }

    /// Creates the temp file destination directory and a sanitized file URL for
    /// an inbound resource named `name`.
    static func destinationURL(for name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-libp2p-peer-connectivity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedFileName(name))")
    }

    /// Materializes an in-memory framed resource buffer (header frame body
    /// directly followed by the raw payload, no chunk framing) to a temp file.
    ///
    /// Retained for in-process construction in tests and small payloads; the
    /// streaming receive path writes chunks to disk directly via
    /// `destinationURL` and a `FileHandle` instead of buffering in memory.
    static func materializeResource(from buffer: ByteBuffer) throws -> PeerResource {
        let bytes = Array(buffer.readableBytesView)
        let materialized: ResourceFrameCodec.MaterializedHeader
        do {
            materialized = try ResourceFrameCodec.decodeMaterialized(bytes)
        } catch {
            throw PeerConnectivityError.invalidResource
        }
        let payload = bytes[materialized.payloadStart...]
        let name = materialized.header.name
        let fileURL = try destinationURL(for: name)
        try Data(payload).write(to: fileURL, options: .atomic)
        return PeerResource(url: fileURL, name: name)
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = name.map { character -> Character in
            allowed.contains(character) ? character : "_"
        }
        let value = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value.isEmpty ? "resource" : value
    }
}
