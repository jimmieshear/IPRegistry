#!/usr/bin/env bash
# Stand up the collector on an Ubuntu VPS: Caddy for TLS, systemd for the daemon.
#
# Idempotent — safe to re-run to change the hostname, rotate the password, or upgrade
# the binary.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
HOSTNAME_ARG=""
ADMIN_USER="admin"
ADMIN_PASSWORD=""
PORT=8710
TITLE="Mac IP Registry"
TOKEN=""
ENABLE_FIREWALL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: sudo $0 --hostname ipreg.example.com [options]

Required:
  --hostname <fqdn>       Public name with an A record pointing at this machine.
                          Let's Encrypt will not issue for a bare IP.

Options:
  --admin-user <name>     Dashboard login (default: admin)
  --admin-password <pw>   Dashboard password (default: generated and printed)
  --token <secret>        Reporter shared secret (default: generated and printed)
  --port <n>              Loopback port for the collector (default: 8710)
  --title <text>          Dashboard heading
  --enable-firewall       Also run 'ufw enable'. Off by default: enabling a firewall
                          on a remote box is how people lock themselves out.
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)       HOSTNAME_ARG="$2"; shift 2 ;;
        --admin-user)     ADMIN_USER="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --token)          TOKEN="$2"; shift 2 ;;
        --port)           PORT="$2"; shift 2 ;;
        --title)          TITLE="$2"; shift 2 ;;
        --enable-firewall) ENABLE_FIREWALL=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }
[[ -n "$HOSTNAME_ARG" ]] || { echo "--hostname is required" >&2; usage >&2; exit 2; }

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }

BINARY=""
for candidate in "$SCRIPT_DIR/ipcollector" "$SCRIPT_DIR/ipcollector-linux-x86_64"; do
    [[ -x "$candidate" ]] && { BINARY="$candidate"; break; }
done
[[ -n "$BINARY" ]] || {
    echo "no ipcollector binary next to this script." >&2
    echo "build one on your Mac with 'make linux' and copy the tarball over." >&2
    exit 1
}

# ---------------------------------------------------------------- DNS sanity check

say "checking DNS for $HOSTNAME_ARG"
RESOLVED="$(getent hosts "$HOSTNAME_ARG" | awk '{print $1}' | head -1 || true)"
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$RESOLVED" ]]; then
    warn "$HOSTNAME_ARG does not resolve yet. Caddy's certificate request will fail"
    warn "until the A record exists and has propagated. Continuing anyway."
elif [[ -n "$PUBLIC_IP" && "$RESOLVED" != "$PUBLIC_IP" ]]; then
    warn "$HOSTNAME_ARG resolves to $RESOLVED but this host appears to be $PUBLIC_IP."
    warn "The certificate request will fail until that A record is corrected."
else
    echo "$HOSTNAME_ARG -> $RESOLVED"
fi

# ---------------------------------------------------------------- Caddy

if ! command -v caddy >/dev/null 2>&1; then
    say "installing Caddy from the official repository"
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq caddy
else
    echo "Caddy already installed: $(caddy version | head -1)"
fi

# ---------------------------------------------------------------- collector

say "installing the collector"
if ! id -u ipreport >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin ipreport
    echo "created system user 'ipreport'"
fi

install -d -m 755 "$PREFIX/libexec"
install -m 755 -o root -g root "$BINARY" "$PREFIX/libexec/ipcollector"

install -d -m 750 -o root -g ipreport /etc/ipreport
install -d -m 750 -o ipreport -g ipreport /var/lib/ipreport

GENERATED_TOKEN=0
if [[ -n "$TOKEN" ]]; then
    printf '%s\n' "$TOKEN" > /etc/ipreport/token
elif [[ ! -s /etc/ipreport/token ]]; then
    head -c 32 /dev/urandom | xxd -p -c 32 > /etc/ipreport/token
    GENERATED_TOKEN=1
fi
chown root:ipreport /etc/ipreport/token
chmod 640 /etc/ipreport/token

say "installing the systemd unit"
sed -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@TITLE@|$TITLE|g" \
    "$SCRIPT_DIR/ipcollector.service" > /etc/systemd/system/ipcollector.service
