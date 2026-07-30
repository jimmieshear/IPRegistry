# mac-ip-registry

A live registry of the current IP addresses of a fleet of Macs, for when machines reboot
or cycle DNS and you need to know where they went.

Two Swift binaries, no external dependencies, nothing leaves your network:

- **`ipreporter`** — a LaunchDaemon on each machine. Pushes its addresses on boot, on
  every link change, and on a heartbeat.
- **`ipcollector`** — a LaunchDaemon on one always-on Mac. Keeps the current state and
  serves a dashboard you can open in a browser.

```
GET  /                  HTML dashboard, auto-refreshing
GET  /json              full snapshot for scripting
GET  /ip/<hostname>     bare address, one line, for shell scripts
GET  /healthz           liveness probe
POST /report            reporter endpoint (bearer token)
DELETE /host/<hostname> retire a decommissioned machine (bearer token)
```

## Why a LaunchDaemon and not a LaunchAgent

The case this tool exists for is *the machine just rebooted and I don't know its address*.
At that moment nobody is logged in. iCloud Drive, `NSUbiquitousKeyValueStore`, CloudKit's
private database, and anything else in a user's Aqua session are all unavailable until
someone signs in — and with FileVault on, the machine sits at the unlock screen
indefinitely. A LaunchDaemon runs at boot regardless, which is why the reporter is one.

It also means no TCC prompts and no MDM PPPC profile: the reporter reads `sysctl`, the
IORegistry, and `getifaddrs`, none of which are privacy-protected.

## Build

Requires Swift 6 (Xcode 16+ or Command Line Tools).

```sh
make build      # debug
make release    # universal binary, arm64 + x86_64
make test       # 49 tests
```

`make release` produces a universal binary so one build covers Apple silicon and Intel
machines in the same fleet. It builds each slice against its own triple and `lipo`s them,
because `swift build --arch arm64 --arch x86_64` needs xcbuild from full Xcode.

In a sandboxed CI environment where SwiftPM cannot sandbox its own manifest evaluation,
pass `SWIFT_FLAGS=--disable-sandbox`.

## Install the collector

Pick a Mac that is always on and has a stable address — the reporters need to reach it by
a name or IP that does not itself change.

```sh
sudo make install-collector
# or, with options:
sudo deploy/install-collector.sh --port 8710 --title "Lab Macs"
```

It generates a shared secret at `/usr/local/etc/ipreport/token` and prints it. Keep that;
every reporter needs it.

```sh
sudo cat /usr/local/etc/ipreport/token   # print it again later
```

## Install a reporter

```sh
sudo make install-reporter COLLECTOR=http://collector.example.com:8710 TOKEN=<secret>
```

The installer sends one test report before loading the daemon, so a wrong URL or secret
fails immediately instead of silently at 3am.

For a fleet, build a tarball once and copy it around:

```sh
make package-reporter
scp dist/ipreporter.tar.gz somemac:
ssh somemac 'tar xzf ipreporter.tar.gz && sudo ipreporter/install-reporter.sh \
    --collector http://collector.example.com:8710 --token <secret>'
```

## Using it

Open `http://collector:8710/` for the table. For scripts:

```sh
ssh "admin@$(curl -s http://collector:8710/ip/buildbox-07)"

# refuse to hand back an address we cannot vouch for
curl -sf 'http://collector:8710/ip/buildbox-07?strict=1' || echo "buildbox-07 is not reporting"

# everything, as JSON
curl -s http://collector:8710/json | jq -r '.hosts[] | "\(.hostname)\t\(.primaryAddress)"'
```

A useful shell function:

```sh
macip() { curl -sf "http://collector.example.com:8710/ip/$1?strict=1"; }
ssh "admin@$(macip buildbox-07)"
```

## What each machine reports

```json
{
  "machineID": "8820F0AC-…",          // IOPlatformUUID — survives renames and reimaging
  "hostname": "buildbox-07.corp.example.com",
  "localHostname": "buildbox-07.local",
  "serialNumber": "C02XY1234567",
  "model": "Mac15,3",
  "osVersion": "26.4.2",
  "primaryAddress": "10.0.4.22",       // chosen by the routing table, not guessed
  "primaryInterface": "en0",
  "addresses": [ … ],                  // every usable address, all interfaces
  "bootTime": "2026-07-25T13:41:34Z",
  "reportedAt": "2026-07-30T00:33:41Z"
}
```

