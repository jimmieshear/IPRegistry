import Foundation
import IPReportCore

/// The collector's whole HTTP surface, as a pure function of request plus state. Kept free
/// of Network.framework so every status code and body can be tested without a socket.
public enum Router {
    public static func route(
        _ request: HTTPRequest,
        peer: String?,
        store: Store,
        options: CollectorOptions,
        token: String,
        now: Date = Date()
    ) async -> HTTPResponse {
        let authorized = request.bearerToken.map { Wire.constantTimeEquals($0, token) } ?? false
        let client = clientAddress(request, peer: peer, trustForwardedFor: options.trustForwardedFor)

        switch (request.method, request.path) {
        case ("POST", "/report"):
            guard authorized else {
                Log.warn("rejected unauthenticated report from \(client ?? "unknown")")
                return .text("unauthorized\n", status: 401)
            }
            do {
                let report = try Wire.decoder().decode(HostReport.self, from: request.body)
                guard !report.machineID.isEmpty, !report.hostname.isEmpty else {
                    return .text("machineID and hostname are required\n", status: 400)
                }
                let (record, changed) = await store.record(report, observedAddress: client, at: now)
                if changed {
                    let from = record.previousPrimaryAddress.map { "\($0) -> " } ?? ""
                    Log.info("\(report.hostname): \(from)\(report.primaryAddress ?? "unknown") via \(report.primaryInterface ?? "?")")
                } else if options.verbose {
                    Log.info("\(report.hostname): heartbeat, still \(report.primaryAddress ?? "unknown")")
                }
                let ack = Acknowledgement(observedAddress: client, changed: changed)
                let body = (try? Wire.encoder().encode(ack)) ?? Data("{}".utf8)
                return .json(body)
            } catch {
                Log.warn("malformed report from \(client ?? "unknown"): \(error)")
                return .text("could not decode report: \(error)\n", status: 400)
            }

        case ("GET", "/"), ("GET", "/index.html"):
            guard !options.requireAuthForReads || authorized else { return unauthorizedRead }
            let snapshot = Snapshot(records: await store.snapshot(), now: now, staleAfter: options.staleAfter)
            return .html(HTMLPage.render(snapshot, title: options.title, refreshSeconds: options.refreshSeconds))

        case ("GET", "/json"):
            guard !options.requireAuthForReads || authorized else { return unauthorizedRead }
            let snapshot = Snapshot(records: await store.snapshot(), now: now, staleAfter: options.staleAfter)
            guard let data = try? Wire.encoder(pretty: true).encode(snapshot) else {
                return .text("could not encode snapshot\n", status: 500)
            }
            return .json(data)

        case ("GET", "/healthz"):
            return .text("ok\n")

        default:
            // GET /ip/<name> — a bare address, for shell scripts and ssh wrappers.
            if request.method == "GET", request.path.hasPrefix("/ip/") {
                guard !options.requireAuthForReads || authorized else { return unauthorizedRead }
                let needle = String(request.path.dropFirst("/ip/".count))
                guard !needle.isEmpty, let record = await store.lookup(needle) else {
                    return .text("unknown host\n", status: 404)
                }
                guard let address = record.report.primaryAddress else {
                    return .text("no address on record\n", status: 404)
                }
                let age = now.timeIntervalSince(record.lastReportAt)
                let stale = age > options.staleAfter
                // `?strict=1` refuses to hand out an address we cannot vouch for.
                if stale, request.query["strict"] != nil {
                    return .text("stale: last report \(Int(age))s ago\n", status: 404)
                }
                return HTTPResponse(
                    status: 200,
                    contentType: "text/plain; charset=utf-8",
                    body: Data("\(address)\n".utf8),
                    extraHeaders: [
                        ("X-Host-Stale", stale ? "true" : "false"),
                        ("X-Host-Age-Seconds", String(Int(age))),
                    ]
                )
            }

            // DELETE /host/<name> — retire a decommissioned machine.
            if request.method == "DELETE", request.path.hasPrefix("/host/") {
                guard authorized else { return .text("unauthorized\n", status: 401) }
                let needle = String(request.path.dropFirst("/host/".count))
                guard let removed = await store.forget(needle) else {
                    return .text("unknown host\n", status: 404)
                }
                Log.info("forgot \(removed.report.hostname) on request from \(client ?? "unknown")")
                return .text("forgot \(removed.report.hostname)\n")
            }

            return .text("not found\n", status: 404)
        }
    }

    /// Told to the reporter so it can log the address the collector actually saw.
    struct Acknowledgement: Codable {
        var observedAddress: String?
        var changed: Bool
    }

    /// Behind a reverse proxy every connection arrives from loopback, so the real client
    /// address has to come from `X-Forwarded-For`. That header is trivially forgeable by
    /// anyone who can reach the collector directly, so honouring it is opt-in and only
    /// correct when the collector binds loopback and the proxy is the sole possible source.
    static func clientAddress(_ request: HTTPRequest, peer: String?, trustForwardedFor: Bool) -> String? {
        guard trustForwardedFor, let forwarded = request.header("x-forwarded-for") else { return peer }
        // Left-most entry is the original client; anything after it is an intermediate proxy.
        guard let first = forwarded.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty
        else { return peer }
        return first
    }

    static let unauthorizedRead = HTTPResponse(
        status: 401,
        contentType: "text/plain; charset=utf-8",
        body: Data("unauthorized\n".utf8),
        extraHeaders: [("WWW-Authenticate", "Bearer")]
    )
}
