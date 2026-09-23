# Windows release packaging

`package.ps1` produces a self-contained `GraphCode-<version>-windows-x86_64`
directory and ZIP. The bundle contains the GraphCode shell, `graphcoded`,
`graphcode`, `zmx`, Winghostty host assets, Swift runtime DLLs, pinned provider
metadata, `LICENSE`, `THIRD-PARTY-NOTICES.txt`, and `GraphCode-Setup.ps1`.

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
code signed)` in `metadata.json` and `SIGNING.txt`. Their checksums detect
corruption, not publisher authenticity. They remain accepted for development
unless `-TrustedSignerThumbprint` is supplied.

## Standalone setup without a checkout

Extract the ZIP and use its `GraphCode\GraphCode-Setup.ps1`. The setup supports
Windows PowerShell 5.1 (the built-in `powershell.exe`) and PowerShell 7. It needs
neither this repository nor Git, Swift, Zig, the SDK, or a separate helper script.
It is a command-line PowerShell installer, not an MSI or graphical EXE installer.
The default command is non-mutating `Verify`; installation must be explicit.

For a **locally built, trusted development package**:

```powershell
Expand-Archive -LiteralPath .\GraphCode-1.2.3-windows-x86_64.zip `
  -DestinationPath .\extracted
powershell.exe -NoProfile -File .\extracted\GraphCode\GraphCode-Setup.ps1 `
  -Command Verify
powershell.exe -NoProfile -File .\extracted\GraphCode\GraphCode-Setup.ps1 `
  -Command Install
```

For signed releases, authenticate the setup script **before executing it**, as
shown under Signed setup bootstrap below. A script cannot establish its own
authenticity after it has already started running.

The default install root is `%LOCALAPPDATA%\GraphCode\current`. Setup creates
the per-user Start menu shortcut, user PATH entry, and current-user scheduled
daemon task using the same transaction as the repository tooling. Use the new
release's extracted setup with `-Command Upgrade` to replace an existing
installation. `-Package` can select another extracted package or a ZIP; without
it, setup verifies/installs its own directory. `-InstallRoot` supports custom
locations and must also be supplied when managing that custom installation.
`-NoScheduledTask` retains the explicit development/portable mode.

Standalone provenance checks use the selected package's declared provider pins,
so an older setup can verify another release whose pins changed. Signed-package
catalog verification authenticates those declarations. Repository commands
instead retain their comparison against the checkout's canonical pins.

The installed copy remains usable after the extraction directory is removed:

```powershell
powershell.exe -NoProfile -File "$env:LOCALAPPDATA\GraphCode\current\GraphCode-Setup.ps1" `
  -Command Uninstall