Two details worth knowing:

**`primaryAddress` comes from the routing table.** The reporter connects a UDP socket
toward the collector — which performs a route lookup without putting a packet on the wire
— then reads back the bound local address. On a multihomed Mac or one with a split-tunnel
VPN, that is the address that actually reaches you; picking the first entry from
`getifaddrs` is a coin flip. If the lookup returns loopback (which it does when the
reporter runs on the collector's own Mac) it falls back to the interface scan.

**The collector also records the peer address it saw.** When that differs from what the
machine reported, the dashboard flags the row `NAT` — there is address translation or a
VPN between you and that machine, so the reported address will not work from where you
are sitting.

## Records are keyed by hardware, not hostname

The primary key is `IOPlatformUUID`, so renaming a machine updates its row instead of
creating a second one. Lookups accept the short hostname, the FQDN, the `.local` name, the
serial number, or the UUID.

## Staleness

Heartbeats are how the dashboard tells "alive" from "gone". A machine silent for longer
than `--stale-after` (default 180s, i.e. three missed heartbeats) is dimmed and marked
stale; `/ip/<host>` still answers but sets `X-Host-Stale: true`, and `?strict=1` makes it
a 404 instead. After `--forget-after` (default 30 days) the record is dropped entirely,
because a month-old address is worse than no address.

The store distinguishes *last report* from *last change*, so a machine that has been up
for three months shows a recent heartbeat and an IP that changed 92 days ago.

## Security

Plain HTTP with a bearer token on the write path, which is what an internal network
warrants. Worth understanding what that does and does not buy:

- The token stops anyone on the LAN from poisoning the table with false entries. It is
  compared in constant time.
- Reads are open by default, so you can just open the page. `--require-auth-reads` puts
  the dashboard, `/json` and `/ip/` behind the same token.
- Nothing is encrypted. Anyone who can sniff your network can see which machines are at
  which addresses — an inventory of the network they are already on. If that matters,
  terminate TLS in front of the collector rather than teaching it certificate handling.
- The secret lives in a `0600` root-owned file, never in the plist or the JSON config,
  because LaunchDaemon plists are world-readable.

## Operating it

```sh
tail -f /usr/local/var/log/ipcollector.log
tail -f /usr/local/var/log/ipreporter.log

sudo launchctl kickstart -k system/com.ipreport.reporter   # force a restart
/usr/local/libexec/ipreporter --dry-run --collector http://collector:8710   # what would I send?
/usr/local/libexec/ipreporter --config /usr/local/etc/ipreport/reporter.json --once
```

Both binaries take `--help`. Logs rotate via `/etc/newsyslog.d/ipreport.conf`.

State is a single JSON file (`/usr/local/var/ipreport/state.json`), written atomically and
flushed on `SIGTERM`, so a collector restart does not blank the dashboard.

```sh
sudo deploy/uninstall.sh reporter            # remove the daemon and binary
sudo deploy/uninstall.sh collector --purge   # also discard state and logs
```

## Layout

```
Sources/IPReportCore/    models, wire format, minimal HTTP, sysctl/IOKit/getifaddrs
Sources/CollectorKit/    store, router, dashboard — everything that isn't a socket
Sources/ipcollector/     NWListener plumbing and argument parsing
Sources/ipreporter/      the client daemon
Tests/                   49 tests over the HTTP surface, store semantics and helpers
deploy/                  LaunchDaemon plists, installers, log rotation
```

The collector's routing, storage, and rendering live in `CollectorKit` rather than in the
executable, so the entire HTTP surface — every status code, the auth checks, HTML escaping
— is tested without binding a port.

## Limits

- IPv4 and IPv6 are both recorded, but `primaryAddress` prefers whatever the route lookup
  returns, and the fallback prefers IPv4.
- One collector, no replication. It is a cache of a fact you can always re-derive, so if
  it dies you lose visibility for one heartbeat interval, not data.
- `--forget-after` prunes on save, not on a timer, so an idle collector keeps expired rows
  until the next report arrives.
