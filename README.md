# mac-ip-registry

A live registry of the current IP addresses of a fleet of Macs, for when machines reboot
or cycle DNS and you need to know where they went.

Two Swift binaries, no external package dependencies:

- **`ipreporter`** — a LaunchDaemon on each Mac. Pushes its addresses on boot, on every
  link change, and on a heartbeat. macOS only.
- **`ipcollector`** — keeps the current state and serves a dashboard. Runs on macOS under
  launchd, or on Linux under systemd — the transport is POSIX sockets, so the same source
  cross-compiles to a static Linux binary for a VPS.

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
make release    # universal macOS binary, arm64 + x86_64
make test       # 54 tests
make linux      # static x86_64 Linux ipcollector (needs 'make sdk-install' once)
```

`make release` produces a universal binary so one build covers Apple silicon and Intel
machines in the same fleet. It builds each slice against its own triple and `lipo`s them,
because `swift build --arch arm64 --arch x86_64` needs xcbuild from full Xcode.

In a sandboxed CI environment where SwiftPM cannot sandbox its own manifest evaluation,
pass `SWIFT_FLAGS=--disable-sandbox`.

## Install the collector on a Mac

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

## Install the collector on a Linux VPS

Use this when the machines are behind NAT with no inbound path — they can reach a VPS even
though you cannot reach them. The collector sits behind Caddy, which terminates TLS.

```
Mac (private 10.x)  ──HTTPS POST /report──▶  VPS :443  Caddy ──▶ 127.0.0.1:8710 ipcollector
```

`ipcollector` binds **loopback only**, so it is not reachable from the internet at all;
Caddy is the only thing that can talk to it. Port 8710 needs no firewall rule and must not
get one.

**On your Mac** — ship the source; the VPS builds it:

```sh
make package-source
scp dist/mac-ip-registry-src.tar.gz root@your.vps:
```

**On the VPS** — one A record must already point at it, because Let's Encrypt validates
over HTTP and will not issue for a bare IP:

```sh
tar xzf mac-ip-registry-src.tar.gz
sudo mac-ip-registry/deploy/linux/build-on-vps.sh
sudo mac-ip-registry/deploy/linux/bootstrap-collector.sh --hostname ipreg.example.com
```

`build-on-vps.sh` installs Swift via swiftly, builds `ipcollector` with
`--static-swift-stdlib`, and tells you how to remove the ~2GB toolchain afterwards, since
the finished binary does not need it. On a small VPS it adds a 3GB swapfile first —
`swift-frontend` wants more than 1GB of RAM, and swap is the cheap fix when you have disk
to spare. It compiles at `-j1` by default for the same reason.

### Cross-compiling instead

There is a `make sdk-install` / `make linux` / `make package-collector` path that produces
a static Linux binary on your Mac. It is only worth it if you already run a **swift.org**
toolchain: the Static Linux SDK is published against those, and using it from Xcode's Swift
generally fails a toolchain version check. `make sdk-probe` will tell you whether a usable
SDK URL exists for your version. Building on the VPS avoids the whole question.

That installs Caddy from its official repo, creates an `ipreport` system user, installs a
hardened systemd unit, generates the shared secret and a dashboard password, writes and
validates the Caddyfile, and stages ufw rules. It is idempotent — re-run it to change the
hostname, rotate the password, or drop in a new binary.

Two deliberate choices in that script: it **stages ufw rules without enabling ufw** (and
allows SSH first), because enabling a firewall on a remote box is how people lock
themselves out; and it **checks DNS before touching Caddy**, warning you rather than
letting the certificate request fail confusingly.

Then point the reporters at it:

```sh
sudo make install-reporter COLLECTOR=https://ipreg.example.com TOKEN=<secret>
```

The reporter needs no code change for TLS — `URLSession` uses the system trust store.

### How auth splits behind the proxy

- `POST /report` passes straight through Caddy and is protected by the **bearer token**.
- Everything else — dashboard, `/json`, `/ip/` — sits behind Caddy **basic auth**, so a
  browser gives you a normal password prompt instead of requiring a header.

The collector runs with `--trust-forwarded-for`, so the client address comes from
`X-Forwarded-For` rather than the socket peer, which would otherwise be `127.0.0.1` for
every machine. That header is trivially forged by anyone who can reach the collector
directly, which is exactly why the flag is opt-in and why the collector binds loopback.

```sh
journalctl -u ipcollector -f
journalctl -u caddy -f
systemctl restart ipcollector
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

**The collector also records the address it saw the report arrive from.** Behind a reverse
proxy that comes from `X-Forwarded-For`; otherwise it is the socket peer. When it differs
from the reported address, the dashboard shows it in the "Seen from" column — with the
collector on a VPS, every machine at a site shares one egress IP, so a difference is the
normal case rather than a warning. The reported private address stays the useful one.

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

The write path is a bearer token, compared in constant time; it stops anyone who can reach
the collector from poisoning the table with false entries. What else you need depends
entirely on where the collector sits.

**On an internal LAN**, plain HTTP with that token is a reasonable trade. Reads are open by
default so you can just open the page; `--require-auth-reads` puts the dashboard, `/json`
and `/ip/` behind the same token. Nothing is encrypted, so anyone sniffing the network can
see which machines are at which addresses — an inventory of a network they are already on.

**On a public VPS, plain HTTP is not acceptable** and the bootstrap script does not offer
it. Without TLS the token crosses the open internet in cleartext on every heartbeat, and
one captured request grants indefinite write access; the dashboard would also be a
world-readable map of your internal network. Hence Caddy, TLS, basic auth on the dashboard,
and a collector bound to loopback.

In both cases the secret lives in a `0600`/`0640` root-owned file, never in the plist,
the systemd unit, or the JSON config — LaunchDaemon plists and systemd units are
world-readable.

Worth being explicit about what this still does not do: there is no per-machine identity,
so any holder of the shared token can write a record for any hostname. Rotating the secret
means touching every machine. For a fleet where that matters, put a client certificate on
each Mac and let Caddy verify it.

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
Sources/IPReportCore/    models, wire format, minimal HTTP, portable libc helpers
Sources/CollectorKit/    store, router, dashboard, POSIX socket server
Sources/ipcollector/     argument parsing and startup (macOS + Linux)
Sources/ipreporter/      the client daemon, plus the IOKit/sysctl lookups (macOS only)
Tests/                   54 tests over the HTTP surface, store semantics and helpers
deploy/                  LaunchDaemon plists, macOS installers, log rotation
deploy/linux/            systemd unit, Caddyfile template, VPS bootstrap
```

The collector's routing, storage, and rendering live in `CollectorKit` rather than in the
executable, so the entire HTTP surface — every status code, the auth checks, HTML escaping,
the `X-Forwarded-For` handling — is tested without binding a port. That split is also what
made the Linux port cheap: only the transport changed.

Two portability notes, both deliberate: timestamps go through `gmtime_r`/`strftime` rather
than `ISO8601DateFormatter`, and hostname sorting uses a plain lowercased comparison rather
than `localizedCaseInsensitiveCompare`, because both Foundation APIs depend on
internationalization support that the static Linux SDK does not reliably carry.

## Limits

- IPv4 and IPv6 are both recorded, but `primaryAddress` prefers whatever the route lookup
  returns, and the fallback prefers IPv4.
- One collector, no replication. It is a cache of a fact you can always re-derive, so if
  it dies you lose visibility for one heartbeat interval, not data.
- `--forget-after` prunes on save, not on a timer, so an idle collector keeps expired rows
  until the next report arrives.
