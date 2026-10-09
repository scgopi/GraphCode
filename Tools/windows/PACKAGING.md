# Windows release packaging

`package.ps1` produces a self-contained `GraphCode-<version>-windows-x86_64`
directory and ZIP. The bundle contains the GraphCode shell, `graphcoded`,
`graphcode`, `zmx`, Winghostty host assets, Swift runtime DLLs, pinned provider
metadata, `LICENSE`, `THIRD-PARTY-NOTICES.txt`, and `GraphCode-Setup.ps1`.

For developer iteration from an untagged checkout, use the explicit local mode:

```powershell
. .\.graphcode-tools\environment.ps1
pwsh -NoProfile -File Tools\windows\stage-swift-products.ps1
pwsh -NoProfile -File Tools\windows\package.ps1 -Command Build -Local `
  -WinghosttyRoot $env:GRAPHCODE_WINGHOSTTY_ROOT `
  -ZmxRoot $env:GRAPHCODE_ZMX_ROOT

$package = Get-ChildItem .build\windows\packages\GraphCode-0.0.0-local+*-windows-x86_64.zip |
  Select-Object -First 1
pwsh -NoProfile -File Tools\windows\package.ps1 -Command Verify -Package $package.FullName
```

`-Local` derives the version from the checked-out commit as
`0.0.0-local+<12-character SHA>` and records the complete 40-character SHA plus
the source-tree dirty state in `metadata.json`. It does not accept a caller
supplied version, release-tag provenance, signing certificate, or trusted
publisher pin. Verification performs the ordinary complete manifest and provider
checks, then prints `LOCAL UNSIGNED` and the exact source SHA.

Local metadata is deliberately unmistakable:

- `packageKind` is `local-development`
- `signing` is `UNSIGNED LOCAL DEVELOPMENT PACKAGE (not code signed)`
- `sourceProvenance.kind` is `local`
- `sourceProvenance.sourceCommit` is the exact 40-character `HEAD` SHA
- `sourceProvenance.sourceTreeDirty` reports whether tracked or untracked
  checkout changes were present

No supported publication route accepts this metadata. `release.ps1` requires
`release-candidate` / `release-tag` provenance and refuses a local package before
any GitHub upload.

## Candidate source custody

A Git bundle contains Git objects but not Git LFS media. Do not use a bare
`GraphCode-source.bundle` as an offline handoff: cloning it can make Git LFS
treat the bundle file as a standalone-file remote, and disabling smudging does
not produce the required materialized clean checkout.

Create and verify the source custody ZIP separately from the product package:

```powershell
pwsh -NoProfile -File Tools\windows\source-custody.ps1 -Command Create `
  -Repository . -Candidate <candidate-sha> -Tag <approved-tag> `
  -Artifact .\GraphCode-source-custody.zip
pwsh -NoProfile -File Tools\windows\source-custody.ps1 -Command Verify `
  -Artifact .\GraphCode-source-custody.zip
```

The deterministic ZIP contains the Git bundle, the exact LFS objects referenced
by the candidate tree, an integrity manifest, and
`Restore-GraphCodeSource.ps1`. Restore first checks out LFS pointers with
smudging disabled, copies the verified media into local LFS storage, and runs
`git lfs checkout`, which does not download. It then requires the detached
`HEAD`, peeled annotated tag, materialized LFS set, and empty
`git status --short` to match the manifest.

After the handoff hash is verified, restore without network access:

```powershell
Expand-Archive -LiteralPath .\GraphCode-source-custody.zip `
  -DestinationPath .\GraphCode-source-custody
powershell.exe -NoProfile `
  -File .\GraphCode-source-custody\Restore-GraphCodeSource.ps1 `
  -Command Restore -ArtifactRoot .\GraphCode-source-custody `
  -Destination C:\GraphCode-Evidence\source
```

This artifact is source/evidence custody only. Regenerating it does not rebuild
or alter the candidate product ZIP, commit, or tag.

The ZIP contains one top-level `GraphCode` directory. Installation verifies the
complete manifest and provider provenance before copying anything, then stages
and swaps atomically. The scheduled task is created and run; the exact installed
daemon endpoint must become reachable or the previous installation is restored.
The daemon's actual `%USERPROFILE%\.graphcode` data directory is preserved by
uninstall unless `-RemoveUserData` is explicitly requested.

Unsigned artifacts are explicitly marked `UNSIGNED (not code signed)` in
`metadata.json` and `SIGNING.txt`. This is also the current Windows release
format. Their checksums detect corruption, not publisher authenticity. They
remain accepted unless `-TrustedSignerThumbprint` is supplied.

Local development artifacts use the stronger
`UNSIGNED LOCAL DEVELOPMENT PACKAGE (not code signed)` marker described above;
they are installable for local testing but are never release candidates.

## Standalone setup without a checkout

Extract the ZIP and use its `GraphCode\GraphCode-Setup.ps1`. The setup supports
Windows PowerShell 5.1 (the built-in `powershell.exe`) and PowerShell 7. It needs
neither this repository nor Git, Swift, Zig, the SDK, or a separate helper script.
It is a command-line PowerShell installer, not an MSI or graphical EXE installer.
The default command is non-mutating `Verify`; installation must be explicit.

For a locally built development package:

```powershell
$localPackage = Get-ChildItem .\GraphCode-0.0.0-local+*-windows-x86_64.zip |
  Select-Object -First 1
