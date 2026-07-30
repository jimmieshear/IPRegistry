import CollectorKit
import Foundation
import IPReportCore
import Network

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

        let listener: NWListener
        do {
            listener = try makeListener(options: options)
        } catch {
            Log.error("could not create listener: \(error)")
            exit(1)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("collector listening on \(options.bindHost ?? "0.0.0.0"):\(options.port)")
                Log.info("dashboard: http://\(options.bindHost ?? SystemInfo.hostname):\(options.port)/")
            case .failed(let error):
                Log.error("listener failed: \(error)")
                exit(1)
            case .cancelled:
                Log.info("listener cancelled")
                exit(0)
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            Task { await handle(connection, store: store, options: options, token: token) }
        }

        listener.start(queue: DispatchQueue(label: "ipcollector.listener"))

        // Park forever; all work happens on listener callbacks.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private static func makeListener(options: CollectorOptions) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Report and dashboard payloads are tiny; disabling Nagle shaves a round trip.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        guard let port = NWEndpoint.Port(rawValue: options.port) else {
            throw CollectorError.usage("invalid port \(options.port)")
        }
        guard let host = options.bindHost else {
            return try NWListener(using: parameters, on: port)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        return try NWListener(using: parameters)
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
            // Deliberately leaked: these live for the lifetime of the process.
            signalSources.append(source)
        }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    // MARK: - Connection handling

    private static func handle(
        _ connection: NWConnection,
        store: Store,
        options: CollectorOptions,
        token: String
    ) async {
        let peer = peerAddress(of: connection)
        connection.start(queue: DispatchQueue(label: "ipcollector.connection"))

        // A client that opens a socket and goes quiet must not hold a slot forever.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            connection.forceCancel()
        }
        defer {
            watchdog.cancel()
            connection.cancel()
        }

        var parser = HTTPRequestParser()
        var request: HTTPRequest?

        do {
            while request == nil {
                guard let chunk = try await receive(connection) else { break }
                if chunk.isEmpty { continue }
                request = try parser.append(chunk)
            }
        } catch let error as HTTPParseError {
            let status: Int
            switch error {
            case .bodyTooLarge, .headersTooLarge: status = 413
            default: status = 400
            }
            await send(connection, HTTPResponse.text("\(error)\n", status: status))
            return
        } catch {
            // Client vanished mid-request; nothing useful to say back.
            return
        }

        guard let request else { return }

        let response = await Router.route(request, peer: peer, store: store, options: options, token: token)
        await send(connection, response)
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ response: HTTPResponse) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: response.serialized(),
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }

    /// The remote address of an inbound connection, normalised so an IPv4-mapped IPv6
    /// peer reads as plain IPv4.
    private static func peerAddress(of connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        var text: String
        switch host {
        case .ipv4(let address):
            text = String(describing: address)
        case .ipv6(let address):
            text = String(describing: address)
        case .name(let name, _):
            text = name
        @unknown default:
            return nil
        }
        if let zone = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<zone])
        }
        for prefix in ["::ffff:", "::FFFF:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - Arguments

    private static let usage = """
    ipcollector — receives IP reports from Macs and serves a live dashboard

    USAGE
      ipcollector [options]

    OPTIONS
      --port <n>              TCP port to listen on (default 8710)
      --bind <host>           Bind to one address only (default: all interfaces)
      --token-file <path>     Shared secret file (default /usr/local/etc/ipreport/token)
      --token <secret>        Shared secret inline — for testing only, it leaks via ps(1)
      --state <path>          State file (default /usr/local/var/ipreport/state.json)
      --stale-after <sec>     Mark a machine stale after this long without a report (default 180)
      --forget-after <sec>    Drop a machine entirely after this long (default 2592000, 0 disables)
      --refresh <sec>         Dashboard auto-refresh interval (default 15)
      --require-auth-reads    Require the bearer token for the dashboard and /json too
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
