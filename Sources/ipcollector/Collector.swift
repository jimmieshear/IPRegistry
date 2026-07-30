import CollectorKit
import Foundation
import IPReportCore

enum CollectorError: Error {
    case usage(String)
}

@main
struct Collector {
    static func main() async {
        let options: CollectorOptions
        do {
            guard let parsed = try parseArguments(Array(CommandLine.arguments.dropFirst())) else { return }
            options = parsed
        } catch let CollectorError.usage(message) {
            Log.error(message)
            FileHandle.standardError.write(Data("\n\(usage)\n".utf8))
            exit(2)
        } catch {
            Log.error("\(error)")
            exit(2)
        }

        let token: String
        if let inline = options.inlineToken {
            token = inline
        } else {
            do {
                token = try Wire.readToken(at: options.tokenPath)
            } catch {
                Log.error("could not read shared secret: \(error)")
                Log.error("create one with: head -c 32 /dev/urandom | xxd -p -c 32 > \(options.tokenPath)")
                exit(1)
            }
        }

        let store = Store(
            stateURL: URL(fileURLWithPath: options.statePath),
            forgetAfter: options.forgetAfter
        )
        await store.load()

        installSignalHandlers(store: store)

        let server = HTTPServer(bindHost: options.bindHost, port: options.port) { request, peer in
            await Router.route(request, peer: peer, store: store, options: options, token: token)
        }

        do {
            try server.start()
        } catch {
            Log.error("\(error)")
            exit(1)
        }

        let boundTo = options.bindHost ?? "*"
        Log.info("collector listening on \(boundTo):\(options.port)")
        if options.trustForwardedFor {
            Log.info("trusting X-Forwarded-For — this must only be reachable via a trusted proxy")
        }
        if options.bindHost == nil {
            Log.warn("bound to all interfaces; behind a reverse proxy use --bind 127.0.0.1")
        } else {
            Log.info("dashboard: http://\(boundTo):\(options.port)/")
        }

        // Park forever; all work happens on the server's accept thread.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// Persist on shutdown so an in-flight debounced save is never lost.
    private static func installSignalHandlers(store: Store) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                Task {
                    await store.flush()
                    Log.info("state flushed, exiting")
                    exit(0)
                }
            }
            source.resume()
            // Deliberately retained: these live for the lifetime of the process.
            signalSources.append(source)
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    // MARK: - Arguments

    private static let usage = """
    ipcollector — receives IP reports from Macs and serves a live dashboard

    USAGE
      ipcollector [options]

    OPTIONS
      --port <n>              TCP port to listen on (default 8710)
      --bind <host>           Bind to one address only (default: all interfaces).
                              Use 127.0.0.1 when running behind a reverse proxy.
      --token-file <path>     Shared secret file (default /usr/local/etc/ipreport/token)
      --token <secret>        Shared secret inline — for testing only, it leaks via ps(1)
      --state <path>          State file (default /usr/local/var/ipreport/state.json)
      --stale-after <sec>     Mark a machine stale after this long without a report (default 180)
      --forget-after <sec>    Drop a machine entirely after this long (default 2592000, 0 disables)
      --refresh <sec>         Dashboard auto-refresh interval (default 15)
      --require-auth-reads    Require the bearer token for the dashboard and /json too
      --trust-forwarded-for   Take the client address from X-Forwarded-For. Only safe with
                              --bind 127.0.0.1 behind a proxy you control.
      --title <text>          Dashboard heading
      --verbose               Log heartbeats as well as address changes
      -h, --help              Show this help

    ENDPOINTS
      GET  /                  HTML dashboard
      GET  /json              Full snapshot as JSON
      GET  /ip/<hostname>     Bare primary address (add ?strict=1 to 404 on stale records)
      GET  /healthz           Liveness probe
      POST /report            Reporter endpoint (bearer token required)
      DELETE /host/<hostname> Retire a machine (bearer token required)
    """

    private static func parseArguments(_ arguments: [String]) throws -> CollectorOptions? {
        var options = CollectorOptions()
        var index = 0

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CollectorError.usage("\(flag) requires a value") }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                print(usage)
                return nil
            case "--port":
                let raw = try next(argument)
                guard let port = UInt16(raw), port > 0 else { throw CollectorError.usage("invalid port \(raw)") }
                options.port = port
            case "--bind":
                options.bindHost = try next(argument)
            case "--token-file":
                options.tokenPath = try next(argument)
            case "--token":
                options.inlineToken = try next(argument)
            case "--state":
                options.statePath = try next(argument)
            case "--stale-after":
                let raw = try next(argument)
                guard let value = TimeInterval(raw), value > 0 else {
                    throw CollectorError.usage("invalid --stale-after \(raw)")
                }
                options.staleAfter = value
            case "--forget-after":
                let raw = try next(argument)
                guard let value = TimeInterval(raw), value >= 0 else {
                    throw CollectorError.usage("invalid --forget-after \(raw)")
                }
                options.forgetAfter = value
            case "--refresh":
                let raw = try next(argument)
                guard let value = Int(raw), value > 0 else { throw CollectorError.usage("invalid --refresh \(raw)") }
                options.refreshSeconds = value
            case "--require-auth-reads":
                options.requireAuthForReads = true
            case "--trust-forwarded-for":
                options.trustForwardedFor = true
            case "--title":
                options.title = try next(argument)
            case "--verbose":
                options.verbose = true
            default:
                throw CollectorError.usage("unknown argument \(argument)")
            }
            index += 1
        }
        return options
    }
}
