#!/usr/bin/env bash
# Path-mapping tests for Tools/ci/classify-changes.sh.
# Run: bash Tools/ci/tests/classify-changes.test.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classifier="$here/../classify-changes.sh"
passed=0
failed=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name"
    echo "  want: $want"
    echo "  got:  $got"
  fi
}

flatten() { tr -d '\r' | tr '\n' ' ' | sed 's/ $//'; }

# expect NAME WINDOWS MACOS LINUX PATH...
expect() {
  local name="$1" want="windows=$2 macos=$3 linux=$4 native_a11y=${native_expected:-false}"
  shift 4
  local got
  if [[ $# -eq 0 ]]; then
    got="$(: | GITHUB_OUTPUT='' bash "$classifier" --event pull_request --stdin 2>/dev/null | flatten)"
  else
    got="$(printf '%s\n' "$@" | GITHUB_OUTPUT='' bash "$classifier" --event pull_request --stdin 2>/dev/null | flatten)"
  fi
  check "$name" "$want" "$got"
}

expect_native() {
  local name="$1" native_expected="$2"
  shift 2
  expect "$name" "$@"
}

expect "parity ledger only" false false false \
  investigation/ui-parity-matrix.md
expect "macOS evidence prompt only" false false false \
  investigation/macos-parity-evidence-agent-prompt.md
expect "prompt and ledger together" false false false \
  investigation/ui-parity-matrix.md investigation/macos-parity-evidence-agent-prompt.md
expect "general documentation only" false false false \
  README.md AGENTS.md CONTRIBUTING.md docs/guide.md investigation/contracts/remote-bridge.md \
  .github/PULL_REQUEST_TEMPLATE.md screenshots/canvas.png
expect "DCO and TDD workflows only" false false false \
  .github/workflows/dco.yml .github/workflows/tdd-evidence.yml

expect "Windows Zig source" true false false \
  graphcode-windows/src/App.zig
expect "Windows validation tooling" true false false \
  Tools/windows/validate.ps1
expect "Windows production tests" true false false \
  windows-tests/WindowsDaemonTests.swift
expect "UI scenario schema" true false false \
  windows-tests/ui-scenarios/scenario.schema.json
expect "UI claim scenario path" true false false \
  windows-tests/ui-scenarios/818-C1.json
expect "offline UI scenario validator" true false false \
  Tools/windows/Test-UiScenario.ps1
expect "Windows spike package" true false false \
  investigation/spikes/swift-contracts/Package.swift
expect "TDD evidence tooling validated by Windows suite" true false false \
  Tools/tdd/Test-TddEvidence.ps1
expect "visual baseline manifest" true false false \
  investigation/visual-baseline/manifest.json
expect "macOS icon source image" false true false \
  Tools/icon/icon-master-1024.png
expect "macOS reference screenshot only" false false false \
  investigation/macos-parity-evidence/evidence/empty-welcome-original.png
expect "Windows release workflow" true false false \
  .github/workflows/windows-release.yml

expect "macOS Swift app" false true true \
  graphcode/Sources/App.swift
expect "Tuist project" false true false \
  Project.swift
expect "Tuist dependencies" false true false \
  Tuist/Package.swift
expect "Makefile" false true false \
  Makefile
expect "submodule bump" false true false \
  ThirdParty/ghostty
expect "portable prepare script" false true false \
  Tools/portable-prepare.py
expect "Zig SDK shim" false true false \
  Tools/zig-sdk-shim/xcrun
expect "portable Swift spike" true true false \
  investigation/spikes/swift-portable/Package.swift

expect "shared GraphcodeKit" true true true \
  GraphcodeKit/Sources/GraphStore.swift
expect "shared MailroomKit" true true true \
  MailroomKit/Sources/Mailroom.swift
expect "daemon" true true true \
  graphcoded/Sources/main.swift
expect "CLI" true true true \
  graphcode-cli/Sources/main.swift
expect "SwiftPM manifest" true true true \
  Package.swift
expect "SwiftPM pins" true true true \
  Package.resolved
expect "swift-format configuration" false true true \
  .swift-format
expect "SwiftLint configuration" false true false \
  .swiftlint.yml
expect "CLI smoke script" false true true \
  scripts/cli-smoke.sh
expect "mise pins" true true false \
  mise.toml

expect "mixed ledger and Windows source" true false false \
  investigation/ui-parity-matrix.md graphcode-windows/src/GraphModel.zig
expect "mixed prompt and GraphcodeKit" true true true \
  investigation/macos-parity-evidence-agent-prompt.md GraphcodeKit/Sources/Workspace.swift

expect "Windows shell workflow" true false false \
  .github/workflows/windows-shell.yml
expect "Windows port workflow" true false false \
  .github/workflows/windows-port-validation.yml
expect "Windows cache warmer workflow" true false false \
  .github/workflows/windows-cache-warmer.yml
expect_native "Windows hardening workflow" true true false false \
  .github/workflows/windows-hardening.yml
expect "macOS workflow" false true false \
  .github/workflows/macos-shared-regression.yml
expect "Linux workflow" false false true \
  .github/workflows/linux.yml
expect_native "classifier script" true true true true \
  Tools/ci/classify-changes.sh
expect_native "classifier tests" true true true true \
  Tools/ci/tests/classify-changes.test.sh

expect_native "native provider implementation" true true false false \
  graphcode-windows/src/AccessibilityProvider.cpp
expect_native "native provider header" true true false false \
  graphcode-windows/src/AccessibilityProvider.h
expect_native "native provider test runner" true true false false \
  Tools/windows/Tests/AccessibilityProvider.Native.Tests.ps1
expect_native "native provider test fixture" true true false false \
  Tools/windows/Tests/AccessibilityProvider.Native.Tests.cpp
expect_native "native provider future fixture extension" true true false false \
  Tools/windows/Tests/AccessibilityProvider.Native.Tests.json
expect_native "mixed docs and native provider" true true false false \
  README.md graphcode-windows/src/AccessibilityProvider.cpp
expect_native "unknown path fails safe" true true true true \
  some-new-directory/build.sh
expect_native "unclassified root image fails safe" true true true true \
  notes/diagram.png
expect_native "empty change list fails safe" true true true true

fixture="$(mktemp -d)"
git -C "$fixture" init -q
git -C "$fixture" config user.name "Classifier Test"
git -C "$fixture" config user.email "classifier@example.invalid"
git -C "$fixture" config core.autocrlf false
printf 'base\n' >"$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" commit -qm "base"
base="$(git -C "$fixture" rev-parse HEAD)"
printf 'documentation\n' >"$fixture/notes.md"
git -C "$fixture" add notes.md
git -C "$fixture" commit -qm "documentation"
head="$(git -C "$fixture" rev-parse HEAD)"
got="$(
  cd "$fixture" &&
    GITHUB_OUTPUT='' bash "$classifier" --event pull_request --base "$base" --head "$head" 2>/dev/null |
    flatten
)"
check "full-history docs-only diff is skipped" \
  "windows=false macos=false linux=false native_a11y=false" "$got"
git -C "$fixture" checkout -q --detach "$base"
mkdir -p "$fixture/graphcode-windows/src"
printf 'base-only provider change\n' >"$fixture/graphcode-windows/src/AccessibilityProvider.cpp"
git -C "$fixture" add graphcode-windows/src/AccessibilityProvider.cpp
git -C "$fixture" commit -qm "advance base"
advanced_base="$(git -C "$fixture" rev-parse HEAD)"
got="$(
  cd "$fixture" &&
    GITHUB_OUTPUT='' bash "$classifier" --event pull_request --base "$advanced_base" --head "$head" 2>/dev/null |
    flatten
)"
check "base-only provider change is not a PR change" \
  "windows=false macos=false linux=false native_a11y=false" "$got"
