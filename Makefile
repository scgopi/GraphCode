.PHONY: doctor generate build-app build-daemon run-app run-daemon \
        daemon-install daemon-uninstall daemon-status test check format clean \
        third-party build-zmx build-ghostty vendor-sdk

SCHEME_APP := graphcode
SCHEME_DAEMON := graphcoded
WORKSPACE := graphcode.xcworkspace
DESTINATION := platform=macOS

BUILD_DIR := $(CURDIR)/.build

# zig 0.15.2 cannot link against macOS SDK 26.x — that SDK dropped the plain
# `arm64-macos` slice from libSystem.tbd, so every libc symbol resolves to
# undefined. Tools/zig-sdk-shim/xcrun answers zig's SDK query with a macOS 15 SDK
# instead. See that script's header for the full explanation; it is prepended to
# PATH for every zig build below and is a no-op for all other xcrun calls.
ZIG_SDK_SHIM := $(CURDIR)/Tools/zig-sdk-shim

SUPPORT_DIR := $(HOME)/Library/Application Support/graphcode
LAUNCH_AGENTS_DIR := $(HOME)/Library/LaunchAgents
DAEMON_LABEL := dev.graphcode.graphcoded
DAEMON_PLIST := $(LAUNCH_AGENTS_DIR)/$(DAEMON_LABEL).plist

MISE := mise exec --

# ---------------------------------------------------------------------------
# doctor — verify every build prerequisite and print fixes for anything missing.
# ---------------------------------------------------------------------------
doctor:
	@echo "graphcode doctor"
	@echo "----------------"
	@command -v mise >/dev/null 2>&1 && echo "[ok] mise: $$(mise --version)" \
		|| echo "[missing] mise — install with: brew install mise"
	@$(MISE) tuist version >/dev/null 2>&1 && echo "[ok] tuist: $$($(MISE) tuist version)" \
		|| echo "[missing] tuist — run: mise install"
	@$(MISE) swiftlint version >/dev/null 2>&1 && echo "[ok] swiftlint: $$($(MISE) swiftlint version)" \
		|| echo "[missing] swiftlint — run: mise install"
	@$(MISE) xcbeautify --version >/dev/null 2>&1 && echo "[ok] xcbeautify: $$($(MISE) xcbeautify --version)" \
		|| echo "[missing] xcbeautify — run: mise install"
	@command -v swift >/dev/null 2>&1 && echo "[ok] swift: $$(swift --version 2>&1 | head -1)" \
		|| echo "[missing] swift toolchain — install Xcode"
	@xcode-select -p >/dev/null 2>&1 && echo "[ok] Xcode: $$(xcodebuild -version 2>&1 | head -1)" \
		|| echo "[missing] Xcode command line tools — run: xcode-select --install"
	@test -f Project.swift && echo "[ok] Project.swift present" \
		|| echo "[missing] Project.swift — you're not in the graphcode repo root"
	@test -d ThirdParty/ghostty && echo "[ok] ThirdParty/ghostty submodule present" \
		|| echo "[not yet vendored] ThirdParty/ghostty — run: git submodule update --init --recursive (added in a later Phase 0 step; terminal rendering isn't wired up until then)"
	@test -d ThirdParty/zmx && echo "[ok] ThirdParty/zmx submodule present" \
		|| echo "[not yet vendored] ThirdParty/zmx — run: git submodule update --init --recursive"
	@SDK=$$(PATH="$(ZIG_SDK_SHIM):$$PATH" xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
		case "$$SDK" in *MacOSX15*) echo "[ok] zig-linkable macOS 15 SDK: $$SDK";; \
		*) echo "[missing] no macOS 15 SDK — zig cannot link against SDK 26.x (see Tools/zig-sdk-shim/xcrun). Run: xcode-select --install";; esac
	@# `xcrun -f metal` only finds the driver stub, which exists even when the
	@# toolchain itself was never downloaded — actually invoke it instead.
	@if xcrun metal --version 2>&1 | grep -q "missing Metal Toolchain"; then \
		echo "[missing] Metal toolchain (needed by GhosttyKit) — run: xcodebuild -downloadComponent MetalToolchain"; \
	else echo "[ok] Metal toolchain present"; fi
	@test -x "$(BUILD_DIR)/zmx/bin/zmx" && echo "[ok] zmx built: $$($(BUILD_DIR)/zmx/bin/zmx --version 2>&1 | head -1 | tr -s '\t' ' ')" \
		|| echo "[not built] zmx — run: make build-zmx"
	@test -d "$(BUILD_DIR)/ghostty/GhosttyKit.xcframework" && echo "[ok] GhosttyKit.xcframework built" \
		|| echo "[not built] GhosttyKit.xcframework — run: make build-ghostty"

# ---------------------------------------------------------------------------
# third-party (zig) builds — zmx for session persistence, GhosttyKit for the
# terminal surface. Both go through the SDK shim; see Tools/zig-sdk-shim/xcrun.
# ---------------------------------------------------------------------------
third-party: build-zmx build-ghostty