chmod 644 /etc/systemd/system/ipcollector.service

systemctl daemon-reload
systemctl enable --now ipcollector
sleep 1
systemctl is-active --quiet ipcollector || {
    echo "the collector did not start. Recent log:" >&2
    journalctl -u ipcollector -n 30 --no-pager >&2
    exit 1
}
echo "collector active on 127.0.0.1:$PORT"

# ---------------------------------------------------------------- Caddy config

say "configuring Caddy for $HOSTNAME_ARG"
GENERATED_PASSWORD=0
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    GENERATED_PASSWORD=1
fi
PASSWORD_HASH="$(caddy hash-password --plaintext "$ADMIN_PASSWORD")"

install -d -m 755 /var/log/caddy
chown caddy:caddy /var/log/caddy 2>/dev/null || true

[[ -f /etc/caddy/Caddyfile && ! -f /etc/caddy/Caddyfile.orig ]] && \
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig

# The password hash contains $ and / — write it with awk rather than sed to avoid
# escaping games.
export HOSTNAME_ARG ADMIN_USER PASSWORD_HASH PORT
awk '{
    gsub(/@HOSTNAME@/, ENVIRON["HOSTNAME_ARG"]);
    gsub(/@USERNAME@/, ENVIRON["ADMIN_USER"]);
    gsub(/@PASSWORD_HASH@/, ENVIRON["PASSWORD_HASH"]);
    gsub(/@PORT@/, ENVIRON["PORT"]);
    print
}' "$SCRIPT_DIR/Caddyfile.template" > /etc/caddy/Caddyfile

caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || {
    echo "the generated Caddyfile is invalid; leaving the previous config in place" >&2
    exit 1
}
systemctl reload caddy 2>/dev/null || systemctl restart caddy
systemctl enable caddy >/dev/null 2>&1 || true

# ---------------------------------------------------------------- firewall

if command -v ufw >/dev/null 2>&1; then
    say "firewall rules"
    # SSH first, always — before anything that could enable the firewall.
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    echo "allowed OpenSSH, 80/tcp, 443/tcp"
    echo "port $PORT is NOT opened, and must not be: the collector is loopback-only"
    if [[ $ENABLE_FIREWALL -eq 1 ]]; then
        ufw --force enable
        ufw status verbose
    elif ! ufw status | grep -q "Status: active"; then
        echo "ufw is inactive. Rules are staged; enable it when you are ready with:"
        echo "    sudo ufw enable"
    fi
fi

# ---------------------------------------------------------------- verify

say "verifying"
if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/healthz" >/dev/null; then
    echo "collector responds on loopback"
else
    warn "collector did not answer on 127.0.0.1:$PORT"
fi

echo "waiting up to 60s for the certificate"
for _ in $(seq 1 30); do
    if curl -fsS --max-time 5 "https://$HOSTNAME_ARG/healthz" -u "$ADMIN_USER:$ADMIN_PASSWORD" >/dev/null 2>&1; then
        echo "HTTPS is live with a valid certificate"
        break
    fi
    sleep 2
done

cat <<EOF

──────────────────────────────────────────────────────────────
Dashboard   https://$HOSTNAME_ARG/
Login       $ADMIN_USER${GENERATED_PASSWORD:+ / $ADMIN_PASSWORD}
Reporters   --collector https://$HOSTNAME_ARG
EOF

if [[ $GENERATED_TOKEN -eq 1 ]]; then
    echo "Token       $(cat /etc/ipreport/token)"
else
    echo "Token       (unchanged; read it with: sudo cat /etc/ipreport/token)"
fi

cat <<EOF
──────────────────────────────────────────────────────────────

Logs:   journalctl -u ipcollector -f
        journalctl -u caddy -f
State:  /var/lib/ipreport/state.json

Next, on each Mac:
  sudo ipreporter/install-reporter.sh \\
      --collector https://$HOSTNAME_ARG \\
      --token \$(the token above)
EOF

if [[ $GENERATED_PASSWORD -eq 1 ]]; then
    echo
    warn "the dashboard password above is shown once — save it now"
fi
