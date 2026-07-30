# mac-ip-registry — build and install
#
# Two notes on why this is not just `swift build`:
#
#  * `swift build --arch arm64 --arch x86_64` needs xcbuild, which ships with full Xcode
#    only. Building each slice against its own triple and lipo-ing them works with
#    Command Line Tools alone, and produces the same universal binary.
#  * With Command Line Tools, swift-testing lives outside the default search path, so
#    `make test` adds it. With full Xcode the flags stay empty.

PREFIX        ?= /usr/local
DEPLOY_TARGET  = 13.0
DIST_BIN       = dist/bin
ARM_DIR        = .build/arm64-apple-macosx/release
X86_DIR        = .build/x86_64-apple-macosx/release

# Extra flags for every swift invocation. Some sandboxed CI environments need
# SWIFT_FLAGS=--disable-sandbox, because SwiftPM sandboxes manifest evaluation itself
# and nested sandboxes are refused.
SWIFT_FLAGS   ?=

# Cross-compilation for the VPS. The static Linux SDK version must match the local
# toolchain exactly, so this is derived from `swift --version` rather than hardcoded.
SWIFT_VERSION := $(shell swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p')
LINUX_SDK     ?= x86_64-swift-linux-musl
STATIC_SDK_URL ?= https://download.swift.org/swift-$(SWIFT_VERSION)-release/static-sdk/swift-$(SWIFT_VERSION)-RELEASE/swift-$(SWIFT_VERSION)-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz

DEVELOPER_DIR      := $(shell xcode-select -p 2>/dev/null)
TESTING_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TESTING_LIBS       := $(DEVELOPER_DIR)/Library/Developer/usr/lib

ifneq ($(wildcard $(TESTING_FRAMEWORKS)/Testing.framework),)
TEST_FLAGS = -Xswiftc -F -Xswiftc $(TESTING_FRAMEWORKS) \
             -Xlinker -F -Xlinker $(TESTING_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(TESTING_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(TESTING_LIBS)
endif

.PHONY: all help build release release-native test clean token \
        install-collector install-reporter uninstall-collector uninstall-reporter \
        package-reporter sdk-install linux package-collector

all: build

help:
	@echo "make build             debug build"
	@echo "make release           universal binaries in $(DIST_BIN) (arm64 + x86_64)"
	@echo "make release-native    release build for this Mac's architecture only"
	@echo "make test              run the test suite"
	@echo "make token             print a fresh shared secret"
	@echo "make package-reporter  tarball to copy to fleet machines"
	@echo ""
	@echo "Linux collector (for the VPS):"
	@echo "  make sdk-install         one-time: install the static Linux SDK"
	@echo "  make linux               cross-compile a static ipcollector for x86_64 Linux"
	@echo "  make package-collector   tarball to scp to the VPS"
	@echo ""
	@echo "sudo make install-collector"
	@echo "sudo make install-reporter COLLECTOR=http://host:8710 TOKEN=secret"
	@echo "sudo make uninstall-collector | uninstall-reporter"

build:
	swift build $(SWIFT_FLAGS)

release:
	swift build $(SWIFT_FLAGS) -c release --triple arm64-apple-macosx$(DEPLOY_TARGET)
	swift build $(SWIFT_FLAGS) -c release --triple x86_64-apple-macosx$(DEPLOY_TARGET)
	@mkdir -p $(DIST_BIN)
	lipo -create -output $(DIST_BIN)/ipcollector $(ARM_DIR)/ipcollector $(X86_DIR)/ipcollector
	lipo -create -output $(DIST_BIN)/ipreporter  $(ARM_DIR)/ipreporter  $(X86_DIR)/ipreporter
	@lipo -info $(DIST_BIN)/ipcollector $(DIST_BIN)/ipreporter

release-native:
	swift build $(SWIFT_FLAGS) -c release
	@mkdir -p $(DIST_BIN)
	@cp .build/release/ipcollector .build/release/ipreporter $(DIST_BIN)/
	@echo "built $(DIST_BIN)/ipcollector and $(DIST_BIN)/ipreporter for this Mac only"

test:
	swift test $(SWIFT_FLAGS) $(TEST_FLAGS)

# ---------------------------------------------------------------- Linux collector

# One-time. The SDK must match the toolchain: a 6.3.3 toolchain needs the 6.3.3 SDK, or
# the cross-build fails with module-format errors.
sdk-install:
	@test -n "$(SWIFT_VERSION)" || { echo "could not determine the Swift version"; exit 1; }
	@echo "installing the static Linux SDK for Swift $(SWIFT_VERSION)"
	swift sdk install $(STATIC_SDK_URL)
	@swift sdk list

linux:
	@swift sdk list 2>/dev/null | grep -q "$(LINUX_SDK)" \
	    || { echo "static Linux SDK not installed — run 'make sdk-install' first"; exit 1; }
	swift build $(SWIFT_FLAGS) -c release --swift-sdk $(LINUX_SDK) --product ipcollector
	@mkdir -p $(DIST_BIN)
	@cp .build/$(LINUX_SDK)/release/ipcollector $(DIST_BIN)/ipcollector-linux-x86_64
	@file $(DIST_BIN)/ipcollector-linux-x86_64
	@echo "static: no Swift runtime needed on the VPS"

# Everything the VPS needs, in one tarball.
package-collector: linux
	@rm -rf dist/ipcollector
	@mkdir -p dist/ipcollector
	@cp $(DIST_BIN)/ipcollector-linux-x86_64 dist/ipcollector/ipcollector
	@chmod 755 dist/ipcollector/ipcollector
	@cp deploy/linux/bootstrap-collector.sh dist/ipcollector/
	@cp deploy/linux/ipcollector.service deploy/linux/Caddyfile.template dist/ipcollector/
	@tar -czf dist/ipcollector.tar.gz -C dist ipcollector
	@rm -rf dist/ipcollector
	@echo ""
	@echo "built dist/ipcollector.tar.gz"
	@echo "  scp dist/ipcollector.tar.gz root@107.172.208.144:"
	@echo "  ssh root@107.172.208.144 'tar xzf ipcollector.tar.gz && \\"
	@echo "      ./ipcollector/bootstrap-collector.sh --hostname ipreg.calhobs.com'"

clean:
	swift package clean $(SWIFT_FLAGS)
	rm -rf .build dist

token:
	@head -c 32 /dev/urandom | xxd -p -c 32

install-collector: release
	@deploy/install-collector.sh

install-reporter: release
	@test -n "$(COLLECTOR)" || { echo "usage: sudo make install-reporter COLLECTOR=http://host:8710 TOKEN=secret"; exit 2; }
	@deploy/install-reporter.sh --collector "$(COLLECTOR)" --token "$(TOKEN)"

uninstall-collector:
	@deploy/uninstall.sh collector

uninstall-reporter:
	@deploy/uninstall.sh reporter

# A self-contained tarball: universal binary, installer, plist, log rotation.
package-reporter: release
	@rm -rf dist/ipreporter
	@mkdir -p dist/ipreporter
	@cp $(DIST_BIN)/ipreporter dist/ipreporter/
	@cp deploy/install-reporter.sh deploy/uninstall.sh dist/ipreporter/
	@cp deploy/com.ipreport.reporter.plist deploy/ipreport.newsyslog.conf dist/ipreporter/
	@tar -czf dist/ipreporter.tar.gz -C dist ipreporter
	@rm -rf dist/ipreporter
	@echo "built dist/ipreporter.tar.gz"
	@echo "on each machine:"
	@echo "  tar xzf ipreporter.tar.gz"
	@echo "  sudo ipreporter/install-reporter.sh --collector http://host:8710 --token SECRET"
