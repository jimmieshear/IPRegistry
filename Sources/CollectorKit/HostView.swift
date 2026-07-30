import Foundation
import IPReportCore

/// Read model for the dashboard and the JSON endpoint. Derived values (staleness, uptime,
/// NAT mismatch) are computed here so both renderers agree.
public struct HostView: Codable, Sendable {
    public var hostname: String
    public var localHostname: String?
    public var machineID: String
    public var serialNumber: String?
    public var model: String?
    public var osVersion: String?
    public var primaryAddress: String?
    public var primaryInterface: String?
    public var observedAddress: String?
    /// True when the collector saw a different source address than the machine reported —
    /// the signature of NAT or a split-tunnel VPN between you and the machine.
    public var addressMismatch: Bool
    public var addresses: [InterfaceAddress]
    public var bootTime: Date?
    public var uptimeSeconds: Double?
    public var firstSeen: Date
    public var lastReportAt: Date
    public var lastChangedAt: Date
    public var previousPrimaryAddress: String?
    public var secondsSinceReport: Double
    public var stale: Bool
    public var reportCount: Int
    public var agentVersion: String

    public init(record: HostRecord, now: Date, staleAfter: TimeInterval) {
        let report = record.report
        hostname = report.hostname
        localHostname = report.localHostname
        machineID = report.machineID
        serialNumber = report.serialNumber
        model = report.model
        osVersion = report.osVersion
        primaryAddress = report.primaryAddress
        primaryInterface = report.primaryInterface
        observedAddress = record.observedAddress
        addressMismatch = {
            guard let observed = record.observedAddress, let primary = report.primaryAddress else { return false }
            return observed != primary
        }()
        addresses = report.addresses
        bootTime = report.bootTime
        uptimeSeconds = report.bootTime.map { now.timeIntervalSince($0) }
        firstSeen = record.firstSeen
        lastReportAt = record.lastReportAt
        lastChangedAt = record.lastChangedAt
        previousPrimaryAddress = record.previousPrimaryAddress
        secondsSinceReport = now.timeIntervalSince(record.lastReportAt)
        stale = now.timeIntervalSince(record.lastReportAt) > staleAfter
        reportCount = record.reportCount
        agentVersion = report.agentVersion
    }
}

public struct Snapshot: Codable, Sendable {
    public var generatedAt: Date
    public var staleAfterSeconds: Double
    public var total: Int
    public var current: Int
    public var stale: Int
    public var hosts: [HostView]

    public init(records: [HostRecord], now: Date, staleAfter: TimeInterval) {
        let views = records.map { HostView(record: $0, now: now, staleAfter: staleAfter) }
        generatedAt = now
        staleAfterSeconds = staleAfter
        total = views.count
        stale = views.filter(\.stale).count
        current = views.count - stale
        hosts = views
    }
}
