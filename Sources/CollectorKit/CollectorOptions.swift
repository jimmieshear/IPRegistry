import Foundation

public struct CollectorOptions: Sendable {
    public var bindHost: String?
    public var port: UInt16 = 8710
    public var tokenPath = "/usr/local/etc/ipreport/token"
    public var inlineToken: String?
    public var statePath = "/usr/local/var/ipreport/state.json"
    public var staleAfter: TimeInterval = 180
    public var forgetAfter: TimeInterval = 30 * 86_400
    public var refreshSeconds = 15
    public var requireAuthForReads = false
    public var verbose = false
    public var title = "Mac IP Registry"

    public init() {}
}
