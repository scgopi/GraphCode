#!/bin/bash
# Installs a graphcode release: the app, the daemon, the CLI, and zmx.
#
# Mirrors what `make install-zmx install-cli daemon-install` does from a source checkout,
# minus the building. Safe to re-run — it replaces what it installed last time and reloads
# the daemon.
set -euo pipefail

SUPPORT_DIR="$HOME/.graphcode"
BIN_DIR="$SUPPORT_DIR/bin"
APP_DIR="/Applications"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="dev.graphcode.graphcoded"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -m)" != "arm64" ]; then
  echo "graphcode is Apple Silicon only — this machine is $(uname -m)." >&2
  exit 1
fi

# A browser download quarantines everything inside the archive, and Gatekeeper then refuses
# an ad-hoc signed binary with a misleading "damaged" error. Clearing it here is the same
# thing the README tells people to do by hand, done once, for everything at once.
if xattr -p com.apple.quarantine "$HERE/graphcode.app" >/dev/null 2>&1; then
  echo "clearing quarantine (this came from a browser download)"
  xattr -dr com.apple.quarantine "$HERE/graphcode.app" "$HERE/bin" 2>/dev/null || true
fi

mkdir -p "$BIN_DIR" "$LAUNCH_AGENTS"

echo "stopping any running daemon"
launchctl unload "$PLIST" >/dev/null 2>&1 || true

# `launchctl unload` returns before the process has actually exited, so re-running this
# script could otherwise leave the old daemon alive alongside the new one — two daemons
# with the same socket path, one of them holding an unlinked socket nothing can reach.
# Matched on the full installed path so this can't touch anything else named graphcoded.
for _ in $(seq 1 20); do
  pgrep -f "^$BIN_DIR/graphcoded$" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -f "^$BIN_DIR/graphcoded$" >/dev/null 2>&1; then
  echo "  old daemon still running after unload — terminating it"
  pkill -f "^$BIN_DIR/graphcoded$" 2>/dev/null || true
  sleep 1
fi

# Remove before copying, then re-sign in place. Copying over a path macOS has already
# validated leaves a stale cached signature, and the result is SIGKILLed at exec
# ("Taskgated Invalid Signature") even though `codesign -v` calls it valid on disk. That
# failure is near-silent, so verify each binary actually runs rather than assuming.
install_binary() {
  local name="$1"
  rm -f "$BIN_DIR/$name"
  cp "$HERE/bin/$name" "$BIN_DIR/$name"
  codesign --force --sign - "$BIN_DIR/$name" 2>/dev/null || true
  chmod +x "$BIN_DIR/$name"
}

for b in zmx graphcoded graphcode; do
  echo "installing $b -> $BIN_DIR/$b"
  install_binary "$b"
done

"$BIN_DIR/zmx" version >/dev/null 2>&1 \
  || { echo "zmx installed but won't run — check its code signature" >&2; exit 1; }

echo "installing graphcode.app -> $APP_DIR"
rm -rf "$APP_DIR/graphcode.app"
# ditto rather than cp: it preserves the bundle's signature and extended attributes.
ditto "$HERE/graphcode.app" "$APP_DIR/graphcode.app"
codesign --force --deep --sign - "$APP_DIR/graphcode.app" 2>/dev/null || true

echo "loading the daemon"
sed -e "s#__GRAPHCODED_BIN__#$BIN_DIR/graphcoded#g" \
    -e "s#__GRAPHCODED_SUPPORT_DIR__#$SUPPORT_DIR#g" \
    "$HERE/dev.graphcode.graphcoded.plist.template" > "$PLIST"
launchctl load "$PLIST"

# Substitution rather than `launchctl list | grep -q`: under `set -o pipefail`, grep -q
# exits at the first match and SIGPIPEs the producer, so the pipeline reports failure even
# though the match succeeded — which reads as "the daemon didn't load" on a daemon that
# loaded perfectly.
#
# Polling rather than a flat sleep, because launchd registers asynchronously: a fixed wait
# either fails a daemon that was merely slow or passes before it has really come up.
daemon_is_loaded() {
  case "$(launchctl list 2>/dev/null)" in
    *"$LABEL"*) return 0 ;;
    *) return 1 ;;
  esac
}

for _ in $(seq 1 20); do
  if daemon_is_loaded; then break; fi
  sleep 0.5
done

if daemon_is_loaded; then
  echo
  echo "installed."
  echo "  app     $APP_DIR/graphcode.app"
  echo "  binaries $BIN_DIR"
  echo "  state    $SUPPORT_DIR"
  echo
  echo "Add $BIN_DIR to your PATH to use the 'graphcode' CLI."
  echo "Open the app from Applications, or run: open $APP_DIR/graphcode.app"
else
  echo "the daemon didn't stay loaded — check $SUPPORT_DIR/graphcoded.err.log" >&2
  exit 1
fi
