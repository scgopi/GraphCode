# Compiled host root contracts

`GraphCode.Validation.Host.RootContracts.SuiteRegistration.CreateSuites()` supplies
exactly six mandatory `IValidationSuite` implementations. The host owner registers
this method and merges `manifest-fragment.json` into the existing host manifest;
do not load the fragment as a fourth manifest or register the units twice.

The five PowerShell payloads run through the host's public `CaseScriptSuite`,
which supplies owned-child supervision, isolated TEMP/TMP, raw stream capture and
cleanup/retention authority. They independently exercise actual production
functions or scripts. AST extraction is restricted to production functions;
no part of the old monolithic test program is loaded or executed. Aggregate and
section-manifest scripts are invoked within that supervised payload, not through
unowned nested native processes. No provider, product, UI or Zig executable is
launched by these six families.

The C# source contracts use typed predicates, with explicit positive and negative
controls. They preserve the original workflow scheduling, required job names,
partitioning, source observations and measured timeout headroom. New execution
guards require the normal full compiled entry, exact SDK, nested build working
directory, complete coverage with positive equal required/passed counts, exit
zero and exactly one of each terminal success marker. They intentionally reject
the old PowerShell entry; a pre-cutover workflow is a real source-contract failure.
These source observations are not evidence that GitHub Actions executed.

`source-correspondence.json` identifies every expanded case and its frozen source
condition. The manifest inventory is not counted as execution. Adapter case JSON
under the requested artifact root records individual pass/fail results. Successful
unit groups must match the runtime case inventory exactly, including positive
counts; missing, extra or duplicate successful adapter groups fail closed.

Build from `Tools\windows\ValidationRunner` so `global.json` selects SDK 10.0.403:

```powershell
Push-Location Tools\windows\ValidationRunner
dotnet build -c Release
Pop-Location
```

For focused development before the host registration lands:

```powershell
$artifacts = Join-Path $PWD '.build\root-contracts'
New-Item -ItemType Directory -Force $artifacts | Out-Null
pwsh -NoLogo -NoProfile -File Tools\windows\ValidationRunner\Host\CiContracts\Focused.ps1 `
  -RepositoryRoot $PWD.Path -ArtifactRoot $artifacts `
  -AssemblyPath (Join-Path $PWD 'Tools\windows\ValidationRunner\bin\Release\net10.0-windows\ValidationRunner.dll')
```

`-Suite` selects one of the six IDs for local diagnostics only. This focused
entry reports only those suites and never emits the full-host PASS marker.
Canonical CI must use the normal compiled EXE, without a suite selector.

Local implementation evidence used PowerShell 7.6.9 on .NET 10, not PowerShell
7.4. The first no-restore build failed because project assets were absent;
restore then exposed missing `System.IO` imports. Those compile failures are
not behavioral RED evidence. The first focused run exposed two CRLF-sensitive
negative-control fixtures; normalizing those fixtures fixed them. Subsequent
focused execution passed the five behavioral families and all topology controls,
while four topology observations correctly remained RED against the legacy
workflow/wrapper before the host owner's cutover. No full coverage or CI success
is claimed by that partial result.

After the four-file CI/caller lease was transferred to this lane, the actual
workflow and wrapper cutover made all 35 topology cases pass. The six families
plus the deduplicated residual suite then executed **143/143 passing cases**;
the standalone topology script passed 24 checks and the integrated host passed
61 self-tests. The initial topology-only focused invocation exposed a lazy
binding-load error in the harness's exit barrier after its 35 cases had passed.
Explicitly loading the real Windows bindings fixed that harness error without
replacing or weakening the retained-authority barrier. These focused results
remain distinct from the integration owner's normal full-host run and from
hosted CI, neither of which this lane ran.
