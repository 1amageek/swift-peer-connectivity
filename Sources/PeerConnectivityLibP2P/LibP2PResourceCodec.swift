import Foundation
import NIOCore
import PeerConnectivity

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

    /// Encodes the header frame payload (`"<name>\0<size>"`).
    ///
    /// This is the body of the first length-prefixed frame, not including the
    /// length prefix itself.
    static func header(for name: String, size: UInt64) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeString(name)
        buffer.writeInteger(UInt8(0))
        buffer.writeString(String(size))
        buffer.writeInteger(UInt8(0))
        return buffer
    }

    struct ResourceHeader: Sendable, Equatable {
        let name: String
        let size: Int
    }

    /// Parses a header frame payload, requiring the trailing separator after the
    /// size so a partial header is never accepted.
    static func parseHeaderFrame(_ buffer: ByteBuffer) throws -> ResourceHeader {
        let bytes = Array(buffer.readableBytesView)
        guard let nameEnd = bytes.firstIndex(of: 0), nameEnd > 0 else {
            throw PeerConnectivityError.invalidResource
        }
        let sizeStart = nameEnd + 1
        guard sizeStart < bytes.endIndex,
              let sizeEnd = bytes[sizeStart...].firstIndex(of: 0) else {
            throw PeerConnectivityError.invalidResource
        }
        let sizeBytes = bytes[sizeStart..<sizeEnd]
        guard !sizeBytes.isEmpty,
              let sizeString = String(bytes: sizeBytes, encoding: .utf8),
              let size = Int(sizeString),
              size >= 0 else {
            throw PeerConnectivityError.invalidResource
        }
        let name = String(decoding: bytes[..<nameEnd], as: UTF8.self)
        return ResourceHeader(name: name, size: size)
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
        let header = try parseHeaderInline(bytes)
        let payload = bytes[header.payloadStart...]
        guard payload.count == header.size else {
            throw PeerConnectivityError.invalidResource
        }
        let name = String(decoding: bytes[..<header.nameEnd], as: UTF8.self)
        let fileURL = try destinationURL(for: name)
        try Data(payload).write(to: fileURL, options: .atomic)
        return PeerResource(url: fileURL, name: name)
    }

    private struct InlineHeader {
        let nameEnd: Int
        let payloadStart: Int
        let size: Int
    }

    private static func parseHeaderInline(_ bytes: [UInt8]) throws -> InlineHeader {
        guard let nameEnd = bytes.firstIndex(of: 0), nameEnd > 0 else {
            throw PeerConnectivityError.invalidResource
        }
        let sizeStart = nameEnd + 1
        guard sizeStart < bytes.endIndex,
              let sizeEnd = bytes[sizeStart...].firstIndex(of: 0) else {
            throw PeerConnectivityError.invalidResource
        }
        let sizeBytes = bytes[sizeStart..<sizeEnd]
        guard !sizeBytes.isEmpty,
              let sizeString = String(bytes: sizeBytes, encoding: .utf8),
              let size = Int(sizeString),
              size >= 0 else {
            throw PeerConnectivityError.invalidResource
        }
        return InlineHeader(nameEnd: nameEnd, payloadStart: sizeEnd + 1, size: size)
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