git -C "$fixture" checkout -q --detach "$head"
mkdir -p "$fixture/Tools/windows/Tests"
printf 'native fixture change\n' >"$fixture/Tools/windows/Tests/AccessibilityProvider.Native.Tests.cpp"
git -C "$fixture" add Tools/windows/Tests/AccessibilityProvider.Native.Tests.cpp
git -C "$fixture" commit -qm "native PR fixture"
native_head="$(git -C "$fixture" rev-parse HEAD)"
got="$(
  cd "$fixture" &&
    GITHUB_OUTPUT='' bash "$classifier" --event pull_request --base "$advanced_base" --head "$native_head" 2>/dev/null |
    flatten
)"
check "PR-head native fixture change triggers native validation" \
  "windows=true macos=false linux=false native_a11y=true" "$got"
rm -rf "$fixture"

# A PR path classifier must have the merge base locally; zero is a literal
# depth, not a falsy workflow-expression operand.
for workflow in \
  .github/workflows/linux.yml \
  .github/workflows/macos-shared-regression.yml \
  .github/workflows/windows-shell.yml \
  .github/workflows/windows-port-validation.yml \
  .github/workflows/windows-hardening.yml; do
  depth="$(awk '
    /^  changes:/ { in_changes=1; next }
    in_changes && /^  [^ ]/ { exit }
    in_changes && /fetch-depth:/ {
      sub(/^[[:space:]]*/, "")
      print
    }
  ' "$here/../../../$workflow")"
  check "$workflow changes checkout has full history" "fetch-depth: 0" "$depth"
