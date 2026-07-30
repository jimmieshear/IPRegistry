#!/bin/bash
# Stop and remove a daemon: uninstall.sh collector|reporter [--purge]
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
PURGE=0
ROLE="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)  PURGE=1; shift ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ROLE" in
    collector) LABEL="com.ipreport.collector"; BINARY="ipcollector" ;;
    reporter)  LABEL="com.ipreport.reporter";  BINARY="ipreporter" ;;
    *) echo "usage: sudo $0 collector|reporter [--purge]" >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }

echo "stopping $LABEL"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f "$PREFIX/libexec/$BINARY"

if [[ $PURGE -eq 1 ]]; then
    # Deliberately opt-in: --purge discards the shared secret and, for the collector,
    # the registry of every machine it has ever seen.
    echo "purging configuration, logs and state"
    rm -f "$PREFIX/var/log/$BINARY.log"
    if [[ "$ROLE" == "collector" ]]; then
        rm -rf "$PREFIX/var/ipreport"
    else
        rm -f "$PREFIX/etc/ipreport/reporter.json"
    fi
    echo "note: $PREFIX/etc/ipreport/token was left in place; remove it by hand if nothing else uses it"
fi

echo "$ROLE removed"
