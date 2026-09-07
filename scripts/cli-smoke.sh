#!/bin/sh
# Runs the built CLI against a throwaway daemon and insists on exit 0 — the check no
# scheme build can make. The `graphcode` test scheme does not build `graphcode-cli`,
# a scheme build of it cannot see a runtime fault (a helper that called itself took
# every verb down with SIGSEGV and passed three green gates), and no test invokes the
# binary. This does. SwiftPM products, so it runs identically on macOS and Linux CI.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/.build/debug"
[ -x "$bin/graphcode" ] && [ -x "$bin/graphcoded" ] || swift build --package-path "$root"

# Short: sockaddr_un.sun_path is 104 bytes on Darwin.
support="$(mktemp -d /tmp/gcsmoke.XXXXXX)"
project="$support/project"
mkdir -p "$project"
export GRAPHCODE_SUPPORT_DIR="$support"
"$bin/graphcoded" > "$support/daemon.out" 2>&1 &
daemon=$!
trap 'kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null; rm -rf "$support"' EXIT INT TERM

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$support/graphcoded.sock" ] && break
  sleep 0.5
done
[ -S "$support/graphcoded.sock" ] || { echo "smoke: daemon never listened"; cat "$support/daemon.out"; exit 1; }

fail=0
check() {
  if "$@" > "$support/out" 2>&1; then
    echo "smoke: ok   $*"
  else
    echo "smoke: FAIL $* (exit $?)"; cat "$support/out"; fail=1
  fi
}
check "$bin/graphcode" status "$project"
check "$bin/graphcode" mail list "$project"
check "$bin/graphcode" mail post "$project" --topic smoke "the smoke test was here"
check "$bin/graphcode" mail read "$project" 1
check "$bin/graphcode" projects
exit "$fail"
