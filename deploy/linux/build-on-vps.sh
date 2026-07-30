#!/usr/bin/env bash
# Build ipcollector on the VPS itself.
#
# Why here rather than cross-compiled on a Mac: the Static Linux SDK is published against
# swift.org toolchains, and Xcode's Swift is not one, so cross-compiling means installing a
# second toolchain plus a version-matched SDK. Building in place has no such coupling. The
# only obstacle is RAM, and swap solves that.
#
# Uses swiftly to install Swift, because swiftly's own download URL is stable and it
# resolves toolchain versions itself — no guessing at release URLs.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
SWAP_SIZE="3G"
SKIP_SWAP=0
KEEP_TOOLCHAIN=0
JOBS=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: sudo $0 [options]

Builds ipcollector from the source tree this script sits in, and leaves the binary
next to bootstrap-collector.sh ready to install.

Options:
  --swap-size <n>     Swapfile size if more is needed (default: 3G)
  --no-swap           Do not touch swap, even if memory looks too small
  --jobs <n>          Parallel compile jobs (default: 1 — more will OOM on 1GB)
  --keep-toolchain    Leave Swift installed afterwards (default: prints how to remove it)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --swap-size)     SWAP_SIZE="$2"; shift 2 ;;
        --no-swap)       SKIP_SWAP=1; shift ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --keep-toolchain) KEEP_TOOLCHAIN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)" >&2; exit 1; }

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }

# Find the package root: this script lives in deploy/linux/ of the source tree.
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[[ -f "$SOURCE_ROOT/Package.swift" ]] || {
    echo "could not find Package.swift above $SCRIPT_DIR" >&2
    echo "run this from inside the source tree (see 'make package-source')" >&2
    exit 1
}

# ---------------------------------------------------------------- swap

TOTAL_MB=$(( $(free -m | awk '/^Mem:/{print $2}') + $(free -m | awk '/^Swap:/{print $2}') ))
say "memory + swap: ${TOTAL_MB}MB"

if [[ $TOTAL_MB -lt 3000 && $SKIP_SWAP -eq 0 ]]; then
    if [[ -f /swapfile-ipreport ]]; then
        echo "/swapfile-ipreport already exists"
        swapon --show | grep -q /swapfile-ipreport || swapon /swapfile-ipreport
    else
        say "adding a ${SWAP_SIZE} swapfile — swift-frontend needs more than ${TOTAL_MB}MB"
        fallocate -l "$SWAP_SIZE" /swapfile-ipreport 2>/dev/null \
            || dd if=/dev/zero of=/swapfile-ipreport bs=1M count=3072 status=progress
        chmod 600 /swapfile-ipreport
        mkswap /swapfile-ipreport >/dev/null
        swapon /swapfile-ipreport
        grep -q '^/swapfile-ipreport' /etc/fstab \
            || echo '/swapfile-ipreport none swap sw 0 0' >> /etc/fstab
    fi
    free -h
elif [[ $TOTAL_MB -lt 3000 ]]; then
    warn "only ${TOTAL_MB}MB available and --no-swap was passed; the compile may be OOM-killed"
fi

# ---------------------------------------------------------------- Swift toolchain

if ! command -v swift >/dev/null 2>&1 && [[ ! -x "$HOME/.local/share/swiftly/bin/swift" ]]; then
    say "installing Swift build dependencies"
    apt-get update -qq
    apt-get install -y -qq \
        binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev \
        libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev \
        pkg-config tzdata unzip zlib1g-dev curl

    say "installing Swift via swiftly"
    ARCH="$(uname -m)"
    curl -fL -o /tmp/swiftly.tar.gz "https://download.swift.org/swiftly/linux/swiftly-${ARCH}.tar.gz"
    tar -xzf /tmp/swiftly.tar.gz -C /tmp
    # swiftly installs per-user; running as root puts it under /root.
    /tmp/swiftly init --quiet-shell-followup --assume-yes --skip-install
    # shellcheck disable=SC1090
    source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    swiftly install latest --use --assume-yes
else
    if [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
        # shellcheck disable=SC1090
        source "$HOME/.local/share/swiftly/env.sh"
    fi
fi

command -v swift >/dev/null 2>&1 || { echo "swift is still not on PATH" >&2; exit 1; }
say "using $(swift --version 2>&1 | head -1)"

# ---------------------------------------------------------------- build

say "building ipcollector (this takes a few minutes at -j$JOBS)"
cd "$SOURCE_ROOT"
# --static-swift-stdlib so the finished binary does not need the toolchain at runtime,
# which means Swift can be removed afterwards.
swift build -c release --product ipcollector --static-swift-stdlib -j "$JOBS"

BUILT="$(swift build -c release --product ipcollector --static-swift-stdlib --show-bin-path)/ipcollector"
[[ -x "$BUILT" ]] || { echo "build reported success but $BUILT is missing" >&2; exit 1; }

cp "$BUILT" "$SCRIPT_DIR/ipcollector"
chmod 755 "$SCRIPT_DIR/ipcollector"

say "built $SCRIPT_DIR/ipcollector"
file "$SCRIPT_DIR/ipcollector" || true
ls -lh "$SCRIPT_DIR/ipcollector"

cat <<EOF

Next:
  sudo $SCRIPT_DIR/bootstrap-collector.sh --hostname ipreg.calhobs.com
EOF

if [[ $KEEP_TOOLCHAIN -eq 0 ]]; then
    cat <<EOF

The binary is statically linked, so Swift is no longer needed. To reclaim ~2GB:
  swiftly uninstall all --assume-yes && rm -rf ~/.local/share/swiftly
  rm -rf $SOURCE_ROOT/.build
EOF
fi
