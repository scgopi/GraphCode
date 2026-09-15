# Windows release packaging

`package.ps1` produces a self-contained `GraphCode-<version>-windows-x86_64`
directory and ZIP. The bundle contains the GraphCode shell, `graphcoded`,
`graphcode`, `zmx`, Winghostty host assets, Swift runtime DLLs, pinned provider
metadata, `LICENSE`, and `THIRD-PARTY-NOTICES.txt`.

```powershell
pwsh Tools/windows/package.ps1 -Command Build `
  -InputDirectory .build/windows/release `
  -Version 1.0.0
pwsh Tools/windows/package.ps1 -Command Verify `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64.zip
pwsh Tools/windows/package.ps1 -Command Install `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64
```

The ZIP contains one top-level `GraphCode` directory. Installation verifies the
complete manifest and provider provenance before copying anything, then stages
and swaps atomically. The scheduled task is created and run; the exact installed
daemon endpoint must become reachable or the previous installation is restored.
The daemon's actual `%USERPROFILE%\.graphcode` data directory is preserved by
uninstall unless `-RemoveUserData` is explicitly requested.

Unsigned artifacts are explicitly marked `UNSIGNED (development artifact; not
code signed)` in `metadata.json` and `SIGNING.txt`. Signing is opt-in:
`-SignCertificate <thumbprint>` requires `signtool.exe` and fails if signing
cannot be completed. The script never reports a signed artifact without that
input.
