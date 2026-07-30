import Foundation
import Testing

@testable import CollectorKit
@testable import IPReportCore

// MARK: - Fixtures

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func makeReport(
    machineID: String = "UUID-1",
    hostname: String = "buildbox-07.corp.example.com",
    localHostname: String? = "buildbox-07.local",
    serial: String? = "C02XY1234567",
    primary: String? = "10.0.4.22",
    primaryInterface: String? = "en0",
    addresses: [InterfaceAddress]? = nil,
    reportedAt: Date = epoch
) -> HostReport {
    HostReport(
        machineID: machineID,
        hostname: hostname,
        localHostname: localHostname,
        model: "Mac15,3",
        osVersion: "26.4.2",
        serialNumber: serial,
        primaryAddress: primary,
        primaryInterface: primaryInterface,
        addresses: addresses ?? [
            InterfaceAddress(interface: "en0", address: primary ?? "10.0.4.22", family: .ipv4),
            InterfaceAddress(interface: "en1", address: "10.9.9.9", family: .ipv4),
        ],
        bootTime: epoch.addingTimeInterval(-90_000),
        reportedAt: reportedAt
    )
}

private func makeStore(forgetAfter: TimeInterval = 0) -> (Store, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ipreg-test-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("state.json")
    return (Store(stateURL: url, forgetAfter: forgetAfter), url)
}

private func options(
    staleAfter: TimeInterval = 180,
    requireAuthForReads: Bool = false,
    trustForwardedFor: Bool = false
) -> CollectorOptions {
    var options = CollectorOptions()
    options.staleAfter = staleAfter
    options.requireAuthForReads = requireAuthForReads
    options.trustForwardedFor = trustForwardedFor
    return options
}

private let token = "s3cret-token"

private func request(
    _ method: String,
    _ target: String,
    bearer: String? = nil,
    headers: [String: String] = [:],
    body: String = ""
) throws -> HTTPRequest {
    var raw = "\(method) \(target) HTTP/1.1\r\nHost: collector\r\n"
    if let bearer { raw += "Authorization: Bearer \(bearer)\r\n" }
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        raw += "\(name): \(value)\r\n"
    }
    let bodyData = Data(body.utf8)
    raw += "Content-Length: \(bodyData.count)\r\n\r\n"

    var parser = HTTPRequestParser()
    var data = Data(raw.utf8)
    data.append(bodyData)
    guard let parsed = try parser.append(data) else {
        throw TestFailure.incompleteRequest
    }
    return parsed
}

private enum TestFailure: Error { case incompleteRequest }

private func bodyText(_ response: HTTPResponse) -> String {
    String(decoding: response.body, as: UTF8.self)
}

private func headerValue(_ response: HTTPResponse, _ name: String) -> String? {
    response.headers.first { $0.0.lowercased() == name.lowercased() }?.1
}

// MARK: - HTTP parsing

