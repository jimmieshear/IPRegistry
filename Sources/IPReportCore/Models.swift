import Foundation

/// Bumped whenever the wire format or reporter behaviour changes.
public let ipReportAgentVersion = "1.0.0"

/// A single address bound to a single interface at report time.
public struct InterfaceAddress: Codable, Sendable, Hashable {
    public enum Family: String, Codable, Sendable {
        case ipv4
        case ipv6
    }

    public var interface: String
    public var address: String
    public var family: Family

    public init(interface: String, address: String, family: Family) {
        self.interface = interface
        self.address = address
        self.family = family
    }
}

/// What a reporter pushes to the collector.
public struct HostReport: Codable, Sendable {
    /// Stable hardware identity. Survives hostname changes and re-imaging.
    public var machineID: String
    public var hostname: String
    public var localHostname: String?
    public var model: String?
    public var osVersion: String?
    public var serialNumber: String?
    /// The address the machine would use as its source when talking to the collector.
    public var primaryAddress: String?
    public var primaryInterface: String?
    public var addresses: [InterfaceAddress]
    public var bootTime: Date?
    public var agentVersion: String
    public var reportedAt: Date

    public init(
        machineID: String,
        hostname: String,
        localHostname: String? = nil,
        model: String? = nil,
        osVersion: String? = nil,
        serialNumber: String? = nil,
        primaryAddress: String? = nil,
        primaryInterface: String? = nil,
        addresses: [InterfaceAddress] = [],
        bootTime: Date? = nil,
        agentVersion: String = ipReportAgentVersion,
        reportedAt: Date = Date()
    ) {
        self.machineID = machineID
        self.hostname = hostname
        self.localHostname = localHostname
        self.model = model
        self.osVersion = osVersion
        self.serialNumber = serialNumber
        self.primaryAddress = primaryAddress
        self.primaryInterface = primaryInterface
        self.addresses = addresses
        self.bootTime = bootTime
        self.agentVersion = agentVersion
        self.reportedAt = reportedAt
    }

    /// Identity-independent fingerprint of the addressing, used to skip redundant pushes.
    public var addressSignature: String {
        let sorted = addresses
            .map { "\($0.interface)=\($0.address)" }
            .sorted()
            .joined(separator: ",")
        return "\(primaryAddress ?? "-")|\(sorted)"
    }
}

/// What the collector keeps for each machine. Current state only — one record per machine.
public struct HostRecord: Codable, Sendable {
    public var report: HostReport
    /// Peer address of the TCP connection the report arrived on. Authoritative, and
    /// differs from `primaryAddress` when there is NAT or a VPN in the path.
    public var observedAddress: String?
    public var firstSeen: Date
    public var lastReportAt: Date
    /// When the addressing last actually changed, as opposed to when we last heard a heartbeat.
    public var lastChangedAt: Date
    public var previousPrimaryAddress: String?
    public var reportCount: Int

    public init(
        report: HostReport,
        observedAddress: String?,
        firstSeen: Date,
        lastReportAt: Date,
        lastChangedAt: Date,
        previousPrimaryAddress: String? = nil,
        reportCount: Int = 1
    ) {
        self.report = report
        self.observedAddress = observedAddress
        self.firstSeen = firstSeen
        self.lastReportAt = lastReportAt
        self.lastChangedAt = lastChangedAt
        self.previousPrimaryAddress = previousPrimaryAddress
        self.reportCount = reportCount
    }
}

/// On-disk shape of the collector's state file.
public struct StateFile: Codable, Sendable {
    public var version: Int
    public var savedAt: Date
    public var records: [HostRecord]

    public init(version: Int = 1, savedAt: Date = Date(), records: [HostRecord]) {
        self.version = version
        self.savedAt = savedAt
        self.records = records
    }
}
