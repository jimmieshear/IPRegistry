import Foundation
import IPReportCore

/// Current-state registry: exactly one record per machine, keyed by hardware identity.
/// Persisted to a JSON file so a collector restart does not blank the dashboard.
public actor Store {
    private var records: [String: HostRecord] = [:]
    private let stateURL: URL
    private let forgetAfter: TimeInterval
    private var pendingSave: Task<Void, Never>?

    public init(stateURL: URL, forgetAfter: TimeInterval) {
        self.stateURL = stateURL
        self.forgetAfter = forgetAfter
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            Log.info("no existing state at \(stateURL.path), starting empty")
            return
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try Wire.decoder().decode(StateFile.self, from: data)
            records = Dictionary(
                state.records.map { ($0.report.machineID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            Log.info("loaded \(records.count) host record(s) from \(stateURL.path)")
        } catch {
            Log.error("could not read state at \(stateURL.path): \(error). Starting empty.")
        }
    }

    /// Upserts a report. Returns the stored record and whether the addressing actually
    /// changed, so heartbeats can be logged more quietly than real changes.
    @discardableResult
    public func record(
        _ report: HostReport,
        observedAddress: String?,
        at now: Date = Date()
    ) -> (record: HostRecord, changed: Bool) {
        let key = report.machineID

        guard var existing = records[key] else {
            let fresh = HostRecord(
                report: report,
                observedAddress: observedAddress,
                firstSeen: now,
                lastReportAt: now,
                lastChangedAt: now
            )
            records[key] = fresh
            scheduleSave()
            return (fresh, true)
        }

        let changed = existing.report.addressSignature != report.addressSignature
        let previousPrimary = existing.report.primaryAddress

        existing.report = report
        existing.observedAddress = observedAddress
        existing.lastReportAt = now
        existing.reportCount += 1
        if changed {
            existing.lastChangedAt = now
            existing.previousPrimaryAddress = previousPrimary
        }

        records[key] = existing
        scheduleSave()
        return (existing, changed)
    }

    public func snapshot() -> [HostRecord] {
        records.values.sorted {
            $0.report.hostname.localizedCaseInsensitiveCompare($1.report.hostname) == .orderedAscending
        }
    }

    public var count: Int { records.count }

    /// Resolves a machine by hostname, short hostname, `.local` name, serial, or machine ID.
    public func lookup(_ needle: String) -> HostRecord? {
        let target = needle.lowercased()
        return records.values.first { record in
            let report = record.report
            if report.machineID.lowercased() == target { return true }
            if report.hostname.lowercased() == target { return true }
            if report.localHostname?.lowercased() == target { return true }
            if report.serialNumber?.lowercased() == target { return true }
            let short = report.hostname.split(separator: ".").first.map { $0.lowercased() }
            return short == target
        }
    }

    @discardableResult
    public func forget(_ needle: String) -> HostRecord? {
        guard let record = lookup(needle) else { return nil }
        records.removeValue(forKey: record.report.machineID)
        scheduleSave()
        return record
    }

    public func flush(at now: Date = Date()) {
        pendingSave?.cancel()
        pendingSave = nil
        persist(now: now)
    }

    /// Coalesces bursts of reports into a single disk write.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.persist(now: Date())
        }
    }

    private func persist(now: Date) {
        // Drop machines we have not heard from in a very long time; they have been
        // decommissioned or reimaged, and a stale row is worse than no row.
        if forgetAfter > 0 {
            let cutoff = now.addingTimeInterval(-forgetAfter)
            for (key, value) in records where value.lastReportAt < cutoff {
                records.removeValue(forKey: key)
                Log.info("forgetting \(value.report.hostname): last report \(value.lastReportAt.relativeDescription(from: now))")
            }
        }

        let state = StateFile(savedAt: now, records: snapshot())
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Wire.encoder(pretty: true).encode(state)
            // .atomic writes to a temp file and renames, so a crash mid-write cannot
            // truncate the registry.
            try data.write(to: stateURL, options: .atomic)
        } catch {
            Log.error("could not persist state to \(stateURL.path): \(error)")
        }
    }
}