```

Uninstall preserves user data by default; `-RemoveUserData` opts into removal.
Authenticate signed setup before uninstall too. Setup never changes PowerShell
execution policy or certificate stores; organization policy may restrict
execution. Do not disable that policy to bypass a signature failure.

`package.ps1` imports `PackageRuntime.ps1` for repository commands and embeds
that same runtime verbatim into `setup.template.ps1` when building a package.
There is one implementation of verification and install/upgrade/rollback/
uninstall, and no downloaded helper is loaded before verification. The generated
setup is included in the manifest/catalog and is independently Authenticode
signed when signing is enabled.

## Failed installation and recovery

Install and upgrade track which transaction steps actually completed. A failed
daemon stop, locked installation, or failed move to backup never authorizes
deleting the existing installation. Same-volume directory renames prevent the
partial recursive moves that PowerShell can perform on locked trees.
Only a newly promoted payload is removed
during rollback. Staging and shortcut-snapshot failures also clean up their
temporary directories without changing the installed product.
The extraction directory is recorded before ZIP expansion, so interrupted
expansion also reaches the normal cleanup path.

If rollback itself fails, the command reports both the initiating failure and
the recovery errors, rather than replacing one with the other. An unrestored
previous installation is retained in the reported `.GraphCode-rollback-<id>`
directory alongside the installation root. A failed shortcut restoration keeps
its `.GraphCode-shortcut-<id>` snapshot and reports that path too. Do not delete
these recovery directories until the previous installation/integration has been
restored. The previous daemon is restarted only when its payload is back at the
installation root; an incomplete rollback is never reported as a successful
installation.

`Packaging.Rollback.Tests.ps1` covers pre-swap failures, failed promotion,
post-swap rollback, secondary recovery failures, fresh/portable installs, and a
native Windows file-sharing lock. It isolates daemon and shortcut operations;
the real-product packaging gate separately exercises scheduled-daemon
install/upgrade/rollback/uninstall.

## Signed package integrity

Signing is opt-in: `-SignCertificate <thumbprint>` requires a trusted code-signing
certificate with its private key and the Windows SDK's `signtool.exe` (or
`-SignToolPath`). Executables and `GraphCode-Setup.ps1` are signed with SHA-256, then their final hashes
are recorded in the manifest and provider provenance. A SHA-256 `package.cat`
catalog covers the payload, runtime DLLs, licenses, metadata, manifest, and
checksum list. The catalog is signed by the same publisher. Third-party DLLs
retain their original signatures; the catalog and manifest bind their exact bytes.
The completed package is verified before a ZIP is produced.

```powershell
pwsh -NoProfile -File Tools\windows\package.ps1 -Command Build `
  -Version 1.2.3 `
  -WinghosttyRoot $env:GRAPHCODE_WINGHOSTTY_ROOT `
  -ZmxRoot $env:GRAPHCODE_ZMX_ROOT `
  -SignCertificate $env:GRAPHCODE_SIGNER_THUMBPRINT `
  -SignTimestampUrl $env:GRAPHCODE_SIGN_TIMESTAMP_URL

pwsh -NoProfile -File Tools\windows\package.ps1 -Command Verify `
  -Package .build\windows\packages\GraphCode-1.2.3-windows-x86_64.zip `
  -TrustedSignerThumbprint $env:GRAPHCODE_SIGNER_THUMBPRINT

pwsh -NoProfile -File Tools\windows\package.ps1 -Command Upgrade `
  -Package .build\windows\packages\GraphCode-1.2.3-windows-x86_64.zip `
  -TrustedSignerThumbprint $env:GRAPHCODE_SIGNER_THUMBPRINT
```

Obtain the 40-hex-digit publisher certificate thumbprint through an independently
trusted release policy, **never from the downloaded package or its checksum
sidecar**. Signed packages require that explicit pin for `Verify`, `Install`,
and `Upgrade`. Supplying it also rejects unsigned packages, including a package
whose signing metadata and catalog have been stripped. Windows must report a
valid Authenticode signature, the catalog must use SHA-256 and match the files,
and the catalog, executables, and bundled setup must match the expected publisher. A valid
signature from a different publisher is not sufficient. Verification needs only
Windows PowerShell security cmdlets; the SDK is optional on the target machine.
Installation re-verifies the staged copy before altering the existing install,
scheduled task, shortcut, or PATH.

### Signed setup bootstrap

Run this in a trusted PowerShell session before invoking the downloaded setup.
`GRAPHCODE_SIGNER_THUMBPRINT` must already contain the independently obtained
publisher pin, not a value read from the download:

```powershell
$setup = (Resolve-Path -LiteralPath .\extracted\GraphCode\GraphCode-Setup.ps1).Path
$expected = $env:GRAPHCODE_SIGNER_THUMBPRINT
if ($expected -notmatch '^[0-9a-fA-F]{40}$') {
  throw "An independently trusted publisher thumbprint is required"
}
$signature = Get-AuthenticodeSignature -FilePath $setup
if ($signature.Status -ne 'Valid' -or
    $signature.SignerCertificate.Thumbprint -ne $expected) {
  throw "Setup does not have a trusted signature from the expected publisher"
}
& $setup -Command Install -TrustedSignerThumbprint $expected
```

