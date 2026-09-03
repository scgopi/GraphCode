.PHONY: doctor generate build-app build-daemon run-app run-daemon \
        daemon-install daemon-uninstall daemon-status test check format clean \
        dev-generate dev-build-app dev-build-daemon dev-install-daemon \
        dev-install-zmx dev-run-app dev-status \
        third-party build-zmx install-zmx build-ghostty vendor-sdk \
        build-cli install-cli release-dmg notarize signing-doctor tap-bump

SCHEME_APP := graphcode
SCHEME_DAEMON := graphcoded
SCHEME_CLI := graphcode-cli
WORKSPACE := graphcode.xcworkspace
DESTINATION := platform=macOS

# Optional developer-local overrides. `.env.local` wins when both exist;
# command-line assignments still win over either file.
-include .env
-include .env.local

BUILD_DIR := $(CURDIR)/.build

# zig 0.15.2 cannot link against macOS SDK 26.x — that SDK dropped the plain
# `arm64-macos` slice from libSystem.tbd, so every libc symbol resolves to
# undefined. Tools/zig-sdk-shim/xcrun answers zig's SDK query with a macOS 15 SDK
# instead. See that script's header for the full explanation; it is prepended to
# PATH for every zig build below and is a no-op for all other xcrun calls.
ZIG_SDK_SHIM := $(CURDIR)/Tools/zig-sdk-shim

SUPPORT_DIR := $(HOME)/.graphcode
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
	@test -f Tuist/.build/workspace-state.json \
		&& echo "[ok] Tuist dependencies installed" \
		|| echo "[not installed] Tuist dependencies — run: mise exec -- tuist install"
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
	@# -Doptimize is load-bearing: zig defaults to Debug, whose ghostty-vt runs
	@# page-integrity verification on every scrolled line. Measured via
	@# Tools/relay-bench: Debug zmx relays 0.3 MB/s and turns a 60Hz TUI redraw
	@# stream into ~4Hz; ReleaseFast is at parity with a bare PTY.
	cd ThirdParty/zmx && PATH="$(ZIG_SDK_SHIM):$$PATH" $(MISE) zig build \
		-Doptimize=ReleaseFast \
		--prefix "$(BUILD_DIR)/zmx" \
		--global-cache-dir "$(BUILD_DIR)/zmx/.zig-global-cache"
	@# zig's own linker-generated ad-hoc signature (produced while linking against the
	@# macOS 15 SDK via the shim, see ZIG_SDK_SHIM above) is rejected outright by this
	@# host's code-signing monitor at launch — SIGKILL, "Taskgated Invalid Signature",
	@# even run standalone with no relation to graphcode/Ghostty. Re-signing with the
	@# real macOS codesign tool (still ad-hoc, just host-native) fixes it.
	codesign --force --sign - "$(BUILD_DIR)/zmx/bin/zmx"
	@echo "zmx built: $(BUILD_DIR)/zmx/bin/zmx"

# Installs to the fixed path GraphcodeKit's ZmxLocator looks for at runtime (see
# GraphcodeKit/Sources/Sessions/ZmxLocator.swift) — simpler than requiring zmx on
# PATH, and matches how graphcoded itself lives under ~/.graphcode.
install-zmx: build-zmx
	@mkdir -p "$(SUPPORT_DIR)/bin"
	@# Remove before copying, then re-sign in place. Copying over a path whose old
	@# inode macOS has already validated leaves a stale cached signature, and the
	@# result is SIGKILLed at exec ("Taskgated Invalid Signature") even though
	@# `codesign -v` reports it valid on disk. That failure is near-silent — zmx
	@# prints nothing and dies before main() — so every session graphcode tries to
	@# start just quietly never appears.
	@rm -f "$(SUPPORT_DIR)/bin/zmx"
	@cp "$(BUILD_DIR)/zmx/bin/zmx" "$(SUPPORT_DIR)/bin/zmx"
	@codesign --force --sign - "$(SUPPORT_DIR)/bin/zmx" 2>/dev/null
	@"$(SUPPORT_DIR)/bin/zmx" version >/dev/null 2>&1 \
		|| { echo "zmx installed but won't run — check its code signature"; exit 1; }
	@echo "zmx installed: $(SUPPORT_DIR)/bin/zmx"

