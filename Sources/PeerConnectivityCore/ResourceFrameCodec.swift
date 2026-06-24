import LibP2PCore

/// Resource-transfer header framing for PeerConnectivity (Embedded-clean).
///
/// Embedded-clean: no Foundation, no NIO, no `any`, no Mutex, no
/// ContinuousClock, no key paths. Operates over `[UInt8]` and uses
/// `LibP2PCore.decodeUTF8Strict` for strict UTF-8 decoding of the size token.
///
/// A resource is sent over a libp2p stream as a sequence of length-prefixed
/// frames (the length prefix is owned by the muxer's
/// `read/writeLengthPrefixedMessage`, not by this core). The first frame's body
/// is the header parsed/encoded here:
///
/// ```
/// header body : "<name>\0<size>\0"
/// ```
///
/// where `<size>` is the decimal payload byte count and both fields are
/// NUL-terminated. The trailing NUL after `<size>` is required so a partial
/// header is never accepted as complete. The `name` is decoded with lossy UTF-8
/// (substituting U+FFFD) to mirror the historical behavior — a malformed name
/// never fails the transfer — while the `size` token is decoded strictly because
/// a non-numeric size is a framing error.
///
/// The async stream loop, file I/O, and chunk transfer stay in the adapter
/// (`PeerConnectivityLibP2P`); only the value-type byte framing lives here.
public enum ResourceFrameCodec {

    /// The field separator byte (NUL).
    public static let separator: UInt8 = 0

    /// The parsed header of a resource transfer frame.
    public struct ResourceHeader: Sendable, Equatable {
        /// The resource name as carried in the header.
        public let name: String
        /// The exact payload byte count declared by the sender.
        public let size: Int

        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    /// Encodes the header frame body (`"<name>\0<size>\0"`).
    ///
    /// This is the body of the first length-prefixed frame, not including the
    /// length prefix itself (the muxer owns the prefix).
    ///
    /// - Parameters:
    ///   - name: The resource name.
    ///   - size: The exact payload byte count.
    /// - Returns: The encoded header bytes.
    public static func encodeHeader(name: String, size: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array(name.utf8))
        bytes.append(separator)
        bytes.append(contentsOf: Array(String(size).utf8))
        bytes.append(separator)
        return bytes
    }

    /// Parses a header frame body, requiring the trailing separator after the
    /// size so a partial header is never accepted.
    ///
    /// - Parameter bytes: The header frame body (no length prefix).
    /// - Returns: The parsed `ResourceHeader`.
    /// - Throws: `ResourceFrameError` describing the specific framing failure.
    public static func decodeHeader(_ bytes: [UInt8]) throws(ResourceFrameError) -> ResourceHeader {
        let layout = try parseHeaderLayout(bytes)
        let name = lossyUTF8(Array(bytes[0..<layout.nameEnd]))
        return ResourceHeader(name: name, size: layout.size)
    }

    /// The result of locating an inline header within a materialized frame: the
    /// parsed header plus the offset at which the raw payload begins.
    public struct MaterializedHeader: Sendable, Equatable {
        /// The parsed header.
        public let header: ResourceHeader
        /// The byte offset at which the payload begins (immediately after the
        /// header's trailing separator).
        public let payloadStart: Int

        public init(header: ResourceHeader, payloadStart: Int) {
            self.header = header
            self.payloadStart = payloadStart
        }
    }

    /// Locates an inline header within a materialized buffer (header body
    /// directly followed by the raw payload, no chunk framing) and validates
    /// that the remaining payload length matches the declared size.
    ///
    /// Retained for in-process construction (small payloads, tests); the
    /// streaming receive path uses `decodeHeader` plus chunk frames instead.
    ///
    /// - Parameter bytes: The full materialized buffer.
    /// - Returns: The parsed header and the payload start offset.
    /// - Throws: `ResourceFrameError` describing the specific framing failure.
    public static func decodeMaterialized(_ bytes: [UInt8]) throws(ResourceFrameError) -> MaterializedHeader {
        let layout = try parseHeaderLayout(bytes)
        let availablePayload = bytes.count - layout.payloadStart
        guard availablePayload == layout.size else {
            throw .payloadSizeMismatch(declared: layout.size, available: availablePayload)
        }
        let name = lossyUTF8(Array(bytes[0..<layout.nameEnd]))
        return MaterializedHeader(
            header: ResourceHeader(name: name, size: layout.size),
            payloadStart: layout.payloadStart
        )
    }

    // MARK: - Private

    private struct HeaderLayout {
        let nameEnd: Int
        let payloadStart: Int
        let size: Int
    }

    private static func parseHeaderLayout(_ bytes: [UInt8]) throws(ResourceFrameError) -> HeaderLayout {
        guard let nameEnd = firstIndex(of: separator, in: bytes, from: 0), nameEnd > 0 else {
            throw .missingNameSeparator
        }
        let sizeStart = nameEnd + 1
        guard sizeStart < bytes.count,
              let sizeEnd = firstIndex(of: separator, in: bytes, from: sizeStart) else {
            throw .missingSizeSeparator
        }
        let sizeBytes = Array(bytes[sizeStart..<sizeEnd])
        guard !sizeBytes.isEmpty else {
            throw .emptySize
        }
        guard let sizeString = decodeSizeToken(sizeBytes),
              let size = parseNonNegativeInt(sizeString) else {
            throw .invalidSize
        }
        return HeaderLayout(nameEnd: nameEnd, payloadStart: sizeEnd + 1, size: size)
    }

    private static func firstIndex(of byte: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func decodeSizeToken(_ bytes: [UInt8]) -> String? {
        // Strict UTF-8: a non-numeric / malformed size token is a framing error,
        // never substituted. Reuses the Embedded-clean helper from LibP2PCore.
        decodeUTF8Strict(bytes)
    }

    /// Parses a non-negative base-10 integer from `string`, rejecting any
    /// non-digit character, leading sign, or overflow. Returns `nil` on failure.
    private static func parseNonNegativeInt(_ string: String) -> Int? {
        var value = 0
        var sawDigit = false
        for scalar in string.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else {
                return nil
            }
            sawDigit = true
            let digit = Int(scalar.value - 48)
            let (multiplied, overflowMul) = value.multipliedReportingOverflow(by: 10)
            guard !overflowMul else {
                return nil
            }
            let (added, overflowAdd) = multiplied.addingReportingOverflow(digit)
            guard !overflowAdd else {
                return nil
            }
            value = added
        }
        guard sawDigit else {
            return nil
        }
        return value
    }

    private static func lossyUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Errors from the resource-transfer header codec.
///
/// Each case is a distinct, typed framing failure. The adapter maps these onto
/// its public `PeerConnectivityError.invalidResource` so the host-facing error
/// surface is unchanged.
public enum ResourceFrameError: Error, Equatable, Sendable {
    /// No NUL separator terminating the name field (or an empty name).
    case missingNameSeparator
    /// No NUL separator terminating the size field.
    case missingSizeSeparator
    /// The size field was empty.
    case emptySize
    /// The size field was not a valid non-negative base-10 integer (or overflowed).
    case invalidSize
    /// The materialized payload length did not match the declared size.
    case payloadSizeMismatch(declared: Int, available: Int)
}
