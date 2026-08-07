#if canImport(MultipeerConnectivity)
import Foundation
import NIOCore
import PeerConnectivity
import Synchronization

/// A shared run loop thread that drives `Stream` events for the Multipeer
/// channels.
///
/// `Stream.Delegate` callbacks are delivered on the run loop the stream is
/// scheduled on. A single long-lived background run loop hosts all channel
/// streams so reads and writes are event-driven and never block a cooperative
/// pool thread.
final class StreamRunLoop: Sendable {
    static let shared = StreamRunLoop()

    /// Reference-typed holder so the run-loop thread closure can capture the
    /// shared box by reference (a `Mutex` is non-copyable and cannot be captured).
    private final class RunLoopBox: Sendable {
        let value = Mutex<CFRunLoop?>(nil)
    }

    private let box = RunLoopBox()

    private init() {
        let box = self.box
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value.withLock { $0 = CFRunLoopGetCurrent() }
            ready.signal()
            // Keep the run loop alive with a port source so it does not exit when
            // no streams are currently scheduled. A bare `CFRunLoopSourceCreate`
            // with a nil context traps, so use an `NSMachPort` which provides a
            // valid run-loop source.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .common)
            CFRunLoopRun()
        }
        thread.name = "swift-peer-connectivity.multipeer.stream"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 512 * 1024
        thread.start()
        ready.wait()
    }

    /// Schedules `work` on the run loop thread.
    func schedule(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop = box.value.withLock({ $0 }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }
}

/// Drives an `InputStream` via its delegate, exposing an async `read()`.
///
/// State lives behind a `Mutex` that is only ever held for short, non-blocking
/// sections (buffer manipulation and continuation hand-off). The actual waiting
/// happens by suspending the `read()` caller on a continuation that a delegate
/// callback resumes; no lock is held across the suspension.
final class InputStreamPump: NSObject, StreamDelegate, @unchecked Sendable {
    private let stream: InputStream
    private let state = Mutex(State())

    private struct State {
        var buffer = ByteBuffer()
        var atEnd = false
        var error: (any Error)?
        var closed = false
        var pendingRead: CheckedContinuation<ByteBuffer, any Error>?
    }

    init(stream: InputStream) {
        self.stream = stream
        super.init()
        StreamRunLoop.shared.schedule { [weak self] in
            guard let self else { return }
            self.stream.delegate = self
            self.stream.schedule(in: .current, forMode: .common)
            self.stream.open()
        }
    }

    func read() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ByteBuffer, any Error>) in
            // Resolve immediately if data, EOF, or an error is already available.
            enum Resolution {
                case value(ByteBuffer)
                case failure(any Error)
                case wait
            }
            let resolution: Resolution = state.withLock { state in
                if state.pendingRead != nil {
                    return .failure(PeerConnectivityError.channelUnavailable)
                }
                if state.buffer.readableBytes > 0 {
                    let bytes = state.buffer
                    state.buffer = ByteBuffer()
                    return .value(bytes)
                }
                if let error = state.error {
                    return .failure(error)
                }
                if state.atEnd || state.closed {
                    return .failure(PeerConnectivityError.channelClosed)
                }
                state.pendingRead = continuation
                return .wait
            }
            switch resolution {
            case .value(let buffer):
                continuation.resume(returning: buffer)
            case .failure(let error):
                continuation.resume(throwing: error)
            case .wait:
                break
            }
        }
    }

    func close() {
        let continuation = state.withLock { state -> CheckedContinuation<ByteBuffer, any Error>? in
            state.closed = true
            let pending = state.pendingRead
            state.pendingRead = nil
            return pending
        }
        continuation?.resume(throwing: PeerConnectivityError.channelClosed)
        StreamRunLoop.shared.schedule { [weak self] in
            guard let self else { return }
            self.stream.remove(from: .current, forMode: .common)
            self.stream.close()
        }
    }

    // MARK: StreamDelegate (called on the run loop thread)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            drain()
        case .endEncountered:
            let continuation = state.withLock { state -> CheckedContinuation<ByteBuffer, any Error>? in
                state.atEnd = true
                guard state.buffer.readableBytes == 0 else { return nil }
                let pending = state.pendingRead
                state.pendingRead = nil
                return pending
            }
            continuation?.resume(throwing: PeerConnectivityError.channelClosed)
        case .errorOccurred:
            let error = aStream.streamError ?? PeerConnectivityError.channelClosed
            let continuation = state.withLock { state -> CheckedContinuation<ByteBuffer, any Error>? in
                state.error = error
                let pending = state.pendingRead
                state.pendingRead = nil
                return pending
            }
            continuation?.resume(throwing: error)
        default:
            break
        }
    }

    private func drain() {
        let capacity = 64 * 1024
        var storage = [UInt8](repeating: 0, count: capacity)
        let count = storage.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return stream.read(base.assumingMemoryBound(to: UInt8.self), maxLength: capacity)
        }
        guard count > 0 else { return }
        let chunk = ByteBuffer(bytes: storage.prefix(count))
        let continuation = state.withLock { state -> (CheckedContinuation<ByteBuffer, any Error>, ByteBuffer)? in
            if let pending = state.pendingRead {
                state.pendingRead = nil
                return (pending, chunk)
            }
            var stored = chunk
            state.buffer.writeBuffer(&stored)
            return nil
        }
        if let (continuation, value) = continuation {
            continuation.resume(returning: value)
        }
    }
}