build-zmx:
	@test -d ThirdParty/zmx || { echo "ThirdParty/zmx missing — run: git submodule update --init --recursive"; exit 1; }
	cd ThirdParty/zmx && PATH="$(ZIG_SDK_SHIM):$$PATH" $(MISE) zig build \
		--prefix "$(BUILD_DIR)/zmx" \
		--global-cache-dir "$(BUILD_DIR)/zmx/.zig-global-cache"
	@echo "zmx built: $(BUILD_DIR)/zmx/bin/zmx"

build-ghostty:
	@test -d ThirdParty/ghostty || { echo "ThirdParty/ghostty missing — run: git submodule update --init --recursive"; exit 1; }
	@if xcrun metal --version 2>&1 | grep -q "missing Metal Toolchain"; then \
		echo "[missing] Metal toolchain — GhosttyKit compiles Metal shaders."; \
		echo "          Install it with: xcodebuild -downloadComponent MetalToolchain"; exit 1; fi
	@# -Demit-macos-app=false: graphcode needs GhosttyKit.xcframework only. Ghostty's
	@# own Ghostty.app bundle is a separate xcodebuild step that graphcode never uses,
	@# and it fails here on an unrelated CoreSimulator version mismatch.
	cd ThirdParty/ghostty && PATH="$(ZIG_SDK_SHIM):$$PATH" $(MISE) zig build \
		-Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false \
		--prefix "$(BUILD_DIR)/ghostty" \
		--global-cache-dir "$(BUILD_DIR)/ghostty-cache"
	@# Zig emits the xcframework into the submodule; mirror it into .build so every
	@# consumer (Project.swift, doctor) has one stable path to point at.
	@rm -rf "$(BUILD_DIR)/ghostty/GhosttyKit.xcframework"
	@mkdir -p "$(BUILD_DIR)/ghostty"
	@ditto ThirdParty/ghostty/macos/GhosttyKit.xcframework "$(BUILD_DIR)/ghostty/GhosttyKit.xcframework"
	@echo "GhosttyKit built: $(BUILD_DIR)/ghostty/GhosttyKit.xcframework"

# Copy a macOS 15 SDK into the repo so a Command Line Tools update that drops it
# can't break the zig builds. The shim prefers this copy when it exists.
vendor-sdk:
	@SRC=$$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk 2>/dev/null | sort -V | tail -1); \
	test -n "$$SRC" || { echo "no macOS 15 SDK in Command Line Tools to vendor"; exit 1; }; \
	mkdir -p "$(BUILD_DIR)/sdk"; \
	ditto "$$SRC" "$(BUILD_DIR)/sdk/$$(basename $$SRC)"; \
	echo "vendored $$SRC -> $(BUILD_DIR)/sdk/$$(basename $$SRC)"

# ---------------------------------------------------------------------------
# generate / build / run
# ---------------------------------------------------------------------------
generate:
	$(MISE) tuist generate --no-open

build-app: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-destination '$(DESTINATION)' build | $(MISE) xcbeautify

build-daemon: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_DAEMON) \
		-destination '$(DESTINATION)' build | $(MISE) xcbeautify

run-app: build-app
	@APP_PATH=$$($(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcode.app; \
	echo "Launching $$APP_PATH"; \
	open "$$APP_PATH"

run-daemon: build-daemon
	@BIN_PATH=$$($(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_DAEMON) \
		-destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcoded; \
	echo "Running $$BIN_PATH (Ctrl-C to stop)"; \
	"$$BIN_PATH"

# ---------------------------------------------------------------------------
# graphcoded as a launchd agent — survives terminal/app quit, matches how the
# real daemon is meant to run once Phase 3 makes it load-bearing.
# ---------------------------------------------------------------------------
daemon-install: build-daemon
	@mkdir -p "$(SUPPORT_DIR)"
	@BIN_PATH=$$($(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_DAEMON) \
		-destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcoded; \
	sed -e "s#__GRAPHCODED_BIN__#$$BIN_PATH#g" \
	    -e "s#__GRAPHCODED_SUPPORT_DIR__#$(SUPPORT_DIR)#g" \
	    graphcoded/Support/dev.graphcode.graphcoded.plist.template > "$(DAEMON_PLIST)"; \
	launchctl unload "$(DAEMON_PLIST)" >/dev/null 2>&1 || true; \
	launchctl load "$(DAEMON_PLIST)"; \
	echo "graphcoded installed and loaded: $(DAEMON_PLIST)"

daemon-uninstall:
	@launchctl unload "$(DAEMON_PLIST)" >/dev/null 2>&1 || true
	@rm -f "$(DAEMON_PLIST)"
	@echo "graphcoded unloaded and removed"

daemon-status:
	@launchctl list | grep $(DAEMON_LABEL) || echo "graphcoded is not loaded"

# ---------------------------------------------------------------------------
# test / check / format
# ---------------------------------------------------------------------------
test: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-destination '$(DESTINATION)' test | $(MISE) xcbeautify

check:
	$(MISE) swiftlint lint
	swift format lint --recursive --strict --configuration .swift-format graphcode graphcoded

format:
	swift format format --recursive --in-place --configuration .swift-format graphcode graphcoded
	$(MISE) swiftlint lint --fix

clean:
	rm -rf $(WORKSPACE) graphcode.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/graphcode-*
