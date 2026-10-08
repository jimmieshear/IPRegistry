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
# Each slice gets its own scratch path. Since Swift 6.4 SwiftPM's default build system
# puts every release build in .build/out/Products/Release regardless of --triple, so a
# shared scratch path would let the second slice overwrite the first.
ARM_BUILD      = swift build $(SWIFT_FLAGS) -c release --triple arm64-apple-macosx$(DEPLOY_TARGET) --scratch-path .build/universal-arm64
X86_BUILD      = swift build $(SWIFT_FLAGS) -c release --triple x86_64-apple-macosx$(DEPLOY_TARGET) --scratch-path .build/universal-x86_64

# Extra flags for every swift invocation. Some sandboxed CI environments need
# SWIFT_FLAGS=--disable-sandbox, because SwiftPM sandboxes manifest evaluation itself
# and nested sandboxes are refused.
SWIFT_FLAGS   ?=

# Cross-compilation for the VPS. The static Linux SDK version must match the local
# toolchain exactly, so this is derived from `swift --version` rather than hardcoded.
SWIFT_VERSION := $(shell swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p')
LINUX_SDK     ?= x86_64-swift-linux-musl
STATIC_SDK_URL ?= https://download.swift.org/swift-$(SWIFT_VERSION)-release/static-sdk/swift-$(SWIFT_VERSION)-RELEASE/swift-$(SWIFT_VERSION)-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz
SDK_CACHE      = .sdk-cache
SDK_TARBALL    = $(SDK_CACHE)/$(notdir $(STATIC_SDK_URL))
# Optional. Set it to install straight from the URL with SwiftPM verifying provenance.
SDK_CHECKSUM  ?=

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
        package-reporter sdk-install sdk-probe linux package-collector package-source

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
	@echo "  make package-source      tarball the VPS builds from   <-- simplest"
	@echo "  make sdk-probe           look for a usable static Linux SDK URL"
	@echo "  make sdk-install         install the static Linux SDK (needs a swift.org toolchain)"
	@echo "  make linux               cross-compile a static ipcollector for x86_64 Linux"
	@echo "  make package-collector   tarball a cross-compiled binary for the VPS"
	@echo ""
	@echo "sudo make install-collector"
	@echo "sudo make install-reporter COLLECTOR=http://host:8710 TOKEN=secret"
	@echo "sudo make uninstall-collector | uninstall-reporter"

build:
	swift build $(SWIFT_FLAGS)

release:
	$(ARM_BUILD)
	$(X86_BUILD)
	@mkdir -p $(DIST_BIN)
	@# Ask SwiftPM where it put things: the layout differs between build systems.
	arm=$$($(ARM_BUILD) --show-bin-path) && x86=$$($(X86_BUILD) --show-bin-path) && \
	lipo -create -output $(DIST_BIN)/ipcollector $$arm/ipcollector $$x86/ipcollector && \
	lipo -create -output $(DIST_BIN)/ipreporter  $$arm/ipreporter  $$x86/ipreporter
	@lipo -info $(DIST_BIN)/ipcollector $(DIST_BIN)/ipreporter

release-native:
	swift build $(SWIFT_FLAGS) -c release
	@mkdir -p $(DIST_BIN)
	@cp .build/release/ipcollector .build/release/ipreporter $(DIST_BIN)/
	@echo "built $(DIST_BIN)/ipcollector and $(DIST_BIN)/ipreporter for this Mac only"

test:
	swift test $(SWIFT_FLAGS) $(TEST_FLAGS)

# ---------------------------------------------------------------- Linux collector

# Ship the source and let the VPS build it. Preferred over cross-compiling: the Static
# Linux SDK is published against swift.org toolchains, so using it from an Xcode toolchain
# means installing a second Swift plus a version-matched SDK. This has no such coupling.
package-source:
	@rm -rf dist/mac-ip-registry
	@mkdir -p dist/mac-ip-registry
	@cp Package.swift Makefile README.md dist/mac-ip-registry/
	@cp -R Sources Tests deploy dist/mac-ip-registry/
	@rm -f dist/mac-ip-registry/deploy/linux/ipcollector
	@tar -czf dist/mac-ip-registry-src.tar.gz -C dist mac-ip-registry
	@rm -rf dist/mac-ip-registry
	@echo "built dist/mac-ip-registry-src.tar.gz ($$(du -h dist/mac-ip-registry-src.tar.gz | cut -f1))"
	@echo ""
	@echo "  scp dist/mac-ip-registry-src.tar.gz root@YOUR.VPS:"
	@echo "  ssh root@YOUR.VPS"
	@echo "    tar xzf mac-ip-registry-src.tar.gz"
	@echo "    sudo mac-ip-registry/deploy/linux/build-on-vps.sh"
	@echo "    sudo mac-ip-registry/deploy/linux/bootstrap-collector.sh --hostname HOST"

# The static SDK URL moves between releases, and it must match the toolchain. Run this
# from a machine with network access to find one that exists.
sdk-probe:
	@echo "local toolchain: $$(swift --version 2>&1 | head -1)"
	@echo "probing download.swift.org ..."
	@found=0; \
	for v in $(SWIFT_VERSION) 6.3.2 6.3.1 6.3.0 6.2.3 6.2.2 6.2.1 6.2.0 6.1.2 6.0.3; do \
	  for b in 0.0.1 0.0.2 0.0.3; do \
	    u="https://download.swift.org/swift-$$v-release/static-sdk/swift-$$v-RELEASE/swift-$$v-RELEASE_static-linux-$$b.artifactbundle.tar.gz"; \
	    code=$$(curl -fsSL --range 0-0 -o /dev/null -w '%{http_code}' "$$u" 2>/dev/null || echo 000); \
	    case "$$code" in 200|206) echo "  FOUND  $$u"; found=1 ;; esac; \
	  done; \
	done; \
	test $$found -eq 1 || echo "  nothing found — check https://www.swift.org/install/macos/"
	@echo ""
	@echo "Note: a swift.org SDK expects a swift.org toolchain. With Xcode's Swift the"
	@echo "cross-build will likely fail a version check even with a valid URL."
	@echo "If so, use 'make package-source' and build on the VPS instead."

