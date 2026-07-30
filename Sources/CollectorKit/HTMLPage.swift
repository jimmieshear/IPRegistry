import Foundation
import IPReportCore

public enum HTMLPage {
    public static func render(_ snapshot: Snapshot, title: String, refreshSeconds: Int) -> String {
        let rows = snapshot.hosts.map { row($0, now: snapshot.generatedAt) }.joined(separator: "\n")
        let body = snapshot.hosts.isEmpty ? emptyState : """
        <table>
          <thead>
            <tr>
              <th></th><th>Host</th><th>Address</th><th>Also on</th><th>Seen from</th>
              <th>macOS</th><th>Uptime</th><th>Last report</th><th>IP changed</th>
            </tr>
          </thead>
          <tbody>
        \(rows)
          </tbody>
        </table>
        """

        let timestamp = iso8601UTC(snapshot.generatedAt)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="\(refreshSeconds)">
        <title>\(htmlEscape(title))</title>
        <style>
        :root {
          color-scheme: light dark;
          --bg: #fbfbfd; --fg: #1c1c1e; --muted: #6e6e73; --line: #d8d8dd;
          --card: #ffffff; --ok: #1f9d55; --bad: #c8372d; --warn: #b06f00;
          --accent: #0b5ed7;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #16161a; --fg: #ececf1; --muted: #9a9aa2; --line: #2f2f36;
            --card: #1e1e24; --ok: #35c46b; --bad: #ff6b5e; --warn: #e0a33a;
            --accent: #6ea8fe;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; padding: 2rem 1.5rem; background: var(--bg); color: var(--fg);
          font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        }
        header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.75rem; margin-bottom: 1.25rem; }
        h1 { font-size: 1.35rem; font-weight: 600; margin: 0; letter-spacing: -0.01em; }
        .summary { color: var(--muted); font-size: 0.85rem; font-variant-numeric: tabular-nums; }
        .summary b { color: var(--fg); font-weight: 600; }
        .wrap { background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow: auto; }
        table { border-collapse: collapse; width: 100%; }
        th, td { text-align: left; padding: 0.55rem 0.85rem; border-bottom: 1px solid var(--line); white-space: nowrap; }
        th {
          font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.06em;
          color: var(--muted); font-weight: 600; background: var(--bg); position: sticky; top: 0;
        }
        tbody tr:last-child td { border-bottom: none; }
        tbody tr:hover { background: color-mix(in srgb, var(--accent) 7%, transparent); }
        td.mono, td.ip {
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
          font-size: 0.86rem; font-variant-numeric: tabular-nums;
        }
        td.ip a { color: var(--fg); text-decoration: none; border-bottom: 1px dotted var(--muted); }
        td.ip a:hover { color: var(--accent); border-bottom-color: var(--accent); }
        .host { font-weight: 600; }
        .sub { display: block; color: var(--muted); font-weight: 400; font-size: 0.76rem; }
        .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; }
        .dot.up { background: var(--ok); }
        .dot.down { background: var(--bad); }
        tr.stale td:not(.status) { opacity: 0.5; }
        .muted { color: var(--muted); }
        .flag {
          display: inline-block; margin-left: 0.35rem; padding: 0 0.3rem; border-radius: 4px;
          font-size: 0.66rem; font-weight: 600; color: var(--warn);
          border: 1px solid color-mix(in srgb, var(--warn) 45%, transparent);
        }
        footer { margin-top: 1rem; color: var(--muted); font-size: 0.78rem; }
        footer code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .empty { padding: 3rem 1rem; text-align: center; color: var(--muted); }
        </style>
        </head>
        <body>
        <header>
          <h1>\(htmlEscape(title))</h1>
          <span class="summary"><b>\(snapshot.current)</b> current · <b>\(snapshot.stale)</b> stale · \(snapshot.total) known</span>
        </header>
        <div class="wrap">
        \(body)
        </div>
        <footer>
          Generated \(htmlEscape(timestamp)) · refreshes every \(refreshSeconds)s ·
          machines silent for more than \(Int(snapshot.staleAfterSeconds))s are marked stale ·
          <code>/json</code> for the full record, <code>/ip/&lt;hostname&gt;</code> for a bare address
        </footer>
        </body>
        </html>
        """
    }

    private static let emptyState = """
    <div class="empty">
      No machines have reported yet.<br>
      Install <code>ipreporter</code> on a Mac and it will appear here within a minute.
    </div>
    """

    private static func row(_ host: HostView, now: Date) -> String {
        let secondary = host.addresses
            .filter { $0.address != host.primaryAddress }
            .map { "\($0.address) (\($0.interface))" }

        let addressCell: String
        if let primary = host.primaryAddress {
            addressCell = "<a href=\"ssh://\(htmlEscape(primary))\">\(htmlEscape(primary))</a>"
                + "<span class=\"sub\">\(htmlEscape(host.primaryInterface ?? "—"))</span>"
        } else {
            addressCell = "<span class=\"muted\">unknown</span>"
        }

        // With the collector on a VPS, every machine at a site arrives from the same
        // egress address, so a difference here is the normal case rather than a warning.
        // The reported private address remains the useful one.
        let seenFrom: String
        if let observed = host.observedAddress, !observed.isEmpty {
            seenFrom = host.addressMismatch
                ? htmlEscape(observed)
                : "<span class=\"muted\">direct</span>"
        } else {
            seenFrom = "<span class=\"muted\">—</span>"
        }

        let changed: String
        if let previous = host.previousPrimaryAddress {
            changed = "\(htmlEscape(host.lastChangedAt.relativeDescription(from: now)))<span class=\"sub\">was \(htmlEscape(previous))</span>"
        } else {
            changed = "<span class=\"muted\">never</span>"
        }

        let localName = host.localHostname.flatMap { $0 == host.hostname ? nil : $0 }

        return """
          <tr class="\(host.stale ? "stale" : "")">
            <td class="status"><span class="dot \(host.stale ? "down" : "up")" title="\(host.stale ? "stale" : "current")"></span></td>
            <td class="host">\(htmlEscape(host.hostname))\(localName.map { "<span class=\"sub\">\(htmlEscape($0))</span>" } ?? "")</td>
            <td class="ip">\(addressCell)</td>
            <td class="mono muted">\(secondary.isEmpty ? "—" : htmlEscape(secondary.joined(separator: ", ")))</td>
            <td class="mono muted">\(seenFrom)</td>
            <td class="mono muted">\(htmlEscape(host.osVersion ?? "—"))<span class="sub">\(htmlEscape(host.model ?? ""))</span></td>
            <td class="mono muted">\(host.uptimeSeconds.map { htmlEscape(formatDuration($0)) } ?? "—")</td>
            <td class="mono">\(htmlEscape(host.lastReportAt.relativeDescription(from: now)))</td>
            <td class="mono muted">\(changed)</td>
          </tr>
        """
    }
}
