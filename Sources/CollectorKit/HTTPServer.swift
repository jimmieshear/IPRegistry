#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import IPReportCore

/// A small blocking HTTP/1.1 server on POSIX sockets.
///
/// Deliberately not Network.framework: the collector cross-compiles to Linux for a VPS,
/// and `NWListener` is Apple-only. The request parser, router and renderer are unchanged
/// and untouched by this — only the transport differs.
///
/// The concurrency model is a dedicated accept thread plus a bounded concurrent dispatch
/// queue for connections, with blocking reads and writes under socket timeouts. Blocking
/// I/O is kept off the Swift cooperative pool entirely; a handful of machines heartbeating
/// once a minute never comes close to the connection cap.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, String?) async -> HTTPResponse

    public enum ServerError: Error, CustomStringConvertible {
        case resolve(String)
        case bind(String)

        public var description: String {
            switch self {
            case .resolve(let detail): return "could not resolve bind address: \(detail)"
            case .bind(let detail): return "could not bind: \(detail)"
            }
        }
    }

    private let bindHost: String?
    private let port: UInt16
    private let handler: Handler
    private let ioTimeoutSeconds: Int
    private let slots: DispatchSemaphore
    private let connectionQueue = DispatchQueue(label: "ipcollector.connections", attributes: .concurrent)
    private var listenDescriptor: Int32 = -1

    public init(
        bindHost: String?,
        port: UInt16,
        maxConcurrentConnections: Int = 24,
        ioTimeoutSeconds: Int = 15,
        handler: @escaping Handler
    ) {
        self.bindHost = bindHost
        self.port = port
        self.handler = handler
        self.ioTimeoutSeconds = ioTimeoutSeconds
        self.slots = DispatchSemaphore(value: maxConcurrentConnections)
    }

    /// Binds, listens, and starts accepting on a background thread. Returns once the
    /// socket is live so the caller can log a ready message and park.
    public func start() throws {
        // A client that disconnects mid-write must not take the process down.
        signal(SIGPIPE, SIG_IGN)

        listenDescriptor = try makeListeningSocket()

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "ipcollector.accept"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    // MARK: - Socket setup

    private func makeListeningSocket() throws -> Int32 {
        var hints = addrinfo()
        // With no explicit bind address, prefer an IPv6 socket with V6ONLY off so one
        // listener serves both families.
        hints.ai_family = bindHost == nil ? AF_INET6 : AF_UNSPEC
        hints.ai_socktype = streamSocketType
        hints.ai_flags = AI_PASSIVE

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(bindHost, String(port), &hints, &list)
        guard status == 0, let list else {
            let detail = String(cString: gai_strerror(status))
            throw ServerError.resolve("\(bindHost ?? "*"):\(port): \(detail)")
        }
        defer { freeaddrinfo(list) }

        var lastError = "no usable addresses"
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let candidate = cursor {
            defer { cursor = candidate.pointee.ai_next }

            let descriptor = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            if descriptor < 0 {
                lastError = errnoDescription()
                continue
            }

            var enabled: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

            if candidate.pointee.ai_family == AF_INET6 {
                var dualStack: Int32 = 0
                setsockopt(descriptor, Int32(IPPROTO_IPV6), Int32(IPV6_V6ONLY), &dualStack, socklen_t(MemoryLayout<Int32>.size))
            }

            if bind(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) != 0 {
                lastError = errnoDescription()
                close(descriptor)
                continue
            }
            if listen(descriptor, 64) != 0 {
                lastError = errnoDescription()
                close(descriptor)
                continue
            }
            return descriptor
        }
        throw ServerError.bind("\(bindHost ?? "*"):\(port): \(lastError)")
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let descriptor = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    accept(listenDescriptor, address, &length)
                }
            }

            if descriptor < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                Log.error("accept failed: \(errnoDescription())")
                // Back off rather than spin on a persistent error such as EMFILE.
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }

            let peer = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    NetworkScan.numericHost(address, length: length)
                }
            }

            // Refuse rather than queue without bound. A stuck client should not be able to
            // exhaust the process.
            guard slots.wait(timeout: .now()) == .success else {
                Log.warn("refused connection from \(peer ?? "unknown"): too many in flight")
                sendAll(descriptor, HTTPResponse.text("busy\n", status: 503).serialized())
                close(descriptor)
                continue
            }

            connectionQueue.async { [weak self] in
                guard let self else {
                    close(descriptor)
                    return
                }
                defer { self.slots.signal() }
                self.serve(descriptor: descriptor, peer: peer)
            }
        }
    }

    // MARK: - Per-connection handling

    private func serve(descriptor: Int32, peer: String?) {
        defer { close(descriptor) }
        applyTimeouts(descriptor)

        var parser = HTTPRequestParser()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var request: HTTPRequest?

        while request == nil {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            if received == 0 { return }
            if received < 0 {
                if errno == EINTR { continue }
                // Timed out or reset: nothing useful to say back.
                return
            }
            do {
                request = try parser.append(Data(buffer[0..<received]))
            } catch let error as HTTPParseError {
                let status: Int
                switch error {
                case .bodyTooLarge, .headersTooLarge: status = 413
                default: status = 400
                }
                sendAll(descriptor, HTTPResponse.text("\(error)\n", status: status).serialized())
                return
            } catch {
                return
            }
        }

        guard let request else { return }
        sendAll(descriptor, awaitHandler(request, peer).serialized())
    }

    /// Bridges the async router into this blocking thread. Safe because the queue thread
    /// blocking here is not part of the Swift cooperative pool that runs the Task.
    private func awaitHandler(_ request: HTTPRequest, _ peer: String?) -> HTTPResponse {
        let box = ResponseBox()
        let finished = DispatchSemaphore(value: 0)
        Task { [handler] in
            box.value = await handler(request, peer)
            finished.signal()
        }
        finished.wait()
        return box.value ?? .text("internal error\n", status: 500)
    }

    private func applyTimeouts(_ descriptor: Int32) {
        // Bounds every blocking read and write, so a silent client cannot hold a slot.
        var timeout = timeval()
        timeout.tv_sec = .init(ioTimeoutSeconds)
        timeout.tv_usec = 0
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func sendAll(_ descriptor: Int32, _ data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(descriptor, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                return
            }
            offset += written
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HTTPResponse?

        // Explicit lock/unlock rather than a `withLock` helper: Foundation gained its own
        // NSLock.withLock, and a local one of the same name is an ambiguity waiting to
        // happen on whichever platform has it.
        var value: HTTPResponse? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }
}