done

hardening="$here/../../../.github/workflows/windows-hardening.yml"
native_job="$(awk '
  /^  native-accessibility:/ { in_native=1 }
  in_native && /^  [^ ]/ && !/^  native-accessibility:/ { exit }
  in_native { print }
' "$hardening")"
check "native PR job is present" "1" "$(printf '%s\n' "$native_job" | grep -c '^  native-accessibility:')"
check "native PR job checks classifier output fail-closed" "1" \
  "$(printf '%s\n' "$native_job" | grep -Fc "needs.changes.outputs.native_a11y != 'false'")"
check "native PR job is PR-triggered" "1" \
  "$(printf '%s\n' "$native_job" | grep -Fc "github.event_name == 'pull_request'")"
check "native PR job targets hosted windows-2022" "1" \
  "$(printf '%s\n' "$native_job" | grep -c '^    runs-on: windows-2022$')"
check "native PR job runs the actual native test script" "1" \
  "$(printf '%s\n' "$native_job" | grep -Fc 'run: ./Tools/windows/Tests/AccessibilityProvider.Native.Tests.ps1')"
check "native PR job verifies harness failure attribution" "1" \
  "$(printf '%s\n' "$native_job" | grep -Fc 'run: ./Tools/windows/Tests/AccessibilityProvider.Native.Tests.Harness.Tests.ps1')"
check "native PR job does not tolerate or conditionally hide step failures" "0" \
  "$(printf '%s\n' "$native_job" | grep -Ec 'continue-on-error:|^        if:')"
check "hardening exposes native classifier output" "1" \
  "$(grep -Fc 'native_a11y: ${{ steps.classify.outputs.native_a11y }}' "$hardening")"
check "both PR and full-pinned jobs verify harness failure attribution" "2" \
  "$(grep -Fc 'run: ./Tools/windows/Tests/AccessibilityProvider.Native.Tests.Harness.Tests.ps1' "$hardening")"

# Non-PR events always get full validation, whatever changed.
for event in push merge_group workflow_dispatch schedule; do
  got="$(printf 'README.md\n' | GITHUB_OUTPUT='' bash "$classifier" --event "$event" --stdin 2>/dev/null | flatten)"
  check "$event forces full validation" "windows=true macos=true linux=true native_a11y=true" "$got"
done

# A diff that cannot be computed fails safe to full validation.
got="$(GITHUB_OUTPUT='' bash "$classifier" --event pull_request \
  --base 0000000000000000000000000000000000000000 \
  --head 1111111111111111111111111111111111111111 2>/dev/null | flatten)"
check "unresolvable diff fails safe" "windows=true macos=true linux=true native_a11y=true" "$got"

# GITHUB_OUTPUT receives the same key=value lines.
out="$(mktemp)"
printf 'investigation/ui-parity-matrix.md\n' | GITHUB_OUTPUT="$out" bash "$classifier" --event pull_request --stdin >/dev/null 2>&1
check "writes GITHUB_OUTPUT" "windows=false macos=false linux=false native_a11y=false" "$(flatten <"$out")"
: >"$out"
printf 'graphcode-windows/src/AccessibilityProvider.cpp\n' |
  GITHUB_OUTPUT="$out" bash "$classifier" --event pull_request --stdin >/dev/null 2>&1
check "writes native provider GITHUB_OUTPUT" \
  "windows=true macos=false linux=false native_a11y=true" "$(flatten <"$out")"
rm -f "$out"

# Linux runners' bash rejects CRLF scripts; .gitattributes must keep these LF.
for script in "$classifier" "${BASH_SOURCE[0]}"; do
  if grep -q $'\r' "$script"; then
    check "$(basename "$script") has LF line endings" "no CR" "CR found"
  else
    check "$(basename "$script") has LF line endings" "no CR" "no CR"
  fi
done

echo "classify-changes: $passed passed, $failed failed"
[[ $failed -eq 0 && $passed -gt 0 ]]
