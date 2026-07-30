import Foundation

public enum Wire {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.withoutEscapingSlashes]
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Compares secrets without leaking their contents through timing. Length is not hidden.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<min(a.count, b.count) {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    /// Reads a shared secret from a file, ignoring trailing newlines and stray whitespace.
    public static func readToken(at path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw IPReportError.emptyToken(path: path)
        }
        return token
    }
}

public enum IPReportError: Error, CustomStringConvertible {
    case emptyToken(path: String)
    case badConfiguration(String)
    case collectorRejected(status: Int, body: String)

    public var description: String {
        switch self {
        case .emptyToken(let path):
            return "token file \(path) is empty"
        case .badConfiguration(let message):
            return message
        case .collectorRejected(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "collector returned HTTP \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        }
    }
}

/// Timestamped line logging. Both daemons have their output captured to a file by launchd
/// or to the journal by systemd, so this is deliberately plain text rather than os_log.
public enum Log {
    public static func info(_ message: String) {
        emit("INFO", message, to: stdout)
    }

    public static func warn(_ message: String) {
        emit("WARN", message, to: stderr)
    }

    public static func error(_ message: String) {
        emit("ERROR", message, to: stderr)
    }

    private static func emit(_ level: String, _ message: String, to stream: UnsafeMutablePointer<FILE>) {
        fputs("\(iso8601UTC(Date())) [\(level)] \(message)\n", stream)
        fflush(stream)
    }
}

public extension Date {
    /// "12s ago", "4m ago", "3d ago" — for the dashboard and log lines.
    func relativeDescription(from reference: Date = Date()) -> String {
        let seconds = Int(reference.timeIntervalSince(self).rounded())
        if seconds < 0 { return "in the future" }
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    guard total >= 0 else { return "—" }
    let days = total / 86_400
    let hours = (total % 86_400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}
