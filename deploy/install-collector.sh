#!/bin/bash
# Install and start the collector on this Mac.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
PORT=8710
TITLE="Mac IP Registry"
BIND=""
LABEL="com.ipreport.collector"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: sudo $0 [--port 8710] [--bind 10.0.0.5] [--title "..."] [--prefix /usr/local]

Installs ipcollector as a LaunchDaemon, generating a shared secret if one does not
already exist. Print the secret afterwards with:
    sudo cat $PREFIX/etc/ipreport/token
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)   PORT="$2"; shift 2 ;;
        --bind)   BIND="$2"; shift 2 ;;
        --title)  TITLE="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }

# The binary is either next to this script (tarball) or in the build tree (repo).
BINARY=""
for candidate in \
    "$SCRIPT_DIR/ipcollector" \
    "$SCRIPT_DIR/../dist/bin/ipcollector" \
    "$SCRIPT_DIR/../.build/release/ipcollector"
do
    if [[ -x "$candidate" ]]; then BINARY="$candidate"; break; fi
done
[[ -n "$BINARY" ]] || { echo "could not find an ipcollector binary — run 'make release' first" >&2; exit 1; }

CONFIG_DIR="$PREFIX/etc/ipreport"
install -d -m 755 "$PREFIX/libexec" "$PREFIX/var/ipreport" "$PREFIX/var/log"
install -d -m 700 "$CONFIG_DIR"

echo "installing $BINARY -> $PREFIX/libexec/ipcollector"
install -m 755 -o root -g wheel "$BINARY" "$PREFIX/libexec/ipcollector"

GENERATED=0
if [[ ! -s "$CONFIG_DIR/token" ]]; then
    head -c 32 /dev/urandom | xxd -p -c 32 > "$CONFIG_DIR/token"
    GENERATED=1
fi
chown root:wheel "$CONFIG_DIR/token"
chmod 600 "$CONFIG_DIR/token"

PLIST="/Library/LaunchDaemons/$LABEL.plist"
echo "writing $PLIST"
sed -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@TITLE@|$TITLE|g" \
    "$SCRIPT_DIR/com.ipreport.collector.plist" > "$PLIST"

# --bind is optional, so it is appended rather than templated.
if [[ -n "$BIND" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string --bind" "$PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string $BIND" "$PLIST" >/dev/null
fi

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
    echo "collector running on port $PORT"
else
    echo "daemon did not come up — check $PREFIX/var/log/ipcollector.log" >&2
    exit 1
fi

cat <<EOF

Dashboard:  http://$(scutil --get LocalHostName 2>/dev/null || hostname):$PORT/
Logs:       $PREFIX/var/log/ipcollector.log
State:      $PREFIX/var/ipreport/state.json
EOF

if [[ $GENERATED -eq 1 ]]; then
    echo
    echo "Shared secret (reporters need this):"
    echo "  $(cat "$CONFIG_DIR/token")"
fi

cat <<EOF

If the macOS application firewall is on, allow incoming connections:
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add $PREFIX/libexec/ipcollector
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp $PREFIX/libexec/ipcollector
EOF