build-ghostty:
	@test -d ThirdParty/ghostty || { echo "ThirdParty/ghostty missing — run: git submodule update --init --recursive"; exit 1; }
	@if xcrun metal --version 2>&1 | grep -q "missing Metal Toolchain"; then \
		echo "[missing] Metal toolchain — GhosttyKit compiles Metal shaders."; \
		echo "          Install it with: xcodebuild -downloadComponent MetalToolchain"; exit 1; fi
	@# -Demit-macos-app=false: graphcode needs GhosttyKit.xcframework only. Ghostty's
	@# own Ghostty.app bundle is a separate xcodebuild step that graphcode never uses,
	@# and it fails here on an unrelated CoreSimulator version mismatch.
	@# -Doptimize for the same reason as build-zmx: without it GhosttyKit is a zig
	@# Debug build — the app's terminal emulation with runtime safety checks the
	@# real Ghostty.app compiles out. ReleaseFast matches Ghostty's own releases.
	cd ThirdParty/ghostty && PATH="$(ZIG_SDK_SHIM):$$PATH" $(MISE) zig build \
		-Doptimize=ReleaseFast \
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
generate: build-ghostty
	$(MISE) tuist generate --no-open

build-app: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-destination '$(DESTINATION)' build | $(MISE) xcbeautify

build-daemon: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_DAEMON) \
		-destination '$(DESTINATION)' build | $(MISE) xcbeautify

build-cli: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_CLI) \
		-destination '$(DESTINATION)' build | $(MISE) xcbeautify