Use the same bootstrap for `Verify`, `Upgrade`, and `Uninstall`, changing only
the final command and any explicit package/install-root arguments. The setup's
publisher check does not replace the catalog and complete payload verification.

Use a trusted RFC 3161 timestamp service via `-SignTimestampUrl` for releases.
Certificate provisioning, publisher-pin distribution/rotation, timestamp service
selection, provider release-ref retention, and publication remain release-owner
prerequisites. The bundled setup is not a published, production-signed installer
and does not enable automatic download/install/relaunch in the native updater.
Older EXE-only signed packages without a catalog are deliberately rejected.

`Packaging.Signing.Tests.ps1` exercises real Windows catalogs and tampering of
DLLs, metadata, manifests, file sets, and checksums. Its OS signature-trust
decisions are simulated without modifying certificate stores; it is not a
production Authenticode or signed-installer lifecycle proof. It runs before the
existing real-product packaging/lifecycle suite under `validate.ps1 -Task packaging`.
`Packaging.Standalone.Tests.ps1` verifies a generated package from outside the
checkout with toolchain environment removed under PowerShell 5.1 and 7. The
real-product gate additionally runs extracted/installed standalone setup under
Windows PowerShell 5.1 with a minimal PATH, including scheduled-daemon startup,
locked upgrade, rollback, and self-uninstall. These are local clean-environment
tests, not a new physical clean-machine or production-certificate qualification.
`Packaging.ScriptSigning.Tests.ps1` additionally uses the real SDK SignTool
with an ephemeral, untrusted certificate to sign the generated setup. Native
PowerShell recognizes its text signature block and detects modified code as a
hash mismatch; no certificate is added to trust stores. This contract requires
the SDK on the build/CI host, not the installation target, and is not proof of
production publisher trust. `Packaging.Scheduler.Tests.ps1` exercises an owned
idle task through native stop/delete and verifies the actual missing-task
HRESULT without suppressing account or permission errors.

## Publishing a Windows release

`Tools/windows/release.ps1` is the only supported path from `package.ps1` to a
GitHub release asset, and `.github/workflows/windows-release.yml` is the only
thing that runs it in CI.

Like the macOS DMG — which a maintainer builds locally with `make release-dmg`
and attaches with `gh release create` — Windows publication is deliberately
manual. The workflow has a single `workflow_dispatch` trigger and never fires on
a tag push or on a published release. Its inputs are the existing release `tag`,
`publish` (default `false`), and `allow_unsigned_publish` (default `false`). The
built artifact is always uploaded as a workflow artifact, so a build can be
inspected without touching any release.

```powershell
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag v1.2.3
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag v1.2.3 -Publish
```

The tag supplies the package version (`v1.2.3` and `1.2.3-beta1` are accepted;
`dev` versions and anything that is not a release version are refused before
anything is built). `release.ps1` then builds through `package.ps1`, re-runs
`package.ps1 -Command Verify` — pinned to the expected publisher when signing —
reads the built package's own `metadata.json`, and **refuses to continue if the
package's declared signing state contradicts what the run actually did**.

Locally, `Tools\windows\stage-swift-products.ps1` produces the Swift half of the
release inputs (`graphcoded.exe`, `graphcode.exe`, and the Swift runtime DLLs in
`.build\windows\release`); `package.ps1` builds the versioned shell itself from
the pinned providers.

### Asset names

| Build | Asset | Publishable |
|---|---|---|
| signed | `graphcode-windows-x86_64.zip` + `.sha256` | yes |
| unsigned | `graphcode-windows-x86_64-unsigned.zip` + `.sha256` | only with `allow_unsigned_publish` |

The signed name is versionless, matching `graphcode-macos-arm64.dmg`, so
`releases/latest/download/graphcode-windows-x86_64.zip` resolves. An unsigned
development build can never occupy that name.

