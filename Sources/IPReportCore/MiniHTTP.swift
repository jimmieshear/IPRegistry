import Foundation

/// A parsed HTTP/1.1 request. Only what a small internal service needs: no chunked
/// transfer-encoding, no keep-alive, no trailers.
public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        target: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.target = target
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Bearer token from `Authorization`, if present and well-formed.
    public var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

public enum HTTPParseError: Error, CustomStringConvertible {
    case malformedRequestLine
    case headersTooLarge
    case bodyTooLarge
    case badContentLength
    case unsupportedTransferEncoding

    public var description: String {
        switch self {
        case .malformedRequestLine: return "malformed request line"
        case .headersTooLarge: return "request headers too large"
        case .bodyTooLarge: return "request body too large"
        case .badContentLength: return "bad Content-Length"
        case .unsupportedTransferEncoding: return "chunked Transfer-Encoding is not supported"
        }
    }
}

/// Incremental request parser. Feed it socket chunks; it returns a request once complete.
public struct HTTPRequestParser: Sendable {
    public var maxHeaderBytes: Int
    public var maxBodyBytes: Int

    private var buffer: [UInt8] = []
    private var head: (method: String, target: String, headers: [String: String])?
    private var bodyStart = 0
    private var expectedBody = 0

    public init(maxHeaderBytes: Int = 32 * 1024, maxBodyBytes: Int = 256 * 1024) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func append(_ chunk: Data) throws -> HTTPRequest? {
        buffer.append(contentsOf: chunk)

        if head == nil {
            guard let separator = Self.range(of: [13, 10, 13, 10], in: buffer) else {
                if buffer.count > maxHeaderBytes { throw HTTPParseError.headersTooLarge }
                return nil
            }
            if separator > maxHeaderBytes { throw HTTPParseError.headersTooLarge }

            let text = String(decoding: buffer[0..<separator], as: UTF8.self)
            bodyStart = separator + 4

            var lines = text.components(separatedBy: "\r\n")
            guard let requestLine = lines.first, !requestLine.isEmpty else {
                throw HTTPParseError.malformedRequestLine
            }
            lines.removeFirst()

            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }

            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex..<colon]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }

            if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
                throw HTTPParseError.unsupportedTransferEncoding
            }
            if let length = headers["content-length"] {
                guard let count = Int(length), count >= 0 else { throw HTTPParseError.badContentLength }
                guard count <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
                expectedBody = count
            }

            head = (String(parts[0]).uppercased(), String(parts[1]), headers)
        }

        guard let head else { return nil }
        guard buffer.count - bodyStart >= expectedBody else { return nil }

        let body = Data(buffer[bodyStart..<(bodyStart + expectedBody)])
        let (path, query) = Self.splitTarget(head.target)
        return HTTPRequest(
            method: head.method,
            target: head.target,
            path: path,
            query: query,
            headers: head.headers,
            body: body
        )
    }

    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var index = 0
        while index <= limit {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces.first ?? "/")
        let path = rawPath.removingPercentEncoding ?? rawPath

        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return (path.isEmpty ? "/" : path, query)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int = 200, contentType: String? = nil, body: Data = Data(), extraHeaders: [(String, String)] = []) {
        self.status = status
        self.body = body
        var headers = extraHeaders
        if let contentType { headers.append(("Content-Type", contentType)) }
        self.headers = headers
    }

    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(string.utf8))
    }

    public static func html(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(string.utf8))
    }

    public static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    public static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }
}

public func htmlEscape(_ string: String) -> String {
    var out = ""
    out.reserveCapacity(string.count)
    for character in string {
        switch character {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(character)
        }
    }
    return out
}
