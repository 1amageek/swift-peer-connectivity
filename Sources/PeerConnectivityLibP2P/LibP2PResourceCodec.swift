import Foundation
import NIOCore
import PeerConnectivity

enum LibP2PResourceCodec {
    static func header(for name: String, size: UInt64) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeString(name)
        buffer.writeInteger(UInt8(0))
        buffer.writeString(String(size))
        buffer.writeInteger(UInt8(0))
        return buffer
    }

    static func materializeResource(from buffer: ByteBuffer) throws -> PeerResource {
        let bytes = Array(buffer.readableBytesView)
        let header = try parseHeader(bytes)
        let payload = bytes[header.payloadStart...]
        guard payload.count == header.size else {
            throw PeerConnectivityError.invalidResource
        }

        let name = String(decoding: bytes[..<header.nameEnd], as: UTF8.self)
        let data = Data(payload)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-libp2p-peer-connectivity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString)-\(sanitizedFileName(name))")
        try data.write(to: fileURL, options: .atomic)
        return PeerResource(url: fileURL, name: name)
    }

    static func expectedTotalLength(
        in buffer: ByteBuffer,
        maxPayloadBytes: Int,
        maxHeaderBytes: Int = 16 * 1024
    ) throws -> Int? {
        let bytes = Array(buffer.readableBytesView)
        guard !bytes.isEmpty else {
            return nil
        }
        guard bytes.count <= maxPayloadBytes + maxHeaderBytes else {
            throw PeerConnectivityError.resourceTooLarge(maxPayloadBytes)
        }
        guard let header = try parseHeaderIfPresent(bytes, maxHeaderBytes: maxHeaderBytes) else {
            return nil
        }
        guard header.size <= maxPayloadBytes else {
            throw PeerConnectivityError.resourceTooLarge(maxPayloadBytes)
        }
        return header.payloadStart + header.size
    }

    private struct Header {
        let nameEnd: Int
        let payloadStart: Int
        let size: Int
    }

    private static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        guard let header = try parseHeaderIfPresent(bytes, maxHeaderBytes: 16 * 1024) else {
            throw PeerConnectivityError.invalidResource
        }
        return header
    }

    private static func parseHeaderIfPresent(_ bytes: [UInt8], maxHeaderBytes: Int) throws -> Header? {
        guard let nameEnd = bytes.firstIndex(of: 0), nameEnd > 0 else {
            if bytes.count > maxHeaderBytes {
                throw PeerConnectivityError.invalidResource
            }
            return nil
        }

        let sizeStart = nameEnd + 1
        guard sizeStart < bytes.endIndex else {
            return nil
        }
        guard let sizeEnd = bytes[sizeStart...].firstIndex(of: 0) else {
            if bytes.count > maxHeaderBytes {
                throw PeerConnectivityError.invalidResource
            }
            return nil
        }

        let sizeBytes = bytes[sizeStart..<sizeEnd]
        guard !sizeBytes.isEmpty,
              let sizeString = String(bytes: sizeBytes, encoding: .utf8),
              let size = Int(sizeString),
              size >= 0 else {
            throw PeerConnectivityError.invalidResource
        }

        return Header(nameEnd: nameEnd, payloadStart: sizeEnd + 1, size: size)
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