# Puts `graphcode` on PATH next to the zmx we already install under Application
# Support, so the CLI is reachable without hunting through DerivedData.
install-cli: build-cli
	@mkdir -p "$(SUPPORT_DIR)/bin"
	@BIN_PATH=$$($(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_CLI) \
		-destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcode; \
	rm -f "$(SUPPORT_DIR)/bin/graphcode"; \
	cp "$$BIN_PATH" "$(SUPPORT_DIR)/bin/graphcode"; \
	"$(SUPPORT_DIR)/bin/graphcode" --help >/dev/null 2>&1 \
		|| { echo "graphcode installed but won't run — check its code signature"; exit 1; }; \
	echo "installed: $(SUPPORT_DIR)/bin/graphcode"

run-app: build-app install-zmx
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
# dev build — a second graphcode that runs beside an installed release.
#
# Side-by-side needs BOTH halves, which is why these are one target and not a
# note in the README:
#   * a distinct bundle id, or macOS confuses the two apps in LaunchServices,
#     Login Items, and background-agent attribution;
#   * a distinct support dir, or they share graphs and zmx session names and
#     fight over the sessions (see SupportDirectory's header).
# The support dir also gives the dev daemon its own launchd label for free —
# `Workspace.daemonLabel` suffixes the slug — so nothing here touches the
# release's agent.
#
# Override these in `.env.local` when the defaults collide with another local build.
# ---------------------------------------------------------------------------
DEV_BUNDLE_ID_PREFIX ?= local.graphcode.dev
DEV_APP_DISPLAY_NAME ?= GraphCode (localdev)
DEV_SUPPORT_DIR_NAME ?= .graphcode-localdev
DEV_SUPPORT_DIR := $(HOME)/$(DEV_SUPPORT_DIR_NAME)
DEV_DAEMON_LABEL := $(DAEMON_LABEL).$(patsubst .graphcode-%,%,$(DEV_SUPPORT_DIR_NAME))
DEV_DAEMON_PLIST := $(LAUNCH_AGENTS_DIR)/$(DEV_DAEMON_LABEL).plist
DEV_ENV := TUIST_BUNDLE_ID_PREFIX="$(DEV_BUNDLE_ID_PREFIX)" \
           TUIST_APP_DISPLAY_NAME="$(DEV_APP_DISPLAY_NAME)"

dev-generate: build-ghostty
	$(DEV_ENV) $(MISE) tuist generate --no-open

dev-build-app: dev-generate
	set -o pipefail && $(DEV_ENV) $(MISE) xcodebuild -workspace $(WORKSPACE) \
		-scheme $(SCHEME_APP) -destination '$(DESTINATION)' build | $(MISE) xcbeautify

dev-build-daemon: dev-generate
	set -o pipefail && $(DEV_ENV) $(MISE) xcodebuild -workspace $(WORKSPACE) \
		-scheme $(SCHEME_DAEMON) -destination '$(DESTINATION)' build | $(MISE) xcbeautify

dev-install-daemon: dev-build-daemon
	@mkdir -p "$(DEV_SUPPORT_DIR)" "$(LAUNCH_AGENTS_DIR)"
	@BIN_PATH=$$($(DEV_ENV) $(MISE) xcodebuild -workspace $(WORKSPACE) \
		-scheme $(SCHEME_DAEMON) -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcoded; \
	sed -e "s#dev.graphcode.graphcoded#$(DEV_DAEMON_LABEL)#g" \
	    -e "s#dev.graphcode.app#$(DEV_BUNDLE_ID_PREFIX).app#g" \
	    -e "s#__GRAPHCODED_BIN__#$$BIN_PATH#g" \
	    -e "s#__GRAPHCODED_SUPPORT_DIR__#$(DEV_SUPPORT_DIR)#g" \
	    graphcoded/Support/dev.graphcode.graphcoded.plist.template > "$(DEV_DAEMON_PLIST)"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" \
	    -c "Add :EnvironmentVariables:GRAPHCODE_SUPPORT_DIR string $(DEV_SUPPORT_DIR)" \
	    "$(DEV_DAEMON_PLIST)"; \
	launchctl unload "$(DEV_DAEMON_PLIST)" >/dev/null 2>&1 || true; \
	launchctl load "$(DEV_DAEMON_PLIST)"; \
	echo "graphcoded installed and loaded: $(DEV_DAEMON_PLIST)"

# Installs zmx into the DEV support dir, not the release's, so the two never
# share a binary or a session namespace.
dev-install-zmx: build-zmx
	@mkdir -p "$(DEV_SUPPORT_DIR)/bin"
	@rm -f "$(DEV_SUPPORT_DIR)/bin/zmx"
	@cp "$(BUILD_DIR)/zmx/bin/zmx" "$(DEV_SUPPORT_DIR)/bin/zmx"
	@codesign --force --sign - "$(DEV_SUPPORT_DIR)/bin/zmx" 2>/dev/null
	@"$(DEV_SUPPORT_DIR)/bin/zmx" version >/dev/null 2>&1 \
		|| { echo "zmx installed but won't run — check its code signature"; exit 1; }
	@echo "installed: $(DEV_SUPPORT_DIR)/bin/zmx"

dev-run-app: dev-build-app dev-install-zmx dev-install-daemon
	@APP_PATH=$$($(DEV_ENV) $(MISE) xcodebuild -workspace $(WORKSPACE) \
		-scheme $(SCHEME_APP) -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}')/graphcode.app; \
	echo "Launching $$APP_PATH with GRAPHCODE_SUPPORT_DIR=$(DEV_SUPPORT_DIR_NAME)"; \
	open -n --env GRAPHCODE_SUPPORT_DIR="$(DEV_SUPPORT_DIR_NAME)" "$$APP_PATH"

# What the dev build actually is, in one command — useful when the two get confusing.
dev-status:
	@echo "bundle id prefix : $(DEV_BUNDLE_ID_PREFIX)"
	@echo "support dir      : $(DEV_SUPPORT_DIR)"
	@echo "daemon (dev)     : $$(launchctl list | awk '$$3 == "$(DEV_DAEMON_LABEL)" {print $$3}')"
	@echo "daemon (release) : $$(launchctl list | awk '$$3 == "$(DAEMON_LABEL)" {print $$3}')"
	@echo "dev app running  : $$(pgrep -f 'Debug/graphcode.app/Contents/MacOS/graphcode' | paste -sd' ' - | sed 's/^$$/no/')"
	@ls -d /Applications/graphcode.app >/dev/null 2>&1 \
		&& echo "installed release: /Applications/graphcode.app ($$(defaults read /Applications/graphcode.app/Contents/Info CFBundleIdentifier 2>/dev/null))" \
		|| echo "installed release: none"

# ---------------------------------------------------------------------------
# test / check / format
# ---------------------------------------------------------------------------
test: generate
	set -o pipefail && $(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-destination '$(DESTINATION)' test | $(MISE) xcbeautify

check:
	$(MISE) swiftlint lint
	swift format lint --recursive --strict --configuration .swift-format \
		GraphcodeKit graphcode graphcode-cli graphcoded

format:
	swift format format --recursive --in-place --configuration .swift-format \
		GraphcodeKit graphcode graphcode-cli graphcoded
	$(MISE) swiftlint lint --fix

# ---------------------------------------------------------------------------
# release-dmg — a self-contained graphcode.app in a drag-to-Applications disk
# image.
#
# The app carries `graphcoded` and `zmx` in Contents/Resources/bin, and
# `DaemonBootstrap` installs them and loads the daemon on first launch. That is
# what makes plain drag-to-Applications a complete install; without the embedded
# helpers the app would open and silently do nothing, having no daemon to talk to.
#
# Release, and arm64 only: GhosttyKit is built `-Dxcframework-target=native` and
# has no x86_64 slice, so a universal build fails at link time.
#
# Signing. With no SIGN_ID the bundle is ad-hoc signed, which is fine on the
# machine that built it and nowhere else — Gatekeeper on any other Mac refuses
# an ad-hoc signature outright ("graphcode is damaged and can't be opened"). To
# cut a DMG a stranger can actually open:
#
#   make release-dmg SIGN_ID="Developer ID Application: Name (TEAMID)" \
#                    NOTARY_PROFILE=graphcode
#
# `make signing-doctor` checks both of those exist and prints how to create them.
# The identity must be a *Developer ID Application* certificate; the "Apple
# Development" certificate Xcode's automatic signing creates cannot ship — it is
# for debugging on machines in your own provisioning profile, and notarization
# rejects anything signed with it.
#
# Note that Xcode's Signing & Capabilities pane is not where this lives: Tuist
# regenerates graphcode.xcodeproj from Project.swift on every `make generate`,
# so anything set there is discarded. Release signing is this recipe's job.
#
# The signed path goes inside out, one codesign call per nested binary, ending
# with the bundle itself. `--deep` is what the ad-hoc path above uses and what
# Apple tells you not to use for distribution: it applies the *same* entitlements
# to every nested binary and silently skips anything it doesn't recognise as
# code, and notarization rejects the result. The three helpers get the hardened
# runtime but no entitlements — they are CLI tools, and TCC prompts on behalf of
# the app that spawned them, not on their own behalf. Contents/Frameworks is
# empty today because GhosttyKit is a *static* xcframework, but a dynamic
# dependency arriving later has to be signed before the enclosing bundle or the
# outer signature is invalid the moment it is written.
#
# graphcode.entitlements carries no comments on purpose. codesign hands the file
# to AMFIUnserializeXML, whose plist reader is not the lenient one — an XML
# comment inside the <dict> is a hard parse error ("syntax error near line N")
# and the signature never gets written. So the reasoning lives here instead:
# the app is deliberately *not* sandboxed, because its whole job is spawning
# arbitrary CLI backends against arbitrary directories; notarization needs only
# the hardened runtime, not the sandbox. The TCC keys mirror Ghostty's release
# set (ThirdParty/ghostty/macos/Ghostty.entitlements) — macOS attributes what a
# PTY child asks for to the app that spawned it, so a session running `claude`
# that wants the microphone is refused outright unless GraphCode itself holds
# the entitlement. A terminal cannot enumerate in advance what its guests need.
#
# The disk image is then signed and notarized in its own right. Stapling the app
# covers whoever drags it out to /Applications; stapling the DMG covers
# Gatekeeper's check on the downloaded file itself, offline, before it is ever
# mounted.
# ---------------------------------------------------------------------------
RELEASE_DIR := $(BUILD_DIR)/release
DMG_STAGE := $(RELEASE_DIR)/dmg
DMG := $(RELEASE_DIR)/graphcode-macos-arm64.dmg
ENTITLEMENTS := $(CURDIR)/graphcode/graphcode.entitlements

# Aliased so the recipe below can recurse without the literal string `$(MAKE)`
# appearing in it. GNU make treats any recipe line mentioning $(MAKE) as a
# recursive invocation and runs it even under `-n` — and since the whole of
# release-dmg is one backslash-joined logical line, that would make a dry run
# perform a full Release build and sign it for real.
SUBMAKE := $(MAKE)

# Empty means ad-hoc. See the block above.
SIGN_ID ?=
# The keychain profile name given to `xcrun notarytool store-credentials`.
NOTARY_PROFILE ?= graphcode

# NOTARIZE=0 signs but does not submit to Apple. Useful only for checking the
# signing pipeline before the notarytool credentials exist — the resulting DMG
# is Developer ID signed but *not* notarized, so Gatekeeper on another Mac still
# quarantines it. Never publish the output of a NOTARIZE=0 run.
NOTARIZE ?= 1

release-dmg: generate build-zmx
	@set -e; \
	for scheme in $(SCHEME_APP) $(SCHEME_DAEMON) $(SCHEME_CLI); do \
		echo "building $$scheme (Release, arm64)"; \
		$(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $$scheme \
			-configuration Release -destination '$(DESTINATION)' \
			ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build >/dev/null; \
	done; \
	PRODUCTS=$$($(MISE) xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP) \
		-configuration Release -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F'= ' '/ BUILT_PRODUCTS_DIR /{print $$2; exit}'); \
	test -x "$$PRODUCTS/graphcode.app/Contents/MacOS/graphcode" \
		|| { echo "the app bundle has no executable — the Release build failed"; exit 1; }; \
	rm -rf "$(DMG_STAGE)"; mkdir -p "$(DMG_STAGE)"; \
	ditto "$$PRODUCTS/graphcode.app" "$(DMG_STAGE)/graphcode.app"; \
	mkdir -p "$(DMG_STAGE)/graphcode.app/Contents/Resources/bin"; \
	cp "$$PRODUCTS/graphcoded" "$(DMG_STAGE)/graphcode.app/Contents/Resources/bin/graphcoded"; \
	cp "$$PRODUCTS/graphcode" "$(DMG_STAGE)/graphcode.app/Contents/Resources/bin/graphcode"; \
	cp "$(BUILD_DIR)/zmx/bin/zmx" "$(DMG_STAGE)/graphcode.app/Contents/Resources/bin/zmx"; \
	APP="$(DMG_STAGE)/graphcode.app"; \
	echo "signing the bundle (embedding helpers invalidates the outer signature)"; \
	if [ -z "$(SIGN_ID)" ]; then \
		codesign --force --deep --sign - "$$APP"; \
		codesign --verify --deep "$$APP" \
			|| { echo "the packaged app failed signature verification"; exit 1; }; \
		echo "  ad-hoc — this DMG opens only on this Mac. See 'make signing-doctor'."; \
	else \
		echo "  identity: $(SIGN_ID)"; \
		for helper in zmx graphcoded graphcode; do \
			codesign --force --options runtime --timestamp \
				--sign "$(SIGN_ID)" "$$APP/Contents/Resources/bin/$$helper" >/dev/null 2>&1 \
				|| { echo "failed to sign helper $$helper"; exit 1; }; \
		done; \
		if [ -d "$$APP/Contents/Frameworks" ]; then \
			find "$$APP/Contents/Frameworks" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 \
				| xargs -0 -I{} codesign --force --options runtime --timestamp \
					--sign "$(SIGN_ID)" {} >/dev/null 2>&1 || true; \
		fi; \
		codesign --force --options runtime --timestamp \
			--entitlements "$(ENTITLEMENTS)" --sign "$(SIGN_ID)" "$$APP" \
			|| { echo "signing graphcode.app failed"; exit 1; }; \
		codesign --verify --strict --verbose=2 "$$APP" \
			|| { echo "the packaged app failed signature verification"; exit 1; }; \
		if [ "$(NOTARIZE)" = "1" ]; then \
			$(SUBMAKE) --no-print-directory notarize TARGET="$$APP"; \
		else echo "  NOTARIZE=0 — skipping notarization of the app"; fi; \
	fi; \
	ln -s /Applications "$(DMG_STAGE)/Applications"; \
	rm -f "$(DMG)"; \
	hdiutil create -volname "graphcode" -srcfolder "$(DMG_STAGE)" -ov -format UDZO \
		"$(DMG)" >/dev/null; \
	if [ -n "$(SIGN_ID)" ]; then \
		codesign --force --timestamp --sign "$(SIGN_ID)" "$(DMG)" \
			|| { echo "signing the disk image failed"; exit 1; }; \
		if [ "$(NOTARIZE)" = "1" ]; then \
			$(SUBMAKE) --no-print-directory notarize TARGET="$(DMG)"; \
			spctl --assess --type open --context context:primary-signature -v "$(DMG)" \
				|| { echo "Gatekeeper rejected the disk image"; exit 1; }; \
		else \
			echo "  NOTARIZE=0 — signed but NOT notarized; do not publish this DMG"; \
		fi; \
	fi; \
	echo "built: $(DMG)"

# ---------------------------------------------------------------------------
# notarize — submit TARGET to Apple, wait for the verdict, staple the ticket.
#
# Stapling is what lets the ticket travel with the file: without it every first
# launch needs a round trip to Apple, and a user who is offline (or behind a
# firewall that eats ocsp.apple.com) is told the app is damaged.
#
# notarytool accepts a .dmg, .pkg or .zip and never a bare .app, so a bundle is
# zipped first. `ditto -c -k --keepParent` is the only archiver Apple supports
# here — plain `zip` flattens the symlinks inside a bundle and the upload comes
# back rejected for a signature that was fine on disk.
# ---------------------------------------------------------------------------
notarize:
	@test -n "$(TARGET)" || { echo "notarize needs TARGET=<path to .app, .dmg or .zip>"; exit 1; }
	@set -e; \
	SUBMIT="$(TARGET)"; \
	case "$(TARGET)" in \
		*.app) SUBMIT="$(RELEASE_DIR)/notarize-upload.zip"; \
			rm -f "$$SUBMIT"; \
			ditto -c -k --keepParent "$(TARGET)" "$$SUBMIT";; \
	esac; \
	echo "notarizing $$(basename "$(TARGET)") — this waits on Apple, usually a minute or two"; \
	xcrun notarytool submit "$$SUBMIT" --keychain-profile "$(NOTARY_PROFILE)" --wait \
		|| { echo "notarization failed. For the reasons: xcrun notarytool log <id> --keychain-profile $(NOTARY_PROFILE)"; exit 1; }; \
	xcrun stapler staple "$(TARGET)" \
		|| { echo "could not staple the ticket to $(TARGET)"; exit 1; }; \
	case "$(TARGET)" in *.app) rm -f "$(RELEASE_DIR)/notarize-upload.zip";; esac

# ---------------------------------------------------------------------------
# tap-bump — point the Homebrew cask at a release that is already published.
#
# The cask lives in its own repository, scgopi/homebrew-graphcode, because that
# is what a tap is: `brew install --cask scgopi/graphcode/graphcode` resolves
# the middle name straight to `homebrew-graphcode` on GitHub. Homebrew's own
# cask repository takes only projects past its notability threshold — 75 stars,
# or 30 forks or watchers — so until GraphCode is there, this tap is the
# published route rather than a stopgap.
#
# Run this *after* `gh release create`, never before: the checksum is read back
# from the asset GitHub is already serving, so the cask cannot end up claiming a
# version whose DMG nobody can download. VERSION defaults to the one
# Project.swift ships.
#
# Two channels, two casks, because Homebrew has no notion of a pre-release: the
# way every other project ships one (firefox@beta, visual-studio-code@insiders)
# is a second cask beside the stable one, and that is what CHANNEL picks.
#
#   make tap-bump                                 # Casks/graphcode.rb,      tag v0.1.9
#   make tap-bump CHANNEL=beta VERSION=0.1.9-beta1 # Casks/graphcode@beta.rb, tag 0.1.9-beta1
#
# The two channels differ in more than the filename. Their tags are shaped
# differently — a release is tagged `v0.1.9`, a beta `0.1.9-beta1`, which is how
# the betas have been tagged since 0.1.8 — so the prefix is per channel rather
# than hardcoded. And a beta's version cannot be read out of Project.swift at
# all: the bundle carries the release it is a beta *of* (0.1.9), never the
# suffix, so VERSION is required for that channel instead of defaulted.
# ---------------------------------------------------------------------------
TAP_REPO ?= scgopi/homebrew-graphcode
TAP_DIR ?= $(BUILD_DIR)/tap
CHANNEL ?= stable

tap-bump:
	@set -e; \
	case "$(CHANNEL)" in \
		stable) CASK_NAME="graphcode"; TAG_PREFIX="v";; \
		beta) CASK_NAME="graphcode@beta"; TAG_PREFIX="";; \
		*) echo "CHANNEL must be stable or beta, not '$(CHANNEL)'"; exit 1;; \
	esac; \
	V="$(VERSION)"; \
	if [ -z "$$V" ]; then \
		[ "$(CHANNEL)" = stable ] \
			|| { echo "a beta's version is not in Project.swift — pass VERSION=0.1.9-beta1"; exit 1; }; \
		V=$$(awk -F'"' '/CFBundleShortVersionString/{print $$4; exit}' Project.swift); \
	fi; \
	TAG="$$TAG_PREFIX$$V"; \
	SHA=$$(gh release view "$$TAG" --json assets \
		--jq '.assets[] | select(.name == "graphcode-macos-arm64.dmg") | .digest' \
		| sed 's/^sha256://'); \
	test -n "$$SHA" \
		|| { echo "release $$TAG carries no graphcode-macos-arm64.dmg — publish it first"; exit 1; }; \
	echo "$$CASK_NAME $$V"; \
	echo "  sha256 $$SHA"; \
	if [ -d "$(TAP_DIR)/.git" ]; then \
		git -C "$(TAP_DIR)" pull -q --ff-only; \
	else \
		rm -rf "$(TAP_DIR)"; \
		git clone -q "https://github.com/$(TAP_REPO).git" "$(TAP_DIR)"; \
	fi; \
	CASK="$(TAP_DIR)/Casks/$$CASK_NAME.rb"; \
	test -f "$$CASK" || { echo "$$CASK does not exist — create it before bumping it"; exit 1; }; \
	/usr/bin/sed -i '' \
		-e "s/^  version \".*\"/  version \"$$V\"/" \
		-e "s/^  sha256 \".*\"/  sha256 \"$$SHA\"/" "$$CASK"; \
	if git -C "$(TAP_DIR)" diff --quiet; then \
		echo "  the cask already says $$V — nothing to push"; exit 0; fi; \
	ruby -c "$$CASK" >/dev/null \
		|| { echo "the bumped cask is no longer valid Ruby — not pushing"; exit 1; }; \
	grep -q "version \"$$V\"" "$$CASK" && grep -q "sha256 \"$$SHA\"" "$$CASK" \
		|| { echo "the version and checksum lines did not take — not pushing"; exit 1; }; \
	git -C "$(TAP_DIR)" commit -q -am "$$CASK_NAME $$V"; \
	git -C "$(TAP_DIR)" push -q origin HEAD; \
	echo "  pushed — 'brew upgrade --cask $$CASK_NAME' now finds $$V"