Expand-Archive -LiteralPath $localPackage.FullName `
  -DestinationPath .\extracted
powershell.exe -NoProfile -File .\extracted\GraphCode\GraphCode-Setup.ps1 `
  -Command Verify
powershell.exe -NoProfile -File .\extracted\GraphCode\GraphCode-Setup.ps1 `
  -Command Install
```

Optional signed packages can authenticate the setup script **before executing
it**, as shown under Signed setup bootstrap below. A script cannot establish its
own authenticity after it has already started running.

The default install root is `%LOCALAPPDATA%\GraphCode\current`. Setup creates
the per-user Start menu shortcut, user PATH entry, and current-user scheduled
daemon task using the same transaction as the repository tooling. Use the new
release's extracted setup with `-Command Upgrade` to replace an existing
installation. `-Package` can select another extracted package or a ZIP; without
it, setup verifies/installs its own directory. `-InstallRoot` supports custom
locations and must also be supplied when managing that custom installation.
`-NoScheduledTask` retains the explicit development/portable mode.

The daemon task has a logon trigger and a one-minute repeating trigger with
`MultipleInstancesPolicy` `IgnoreNew`, the Windows counterpart of launchd
`KeepAlive`: a tick is a no-op while the daemon runs and relaunches it within a
minute once it has stopped, and battery limits never refuse or kill it. (Task
Scheduler's restart-on-failure setting is deliberately not used; it fires only
when a task cannot launch, never when the launched process exits.) Upgrade and
Uninstall disable the task before ending it, so neither is fought by the
trigger; a refused Uninstall re-registers it. In the shell, `Ctrl+R` Reconnect
also starts the registered task (`schtasks /Run`, no elevation) when the daemon
endpoint is missing and no daemon is starting, and falls back to launching a
shell-owned daemon when no task is registered. The status line reports the outcome.

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
Close GraphCode and end its terminal sessions first: Uninstall refuses, without
changing anything, while processes run from the installation (see
[Uninstall with GraphCode still running](#uninstall-with-graphcode-still-running)).
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

## Uninstall with GraphCode still running

Uninstall removes the installation completely or changes nothing. Before
touching the daemon, scheduled task, PATH, or shortcut it lists every process
running from the installation root. Terminal session hosts (`zmx.exe`), the
shell, and the CLI are the user's live work, so Uninstall never kills them: it
refuses with exit code 1, names each process and PID, and explains how to end
the sessions (`<installed>\bin\zmx.exe ls`, then `zmx.exe kill <name>`) and to
rerun Uninstall from a terminal outside GraphCode. Only the installed daemon is
stopped automatically, as before.

After stopping the daemon, Uninstall re-checks for processes, confirms that
every installed file can be opened exclusively, and then renames the whole
installation root to a sibling `.GraphCode-uninstall-<id>` directory in one
step. Any failure up to and including the PATH and shortcut removal moves the
installation back, restores PATH and the shortcut, and restarts the daemon if
it was running. Only after the integration is gone is the renamed directory
deleted; if a file is opened in that brief window, Uninstall still succeeds and
warns with the leftover directory to delete. User data is preserved by default
in every outcome.

`Packaging.Uninstall.Tests.ps1` reproduces a live session host launched from
the installed `bin\zmx.exe`, a runtime DLL held open by another process, a
failed task removal after the rename, and a clean uninstall. It models the
scheduler and user PATH; the real-product packaging gate exercises the real
scheduled-daemon uninstall.

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

If a downstream build opts into Authenticode, use a trusted RFC 3161 timestamp
service via `-SignTimestampUrl`. Certificate provisioning and publisher-pin
distribution/rotation are not GraphCode Windows release prerequisites. The
bundled setup does not enable automatic download/install/relaunch in the native
updater.
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
HRESULT without suppressing account or permission errors. It also registers the
generated daemon task under an owned name with its action swapped for a harmless
command, and proves on the real scheduler that the repeating trigger relaunches
an action that has exited and that `Stop-InstalledDaemon` disables the task so an
explicit stop is not undone (this part waits about two minutes).

## Publishing a Windows release

`Tools/windows/release.ps1` is the only supported path from `package.ps1` to a
GitHub release asset, and `.github/workflows/windows-release.yml` is the only
thing that runs it in CI.

Like the macOS DMG — which a maintainer builds locally with `make release-dmg`
and attaches with `gh release create` — Windows publication is deliberately
manual. The workflow has a single `workflow_dispatch` trigger and never fires on
a tag push or on a published release. Its inputs are the existing release `tag`,
and `publish` (default `false`). The built artifact is always uploaded as a
workflow artifact, so a build can be inspected without touching any release.

```powershell
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag v1.2.3
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag v1.2.3 -Publish
```

The tag supplies the package version (`v1.2.3` and `1.2.3-beta1` are accepted;
`dev` versions and anything that is not a release version are refused before
anything is built). The workflow checks out that tag before staging or building.
`release.ps1` independently peels the tag to a commit and compares it with
`HEAD`; a mismatch is refused before packaging, including when `-Publish` is
absent, because the workflow artifact is itself a durable release object.

For qualification of release packaging changes against an existing release tag,
the deliberate `-AllowTagMismatch` switch permits an unpublished
**release-candidate** package:

```powershell
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag v1.2.3 -AllowTagMismatch
```

The package records the requested tag, peeled tag commit, actual source commit,
failed match, and explicit mismatch allowance in its own `metadata.json` before
the manifest and ZIP are created. `-AllowTagMismatch` can never be combined
with `-Publish`. It is not the developer local-package route; use
`package.ps1 -Command Build -Local` when the artifact should identify itself as
local rather than as a mismatched release candidate.

After the provenance gate, `release.ps1` builds through `package.ps1`, re-runs
`package.ps1 -Command Verify`, reads the built package's own `metadata.json`,
and **refuses to continue unless the package reports both the supplied source
provenance and the standard unsigned release state**.

Locally, `Tools\windows\stage-swift-products.ps1` produces the Swift half of the
release inputs (`graphcoded.exe`, `graphcode.exe`, and the Swift runtime DLLs in
`.build\windows\release`); `package.ps1` builds the versioned shell itself from
the pinned providers.

### Asset names

The release asset is `graphcode-windows-x86_64.zip` with a `.sha256` sidecar,
matching the versionless macOS asset convention so
`releases/latest/download/graphcode-windows-x86_64.zip` resolves. The package's
`metadata.json` and `SIGNING.txt` continue to say explicitly that it is unsigned.
`metadata.json` also carries the source provenance described above; it is part
of the package manifest rather than a workflow-log-only claim.

Low-level `package.ps1` support for `-SignCertificate`,
`-SignTimestampUrl`, and `-TrustedSignerThumbprint` remains available for
downstream or future use and is covered by the signing-specific packaging tests.
The release workflow deliberately does not consume certificate secrets or make
signing a publication requirement.

`Release.Tests.ps1` covers tag resolution, standard asset naming, honest unsigned
metadata, direct publication, unexpected signing-state rejection, build/upload
failure propagation, and the workflow's own triggers, action pinning, and
parameter binding. It runs first under `validate.ps1 -Task packaging` and needs
no certificate, network access, or real build.

## Retained provider sources

The current accepted public provider commits are:

| Provider | Pinned commit | Retained branch |
|---|---|---|
| [coneilen/winghostty](https://github.com/coneilen/winghostty/commit/6286560d0aa3103e068b2b7afa81eac373d870c9) | `6286560d0aa3103e068b2b7afa81eac373d870c9` | `main` |
| [coneilen/zmx](https://github.com/coneilen/zmx/commit/785b3fd15dcafd1882b495c831a10f98c201b908) | `785b3fd15dcafd1882b495c831a10f98c201b908` | `graphcode-quickchat-hang` |

The annotated `graphcode-windows-baseline-2026-09-17` tags remain historical
source-retention references:
[Winghostty's baseline](https://github.com/coneilen/winghostty/tree/graphcode-windows-baseline-2026-09-17)
preserves `f5abc059e4ca58b376eb209313aca7784659c679`, and
[zmx's baseline](https://github.com/coneilen/zmx/tree/graphcode-windows-baseline-2026-09-17)
preserves `029e11d2b19162fb3bdf90c8270237d303b8bfb4`, not the current zmx pin.
The current zmx commit adopts the named-pipe accept-deadline race fix merged in
[coneilen/zmx#4](https://github.com/coneilen/zmx/pull/4).

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
`ProviderPins.Tests.ps1` proves drift in either file is rejected, as are matching
copies of the old zmx pin or the reviewed feature head instead of the merged
commit. JSON property order and explanatory fallback wording are immaterial.
Run it directly or through `validate.ps1 -Task terminal-gate`.
