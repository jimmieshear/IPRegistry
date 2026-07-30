#if os(macOS)
import Foundation
import IPReportCore
import Network

/// On-disk configuration, so the LaunchDaemon plist never has to carry the secret.
struct ReporterConfig: Codable, Sendable {
    var collectorURL: String
    var intervalSeconds: Double?
    var tokenFile: String?
}

struct ReporterOptions: Sendable {
    var collectorURL: URL
    var interval: TimeInterval
    var tokenPath: String
    var once: Bool
    var dryRun: Bool
    var verbose: Bool
}

enum ReporterError: Error, CustomStringConvertible {
    case usage(String)
    case noCollector
    case badURL(String)
    case notHTTP

    var description: String {
        switch self {
        case .usage(let message): return message
        case .noCollector: return "no collector URL: pass --collector or set collectorURL in the config file"
        case .badURL(let raw): return "could not parse collector URL '\(raw)'"
        case .notHTTP: return "collector response was not HTTP"
        }
    }
}

private enum Trigger: Equatable, Sendable {
    case startup
    case heartbeat
    case networkChange
}

@main
struct Reporter {
    static let defaultConfigPath = "/usr/local/etc/ipreport/reporter.json"

    static func main() async {
        let options: ReporterOptions
        do {
            guard let parsed = try resolveOptions(Array(CommandLine.arguments.dropFirst())) else { return }
            options = parsed
        } catch {
            Log.error("\(error)")
            FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
            exit(2)
        }

        guard let host = options.collectorURL.host else {
            Log.error("collector URL has no host: \(options.collectorURL)")
            exit(2)
        }
        let port = UInt16(options.collectorURL.port ?? (options.collectorURL.scheme == "https" ? 443 : 80))

        // Dry run needs no secret — it is for checking what this machine would report.
        var token = ""
        if !options.dryRun {
            do {
                token = try Wire.readToken(at: options.tokenPath)
            } catch {
                Log.error("could not read shared secret: \(error)")
                exit(1)
            }
        }

        if options.dryRun {
            let report = buildReport(collectorHost: host, collectorPort: port)
            let data = (try? Wire.encoder(pretty: true).encode(report)) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return
        }

        if options.once {
            let report = buildReport(collectorHost: host, collectorPort: port)
            do {
                let observed = try await push(report, options: options, token: token)
                Log.info("reported \(report.primaryAddress ?? "unknown") to \(options.collectorURL.absoluteString)\(observed.map { ", seen as \($0)" } ?? "")")
            } catch {
                Log.error("report failed: \(error)")
                exit(1)
            }
            return
        }

        Log.info("ipreporter \(ipReportAgentVersion) starting: collector \(options.collectorURL.absoluteString), heartbeat \(Int(options.interval))s")

        let (stream, continuation) = AsyncStream<Trigger>.makeStream(
            of: Trigger.self,
            bufferingPolicy: .bufferingNewest(4)
        )

        // Fires on every link change: DHCP renewal, Wi-Fi roam, VPN up/down, cable pull.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            continuation.yield(.networkChange)
        }
        monitor.start(queue: DispatchQueue(label: "ipreporter.path"))