# ---------------------------------------------------------------------------
# signing-doctor — the two credentials a shippable DMG needs, and how to get
# each one. Separate from `doctor`, which is about building at all.
# ---------------------------------------------------------------------------
signing-doctor:
	@echo "graphcode signing doctor"
	@echo "------------------------"
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then \
		echo "[ok] Developer ID Application certificate:"; \
		security find-identity -v -p codesigning | grep "Developer ID Application" \
			| sed 's/^/       /'; \
		echo "     pass one to make as SIGN_ID=\"Developer ID Application: ...\""; \
	else \
		echo "[missing] no Developer ID Application certificate."; \
		echo "     The 'Apple Development' certificates below are for debugging on your"; \
		echo "     own machines — Gatekeeper refuses them elsewhere and notarization"; \
		echo "     rejects them. Xcode's 'Automatically manage signing' never creates a"; \
		echo "     Developer ID certificate; you make it once, by hand:"; \
		echo "       Xcode > Settings > Accounts > (your Apple ID) > Manage Certificates"; \
		echo "       > + > Developer ID Application"; \
		echo "     Only the Account Holder of the team can create one, and it needs the"; \
		echo "     paid Apple Developer Program membership (\$$99/yr) — a free account"; \
		echo "     gets Development certificates only."; \
		security find-identity -v -p codesigning 2>/dev/null | sed 's/^/       /'; \
	fi
	@if xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1; then \
		echo "[ok] notarytool keychain profile: $(NOTARY_PROFILE)"; \
	else \
		echo "[missing] notarytool keychain profile '$(NOTARY_PROFILE)'. Create it with:"; \
		echo "       xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
		echo "         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>"; \
		echo "     The password is NOT your Apple ID password — generate an app-specific"; \
		echo "     one at appleid.apple.com > Sign-In and Security > App-Specific Passwords."; \
		echo "     TEAMID is the parenthesised code in the certificate name above."; \
	fi
	@test -f "$(ENTITLEMENTS)" && echo "[ok] entitlements: $(ENTITLEMENTS)" \
		|| echo "[missing] $(ENTITLEMENTS)"

clean:
	rm -rf $(WORKSPACE) graphcode.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/graphcode-*
