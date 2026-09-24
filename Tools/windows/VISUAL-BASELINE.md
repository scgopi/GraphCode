# Visual baseline contract check

`visual-baseline.ps1` is a static, no-launch validator for
`investigation/visual-baseline/manifest.json`. It never builds or launches
`graphcode-windows.exe`; it only reads source and manifest files already in the
checkout.

```powershell
pwsh Tools/windows/visual-baseline.ps1
```

Exits non-zero with a specific diagnostic on any contract violation, or prints
`Visual baseline: PASS`. Must be run with `pwsh` (PowerShell 7), not Windows
PowerShell 5.1's `powershell.exe` -- an unrelated, pre-existing check elsewhere
in this script fails under Desktop edition regardless of this contract.

## currentThemeContract

`manifest.json`'s `tokenContracts`/`baseCommit` section is an immutable
historical pin at commit `ece55b6` and is never edited. `currentThemeContract`
is a separate, additive section that instead tracks *today's*
`graphcode/Sources/Features/App/Theme.swift`, re-derived from the file on disk
every run.

`Tools\windows\Test-CurrentThemeContract.ps1` is the actual comparator. It is
dot-sourced by `visual-baseline.ps1` for the real run, and invoked directly
(same file, as its own process) by
`Tools\windows\Tests\VisualBaseline.Tests.ps1` against fixture files -- tests
exercise this exact production code, not a re-declared copy. For each tracked
token it enforces:

- exact token identity, cardinality, and no duplicates (an empty or partial
  token list fails, it does not pass vacuously)
- RGB shape (3 channels) and range (`0..255`), and that `hex` matches `rgb`
- zero-tolerance equality between the token's recorded `rgb` and the RGB
  derived from Theme.swift's active `Color(red:green:blue:)` literal for that
  token; a commented-out or opacity-suffixed literal is rejected rather than
  silently accepted
- a whole-file SHA-256 (`themeSwiftBlobSha256`, CRLF normalized to LF) against
  the approved Theme.swift blob, without requiring any historical git object
- for tokens with a `windowsToken` field, that the named
  `graphcode-windows/src/DesignTokens.zig` `Color` constant, decoded from its
  Win32 `COLORREF` (`0x00BBGGRR`) byte order, equals the same Theme.swift-derived
  RGB -- an independent macOS-vs-Windows source cross-check, not one manifest
  constant compared against another

This is a source-contract check only. It does not capture or compare live
screenshot pixels; no live/launch mode exists in this script.
