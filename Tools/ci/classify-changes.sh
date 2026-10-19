#!/usr/bin/env bash
# Decide which expensive CI suites a change needs.
#
# Prints (and appends to $GITHUB_OUTPUT when set) one line per suite:
#   windows=true|false  macos=true|false  linux=true|false  native_a11y=true|false
#
# Only pull_request events are narrowed. Every other event (push, merge_group,
# workflow_dispatch, schedule) gets full validation. Anything the classifier cannot
# account for — an unknown path, an empty change list, a diff it cannot compute —
# also gets full validation: it fails safe, never quiet.
#
# Usage:
#   classify-changes.sh --event NAME --base SHA --head SHA   # diff base...head
#   classify-changes.sh --event NAME --stdin                 # newline-separated paths
#
# Tests: bash Tools/ci/tests/classify-changes.test.sh
set -uo pipefail

event=""
base=""
head=""
from_stdin=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) event="${2:-}"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    --stdin) from_stdin=1; shift ;;
    *) echo "classify-changes: unknown argument: $1" >&2; exit 2 ;;
  esac
done

windows=false
macos=false
linux=false
native_a11y=false

emit() {
  local line
  for line in "windows=$windows" "macos=$macos" "linux=$linux" "native_a11y=$native_a11y"; do
    echo "$line"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "$line" >>"$GITHUB_OUTPUT"
    fi
  done
}

all() {
  windows=true
  macos=true
  linux=true
  native_a11y=true
}

if [[ "$event" != "pull_request" ]]; then
  echo "classify-changes: event '${event:-unset}' is not pull_request; running every suite." >&2
  all
  emit
  exit 0
fi

paths=()
if [[ $from_stdin -eq 1 ]]; then
  while IFS= read -r path || [[ -n "$path" ]]; do
    path="${path%$'\r'}"
    [[ -n "$path" ]] && paths+=("$path")
  done
else
  if [[ -z "$base" || -z "$head" ]]; then
    echo "classify-changes: --base and --head are required without --stdin; running every suite." >&2
    all
    emit
    exit 0
  fi
  if ! diff_output="$(git diff --no-renames --name-only "$base...$head" 2>&1)"; then
    echo "classify-changes: could not diff $base...$head; running every suite." >&2
    echo "$diff_output" >&2
    all
    emit
    exit 0
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] && paths+=("$path")
  done <<<"$diff_output"
fi

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "classify-changes: no changed paths found; running every suite." >&2
  all
  emit
  exit 0
fi

for path in "${paths[@]}"; do
  matched=0

  # The classifier governs every gated suite, so a change to it re-runs them all.
  case "$path" in
    Tools/ci/*) all; matched=1 ;;
  esac

  # Run the native provider independently on PRs touching its implementation,
  # fixture, harness, or workflow; it needs only the hosted MSVC/Windows SDK.
  case "$path" in
    graphcode-windows/src/AccessibilityProvider.cpp | \
      graphcode-windows/src/AccessibilityProvider.h | \
      Tools/windows/Tests/AccessibilityProvider.Native.Tests.* | \
      .github/workflows/windows-hardening.yml)
      native_a11y=true; matched=1 ;;
  esac

  # Windows: the Zig shell, its validation/bootstrap/packaging tooling, the Windows
  # Swift tests, the investigation spikes validate.ps1 builds, and the shared Swift
  # products and pins the Windows build consumes.
  case "$path" in
    graphcode-windows/* | Tools/windows/* | Tools/tdd/* | windows-tests/* | \
      investigation/spikes/* | investigation/visual-baseline/* | \
      GraphcodeKit/* | MailroomKit/* | graphcoded/* | graphcode-cli/* | \
      Package.swift | Package.resolved | mise.toml | .gitattributes | \
      .github/workflows/windows-*.yml)
      windows=true; matched=1 ;;
  esac

  # macOS shared Swift regression: the app, kit, daemon, CLI, the portable Swift
  # package, Tuist/SwiftPM/lint configuration, submodules, icon sources, and the
  # scripts that make and the portable setup run.
  case "$path" in
    graphcode/* | GraphcodeKit/* | MailroomKit/* | graphcoded/* | graphcode-cli/* | \
      investigation/spikes/swift-portable/* | \
      Package.swift | Package.resolved | Project.swift | Tuist.swift | Tuist/* | \
      Makefile | mise.toml | .swiftlint.yml | .swift-format | .gitattributes | \
      .gitmodules | ThirdParty/* | scripts/* | Tools/portable-prepare.py | \
      Tools/icon/* | Tools/zig-sdk-shim/* | \
      .github/workflows/macos-shared-regression.yml)
      macos=true; matched=1 ;;
  esac

  # Linux: everything `swift format` lints and `swift build` compiles, plus the CLI
  # smoke script and the workflow itself.
  case "$path" in
    graphcode/* | GraphcodeKit/* | MailroomKit/* | graphcoded/* | graphcode-cli/* | \
      Package.swift | Package.resolved | .swift-format | .gitattributes | \
      scripts/* | .github/workflows/linux.yml)
      linux=true; matched=1 ;;
  esac

  [[ $matched -eq 1 ]] && continue

  # Paths no gated suite reads. The source screenshots are still privacy-scanned
  # by the ungated investigation job. DCO and TDD-evidence run on every PR.
  case "$path" in
    *.md | docs/* | screenshots/* | investigation/contracts/* | \
      investigation/macos-parity-evidence/evidence/* | \
      LICENSE | DCO | .env.example | .github/PULL_REQUEST_TEMPLATE.md | \
      .github/ISSUE_TEMPLATE/* | .github/workflows/dco.yml | \
      .github/workflows/tdd-evidence.yml)
      continue ;;
  esac

  echo "classify-changes: unclassified path '$path'; running every suite." >&2
  all
done

emit