@Suite("HTTP request parsing")
struct HTTPParsingTests {
    @Test("parses a simple GET")
    func simpleGet() throws {
        var parser = HTTPRequestParser()
        let parsed = try parser.append(Data("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let request = try #require(parsed)
        #expect(request.method == "GET")
        #expect(request.path == "/healthz")
        #expect(request.body.isEmpty)
    }

    @Test("lowercases header names and reads a bearer token")
    func headerCasing() throws {
        var parser = HTTPRequestParser()
        let parsed = try parser.append(Data("GET / HTTP/1.1\r\nAUTHORIZATION: Bearer abc123\r\n\r\n".utf8))
        let request = try #require(parsed)
        #expect(request.header("authorization") == "Bearer abc123")
        #expect(request.header("Authorization") == "Bearer abc123")
        #expect(request.bearerToken == "abc123")
    }

    @Test("ignores a non-bearer Authorization scheme")
    func nonBearerAuth() throws {
        var parser = HTTPRequestParser()
        let parsed = try parser.append(Data("GET / HTTP/1.1\r\nAuthorization: Basic abc\r\n\r\n".utf8))
        #expect(try #require(parsed).bearerToken == nil)
    }

    @Test("reassembles a request split across chunks")
    func splitAcrossChunks() throws {
        var parser = HTTPRequestParser()
        #expect(try parser.append(Data("POST /report HTTP/1.1\r\nCont".utf8)) == nil)
        #expect(try parser.append(Data("ent-Length: 7\r\n\r\nab".utf8)) == nil)
        let parsed = try parser.append(Data("cdefg".utf8))
        let request = try #require(parsed)
        #expect(request.method == "POST")
        #expect(bodyTextOf(request) == "abcdefg")
    }

    @Test("waits for the full body before returning")
    func partialBody() throws {
        var parser = HTTPRequestParser()
        #expect(try parser.append(Data("POST /r HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort".utf8)) == nil)
    }

    @Test("splits query parameters and percent-decodes the path")
    func queryAndEncoding() throws {
        var parser = HTTPRequestParser()
        let parsed = try parser.append(Data("GET /ip/my%20box?strict=1&x= HTTP/1.1\r\n\r\n".utf8))
        let request = try #require(parsed)
        #expect(request.path == "/ip/my box")
        #expect(request.query["strict"] == "1")
        #expect(request.query["x"] == "")
    }

    @Test("rejects chunked transfer-encoding")
    func rejectsChunked() {
        var parser = HTTPRequestParser()
        #expect(throws: HTTPParseError.self) {
            _ = try parser.append(Data("POST /r HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        }
    }

    @Test("rejects a non-numeric Content-Length")
    func rejectsBadContentLength() {
        var parser = HTTPRequestParser()
        #expect(throws: HTTPParseError.self) {
            _ = try parser.append(Data("POST /r HTTP/1.1\r\nContent-Length: banana\r\n\r\n".utf8))
        }
    }

    @Test("rejects an oversized body before buffering it")
    func rejectsOversizedBody() {
        var parser = HTTPRequestParser(maxHeaderBytes: 1024, maxBodyBytes: 16)
        #expect(throws: HTTPParseError.self) {
            _ = try parser.append(Data("POST /r HTTP/1.1\r\nContent-Length: 1000\r\n\r\n".utf8))
        }
    }

    @Test("rejects oversized headers")
    func rejectsOversizedHeaders() {
        var parser = HTTPRequestParser(maxHeaderBytes: 64, maxBodyBytes: 1024)
        let padding = String(repeating: "x", count: 200)
        #expect(throws: HTTPParseError.self) {
            _ = try parser.append(Data("GET /\(padding) HTTP/1.1\r\nHost: y\r\n".utf8))
        }
    }

    @Test("serialises a response with the right length and framing")
    func responseSerialisation() {
        let raw = String(decoding: HTTPResponse.text("hi\n", status: 404).serialized(), as: UTF8.self)
        #expect(raw.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(raw.contains("Content-Length: 3\r\n"))
        #expect(raw.contains("Connection: close\r\n"))
        #expect(raw.hasSuffix("\r\n\r\nhi\n"))
    }

    private func bodyTextOf(_ request: HTTPRequest) -> String {
        String(decoding: request.body, as: UTF8.self)
    }
}

// MARK: - Routing and auth

@Suite("Routing")
struct RouterTests {
    @Test("a report without a token is rejected")
    func reportRequiresToken() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport())
        let response = await Router.route(
            try request("POST", "/report", body: String(decoding: payload, as: UTF8.self)),
            peer: "10.0.4.22", store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 401)
        #expect(await store.count == 0)
    }

    @Test("a report with the wrong token is rejected")
    func reportRejectsWrongToken() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport())
        let response = await Router.route(
            try request("POST", "/report", bearer: "not-the-token", body: String(decoding: payload, as: UTF8.self)),
            peer: "10.0.4.22", store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 401)
        #expect(await store.count == 0)
    }

    @Test("a valid report is stored and acknowledged with the observed address")
    func reportAccepted() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport())
        let response = await Router.route(
            try request("POST", "/report", bearer: token, body: String(decoding: payload, as: UTF8.self)),
            peer: "203.0.113.9", store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 200)

        let ack = try Wire.decoder().decode(Router.Acknowledgement.self, from: response.body)
        #expect(ack.observedAddress == "203.0.113.9")
        #expect(ack.changed == true)
        #expect(await store.count == 1)
    }

    @Test("a body that is not JSON is a 400, not a crash")
    func garbageBody() async throws {
        let (store, _) = makeStore()
        let response = await Router.route(
            try request("POST", "/report", bearer: token, body: "this is not json"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 400)
    }

    @Test("a report missing its identity is a 400")
    func missingIdentity() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport(machineID: "", hostname: ""))
        let response = await Router.route(
            try request("POST", "/report", bearer: token, body: String(decoding: payload, as: UTF8.self)),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 400)
        #expect(await store.count == 0)
    }

    @Test("/ip resolves by short hostname, fqdn, .local name, serial and machine id",
          arguments: ["buildbox-07", "BUILDBOX-07", "buildbox-07.corp.example.com", "buildbox-07.local", "C02XY1234567", "UUID-1"])
    func ipLookupAliases(needle: String) async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        let response = await Router.route(
            try request("GET", "/ip/\(needle)"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 200)
        #expect(bodyText(response) == "10.0.4.22\n")
        #expect(headerValue(response, "X-Host-Stale") == "false")
    }

    @Test("/ip on an unknown host is a 404")
    func ipUnknown() async throws {
        let (store, _) = makeStore()
        let response = await Router.route(
            try request("GET", "/ip/nosuchbox"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 404)
    }

    @Test("/ip flags a stale record but still answers")
    func ipStaleFlagged() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        let later = epoch.addingTimeInterval(600)
        let response = await Router.route(
            try request("GET", "/ip/buildbox-07"),
            peer: nil, store: store, options: options(staleAfter: 180), token: token, now: later
        )
        #expect(response.status == 200)
        #expect(headerValue(response, "X-Host-Stale") == "true")
        #expect(headerValue(response, "X-Host-Age-Seconds") == "600")
    }

    @Test("/ip?strict=1 refuses a stale record")
    func ipStaleStrict() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        let response = await Router.route(
            try request("GET", "/ip/buildbox-07?strict=1"),
            peer: nil, store: store, options: options(staleAfter: 180),
            token: token, now: epoch.addingTimeInterval(600)
        )
        #expect(response.status == 404)
        #expect(bodyText(response).contains("stale"))
    }

    @Test("/ip on a record with no address is a 404")
    func ipNoAddress() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(primary: nil, primaryInterface: nil, addresses: []), observedAddress: nil, at: epoch)
        let response = await Router.route(
            try request("GET", "/ip/buildbox-07"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 404)
    }

    @Test("the dashboard renders the host and its address")
    func dashboardRenders() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: "10.0.4.22", at: epoch)
        let response = await Router.route(
            try request("GET", "/"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 200)
        let html = bodyText(response)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("buildbox-07.corp.example.com"))
        #expect(html.contains("10.0.4.22"))
        #expect(html.contains("<b>1</b> current"))
        #expect(headerValue(response, "Content-Type")?.contains("text/html") == true)
    }

    @Test("the dashboard shows an empty state before anything reports")
    func dashboardEmpty() async throws {
        let (store, _) = makeStore()
        let response = await Router.route(
            try request("GET", "/"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 200)
        #expect(bodyText(response).contains("No machines have reported yet"))
    }

    @Test("/json round-trips into a Snapshot")
    func jsonSnapshot() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: "203.0.113.9", at: epoch)
        let response = await Router.route(
            try request("GET", "/json"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(response.status == 200)

        let snapshot = try Wire.decoder().decode(Snapshot.self, from: response.body)
        #expect(snapshot.total == 1)
        #expect(snapshot.current == 1)
        #expect(snapshot.stale == 0)
        #expect(snapshot.hosts.first?.primaryAddress == "10.0.4.22")
        // Reported 10.0.4.22 but seen as 203.0.113.9 — NAT in the path.
        #expect(snapshot.hosts.first?.addressMismatch == true)
        #expect(snapshot.hosts.first?.uptimeSeconds == 90_000)
    }

    @Test("reads can be locked behind the token")
    func readAuthEnforced() async throws {
        let (store, _) = makeStore()
        let locked = options(requireAuthForReads: true)

        for target in ["/", "/json", "/ip/buildbox-07"] {
            let denied = await Router.route(
                try request("GET", target),
                peer: nil, store: store, options: locked, token: token, now: epoch
            )
            #expect(denied.status == 401, "\(target) should require auth")
            #expect(headerValue(denied, "WWW-Authenticate") == "Bearer")
        }

        let allowed = await Router.route(
            try request("GET", "/", bearer: token),
            peer: nil, store: store, options: locked, token: token, now: epoch
        )
        #expect(allowed.status == 200)
    }

    @Test("/healthz needs no token even when reads are locked")
    func healthzAlwaysOpen() async throws {
        let (store, _) = makeStore()
        let response = await Router.route(
            try request("GET", "/healthz"),
            peer: nil, store: store, options: options(requireAuthForReads: true), token: token, now: epoch
        )
        #expect(response.status == 200)
        #expect(bodyText(response) == "ok\n")
    }

    @Test("DELETE needs the token, then retires the machine")
    func deleteRequiresAuth() async throws {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)

        let denied = await Router.route(
            try request("DELETE", "/host/buildbox-07"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(denied.status == 401)
        #expect(await store.count == 1)

        let allowed = await Router.route(
            try request("DELETE", "/host/buildbox-07", bearer: token),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        #expect(allowed.status == 200)
        #expect(await store.count == 0)
    }

    @Test("unknown routes and methods are 404")
    func notFound() async throws {
        let (store, _) = makeStore()
        for (method, target) in [("GET", "/nope"), ("POST", "/"), ("PUT", "/report"), ("GET", "/ip/")] {
            let response = await Router.route(
                try request(method, target, bearer: token),
                peer: nil, store: store, options: options(), token: token, now: epoch
            )
            #expect(response.status == 404, "\(method) \(target)")
        }
    }

    // MARK: Reverse-proxy handling

    @Test("behind a trusted proxy the client address comes from X-Forwarded-For")
    func forwardedForHonoured() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport())
        let response = await Router.route(
            try request("POST", "/report", bearer: token,
                        headers: ["X-Forwarded-For": "203.0.113.9"],
                        body: String(decoding: payload, as: UTF8.self)),
            peer: "127.0.0.1", store: store,
            options: options(trustForwardedFor: true), token: token, now: epoch
        )
        #expect(response.status == 200)

        let ack = try Wire.decoder().decode(Router.Acknowledgement.self, from: response.body)
        // Without this, every machine behind Caddy would record 127.0.0.1.
        #expect(ack.observedAddress == "203.0.113.9")
        #expect(await store.lookup("buildbox-07")?.observedAddress == "203.0.113.9")
    }

    @Test("X-Forwarded-For is ignored unless explicitly trusted")
    func forwardedForIgnoredByDefault() async throws {
        let (store, _) = makeStore()
        let payload = try Wire.encoder().encode(makeReport())
        let response = await Router.route(
            try request("POST", "/report", bearer: token,
                        headers: ["X-Forwarded-For": "1.2.3.4"],
                        body: String(decoding: payload, as: UTF8.self)),
            peer: "10.0.4.22", store: store, options: options(), token: token, now: epoch
        )
        let ack = try Wire.decoder().decode(Router.Acknowledgement.self, from: response.body)
        #expect(ack.observedAddress == "10.0.4.22")
    }

    @Test("the left-most X-Forwarded-For entry wins")
    func forwardedForChain() throws {
        let chained = try request("GET", "/", headers: ["X-Forwarded-For": "203.0.113.9, 70.0.0.1, 127.0.0.1"])
        #expect(Router.clientAddress(chained, peer: "127.0.0.1", trustForwardedFor: true) == "203.0.113.9")
    }

    @Test("a blank or absent X-Forwarded-For falls back to the socket peer")
    func forwardedForFallback() throws {
        let blank = try request("GET", "/", headers: ["X-Forwarded-For": "   "])
        #expect(Router.clientAddress(blank, peer: "127.0.0.1", trustForwardedFor: true) == "127.0.0.1")

        let absent = try request("GET", "/")
        #expect(Router.clientAddress(absent, peer: "127.0.0.1", trustForwardedFor: true) == "127.0.0.1")
    }

    @Test("a hostname with HTML in it cannot inject markup into the dashboard")
    func htmlEscaping() async throws {
        let (store, _) = makeStore()
        await store.record(
            makeReport(hostname: "<script>alert('x')</script>", localHostname: nil),
            observedAddress: nil,
            at: epoch
        )
        let response = await Router.route(
            try request("GET", "/"),
            peer: nil, store: store, options: options(), token: token, now: epoch
        )
        let html = bodyText(response)
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;"))
    }
}

