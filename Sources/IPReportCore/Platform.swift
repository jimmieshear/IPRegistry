#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// Small portability shims. The collector cross-compiles to static musl Linux, where the
// BSD-flavoured spellings and Foundation's internationalisation-backed formatters are
// either absent or best avoided.

#if canImport(Darwin)
public let streamSocketType = SOCK_STREAM
public let datagramSocketType = SOCK_DGRAM
#else
public let streamSocketType = Int32(SOCK_STREAM.rawValue)
public let datagramSocketType = Int32(SOCK_DGRAM.rawValue)
#endif

/// Decodes a null-terminated C buffer. `String(cString:)` on `[CChar]` is deprecated, and
/// several libc APIs here hand back fixed-size buffers.
public func stringFromCBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// An RFC 3339 UTC timestamp, via `gmtime_r` and `strftime`.
///
/// Deliberately not `ISO8601DateFormatter`: that pulls in Foundation's internationalisation
/// support, which the static Linux SDK does not reliably carry. libc has these everywhere,
/// and the output is byte-identical on both platforms.
public func iso8601UTC(_ date: Date) -> String {
    var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
    var parts = tm()
    gmtime_r(&seconds, &parts)
    var buffer = [CChar](repeating: 0, count: 32)
    guard strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%SZ", &parts) > 0 else { return "" }
    return stringFromCBuffer(buffer)
}

public func errnoDescription(_ code: Int32 = errno) -> String {
    guard let text = strerror(code) else { return "errno \(code)" }
    return "\(String(cString: text)) (errno \(code))"
}

/// Writes straight to a file descriptor, looping over short writes.
///
/// Deliberately not `stdout`/`stderr`: Glibc declares those as stored global `var`s, which
/// Swift 6 strict concurrency rejects as shared mutable state. `write(2)` is also
/// unbuffered, so there is no flush to forget and lines from concurrent connections do not
/// interleave.
public func writeToDescriptor(_ descriptor: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(descriptor, base.advanced(by: offset), bytes.count - offset)
        }
        if written <= 0 {
            if written < 0, errno == EINTR { continue }
            return
        }
        offset += written
    }
}

public func writeStandardOutput(_ text: String) { writeToDescriptor(1, text) }
public func writeStandardError(_ text: String) { writeToDescriptor(2, text) }

public enum Platform {
    /// The system hostname as `gethostname(2)` reports it. Available on both platforms,
    /// unlike the IORegistry lookups the reporter uses for hardware identity.
    public static var hostname: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "unknown" }
        let name = stringFromCBuffer(buffer)
        return name.isEmpty ? "unknown" : name
    }
}