/// Drives an `OutputStream` via its delegate, exposing an async `write()`.
///
/// Bytes are queued and flushed when the stream reports space available. The
/// `write()` caller suspends until the queued bytes have all been flushed or an
/// error occurs; no lock is held across the suspension.
final class OutputStreamPump: NSObject, StreamDelegate, @unchecked Sendable {
    private let stream: OutputStream
    private let state = Mutex(State())

    private struct State {
        var pending = ByteBuffer()
        var error: (any Error)?
        var closed = false
        var pendingWrite: CheckedContinuation<Void, any Error>?
    }

    init(stream: OutputStream) {
        self.stream = stream
        super.init()
        StreamRunLoop.shared.schedule { [weak self] in
            guard let self else { return }
            self.stream.delegate = self
            self.stream.schedule(in: .current, forMode: .common)
            self.stream.open()
        }
    }

    func write(_ bytes: ByteBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let immediateError: (any Error)? = state.withLock { state in
                if state.pendingWrite != nil {
                    return PeerConnectivityError.channelUnavailable
                }
                if let error = state.error {
                    return error
                }
                if state.closed {
                    return PeerConnectivityError.channelClosed
                }
                var copy = bytes
                state.pending.writeBuffer(&copy)
                state.pendingWrite = continuation
                return nil
            }
            if let immediateError {
                continuation.resume(throwing: immediateError)
                return
            }
            // Attempt an immediate flush on the run loop thread in case the
            // stream already has space.
            StreamRunLoop.shared.schedule { [weak self] in
                self?.flush()
            }
        }
    }

    func close() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.closed = true
            let pending = state.pendingWrite
            state.pendingWrite = nil
            return pending
        }
        continuation?.resume(throwing: PeerConnectivityError.channelClosed)
        StreamRunLoop.shared.schedule { [weak self] in
            guard let self else { return }
            self.stream.remove(from: .current, forMode: .common)
            self.stream.close()
        }
    }

    // MARK: StreamDelegate (called on the run loop thread)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            let error = aStream.streamError ?? PeerConnectivityError.channelClosed
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.error = error
                let pending = state.pendingWrite
                state.pendingWrite = nil
                return pending
            }
            continuation?.resume(throwing: error)
        case .endEncountered:
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.closed = true
                let pending = state.pendingWrite
                state.pendingWrite = nil
                return pending
            }
            continuation?.resume(throwing: PeerConnectivityError.channelClosed)
        default:
            break
        }
    }

    /// Drains queued bytes to the stream while it has space.
    ///
    /// Always runs on the run-loop thread, so it is never re-entered
    /// concurrently and may safely query the stream's `hasSpaceAvailable`
    /// property. Resumes the pending write continuation exactly once: either on
    /// error, or when the queue fully drains.
    private func flush() {
        // Writability is determined by the stream property at write time; the
        // `.hasSpaceAvailable` delegate event is only a wakeup. Some memory
        // streams accept writes without ever emitting that event, so relying on
        // the cached flag alone would stall the writer.
        guard stream.hasSpaceAvailable else {
            return
        }
        // Pull a writable snapshot under the lock, then write outside the lock.
        let chunk: [UInt8]? = state.withLock { state in
            guard state.error == nil, !state.closed else { return nil }
            let count = state.pending.readableBytes
            guard count > 0 else { return nil }
            return state.pending.getBytes(at: state.pending.readerIndex, length: count)
        }
        guard let chunk, !chunk.isEmpty else { return }

        let written = chunk.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return stream.write(base.assumingMemoryBound(to: UInt8.self), maxLength: chunk.count)
        }

        if written <= 0 {
            let error = stream.streamError ?? PeerConnectivityError.channelClosed
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.error = error
                let pending = state.pendingWrite
                state.pendingWrite = nil
                return pending
            }
            continuation?.resume(throwing: error)
            return
        }

        let remaining = state.withLock { state -> Int in
            state.pending.moveReaderIndex(forwardBy: written)
            return state.pending.readableBytes
        }
        if remaining == 0 {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                let pending = state.pendingWrite
                state.pendingWrite = nil
                return pending
            }
            continuation?.resume(returning: ())
            return
        }
        // The stream took only part of the queue; re-schedule a flush so the
        // remainder drains as soon as the stream can accept more.
        StreamRunLoop.shared.schedule { [weak self] in
            self?.flush()
        }
    }
}
#endif
