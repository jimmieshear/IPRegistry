#!/bin/bash
# Install and start the reporter on this Mac.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
COLLECTOR=""
TOKEN=""
INTERVAL=60
LABEL="com.ipreport.reporter"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: sudo $0 --collector http://host:8710 --token SECRET [--interval 60] [--prefix /usr/local]

Installs ipreporter as a LaunchDaemon so it reports on boot, from the login window,
without waiting for anyone to sign in.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --collector) COLLECTOR="$2"; shift 2 ;;
        --token)     TOKEN="$2"; shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        --prefix)    PREFIX="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }
[[ -n "$COLLECTOR" ]] || { echo "--collector is required" >&2; usage >&2; exit 2; }

CONFIG_DIR="$PREFIX/etc/ipreport"

# Allow re-running without repeating the secret.
if [[ -z "$TOKEN" && -s "$CONFIG_DIR/token" ]]; then
    echo "reusing the existing secret at $CONFIG_DIR/token"
else
    [[ -n "$TOKEN" ]] || { echo "--token is required on first install" >&2; usage >&2; exit 2; }
fi

BINARY=""
for candidate in \
    "$SCRIPT_DIR/ipreporter" \
    "$SCRIPT_DIR/../dist/bin/ipreporter" \
    "$SCRIPT_DIR/../.build/release/ipreporter"
do
    if [[ -x "$candidate" ]]; then BINARY="$candidate"; break; fi
done
[[ -n "$BINARY" ]] || { echo "could not find an ipreporter binary — run 'make release' first" >&2; exit 1; }

install -d -m 755 "$PREFIX/libexec" "$PREFIX/var/log"
install -d -m 700 "$CONFIG_DIR"

echo "installing $BINARY -> $PREFIX/libexec/ipreporter"
install -m 755 -o root -g wheel "$BINARY" "$PREFIX/libexec/ipreporter"

if [[ -n "$TOKEN" ]]; then
    printf '%s\n' "$TOKEN" > "$CONFIG_DIR/token"
fi
chown root:wheel "$CONFIG_DIR/token"
chmod 600 "$CONFIG_DIR/token"

# The secret lives in its own 0600 file, never in the plist or the config, because
# LaunchDaemon plists are world-readable.
cat > "$CONFIG_DIR/reporter.json" <<EOF
{
  "collectorURL": "$COLLECTOR",
  "intervalSeconds": $INTERVAL,
  "tokenFile": "$CONFIG_DIR/token"
}
EOF
chown root:wheel "$CONFIG_DIR/reporter.json"
chmod 644 "$CONFIG_DIR/reporter.json"

echo "verifying the collector accepts a report"
if ! "$PREFIX/libexec/ipreporter" --config "$CONFIG_DIR/reporter.json" --once; then
    echo "the test report failed — fix the collector URL or secret, then re-run" >&2
    exit 1
fi

PLIST="/Library/LaunchDaemons/$LABEL.plist"
echo "writing $PLIST"
sed -e "s|@PREFIX@|$PREFIX|g" "$SCRIPT_DIR/com.ipreport.reporter.plist" > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

if [[ -f "$SCRIPT_DIR/ipreport.newsyslog.conf" ]]; then
    install -m 644 -o root -g wheel "$SCRIPT_DIR/ipreport.newsyslog.conf" /etc/newsyslog.d/ipreport.conf
fi

echo "loading daemon"
launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout returns before launchd has finished tearing the old instance down, and
# bootstrapping over it fails with "37: Operation already in progress". Wait it out.
for _ in {1..50}; do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
done
launchctl bootstrap system "$PLIST"

sleep 1
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "reporter running, heartbeat every ${INTERVAL}s"
    echo "logs: $PREFIX/var/log/ipreporter.log"
else
    echo "daemon did not come up — check $PREFIX/var/log/ipreporter.log" >&2
    exit 1
fi