### Secrets that enable signing

Set these as repository secrets (**Settings → Secrets and variables → Actions →
New repository secret**). No certificate material is stored in this repository.

| Secret | Format | Required |
|---|---|---|
| `WINDOWS_SIGNING_CERTIFICATE` | Base64 text of a PFX holding the code-signing certificate **and** its private key (`[Convert]::ToBase64String([IO.File]::ReadAllBytes('signing.pfx'))`) | yes |
| `WINDOWS_SIGNING_CERTIFICATE_PASSWORD` | That PFX's password | yes |
| `WINDOWS_SIGNING_THUMBPRINT` | The certificate's SHA-1 thumbprint, exactly 40 hexadecimal characters (`package.ps1` validates `^[0-9a-fA-F]{40}$`) | yes |
| `WINDOWS_SIGNING_TIMESTAMP_URL` | RFC 3161 timestamp service `https://` URL | recommended |

The PFX is required because release jobs run on ephemeral GitHub-hosted runners,
which have no certificate store to pre-provision. The workflow imports it into
`Cert:\CurrentUser\My`, **requires the imported certificate's own thumbprint to
equal `WINDOWS_SIGNING_THUMBPRINT`**, passes only that thumbprint to
`package.ps1 -SignCertificate`, and removes both the imported certificate and the
decoded PFX before the job ends. A mismatched or malformed thumbprint aborts
before anything is built.

With **none** of the signing secrets configured the workflow still succeeds and
produces the unsigned development artifact described above. Supplying only
*some* of them is a hard failure rather than a silent downgrade to unsigned, so a
misconfigured secret can never be mistaken for a signed release.

`Release.Tests.ps1` covers tag resolution, unsigned labeling and its publication
gate, incomplete signing material, thumbprint pinning and certificate cleanup,
the signing-state honesty gate, build/upload failure propagation, and the
workflow's own triggers, action pinning, and input defaults. It runs first under
`validate.ps1 -Task packaging` and needs no certificate, network access, or real
build; its signed path uses an ephemeral self-signed certificate that it removes
again. Publishing plumbing is not production-signing evidence: no certificate
exists yet, and no Windows asset has been published.

## Retained provider sources

Both exact public provider pins have the annotated source-retention tag
`graphcode-windows-baseline-2026-09-17`:

| Provider | Pinned commit | Retained branch |
|---|---|---|
| [coneilen/winghostty](https://github.com/coneilen/winghostty/tree/graphcode-windows-baseline-2026-09-17) | `f5abc059e4ca58b376eb209313aca7784659c679` | `graphcode-host` |
| [coneilen/zmx](https://github.com/coneilen/zmx/tree/graphcode-windows-baseline-2026-09-17) | `029e11d2b19162fb3bdf90c8270237d303b8bfb4` | `graphcode-quickchat-hang` |

As verified on 2026-09-17, each fork has an active ruleset forbidding updates or
deletion of `refs/tags/graphcode-windows-*`, without bypass actors. Separate
active rulesets prevent deletion and non-fast-forward changes of the branches
above; normal forward development is allowed. The Winghostty tag/branch ruleset
IDs are `23625509`/`23625510`; zmx's are `23625508`/`23625511`.
Administrators can still change rulesets or repository availability; these
settings are retention controls, not an irrevocable archival guarantee.

These tags preserve source, not signed product releases. No installer or binary
asset is published by creating them. Public CI can fetch them without provider
credentials; collaborator permissions were not changed.

`graphcode-windows\provider-pins.json` remains the source of truth. Bootstrap and
packaging still use exact commit SHAs, not moving branch or tag resolution.
The terminal gate checks every provider field against its investigation copy,
including repository, remote URL, SHA, artifact path, and Zig version.
`ProviderPins.Tests.ps1` proves drift in either file is rejected, while JSON
property order and explanatory fallback wording are immaterial. Run it directly
or through `validate.ps1 -Task terminal-gate`.