// MARK: - Store semantics

@Suite("Store")
struct StoreTests {
    @Test("a first report counts as a change")
    func firstReportIsAChange() async {
        let (store, _) = makeStore()
        let (record, changed) = await store.record(makeReport(), observedAddress: nil, at: epoch)
        #expect(changed)
        #expect(record.reportCount == 1)
        #expect(record.firstSeen == epoch)
        #expect(record.previousPrimaryAddress == nil)
    }

    @Test("a heartbeat with identical addressing is not a change")
    func heartbeatIsNotAChange() async {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        let later = epoch.addingTimeInterval(60)
        let (record, changed) = await store.record(makeReport(reportedAt: later), observedAddress: nil, at: later)

        #expect(!changed)
        #expect(record.reportCount == 2)
        #expect(record.lastReportAt == later)
        // The point of the distinction: liveness advanced, the address did not change.
        #expect(record.lastChangedAt == epoch)
        #expect(record.previousPrimaryAddress == nil)
    }

    @Test("a new address records the change and remembers the old one")
    func addressChangeTracked() async {
        let (store, _) = makeStore()
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        let later = epoch.addingTimeInterval(3600)
        let (record, changed) = await store.record(
            makeReport(primary: "10.0.4.99", addresses: [
                InterfaceAddress(interface: "en0", address: "10.0.4.99", family: .ipv4),
            ], reportedAt: later),
            observedAddress: nil,
            at: later
        )

        #expect(changed)
        #expect(record.report.primaryAddress == "10.0.4.99")
        #expect(record.previousPrimaryAddress == "10.0.4.22")
        #expect(record.lastChangedAt == later)
        #expect(record.firstSeen == epoch)
    }

