#!/bin/bash
# Assembles graphcode/Resources/Licenses.txt from the licence files actually on disk, so
# the notice that ships is the upstream text rather than a transcription of it.
#
# Ghostty and zmx are redistributed as code inside the app — libghostty is linked into the
# binary, zmx is copied into Contents/Resources/bin — and both are MIT, which requires the
# notice travel with the copy. The Swift packages are covered for the same reason.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=graphcode/Resources/Licenses.txt
CHECKOUTS=Tuist/.build/checkouts

emit() { # name, path-to-licence
  printf '%s\n%s\n\n' "$1" "$(printf '=%.0s' $(seq ${#1}))" >>"$OUT"
  cat "$2" >>"$OUT"
  printf '\n\n%s\n\n' "$(printf -- '-%.0s' {1..78})" >>"$OUT"
}

{
  echo "Third-party software in GraphCode"
  echo
  echo "GraphCode itself is licensed separately; see the LICENSE file in the source"
  echo "repository at https://github.com/scgopi/GraphCode."
  echo
  echo "The components below are redistributed with this application under their own"
  echo "terms, reproduced in full."
  echo
  printf -- '-%.0s' {1..78}
  echo
  echo
} >"$OUT"

emit "Ghostty (libghostty)" ThirdParty/ghostty/LICENSE
emit "zmx" ThirdParty/zmx/LICENSE

if [ -d "$CHECKOUTS" ]; then
  for dir in "$CHECKOUTS"/*/; do
    name=$(basename "$dir")
    licence=$(ls "$dir"LICENSE "$dir"LICENSE.txt "$dir"LICENSE.md 2>/dev/null | head -1) || true
    [ -n "$licence" ] && emit "$name" "$licence"
  done
else
  echo "warning: $CHECKOUTS missing — run 'make generate' first; Swift package" >&2
  echo "         notices were not included in $OUT" >&2
  exit 1
fi

echo "wrote $OUT ($(grep -c '' "$OUT") lines)"