# One-time. The SDK must match the toolchain: a 6.3.3 toolchain needs the 6.3.3 SDK, or
# the cross-build fails with module-format errors.
#
# `swift sdk install` demands --checksum for remote URLs but not for local files, so the
# default path downloads first and installs from disk. That is the same trust as a
# self-computed checksum — TLS to swift.org and nothing more. Pass SDK_CHECKSUM=... (from
# swift.org's download page) to have SwiftPM verify provenance properly instead.
sdk-install:
	@test -n "$(SWIFT_VERSION)" || { echo "could not determine the Swift version"; exit 1; }
	@if swift sdk list 2>/dev/null | grep -q "$(LINUX_SDK)"; then \
	    echo "$(LINUX_SDK) is already installed:"; swift sdk list; exit 0; \
	fi
	@echo "==> static Linux SDK for Swift $(SWIFT_VERSION)"
ifneq ($(SDK_CHECKSUM),)
	swift sdk install "$(STATIC_SDK_URL)" --checksum "$(SDK_CHECKSUM)"
else
	@mkdir -p $(SDK_CACHE)
	@echo "==> checking that the URL exists"
	@curl -fsSL --range 0-0 -o /dev/null "$(STATIC_SDK_URL)" || { \
	    echo ""; \
	    echo "Not available at:"; echo "  $(STATIC_SDK_URL)"; \
	    echo ""; \
	    echo "The artifactbundle version in that filename changes between releases."; \
	    echo "Find the current Static Linux SDK URL and checksum at"; \
	    echo "  https://www.swift.org/install/macos/"; \
	    echo "then re-run:"; \
	    echo "  make sdk-install STATIC_SDK_URL=<url> SDK_CHECKSUM=<checksum>"; \
	    exit 1; }
	@if [ -s "$(SDK_TARBALL)" ]; then \
	    echo "==> using cached $(SDK_TARBALL)"; \
	else \
	    echo "==> downloading (a few hundred MB)"; \
	    curl -fL --progress-bar -o "$(SDK_TARBALL).part" "$(STATIC_SDK_URL)" && mv "$(SDK_TARBALL).part" "$(SDK_TARBALL)"; \
	fi
	@echo "==> checksum of the downloaded file (compare with swift.org if you want provenance):"
	@swift package compute-checksum "$(SDK_TARBALL)"
	@echo "==> installing from the local file"
	swift sdk install "$(SDK_TARBALL)"
endif
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
