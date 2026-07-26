.PHONY: doctor generate build-app build-daemon run-app run-daemon \
        daemon-install daemon-uninstall daemon-status test check format clean

SCHEME_APP := graphcode
SCHEME_DAEMON := graphcoded
WORKSPACE := graphcode.xcworkspace
DESTINATION := platform=macOS

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