        // Heartbeats double as liveness: a missing heartbeat is how the dashboard learns
        // a machine went away.
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(options.interval))
                continuation.yield(.heartbeat)
            }
        }
        defer {
            heartbeat.cancel()
            monitor.cancel()
        }

        continuation.yield(.startup)

        var lastSignature: String?
        for await trigger in stream {
            if trigger == .networkChange {
                // Let DHCP and DNS settle; the first address after a link change is often
                // link-local or about to be replaced.
                try? await Task.sleep(for: .seconds(3))
            }

            let report = buildReport(collectorHost: host, collectorPort: port)

            // Link changes fire in bursts and most of them change nothing. Heartbeats
            // always go out, so the collector can still tell alive from dead.
            if trigger == .networkChange, report.addressSignature == lastSignature {
                if options.verbose {
                    Log.info("link changed but addressing is unchanged, skipping push")
                }
                continue
            }

            do {
                let observed = try await pushWithRetry(report, options: options, token: token)
                if lastSignature != report.addressSignature {
                    Log.info("reported \(report.primaryAddress ?? "unknown") via \(report.primaryInterface ?? "?")\(observed.map { ", seen as \($0)" } ?? "")")
                } else if options.verbose {
                    Log.info("heartbeat ok, still \(report.primaryAddress ?? "unknown")")
                }
                lastSignature = report.addressSignature
            } catch {
                Log.error("giving up on this report: \(error)")
                // Do not update lastSignature — the next heartbeat retries from scratch.
            }
        }
    }

    // MARK: - Report building

    static func buildReport(collectorHost: String, collectorPort: UInt16) -> HostReport {
        let addresses = NetworkScan.interfaceAddresses()

        // Ask the routing table which address would be used to reach the collector. Ignore
        // a loopback answer — that happens when the reporter runs on the collector's own
        // Mac, and 127.0.0.1 is not an address anyone can use to reach it.
        let routed = NetworkScan.sourceAddress(reaching: collectorHost, port: collectorPort)
            .flatMap { NetworkScan.isUnroutable($0) ? nil : $0 }

        // Fall back to the first real IPv4, then to any address at all.
        let primary = routed
            ?? addresses.first { $0.family == .ipv4 }?.address
            ?? addresses.first?.address

        let primaryInterface = addresses.first { $0.address == primary }?.interface

        return HostReport(
            machineID: SystemInfo.machineID,
            hostname: SystemInfo.hostname,
            localHostname: SystemInfo.localHostname,
            model: SystemInfo.model,
            osVersion: SystemInfo.osVersion,
            serialNumber: SystemInfo.serialNumber,
            primaryAddress: primary,
            primaryInterface: primaryInterface,
            addresses: addresses,
            bootTime: SystemInfo.bootTime,
            reportedAt: Date()
        )
    }

    // MARK: - Pushing

    /// Returns the address the collector saw us as, when it tells us.
    static func push(_ report: HostReport, options: ReporterOptions, token: String) async throws -> String? {
        var request = URLRequest(url: options.collectorURL.appending(path: "report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ipreporter/\(ipReportAgentVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Wire.encoder().encode(report)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReporterError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw IPReportError.collectorRejected(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        let ack = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let observed = ack?["observedAddress"] as? String
        return (observed?.isEmpty ?? true) ? nil : observed
    }

    static func pushWithRetry(_ report: HostReport, options: ReporterOptions, token: String) async throws -> String? {
        let delays: [Double] = [2, 5, 12, 30]
        var attempt = 0
        while true {
            do {
                return try await push(report, options: options, token: token)
            } catch {
                // A rejected token will never succeed on retry; fail fast and loudly.
                if case IPReportError.collectorRejected(let status, _) = error, status == 401 || status == 403 {
                    throw error
                }
                guard attempt < delays.count else { throw error }
                Log.warn("push failed (\(error)); retrying in \(Int(delays[attempt]))s")
                try? await Task.sleep(for: .seconds(delays[attempt]))
                attempt += 1
            }
        }
    }

    // MARK: - Arguments and config

    static let usage = """
    ipreporter — pushes this Mac's current addresses to an ipcollector

    USAGE
      ipreporter [options]

    OPTIONS
      --config <path>       Config file (default \(defaultConfigPath))
      --collector <url>     Collector base URL, e.g. http://collector.example.com:8710
      --interval <sec>      Heartbeat interval (default 60)
      --token-file <path>   Shared secret file (default /usr/local/etc/ipreport/token)
      --once                Send a single report and exit
      --dry-run             Print the report that would be sent, contact nothing
      --verbose             Log heartbeats as well as changes
      -h, --help            Show this help

    Run as a LaunchDaemon with KeepAlive so it reports from the login window, before
    anyone signs in. It pushes on startup, on every link change, and on each heartbeat.
    """

    private static func resolveOptions(_ arguments: [String]) throws -> ReporterOptions? {
        var configPath: String?
        var collector: String?
        var interval: TimeInterval?
        var tokenPath: String?
        var once = false
        var dryRun = false
        var verbose = false
        var index = 0

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ReporterError.usage("\(flag) requires a value") }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                print(usage)
                return nil
            case "--config": configPath = try next(argument)
            case "--collector": collector = try next(argument)
            case "--interval":
                let raw = try next(argument)
                guard let value = TimeInterval(raw), value >= 5 else {
                    throw ReporterError.usage("invalid --interval \(raw) (minimum 5)")
                }
                interval = value
            case "--token-file": tokenPath = try next(argument)
            case "--once": once = true
            case "--dry-run": dryRun = true
            case "--verbose": verbose = true
            default:
                throw ReporterError.usage("unknown argument \(argument)")
            }
            index += 1
        }

        // Config file supplies defaults; command-line flags win.
        let path = configPath ?? defaultConfigPath
        var config: ReporterConfig?
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                config = try Wire.decoder().decode(ReporterConfig.self, from: data)
            } catch {
                throw ReporterError.usage("could not read config \(path): \(error)")
            }
        } else if configPath != nil {
            throw ReporterError.usage("config file not found: \(path)")
        }

        guard let rawURL = collector ?? config?.collectorURL else { throw ReporterError.noCollector }
        guard let url = URL(string: rawURL), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw ReporterError.badURL(rawURL)
        }

        return ReporterOptions(
            collectorURL: url,
            interval: interval ?? config?.intervalSeconds ?? 60,
            tokenPath: tokenPath ?? config?.tokenFile ?? "/usr/local/etc/ipreport/token",
            once: once,
            dryRun: dryRun,
            verbose: verbose
        )
    }
}

#else
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// The reporter reads the IORegistry and watches NWPathMonitor, so it is macOS-only. This
// stub exists so that cross-compiling the whole package for the Linux collector succeeds
// instead of failing on a target nobody asked for.
@main
struct Reporter {
    static func main() {
        FileHandle.standardError.write(Data("ipreporter runs on macOS only\n".utf8))
        exit(1)
    }
}
#endif
