# Windows release packaging

`package.ps1` produces a self-contained `GraphCode-<version>-windows-x86_64`
directory and ZIP. The bundle contains the GraphCode shell, `graphcoded`,
`graphcode`, `zmx`, Winghostty host assets, Swift runtime DLLs, pinned provider
metadata, `LICENSE`, and `THIRD-PARTY-NOTICES.txt`.

```powershell
pwsh Tools/windows/package.ps1 -Command Build `
  -InputDirectory .build/windows/release -Version 1.0.0
pwsh Tools/windows/package.ps1 -Command Verify `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64
pwsh Tools/windows/package.ps1 -Command Install `
  -Package .build/windows/packages/GraphCode-1.0.0-windows-x86_64
```

Installation is staged and swapped atomically. A failed swap restores the
previous `current` tree. The per-user `data` directory is never removed by
uninstall. Installation adds `current/bin` to the user PATH and registers an
`ONLOGON` scheduled task for `graphcoded`; `-NoScheduledTask` is intended for
tests and portable deployments.

Unsigned artifacts are explicitly marked `UNSIGNED (development artifact; not
code signed)` in `metadata.json` and `SIGNING.txt`. Signing is opt-in:
`-SignCertificate <thumbprint>` requires `signtool.exe` and fails if signing
cannot be completed. The script never reports a signed artifact without that
input.