    @Test("a renamed machine keeps one record, keyed by hardware id")
    func renameKeepsOneRecord() async {
        let (store, _) = makeStore()
        await store.record(makeReport(hostname: "old-name"), observedAddress: nil, at: epoch)
        await store.record(makeReport(hostname: "new-name"), observedAddress: nil, at: epoch)

        #expect(await store.count == 1)
        #expect(await store.lookup("new-name") != nil)
    }

    @Test("two machines are two records")
    func distinctMachines() async {
        let (store, _) = makeStore()
        await store.record(makeReport(machineID: "UUID-1", hostname: "a"), observedAddress: nil, at: epoch)
        await store.record(makeReport(machineID: "UUID-2", hostname: "b"), observedAddress: nil, at: epoch)
        #expect(await store.count == 2)
    }

    @Test("snapshots are sorted by hostname")
    func snapshotSorted() async {
        let (store, _) = makeStore()
        for (index, name) in ["zulu", "alpha", "Mike"].enumerated() {
            await store.record(makeReport(machineID: "UUID-\(index)", hostname: name), observedAddress: nil, at: epoch)
        }
        let names = await store.snapshot().map(\.report.hostname)
        #expect(names == ["alpha", "Mike", "zulu"])
    }

    @Test("state survives a restart")
    func persistenceRoundTrip() async throws {
        let (store, url) = makeStore()
        await store.record(makeReport(), observedAddress: "203.0.113.9", at: epoch)
        await store.flush(at: epoch)

        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = Store(stateURL: url, forgetAfter: 0)
        await reloaded.load()
        #expect(await reloaded.count == 1)

        let record = try #require(await reloaded.lookup("buildbox-07"))
        #expect(record.report.primaryAddress == "10.0.4.22")
        #expect(record.observedAddress == "203.0.113.9")
        #expect(record.firstSeen == epoch)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("long-silent machines are dropped on save")
    func forgetsAncientRecords() async {
        let (store, url) = makeStore(forgetAfter: 3600)
        await store.record(makeReport(machineID: "OLD", hostname: "decommissioned"), observedAddress: nil, at: epoch)
        await store.record(makeReport(machineID: "NEW", hostname: "alive"), observedAddress: nil, at: epoch.addingTimeInterval(7200))

        // Save two hours after the first report: the older record is past forgetAfter.
        await store.flush(at: epoch.addingTimeInterval(7200))

        #expect(await store.count == 1)
        #expect(await store.lookup("alive") != nil)
        #expect(await store.lookup("decommissioned") == nil)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("forgetAfter = 0 keeps records forever")
    func forgetDisabled() async {
        let (store, url) = makeStore(forgetAfter: 0)
        await store.record(makeReport(), observedAddress: nil, at: epoch)
        await store.flush(at: epoch.addingTimeInterval(86_400 * 365))
        #expect(await store.count == 1)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("loading a corrupt state file starts empty instead of dying")
    func corruptStateFile() async throws {
        let (_, url) = makeStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: url)

        let store = Store(stateURL: url, forgetAfter: 0)
        await store.load()
        #expect(await store.count == 0)

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: - Helpers

@Suite("Helpers")
struct HelperTests {
    @Test("constant-time comparison still compares correctly")
    func constantTimeEquality() {
        #expect(Wire.constantTimeEquals("abc", "abc"))
        #expect(!Wire.constantTimeEquals("abc", "abd"))
        #expect(!Wire.constantTimeEquals("abc", "abcd"))
        #expect(!Wire.constantTimeEquals("", "a"))
        #expect(Wire.constantTimeEquals("", ""))
    }

    @Test("address signature ignores ordering but not content")
    func addressSignature() {
        let forward = makeReport(addresses: [
            InterfaceAddress(interface: "en0", address: "10.0.0.1", family: .ipv4),
            InterfaceAddress(interface: "en1", address: "10.0.0.2", family: .ipv4),
        ])
        let reversed = makeReport(addresses: [
            InterfaceAddress(interface: "en1", address: "10.0.0.2", family: .ipv4),
            InterfaceAddress(interface: "en0", address: "10.0.0.1", family: .ipv4),
        ])
        let different = makeReport(addresses: [
            InterfaceAddress(interface: "en0", address: "10.0.0.3", family: .ipv4),
        ])

        #expect(forward.addressSignature == reversed.addressSignature)
        #expect(forward.addressSignature != different.addressSignature)
    }

    @Test("signature notices a primary change even when the address list is identical")
    func signatureCatchesPrimaryChange() {
        let addresses = [
            InterfaceAddress(interface: "en0", address: "10.0.0.1", family: .ipv4),
            InterfaceAddress(interface: "utun3", address: "10.9.0.1", family: .ipv4),
        ]
        let viaEthernet = makeReport(primary: "10.0.0.1", addresses: addresses)
        let viaVPN = makeReport(primary: "10.9.0.1", addresses: addresses)
        #expect(viaEthernet.addressSignature != viaVPN.addressSignature)
    }

    @Test("relative times read naturally", arguments: [
        (0.0, "just now"), (30.0, "30s ago"), (90.0, "1m ago"),
        (7200.0, "2h ago"), (172_800.0, "2d ago"),
    ])
    func relativeTimes(age: Double, expected: String) {
        let past = epoch.addingTimeInterval(-age)
        #expect(past.relativeDescription(from: epoch) == expected)
    }

    @Test("durations read naturally", arguments: [
        (60.0, "1m"), (3660.0, "1h 1m"), (90_061.0, "1d 1h"),
    ])
    func durations(seconds: Double, expected: String) {
        #expect(formatDuration(seconds) == expected)
    }

    @Test("loopback and wildcard addresses are never published", arguments: [
        "127.0.0.1", "127.1.2.3", "::1", "0.0.0.0", "::",
    ])
    func unroutableAddresses(address: String) {
        #expect(NetworkScan.isUnroutable(address))
    }

    @Test("real addresses are publishable", arguments: [
        "10.0.4.22", "192.168.1.5", "17.233.0.2", "2620:149:13d0::e4c", "fd9f:5af4::1",
    ])
    func routableAddresses(address: String) {
        #expect(!NetworkScan.isUnroutable(address))
    }

    @Test("this machine's own interface scan excludes loopback and link-local")
    func liveInterfaceScan() {
        let addresses = NetworkScan.interfaceAddresses()
        #expect(!addresses.isEmpty, "the test host should have at least one address")
        for address in addresses {
            #expect(!address.address.hasPrefix("127."))
            #expect(!address.address.hasPrefix("169.254."))
            #expect(!address.address.lowercased().hasPrefix("fe80"))
            #expect(address.interface != "lo0")
        }
    }

    @Test("this machine reports a usable hostname")
    func liveHostname() {
        // SystemInfo's IORegistry lookups live in the reporter target, which is macOS-only.
        // Platform.hostname is the portable piece the collector itself depends on.
        #expect(!Platform.hostname.isEmpty)
        #expect(Platform.hostname != "unknown")
    }

    @Test("timestamps are RFC 3339 UTC without Foundation's formatter")
    func timestampFormatting() {
        #expect(iso8601UTC(Date(timeIntervalSince1970: 1_800_167_445)) == "2027-01-17T06:30:45Z")
        #expect(iso8601UTC(Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15T08:00:00Z")
        #expect(iso8601UTC(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    @Test("html escaping covers the dangerous characters")
    func escaping() {
        #expect(htmlEscape("<a href='x' title=\"y\">&</a>")
            == "&lt;a href=&#39;x&#39; title=&quot;y&quot;&gt;&amp;&lt;/a&gt;")
    }
}
