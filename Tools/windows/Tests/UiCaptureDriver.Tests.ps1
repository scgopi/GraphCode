param(
    [string]$ScratchRoot = (Join-Path ([IO.Path]::GetTempPath()) ('gc-capture-' + [guid]::NewGuid().ToString('N'))),
    [switch]$LaunchContractOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$driverDirectory = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $driverDirectory 'UiCaptureDriver.psm1'
$supervisorPath = Join-Path $driverDirectory 'Invoke-UiCapture.ps1'
$workerPath = Join-Path $driverDirectory 'Invoke-UiCaptureWorker.ps1'
$mode = 'NO_DESKTOP_REAL_LAUNCH_REHEARSAL'
$results = [Collections.Generic.List[object]]::new()
$scratch = [IO.Path]::GetFullPath($ScratchRoot)
if (Test-Path -LiteralPath $scratch) { throw "Refusing to replace capture test evidence: $scratch" }
$null = New-Item -ItemType Directory -Path $scratch
$sourceHashesBefore = [ordered]@{}
foreach ($path in @($modulePath, $supervisorPath, $workerPath, $PSCommandPath)) {
    $sourceHashesBefore[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Set-CapTracePath -Path (Join-Path $scratch 'test-calls.jsonl')

function Assert-CapTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-CapTest {
    param([string]$Name, [scriptblock]$Action)
    try {
        $detail = & $Action
        $results.Add([ordered]@{ name = $Name; passed = $true; detail = $detail })
        Write-Host "PASS $Name"
    } catch {
        $results.Add([ordered]@{ name = $Name; passed = $false; error = $_.Exception.ToString(); stack = $_.ScriptStackTrace })
        Write-Host "FAIL $Name`: $($_.Exception.Message)"
    }
}

function Assert-CapRejects {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action | Out-Null }
    catch {
        Assert-CapTest ($_.Exception.Message.Contains($Expected)) "Wrong refusal: $($_.Exception.Message)"
        return $_.Exception.Message
    }
    throw "Expected refusal containing '$Expected'."
}

function Invoke-CapBoundedChild {
    param([string]$FilePath, [string[]]$Arguments, [string]$Directory, [string]$Role, [int]$Seconds = 45,
        [hashtable]$Environment = @{})
    $run = Start-CapManagedProcess -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory $Directory -Role $Role -Environment $Environment
    try {
        $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds($Seconds))
        if ($wait.State -ne 'Exited') { throw "Test child timed out: $Role" }
        Assert-CapTest ($run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) "Test child EOF missing: $Role"
        return [pscustomobject]@{
            exitCode = $wait.ExitCode; stdout = [string]$run.StdoutTask.Result; stderr = [string]$run.StderrTask.Result
            pid = $run.Identity.Pid; creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
            executable = $run.Identity.ExpectedImagePath; kernelExited = [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)
            stdinRedirected = $run.StartInfo.RedirectStandardInput
        }
    } finally {
        if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
            $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
        }
        $run.Identity.Process.Dispose()
    }
}

function New-CapHarmlessTarget {
    $fixture = Join-Path $scratch 'fixture'
    $null = New-Item -ItemType Directory -Path $fixture
    # This source is the entire target: no GUI, descendants, backend, network, or user data.
    $source = @'
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
static int cap_run_directory(const wchar_t *output, wchar_t *run, size_t capacity) {
    wchar_t pattern[1040];
    WIN32_FIND_DATAW data;
    HANDLE handle;
    int found = 0;
    if (swprintf_s(pattern, 1040, L"%ls\\..\\runs\\*", output) < 0) return 0;
    handle = FindFirstFileW(pattern, &data);
    if (handle == INVALID_HANDLE_VALUE) return 0;
    do {
        if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
            wcscmp(data.cFileName, L".") != 0 && wcscmp(data.cFileName, L"..") != 0) {
            found = swprintf_s(run, capacity, L"%ls\\..\\runs\\%ls", output, data.cFileName) >= 0;
            break;
        }
    } while (FindNextFileW(handle, &data));
    FindClose(handle);
    return found;
}
static int cap_highest_snapshot(const wchar_t *run) {
    wchar_t pattern[1040];
    WIN32_FIND_DATAW data;
    HANDLE handle;
    int highest = 0, value = 0;
    if (swprintf_s(pattern, 1040, L"%ls\\process-journal.*.json", run) < 0) return -1;
    handle = FindFirstFileW(pattern, &data);
    if (handle == INVALID_HANDLE_VALUE) return 0;
    do {
        if (swscanf_s(data.cFileName, L"process-journal.%d.json", &value) == 1 && value > highest) highest = value;
    } while (FindNextFileW(handle, &data));
    FindClose(handle);
    return highest;
}
static int cap_plant_file(const wchar_t *path, const char *text) {
    DWORD written = 0;
    DWORD length = (DWORD)strlen(text);
    BOOL ok;
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(file, text, length, &written, NULL);
    CloseHandle(file);
    return ok && written == length;
}
static int cap_journal_sabotage(const wchar_t *mode) {
    wchar_t output[1040] = {0}, run[1040] = {0}, journal[1100] = {0};
    int highest = 0, attempt;
    if (GetEnvironmentVariableW(L"CAP_REHEARSAL_OUTPUT", output, 1040) == 0) return 90;
    if (!cap_run_directory(output, run, 1040)) return 91;
    /* The worker publishes its first snapshot after this process starts; wait for that real event. */
    for (attempt = 0; attempt < 2000 && highest < 1; ++attempt) {
        highest = cap_highest_snapshot(run);
        if (highest < 1) Sleep(10);
    }
    if (highest < 1) return 94;
    if (wcscmp(mode, L"journal-readonly-snapshot") == 0) {
        if (swprintf_s(journal, 1100, L"%ls\\process-journal.1.json", run) < 0) return 92;
        return SetFileAttributesW(journal, FILE_ATTRIBUTE_READONLY) ? 0 : 93;
    }
    if (swprintf_s(journal, 1100, L"%ls\\process-journal.%d.json", run,
        wcscmp(mode, L"journal-corrupt-highest") == 0 ? 9999 : highest + 1) < 0) return 95;
    return cap_plant_file(journal, "{\"corrupt\":") ? 0 : 96;
}
int wmain(int argc, wchar_t **argv) {
    char behavior[64] = {0};
    wchar_t output[32768] = {0}, path[32768] = {0};
    int i, c;
    GetEnvironmentVariableA("CAP_REHEARSAL_BEHAVIOR", behavior, 64);
    puts("CAP_READY");
    printf("CAP_ARGC:%d\n", argc - 1);
    for (i = 1; i < argc; ++i) {
        size_t j;
        printf("CAP_ARG_%d:", i - 1);
        for (j = 0; argv[i][j] != 0; ++j) printf("%04X", (unsigned int)argv[i][j]);
        puts("");
    }
    fflush(stdout);
    while ((c = getchar()) != EOF) { (void)c; }
    puts("CAP_STDIN_EOF");
    fputs("CAP_STDERR_EOF\n", stderr);
    fflush(stdout); fflush(stderr);
    if (argc > 1 && (wcscmp(argv[1], L"journal-corrupt-highest") == 0 ||
        wcscmp(argv[1], L"journal-plant-collision") == 0 || wcscmp(argv[1], L"journal-readonly-snapshot") == 0)) {
        return cap_journal_sabotage(argv[1]);
    }
    if (strcmp(behavior, "trace-readonly") == 0) {
        if (GetEnvironmentVariableW(L"CAP_REHEARSAL_OUTPUT", output, 32768) == 0) return 96;
        if (swprintf_s(path, 32768, L"%ls\\supervisor-calls.jsonl", output) < 0) return 97;
        if (!SetFileAttributesW(path, FILE_ATTRIBUTE_READONLY)) return 98;
        return 23;
    }
    if (strcmp(behavior, "primary-cleanup") == 0 || strcmp(behavior, "receipt-block") == 0) {
        if (GetEnvironmentVariableW(L"CAP_REHEARSAL_OUTPUT", output, 32768) == 0) return 93;
        if (swprintf_s(path, 32768, L"%ls\\%ls", output,
            strcmp(behavior, "receipt-block") == 0 ? L"lease-release.json" : L"supervisor-worker-stdout.log") < 0) return 94;
        if (!CreateDirectoryW(path, NULL)) return 95;
        return 23;
    }
    if (strcmp(behavior, "timeout") == 0) Sleep(30000);
    return strcmp(behavior, "nonzero") == 0 ? 23 : 0;
}
'@
    $sourcePath = Join-Path $fixture 'capture-target.c'
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Existing MSVC discovery is unavailable; this offline suite does not install a compiler.'
    }
    $discovery = Invoke-CapBoundedChild -FilePath $vswhere -Arguments @(
        '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'
    ) -Directory $fixture -Role 'fixture-compiler-discovery'
    Assert-CapTest ($discovery.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($discovery.stdout)) 'Existing MSVC was not found.'
    $installation = $discovery.stdout.Trim()
    $vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
    $version = [IO.File]::ReadAllText((Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
    $compiler = Join-Path $installation "VC\Tools\MSVC\$version\bin\Hostx64\x64\cl.exe"
    $exe = Join-Path $fixture 'capture-target.exe'
    $command = 'call "{0}" -vcvars_ver={1} >nul && "{2}" /nologo /W4 /WX /O2 /utf-8 /Fe:"{3}" "{4}" /link /SUBSYSTEM:CONSOLE' -f $vcvars, $version, $compiler, $exe, $sourcePath
    [IO.File]::WriteAllText((Join-Path $fixture 'compile.cmd'), "@echo off`r`n$command`r`nexit /b %errorlevel%`r`n", [Text.UTF8Encoding]::new($false))
    $compilerEnvironment = @{ PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH }
    foreach ($key in @('VSCMD_VER', '__VSCMD_PREINIT_PATH', 'VSINSTALLDIR', 'VCINSTALLDIR',
        'VCToolsInstallDir', 'VCToolsVersion', 'WindowsSdkDir', 'WindowsSDKVersion', 'INCLUDE', 'LIB', 'LIBPATH')) {
        $compilerEnvironment[$key] = ''
    }
    $build = Invoke-CapBoundedChild -FilePath $env:ComSpec -Arguments @('/d', '/c', '.\compile.cmd') `
        -Directory $fixture -Role 'harmless-fixture-compile' -Seconds 90 -Environment $compilerEnvironment
    [IO.File]::WriteAllText((Join-Path $fixture 'compiler-stdout.log'), $build.stdout)
    [IO.File]::WriteAllText((Join-Path $fixture 'compiler-stderr.log'), $build.stderr)
    Assert-CapTest ($build.exitCode -eq 0 -and (Test-Path -LiteralPath $exe -PathType Leaf)) `
        "Harmless target compilation failed (not launch evidence): $($build.stdout) $($build.stderr)"
    $provenance = [ordered]@{
        compiler = $compiler; compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
        compilerSha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
        compilerCommand = $command; compilerExitCode = $build.exitCode
        source = $sourcePath; sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        executable = $exe; executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    }
    $provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'provenance.json') -Encoding utf8NoBOM
    return [pscustomobject]$provenance
}

function Invoke-CapCaptureCommand {
    param(
        [string]$Name,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [string]$Behavior = 'normal',
        [string]$LeaseMutation = '',
        [string]$AdmissionMutation = ''
    )
    $owned = Join-Path $scratch "cases\$Name"
    $null = New-Item -ItemType Directory -Path $owned
    $exe = Join-Path $owned 'harmless-target.exe'
    Copy-Item -LiteralPath $target.executable -Destination $exe
    $jobPath = Join-Path $owned 'job.json'
    $leasePath = Join-Path $owned 'lease.json'
    $output = Join-Path $owned 'output'
    $job = [ordered]@{
        executionMode = $mode; desktopAuthorized = $false; lane = 'B'
        head = 'OFFLINE_FIXTURE_NOT_PRODUCT'; base = 'OFFLINE_FIXTURE_NOT_PRODUCT'
        rehearsalTarget = [ordered]@{ path = $exe; sha256 = $target.executableSha256
            arguments = @($Arguments); behavior = $Behavior; timeoutMilliseconds = 1000 }
    }
    if ($AdmissionMutation) { $job = New-CapAdmissionJob -Owned $owned -Job $job -Mutation $AdmissionMutation }
    $job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jobPath -Encoding utf8NoBOM
    $jobHash = (Get-FileHash -LiteralPath $jobPath -Algorithm SHA256).Hash
    $now = [DateTime]::UtcNow
    $lease = [ordered]@{
        schemaVersion = 1; leaseId = [guid]::NewGuid().ToString(); lane = 'B'
        status = 'REHEARSAL_ONLY'; authorizedAction = 'no-desktop-real-launch-rehearsal'; desktopAuthorized = $false
        head = $job.head; jobManifestSha256 = $jobHash
        moduleSha256 = $sourceHashesBefore[$modulePath]; workerSha256 = $sourceHashesBefore[$workerPath]
        supervisorSha256 = $sourceHashesBefore[$supervisorPath]; preflightReceiptSha256 = $null
        grantedUtc = $now.AddSeconds(-1).ToString('o'); expiresUtc = $now.AddMinutes(5).ToString('o'); maxMinutes = 15
    }
    if ($AdmissionMutation) {
        $lease.lane = $job.lane
        $lease.base = $job.base
        $lease.reviewedHead = $job.admission.reviewedHead
        $lease.reviewAcceptanceSha256 = $job.admission.reviewAcceptance.sha256
        $lease.equivalenceSha256 = $job.admission.equivalence.sha256
        $lease.ciInventorySha256 = $job.admission.ci.sha256
        $lease.ciRuns = $job.admission.ci.runs
        foreach ($phase in @('before', 'after')) {
            $lease["${phase}BuildReceiptSha256"] = $job.binaries[$phase].buildReceipt.sha256
            $lease["${phase}BinarySha256"] = $job.binaries[$phase].sha256
        }
        if ($AdmissionMutation -eq 'lease-base') { $lease.base = '0' * 40 }
    }
    switch ($LeaseMutation) {
        'expired' { $lease.grantedUtc = $now.AddMinutes(-6).ToString('o'); $lease.expiresUtc = $now.AddSeconds(-1).ToString('o') }
        'future' { $lease.grantedUtc = $now.AddMinutes(1).ToString('o') }
        'over-15' { $lease.expiresUtc = $now.AddMinutes(16).ToString('o') }
        'missing-offset' { $lease.grantedUtc = $now.AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ss') }
        'traversal-id' { $lease.leaseId = '..\foreign-output' }
        'hash' { $lease.moduleSha256 = '0' * 64 }
    }
    $lease | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $leasePath -Encoding utf8NoBOM
    if ($LeaseMutation -eq 'malformed') { [IO.File]::WriteAllText($leasePath, '{"leaseId":"..\foreign","outputDirectory":"C:\foreign"') }
    $leaseHash = (Get-FileHash -LiteralPath $leasePath -Algorithm SHA256).Hash
    $argumentsToSupervisor = @(
        '-NoProfile', '-File', $supervisorPath, '-OwnedRoot', $owned, '-OutputDirectory', $output,
        '-ExecutionMode', $mode, '-JobPath', $jobPath, '-JobSha256', $jobHash,
        '-LeaseReceiptPath', $leasePath, '-LeaseReceiptSha256', $leaseHash
    )
    $argumentsToSupervisor | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $owned 'command-arguments.json') -Encoding utf8NoBOM
    $child = Invoke-CapBoundedChild -FilePath (Join-Path $PSHOME 'pwsh.exe') -Arguments $argumentsToSupervisor `
        -Directory $owned -Role "rehearsal-supervisor-$Name"
    [IO.File]::WriteAllText((Join-Path $owned 'command-stdout.log'), $child.stdout)
    [IO.File]::WriteAllText((Join-Path $owned 'command-stderr.log'), $child.stderr)
    $receiptPath = Join-Path $output 'lease-release.json'
    $receipt = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -DateKind String
    } else { $null }
    return [pscustomobject]@{
        name = $Name; child = $child; owned = $owned; output = $output; receipt = $receipt
        receiptPath = $receiptPath; commandArguments = $argumentsToSupervisor
        receiptSha256 = if ($receipt) { (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash } else { $null }
        leaseSha256 = $leaseHash
    }
}

function Write-CapTestArtifact {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
    return [ordered]@{ path = $Path; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Invoke-CapTestGit {
    param([string]$Repository, [string[]]$Arguments)
    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Offline fixture Git failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function New-CapAdmissionJob {
    param([string]$Owned, $Job, [string]$Mutation)
    $repository = Join-Path $Owned 'source-repository'
    $null = New-Item -ItemType Directory -Path $repository
    $null = Invoke-CapTestGit $repository @('init', '--quiet')
    $null = Invoke-CapTestGit $repository @('config', 'user.name', 'Offline capture fixture')
    $null = Invoke-CapTestGit $repository @('config', 'user.email', 'fixture@example.invalid')
    $null = Invoke-CapTestGit $repository @('config', 'core.autocrlf', 'false')
    $null = New-Item -ItemType Directory -Path (Join-Path $repository 'graphcode-windows')
    [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'before')
    $null = Invoke-CapTestGit $repository @('add', '.')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-m', 'Offline before')
    $base = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'reviewed after')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-am', 'Offline reviewed product')
    $reviewed = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    $null = New-Item -ItemType Directory -Path (Join-Path $repository 'Tools\windows') -Force
    [IO.File]::WriteAllText((Join-Path $repository 'Tools\windows\Invoke-UiCapture.ps1'), '# Offline tooling-only delta')
    if ($Mutation -in @('product-diff', 'omitted-product-diff')) {
        [IO.File]::WriteAllText((Join-Path $repository 'graphcode-windows\product.txt'), 'UNREVIEWED product')
    }
    $null = Invoke-CapTestGit $repository @('add', '.')
    $null = Invoke-CapTestGit $repository @('commit', '--quiet', '-m', 'Offline candidate')
    $head = [string](Invoke-CapTestGit $repository @('rev-parse', 'HEAD'))
    if ($Mutation -eq 'unrelated-base') {
        $tree = [string](Invoke-CapTestGit $repository @('rev-parse', "$base`^{tree}"))
        $base = [string](Invoke-CapTestGit $repository @('commit-tree', $tree, '-m', 'Offline unrelated base'))
    }
    $Job.head = $head
    $Job.base = $base
    if ($Mutation -eq 'lane-d') { $Job.lane = 'D' }
    $Job.sourceRepository = $repository
    $Job.binaries = [ordered]@{}
    $buildInput = Join-Path $Owned 'build-input.c'
    Copy-Item -LiteralPath $target.source -Destination $buildInput
    foreach ($phase in @('before', 'after')) {
        $commit = if ($phase -eq 'before') { $base } else { $head }
        $archive = Join-Path $Owned "$phase.zip"
        $sourceRoot = Join-Path $Owned "source-$phase"
        $null = Invoke-CapTestGit $repository @('archive', '--format=zip', "--output=$archive", $commit)
        Expand-Archive -LiteralPath $archive -DestinationPath $sourceRoot
        $logPath = Join-Path $Owned "$phase-build.log"
        [IO.File]::WriteAllText($logPath, 'OFFLINE_TEST_DATA: no product build was performed.')
        $binary = Join-Path $Owned "$phase.exe"
        Copy-Item -LiteralPath $target.executable -Destination $binary
        [IO.File]::AppendAllText($binary, "OFFLINE_DATA_ONLY_PHASE_$phase")
        $binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        $receipt = [ordered]@{
            schemaVersion = 1; evidenceMode = 'OFFLINE_TEST_DATA_NOT_PRODUCT_BUILD'
            sourceCommit = $commit; sourceTree = [string](Invoke-CapTestGit $repository @('rev-parse', "${commit}:graphcode-windows"))
            sourceRoot = Join-Path $sourceRoot 'graphcode-windows'; sourceSubdirectory = 'graphcode-windows'
            binaryBuiltAtSource = $commit
            archive = [ordered]@{ path = $archive; sha256 = (Get-FileHash $archive -Algorithm SHA256).Hash }
            log = [ordered]@{ path = $logPath; sha256 = (Get-FileHash $logPath -Algorithm SHA256).Hash }
            executablePath = $binary; executableSha256 = $binaryHash
            startedUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
            finishedUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            exitCode = 0; command = 'OFFLINE_TEST_DATA: existing harmless fixture, not a product build'
            inputs = @([ordered]@{ path = $buildInput; sha256 = $target.sourceSha256 })
        }
        $receipt.rawReceipt = Write-CapTestArtifact (Join-Path $Owned "$phase-raw-build.json") ([ordered]@{
            sourceSha = $commit; builtAtSha = $commit; sourceTree = $receipt.sourceTree
            sourceExportSha256 = $receipt.archive.sha256; executableSha256 = $receipt.executableSha256
            exitCode = 0; startedUtc = $receipt.startedUtc; finishedUtc = $receipt.finishedUtc; command = $receipt.command
        })
        if ($phase -eq 'after' -and $Mutation -eq 'null-build') { $receipt.sourceCommit = $null }
        if ($phase -eq 'after' -and $Mutation -eq 'stale-build') { $receipt.binaryBuiltAtSource = $base }
        $Job.binaries[$phase] = [ordered]@{
            path = $binary; sha256 = $binaryHash; source = $commit; binaryBuiltAtSource = $commit
            buildReceipt = Write-CapTestArtifact (Join-Path $Owned "$phase-build.json") $receipt
        }
    }
    $ci = [ordered]@{
        schemaVersion = 1; evidenceMode = 'OFFLINE_TEST_DATA_NOT_LIVE_CI'
        repository = 'scgopi/GraphCode'; head = $head
        observedUtc = [DateTime]::UtcNow.ToString('o')
        runs = @([ordered]@{
            id = 123; run_attempt = 1; head_sha = $head; status = 'completed'; conclusion = 'success'
            total_count = 1; jobs = @([ordered]@{
                id = 456; run_id = 123; head_sha = $head; name = 'Offline synthetic context'
                status = 'completed'; conclusion = 'success'; configuredSkip = $false
            })
        })
    }
    if ($Mutation -eq 'red-ci') {
        $ci.runs[0].conclusion = 'failure'
        $ci.runs[0].jobs[0].conclusion = 'failure'
    }
    if ($Mutation -eq 'ci-head') { $ci.runs[0].jobs[0].head_sha = $base }
    if ($Mutation -eq 'empty-ci') { $ci.runs[0].jobs = @(); $ci.runs[0].total_count = 0 }
    if ($Mutation -eq 'duplicate-ci') {
        $ci.runs[0].jobs = @($ci.runs[0].jobs[0], $ci.runs[0].jobs[0])
        $ci.runs[0].total_count = 2
    }
    if ($Mutation -eq 'source-bytes') { [IO.File]::AppendAllText((Join-Path $Owned 'source-after\graphcode-windows\product.txt'), 'DIRTY') }
    if ($Mutation -eq 'binary-hash') { [IO.File]::AppendAllText($Job.binaries.after.path, 'MISMATCH') }
    $Job.admission = [ordered]@{
        schemaVersion = 1; reviewedHead = $reviewed
        reviewAcceptance = Write-CapTestArtifact (Join-Path $Owned 'review.json') ([ordered]@{
            schemaVersion = 1; verdict = 'ACCEPT'; reviewedHead = $reviewed; reviewedBase = $base
            evidenceMode = 'OFFLINE_TEST_DATA_NOT_REVIEW'
        })
        equivalence = Write-CapTestArtifact (Join-Path $Owned 'equivalence.json') ([ordered]@{
            schemaVersion = 1; reviewedHead = $reviewed; head = $head; reviewedBase = $base; base = $base
            headDeltaPaths = @(Invoke-CapTestGit $repository @('diff', '--name-only', '--no-renames', $reviewed, $head))
            baseDeltaPaths = @()
        })
        ci = Write-CapTestArtifact (Join-Path $Owned 'ci.json') $ci
    }
    $Job.admission.ci.runs = @([ordered]@{ id = 123; attempt = 1 })
    if ($Mutation -eq 'omitted-product-diff') {
        $proofPath = $Job.admission.equivalence.path
        $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -DateKind String
        $proof.headDeltaPaths = @($proof.headDeltaPaths | Where-Object { $_ -cne 'graphcode-windows/product.txt' })
        $Job.admission.equivalence = Write-CapTestArtifact $proofPath $proof
    }
    if ($Mutation -eq 'phase-swap') {
        Assert-CapTest ($Job.binaries.before.sha256 -cne $Job.binaries.after.sha256) 'Phase fixture binary hashes must differ.'
        $before = [IO.File]::ReadAllBytes($Job.binaries.before.path)
        $after = [IO.File]::ReadAllBytes($Job.binaries.after.path)
        [IO.File]::WriteAllBytes($Job.binaries.before.path, $after)
        [IO.File]::WriteAllBytes($Job.binaries.after.path, $before)
    }
    if ($Mutation -eq 'duplicate-json') {
        $path = $Job.admission.ci.path
        [IO.File]::WriteAllText($path, [IO.File]::ReadAllText($path).Insert(1, "`"head`":`"$head`","))
        $Job.admission.ci.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return $Job
}

function Assert-CapRehearsalSuccess {
    param($Run, [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    Assert-CapTest ($Run.child.exitCode -eq 0 -and -not $Run.child.stdinRedirected) "Capture command failed or changed default stdin inheritance: $($Run.child.stderr)"
    Assert-CapTest ($null -ne $Run.receipt -and $Run.receipt.status -ceq 'RELEASED_ZERO_SURVIVORS' -and
        $Run.receipt.workerStarted -and $Run.receipt.workerStdoutEof -and $Run.receipt.workerStderrEof -and
        $Run.receipt.captures -eq 0 -and $Run.receipt.kernelVerifiedSurvivors.Count -eq 0 -and
        $Run.receipt.cleanupFailures.Count -eq 0 -and $null -eq $Run.receipt.primaryFailure) 'Release is not a proven successful no-desktop cleanup.'
    $manifest = Get-Content -LiteralPath (Join-Path $Run.output 'manifest.json') -Raw | ConvertFrom-Json -DateKind String
    Assert-CapTest ($manifest.executionMode -ceq $mode -and $manifest.rehearsalLaunches.Count -eq 1 -and
        $manifest.images.Count -eq 0 -and $manifest.guiLaunches.Count -eq 0 -and
        $manifest.rehearsalLaunches[0].argumentCount -eq $Arguments.Count -and
        $manifest.rehearsalLaunches[0].heldKernelHandle -gt 0 -and $manifest.rehearsalLaunches[0].ready) 'Real target launch record missing.'
    $stdout = [IO.File]::ReadAllText((Join-Path $Run.output 'rehearsal-target-stdout.log'))
    Assert-CapTest ($stdout -match "(?m)^CAP_ARGC:$($Arguments.Count)\r?$") 'Target received a different argument count.'
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $hex = (@($Arguments[$i].ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '')
        Assert-CapTest ($stdout -match "(?m)^CAP_ARG_${i}:$hex\r?$") "Target argument $i changed in real Process.Start."
    }
    $trace = @(Get-Content -LiteralPath (Join-Path $Run.output 'worker-calls.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    foreach ($name in @('Start-CapGraphCodeApp', 'Start-CapManagedProcess', 'Start-CapManagedProcessCore')) {
        Assert-CapTest (@($trace | Where-Object command -CEQ $name).Count -ge 1) "Actual launch callsite was not traced: $name"
    }
    Assert-CapTest (@($trace | Where-Object command -In @(
        'Find-CapTopLevelWindow', 'Find-CapAutomationElement', 'Invoke-CapAction',
        'Capture-CapWindow', 'Get-CapWindowMetrics', 'Set-CapWindowPosition'
    )).Count -eq 0) 'No-desktop rehearsal reached a GUI-only operation.'
    Assert-CapTest (@(Get-ChildItem -LiteralPath $Run.output -Filter '*.png' -File).Count -eq 0) 'Offline rehearsal created image files.'
    return [ordered]@{ commandExit = $Run.child.exitCode; release = $Run.receiptPath; releaseSha256 = $Run.receiptSha256
        targetArguments = @($Arguments); actualTargetLaunches = 1; images = 0; desktop = 'NotExecuted' }
}

$script:journalSelf = $null
$script:journalHighestSeen = 0
$journalSupervisorFunctions = @('Open-CapJournalRead', 'Test-CapFileNotFoundError', 'Get-CapJournalSnapshotList',
    'Read-CapJournalSnapshotBytes', 'Convert-CapJournalSnapshot', 'Read-CapJournalHighest', 'Refresh-CapJournal',
    'Assert-CapJournalTerminal', 'Add-CapTrackedIdentity')

function Get-CapActualFunctionText {
    param([string]$Path, [string[]]$Names)
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Path), [ref]$null, [ref]$null)
    $text = foreach ($name in $Names) {
        $function = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
        }, $true)
        if ($function) { $function.Extent.Text }
    }
    Assert-CapTest (@($text).Count -gt 0) "No actual journal function was found in $Path."
    return ($text -join [Environment]::NewLine)
}

function Set-CapJournalReaderContext {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    if (-not $script:journalSelf) {
        $script:journalSelf = Get-CapProcessIdentity -Process $self -ExpectedImagePath $self.MainModule.FileName `
            -Role 'journal-fixture-self'
    }
    Set-Variable -Scope 1 -Name lease -Value ([pscustomobject]@{ leaseId = [guid]::NewGuid().ToString() })
    Set-Variable -Scope 1 -Name jobHash -Value ('A' * 64)
    Set-Variable -Scope 1 -Name moduleHash -Value $sourceHashesBefore[$modulePath]
    Set-Variable -Scope 1 -Name workerHash -Value $sourceHashesBefore[$workerPath]
    Set-Variable -Scope 1 -Name tracked -Value ([Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase))
    Set-Variable -Scope 1 -Name untrackedJournalEntries -Value ([Collections.Generic.List[object]]::new())
    $script:journalHighestSeen = 0
}

function New-CapJournalFixtureDirectory {
    param([string]$Name)
    $directory = Join-Path $scratch "journal-fixtures\$Name"
    $null = New-Item -ItemType Directory -Path $directory
    return $directory
}

function Write-CapJournalFixtureSnapshot {
    param(
        [Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][int]$Sequence,
        [string]$Phase = 'fixture', [string]$PreviousSha256, [switch]$Terminal,
        [hashtable]$Override = @{}, [string[]]$Remove = @(), [string]$FileName, [string]$RawText
    )
    $name = if ($FileName) { $FileName } else { "process-journal.$Sequence.json" }
    $path = Join-Path $Directory $name
    if ($PSBoundParameters.ContainsKey('RawText')) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($RawText)
    } else {
        $self = $script:journalSelf
        $body = [ordered]@{
            schemaVersion = 1; sequence = $Sequence
            previousSha256 = $(if ($PreviousSha256) { $PreviousSha256 } else { $null }); terminal = [bool]$Terminal
            leaseId = $lease.leaseId; jobSha256 = $jobHash; workerSha256 = $workerHash; moduleSha256 = $moduleHash
            updatedUtc = [DateTime]::UtcNow.ToString('o')
            entries = @([ordered]@{
                role = 'journal-fixture-self'; phase = $Phase; pid = [int]$self.Pid
                creationFileTimeUtc = [long]$self.CreationFileTimeUtc; expectedImagePath = [string]$self.ExpectedImagePath
                expectedParentPid = [int]$self.ParentPid; expectedSessionId = [int]$self.SessionId
                windowHandle = 0; registeredUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
        if ($Terminal) { $body.ownedProcessSurvivors = @(); $body.pendingLaunchesRemaining = @(); $body.cleanupFailures = @() }
        foreach ($key in $Override.Keys) { $body[$key] = $Override[$key] }
        foreach ($key in $Remove) { $body.Remove($key) }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $body -Depth 40))
    }
    [IO.File]::WriteAllBytes($path, $bytes)
    return [pscustomobject]@{ Path = $path; Sequence = $Sequence
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}

function Write-CapJournalFixtureChain {
    param([string]$Directory, [int]$Count, [switch]$WithTerminal)
    $records = [Collections.Generic.List[object]]::new()
    $previous = $null
    for ($sequence = 1; $sequence -le $Count; $sequence++) {
        $record = Write-CapJournalFixtureSnapshot -Directory $Directory -Sequence $sequence -Phase "chain-$sequence" `
            -PreviousSha256 $previous -Terminal:($WithTerminal -and $sequence -eq $Count)
        $records.Add($record)
        $previous = $record.Sha256
    }
    return @($records)
}

function Get-CapUnwrappedException {
    param([Parameter(Mandatory)]$ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException -and $exception -isnot [IO.IOException]) { $exception = $exception.InnerException }
    return $exception
}

function Assert-CapJournalReleaseProof {
    param($Run, [string]$State)
    Assert-CapTest ($null -ne $Run.receipt -and $Run.receipt.PSObject.Properties['journal'] -and $null -ne $Run.receipt.journal) `
        'The official release carries no journal snapshot cleanup proof.'
    Assert-CapTest ($Run.receipt.journal.state -ceq $State) "Journal proof state was '$($Run.receipt.journal.state)', expected '$State'."
    return $Run.receipt.journal
}

$target = $null
try {
    $target = New-CapHarmlessTarget
    if (-not $LaunchContractOnly) {
        foreach ($mutation in @('accepted', 'lane-d', 'red-ci', 'binary-hash', 'product-diff',
            'ci-head', 'empty-ci', 'source-bytes', 'lease-base', 'duplicate-ci', 'duplicate-json', 'null-build', 'stale-build',
            'omitted-product-diff', 'phase-swap', 'unrelated-base')) {
            Invoke-CapTest "lease-bound admission $mutation through actual capture command" {
                $run = Invoke-CapCaptureCommand -Name "admission-$mutation" -AdmissionMutation $mutation
                if ($mutation -in @('accepted', 'lane-d')) {
                    $null = Assert-CapRehearsalSuccess -Run $run -Arguments @()
                    foreach ($component in @('supervisor', 'worker')) {
                        $trace = @(Get-Content (Join-Path $run.output "$component-calls.jsonl") |
                            ForEach-Object { $_ | ConvertFrom-Json })
                        Assert-CapTest (@($trace | Where-Object command -CEQ 'Assert-CapJobIdentity').Count -eq 1) `
                            "Lease-bound identity was not checked by the actual $component."
                    }
                } else {
                    $expected = switch ($mutation) {
                        'red-ci' { 'CI run is not exact-head completed success' }
                        'binary-hash' { 'binary hash mismatch' }
                        'product-diff' { 'Non-equivalent product/provider/build input diff' }
                        'ci-head' { 'CI context is not exact-head green' }
                        'empty-ci' { 'CI inventory must contain a positive complete context count' }
                        'source-bytes' { 'Fresh source bytes differ' }
                        'lease-base' { 'Lease-bound job identity differs' }
                        'duplicate-ci' { 'CI context is not exact-head green' }
                        'duplicate-json' { 'Duplicate JSON field' }
                        'null-build' { "field 'sourceCommit'" }
                        'stale-build' { 'Fresh build provenance must name the exact phase source' }
                        'omitted-product-diff' { 'Equivalence proof does not name the complete exact Git delta' }
                        'phase-swap' { 'before binary hash mismatch' }
                        'unrelated-base' { 'merge-base --is-ancestor' }
                    }
                    Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and
                        $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and -not $run.receipt.workerStarted -and
                        $run.receipt.primaryFailure.Contains($expected) -and
                        $run.receipt.leaseReceiptSha256 -ceq $run.leaseSha256 -and
                        $run.receipt.cleanupState -ceq 'NO_WORKER_STARTED') `
                        "Admission $mutation was not refused by the actual supervisor with its official release: $($run.child.stderr)"
                }
                return [ordered]@{ release = $run.receiptPath; sha256 = $run.receiptSha256
                    status = $run.receipt.status; exit = $run.child.exitCode
                    data = 'Synthetic CI/build/review controls; real Git, binaries, command, lease, worker and release; no product evidence' }
            }
        }
    }
    if (-not $LaunchContractOnly) {
        Invoke-CapTest 'unsupported C D E scene adapters refuse independently of generic identity' {
            foreach ($lane in @('C', 'D', 'E')) {
                $null = Assert-CapRejects {
                    Assert-CapSceneContract -Job ([pscustomobject]@{ lane = $lane; sceneAdapter = 'B_FIVE_SCENES_V1' })
                } 'Unsupported scene adapter'
            }
            return 'Pure scene-contract refusal; no scene, UI, product or adapter ran.'
        }
    }
    Invoke-CapTest 'real capture command with nonempty arguments' {
        $arguments = [string[]]@('alpha', 'two words', 'quote"inside', 'trailing\')
        $run = Invoke-CapCaptureCommand -Name 'nonempty' -Arguments $arguments
        Assert-CapRehearsalSuccess -Run $run -Arguments $arguments
    }
    Invoke-CapTest 'real capture command with genuine zero arguments' {
        $run = Invoke-CapCaptureCommand -Name 'empty' -Arguments @()
        Assert-CapRehearsalSuccess -Run $run -Arguments @()
    }
    if (-not $LaunchContractOnly) {
        Invoke-CapTest 'real argument vector preserves an empty string and Unicode' {
            $arguments = [string[]]@('', ('caf' + [char]0x00e9), 'x\"y', 'two trailing\\')
            $run = Invoke-CapCaptureCommand -Name 'argument-vector' -Arguments $arguments
            Assert-CapRehearsalSuccess -Run $run -Arguments $arguments
        }
        $fixedNow = [DateTimeOffset]::Parse('2026-10-14T21:30:00Z',
            [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        $window = $null
        Invoke-CapTest 'UTC Z and numeric offsets preserve exact lease instants and 90-second reserve' {
            $script:window = Get-CapLeaseWindow -GrantedUtc '2026-10-14T21:25:01Z' `
                -ExpiresUtc '2026-10-14T21:40:01Z' -MaximumMinutes 15 -NowUtc $fixedNow
            foreach ($offset in @(
                @('2026-10-15T04:25:01+07:00', '2026-10-15T04:40:01+07:00'),
                @('2026-10-14T14:25:01-07:00', '2026-10-14T14:40:01-07:00')
            )) {
                $other = Get-CapLeaseWindow -GrantedUtc $offset[0] -ExpiresUtc $offset[1] -MaximumMinutes 15 -NowUtc $fixedNow
                Assert-CapTest ($other.GrantedUtc -eq $window.GrantedUtc -and $other.ExpiresUtc -eq $window.ExpiresUtc) 'Offset changed UTC lease instants.'
            }
            $deadline = Get-CapAuthorizedWorkerDeadline -WorkerDeadlineUtc '2026-10-15T04:38:31+07:00' `
                -LeaseWindow $window -NowUtc $fixedNow
            Assert-CapTest ($window.DurationMinutes -eq 15 -and $deadline.Kind -eq [DateTimeKind]::Utc -and
                $deadline -eq $window.ExpiresUtc.AddSeconds(-90)) 'Exact cleanup reserve changed.'
            return [ordered]@{ fixedNow = $fixedNow.ToString('o'); durationMinutes = 15; reserveSeconds = 90 }
        }
        foreach ($mutation in @('expired-boundary', 'future-boundary', 'over-duration', 'over-allocation',
            'missing-offset', 'clock-kind', 'deadline-mismatch', 'deadline-expired')) {
            Invoke-CapTest "fixed UTC guard refuses $mutation" {
                $parameters = @{
                    GrantedUtc = '2026-10-14T21:25:01Z'; ExpiresUtc = '2026-10-14T21:40:01Z'
                    MaximumMinutes = 15; NowUtc = $fixedNow
                }
                $expected = 'Coordinator lease is expired'
                switch ($mutation) {
                    'expired-boundary' { $parameters.NowUtc = $window.ExpiresUtc }
                    'future-boundary' { $parameters.NowUtc = $window.GrantedUtc.AddSeconds(-1) }
                    'over-duration' { $parameters.ExpiresUtc = '2026-10-14T21:40:02Z' }
                    'over-allocation' { $parameters.MaximumMinutes = 16 }
                    'missing-offset' { $parameters.GrantedUtc = '2026-10-14T21:25:01'; $expected = 'explicit UTC marker' }
                    'clock-kind' { $parameters.NowUtc = [DateTime]::SpecifyKind($fixedNow, [DateTimeKind]::Unspecified); $expected = 'explicitly UTC' }
                    'deadline-mismatch' { $expected = 'does not match' }
                    'deadline-expired' { $expected = 'already expired' }
                }
                Assert-CapRejects {
                    if ($mutation -like 'deadline-*') {
                        $value = if ($mutation -eq 'deadline-mismatch') { '2026-10-14T21:38:32Z' } else { '2026-10-14T21:38:31Z' }
                        $clock = if ($mutation -eq 'deadline-expired') { $window.WorkerDeadlineUtc } else { $fixedNow }
                        Get-CapAuthorizedWorkerDeadline -WorkerDeadlineUtc $value -LeaseWindow $window -NowUtc $clock
                    } else { Get-CapLeaseWindow @parameters }
                } $expected
            }
        }
        foreach ($mutation in @('malformed', 'expired', 'future', 'over-15', 'missing-offset', 'traversal-id', 'hash')) {
            Invoke-CapTest "same capture command refuses $mutation lease and writes release" {
                $run = Invoke-CapCaptureCommand -Name "lease-$mutation" -LeaseMutation $mutation
                Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and
                    $run.receipt.status -ceq 'REFUSED_NO_WORKER' -and -not $run.receipt.workerStarted -and
                    -not [string]::IsNullOrWhiteSpace($run.receipt.primaryFailure) -and
                    $run.receipt.leaseReceiptSha256 -ceq $run.leaseSha256 -and
                    $run.receipt.cleanupState -ceq 'NO_WORKER_STARTED') 'Invalid lease did not fail closed with an actual release file.'
                return [ordered]@{ exit = $run.child.exitCode; release = $run.receiptPath
                    sha256 = $run.receiptSha256; status = $run.receipt.status; primary = $run.receipt.primaryFailure }
            }
        }
        foreach ($behavior in @('nonzero', 'timeout', 'primary-cleanup', 'receipt-block', 'trace-readonly')) {
            Invoke-CapTest "same capture command handles target $behavior" {
                $run = Invoke-CapCaptureCommand -Name $behavior -Behavior $behavior
                Assert-CapTest ($run.child.exitCode -ne 0) 'Target failure became successful capture.'
                if ($behavior -eq 'receipt-block') {
                    Assert-CapTest ($null -eq $run.receipt -and $run.child.stderr.Contains('LEASE_RELEASE_WRITE_FAILED') -and
                        $run.child.stderr.Contains('Capture worker exited with code')) 'Receipt write failure or original worker failure was lost.'
                } else {
                    Assert-CapTest ($null -ne $run.receipt -and $null -ne $run.receipt.primaryFailure -and
                        ($behavior -eq 'trace-readonly' -or $run.receipt.workerPrimaryFailure.Count -gt 0) -and
                        $run.receipt.kernelVerifiedSurvivors.Count -eq 0 -and $run.receipt.workerStderrEof) 'Failure/release/EOF evidence missing.'
                    $expected = if ($behavior -in @('primary-cleanup', 'trace-readonly')) { 'CLEANUP_UNPROVEN' } else { 'FAILED_ZERO_SURVIVORS' }
                    Assert-CapTest ($run.receipt.status -ceq $expected) "Wrong failure release state: $($run.receipt.status)"
                    if ($behavior -in @('primary-cleanup', 'trace-readonly')) {
                        Assert-CapTest ($run.receipt.cleanupFailures.Count -gt 0) 'Primary failure replaced cleanup log-write failure.'
                    }
                    if ($behavior -eq 'trace-readonly') {
                        Assert-CapTest ($run.receipt.traceFailures.Count -gt 0) 'Trace I/O failure was not preserved in the actual release.'
                    }
                    if ($behavior -eq 'timeout') {
                        $manifest = Get-Content -LiteralPath (Join-Path $run.output 'manifest.partial.json') -Raw | ConvertFrom-Json
                        Assert-CapTest ($manifest.rehearsalLaunches[0].cleanupResult -ceq 'TERMINATED_GUARDED_HANDLE') 'Timed-out target was not stopped by held kernel identity.'
                    }
                }
                return [ordered]@{ exit = $run.child.exitCode; output = $run.output; releaseSha256 = $run.receiptSha256 }
            }
        }

        Invoke-CapTest 'real pre-identity attestation failure rolls back its held process and EOF' {
            $receipt = Test-CapManagedProcessRollback -ProcessPath (Join-Path $PSHOME 'pwsh.exe') `
                -WorkingDirectory (Join-Path $scratch 'rollback')
            Assert-CapTest ($receipt.Result -ceq 'TERMINATED_GUARDED_HANDLE' -and $receipt.KernelExited -and
                $receipt.StdoutEof -and $receipt.StderrEof -and @(Get-CapPendingLaunches).Count -eq 0) 'Real guarded rollback was incomplete.'
            return $receipt
        }
        Invoke-CapTest 'guarded stop recognizes a genuinely exited held target generation' {
            $run = Start-CapManagedProcess -FilePath $target.executable -ArgumentList @() `
                -WorkingDirectory (Split-Path -Parent $target.executable) -Role 'held-exited-target-component' -CloseStdin `
                -Environment @{ CAP_REHEARSAL_BEHAVIOR = 'normal' }
            try {
                $wait = Wait-CapManagedProcess -Run $run -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
                Assert-CapTest ($wait.State -ceq 'Exited' -and $wait.ExitCode -eq 0) 'Harmless held target did not exit.'
                $terminated = [CapNative]::Terminate($run.Identity.Process.Handle, $run.Identity.Pid, 125, 1000)
                $stop = Stop-CapManagedProcess -Identity $run.Identity
                Assert-CapTest (-not $terminated -and $stop.Result -ceq 'SKIP_GENUINELY_EXITED_KERNEL' -and
                    $run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) 'Held exited generation was not distinguished from termination.'
                return [ordered]@{ pid = $run.Identity.Pid; creationFileTimeUtc = $run.Identity.CreationFileTimeUtc
                    result = $stop.Result; forcedTermination = $terminated
                    accessDeniedExitRace = 'Not forced; native code now waits on the retained kernel before refusing' }
            } finally {
                if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
                    $null = Stop-CapManagedProcess -Identity $run.Identity
                }
                $run.Identity.Process.Dispose()
            }
        }
        Invoke-CapTest 'current metadata and saved parent lifetime refuse unknown generations' {
            $identity = [pscustomobject]@{ Pid = 123; CreationFileTimeUtc = 100; ExpectedImagePath = 'C:\owned\target.exe'; ParentPid = 1; SessionId = 1 }
            $null = Assert-CapRejects { Assert-CapMetadataRecord -Identity $identity -Metadata $null } 'missing for live PID'
            $null = Assert-CapRejects {
                Assert-CapDescendantLifetime -ParentCreationFileTimeUtc 100 -ParentExitFileTimeUtc 200 -ChildCreationFileTimeUtc 201
            } 'outside parent lifetime'
            return 'Pure negative controls; no foreign process is opened or stopped.'
        }
        Invoke-CapTest 'shared live-admission fixture predicates accept an owned relocation and refuse stale or foreign mapping' {
            $owned = Join-Path $scratch 'relocated-fixture'
            $originalRoot = Join-Path $owned 'original'
            $null = New-Item -ItemType Directory -Path (Join-Path $owned 'inputs'), (Join-Path $owned 'fixtures'), (Join-Path $owned 'reports')
            $sourcePath = Join-Path $owned 'inputs\fixture-source.json'
            $fixturePath = Join-Path $owned 'fixtures\fixture.json'
            $mappingPath = Join-Path $owned 'reports\fixture-mapping.json'
            $source = [ordered]@{ graphs = @('Alpha', 'Beta') | ForEach-Object {
                [ordered]@{ project = [ordered]@{ name = $_; path = (Join-Path $originalRoot $_) }
                    nodes = @(1..5 | ForEach-Object { [ordered]@{ id = "node-$_" } }) }
            } }
            $source.graphs[0].nodes[0].worktreeBinding = @{ path = (Join-Path $originalRoot 'Alpha\card-tree') }
            $source.graphs[0].nodes[1].worktreeBinding = @{ path = (Join-Path $originalRoot 'Alpha\long-tree') }
            $source.graphs[1].nodes[0].worktreeBinding = @{ path = (Join-Path $originalRoot 'Beta\card-tree') }
            $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
            $originalEscaped = ($originalRoot | ConvertTo-Json -Compress).Trim('"')
            $ownedEscaped = ((Join-Path $owned 'fixtures\projects') | ConvertTo-Json -Compress).Trim('"')
            $mapped = [IO.File]::ReadAllText($sourcePath).Replace($originalEscaped, $ownedEscaped) | ConvertFrom-Json
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping = [ordered]@{
                sourcePath = (Join-Path $originalRoot 'fixture.json')
                sourceSha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
                copiedSourcePath = $sourcePath; rewrittenFixturePath = $fixturePath
                rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
                pathPrefixMap = [ordered]@{ from = $originalRoot; to = (Join-Path $owned 'fixtures\projects') }
                graphs = 2; topLevelNodes = 10; pathsRewritten = $true
            }
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters = @{ Root = $owned; FixturePath = $fixturePath; SourcePath = $sourcePath; MappingPath = $mappingPath
                ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
                ExpectedSourceSha256 = $mapping.sourceSha256; OriginalRoot = $originalRoot }
            $proof = Assert-CapFixtureMapping @parameters
            Assert-CapTest ($proof.FixtureSha256 -ceq $mapping.rewrittenFixtureSha256) 'Relocated fixture hash was not obtained from the bound mapping.'
            $staleParameters = $parameters.Clone()
            $staleParameters.ExpectedMappingSha256 = '0' * 64
            $null = Assert-CapRejects { Assert-CapFixtureMapping @staleParameters } 'trusted hashes'
            $null = Assert-CapRejects {
                Assert-CapArtifactPath -Root 'C:\gcs\cap' -Path 'C:\gcs\cap\never-created.json'
            } 'dedicated caller-owned root'
            $validFixture = [IO.File]::ReadAllText($fixturePath)
            [IO.File]::AppendAllText($fixturePath, "`n")
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'exact source and rewritten'
            [IO.File]::WriteAllText($fixturePath, $validFixture, [Text.UTF8Encoding]::new($false))
            $mapping.pathPrefixMap.to = $originalRoot
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'exact source and rewritten'
            $mapping.pathPrefixMap.to = Join-Path $owned 'fixtures\projects'
            $validWorktreePath = $mapped.graphs[0].nodes[0].worktreeBinding.path
            $mapped.graphs[0].nodes[0].worktreeBinding.path = Join-Path $originalRoot 'Alpha\card-tree'
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping.rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'embedded path'
            $mapped.graphs[0].nodes[0].worktreeBinding.path = $validWorktreePath
            $mapped.graphs[0].project.path = Join-Path $originalRoot 'Alpha'
            $mapped | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM
            $mapping.rewrittenFixtureSha256 = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
            $mapping | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM
            $parameters.ExpectedMappingSha256 = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash
            $null = Assert-CapRejects { Assert-CapFixtureMapping @parameters } 'owned project path'
            return 'Actual shared root/source/mapping predicates only; no product binary, HWND, native compatibility, or live capture was executed.'
        }
        Invoke-CapTest 'actual journal reader permits worker atomic replacement while retaining its snapshot' {
            foreach ($definition in @(
                @($supervisorPath, 'Open-CapJournalRead'),
                @($workerPath, 'Write-CapJsonAtomic')
            )) {
                $ast = [Management.Automation.Language.Parser]::ParseInput(
                    [IO.File]::ReadAllText($definition[0]), [ref]$null, [ref]$null)
                $function = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $definition[1]
                }, $true)
                Assert-CapTest ($null -ne $function) "Actual journal function missing: $($definition[1])"
                . ([scriptblock]::Create($function.Extent.Text))
            }
            $directory = Join-Path $scratch 'journal-sharing-component'
            $null = New-Item -ItemType Directory -Path $directory
            $path = Join-Path $directory 'process-journal.json'
            Write-CapJsonAtomic -Path $path -Value ([ordered]@{ version = 1; componentOnly = $true; cleanupComplete = $false })
            $stream = Open-CapJournalRead -Path $path
            try {
                Write-CapJsonAtomic -Path $path -Value ([ordered]@{
                    version = 2; componentOnly = $true; cleanupComplete = $true
                    ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @()
                })
                $reader = [IO.StreamReader]::new($stream)
                try { $snapshot = $reader.ReadToEnd() | ConvertFrom-Json }
                finally { $reader.Dispose() }
                $freshStream = Open-CapJournalRead -Path $path
                try {
                    $freshReader = [IO.StreamReader]::new($freshStream)
                    try { $current = $freshReader.ReadToEnd() | ConvertFrom-Json }
                    finally { $freshReader.Dispose() }
                } finally { $freshStream.Dispose() }
                Assert-CapTest ($snapshot.version -eq 1 -and -not $snapshot.cleanupComplete -and
                    $current.version -eq 2 -and $current.cleanupComplete -and $current.ownedProcessSurvivors.Count -eq 0 -and
                    $current.pendingLaunchesRemaining.Count -eq 0 -and $current.cleanupFailures.Count -eq 0) `
                    'Atomic replacement lost the held snapshot or a fresh read mistook it for completed cleanup.'
            } finally { $stream.Dispose() }
            return 'Actual supervisor reader and actual worker atomic writer; held file I/O only, no process, lease or GUI mock.'
        }
        Invoke-CapTest 'actual rehearsal data satisfies the repaired report gate and refuses stale proof' {
            $source = [IO.File]::ReadAllText($supervisorPath)
            $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
            $function = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-CapPreflightReport'
            }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
            $preflight = [ordered]@{
                suite = 'UiCaptureDriver'; executed = $results.Count; passed = $results.Count; failed = 0
                mode = $mode; gui = 'NotExecuted'; images = 0; backendTurns = 0; fixture = $target
                controls = [pscustomobject]@{ moduleSha256 = $sourceHashesBefore[$modulePath]
                    workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath] }
                cases = @($results)
            } | ConvertTo-Json -Depth 25 | ConvertFrom-Json -DateKind String
            $moduleHash = $sourceHashesBefore[$modulePath]
            $workerHash = $sourceHashesBefore[$workerPath]
            $supervisorHash = $sourceHashesBefore[$supervisorPath]
            $preflightHash = 'A' * 64
            $PreflightReceiptSha256 = $preflightHash
            Assert-CapPreflightReport
            $preflight.controls.workerSha256 = '0' * 64
            $null = Assert-CapRejects { Assert-CapPreflightReport } 'exact-source offline rehearsal'
            return 'Actual completed command-case data accepted; stale worker hash refused. Report-data validation only, no native preflight.'
        }
        Invoke-CapTest 'actual release data guard refuses unproved or omitted worker cleanup' {
            $ast = [Management.Automation.Language.Parser]::ParseInput(
                [IO.File]::ReadAllText($supervisorPath), [ref]$null, [ref]$null)
            $guard = $ast.Find({ param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text.Contains('$manifest.ownedProcessSurvivors') -and
                    $node.Extent.Text.Contains('Worker final kernel-cleanup evidence is absent or has survivors.')
            }, $true)
            Assert-CapTest ($null -ne $guard) 'Actual supervisor cleanup guard was not found.'
            foreach ($mutation in @('pending', 'cleanup-failure', 'survivor', 'missing-pending', 'missing-cleanup', 'missing-survivors', 'null-pending', 'scalar-cleanup')) {
                $workerRun = $true
                $manifest = [pscustomobject]@{ ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
                switch ($mutation) {
                    'pending' { $manifest.pendingLaunchesRemaining = @([pscustomobject]@{ pid = 123; role = 'unreturned-child'; state = 'UNPROVEN' }) }
                    'cleanup-failure' { $manifest.cleanupFailures = @('Guarded rollback refused unknown live metadata.') }
                    'survivor' { $manifest.ownedProcessSurvivors = @([pscustomobject]@{ pid = 123 }) }
                    'missing-pending' { $manifest.PSObject.Properties.Remove('pendingLaunchesRemaining') }
                    'missing-cleanup' { $manifest.PSObject.Properties.Remove('cleanupFailures') }
                    'missing-survivors' { $manifest.PSObject.Properties.Remove('ownedProcessSurvivors') }
                    'null-pending' { $manifest.pendingLaunchesRemaining = $null }
                    'scalar-cleanup' { $manifest.cleanupFailures = 0 }
                }
                $cleanupFailures = [Collections.Generic.List[string]]::new()
                & ([scriptblock]::Create($guard.Extent.Text))
                Assert-CapTest ($cleanupFailures.Count -eq 1) "Actual release guard falsely accepted $mutation cleanup data."
            }
            $manifest = [pscustomobject]@{ ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @() }
            $cleanupFailures.Clear()
            & ([scriptblock]::Create($guard.Extent.Text))
            Assert-CapTest ($cleanupFailures.Count -eq 0) 'Actual guard refused complete empty cleanup arrays.'
            return 'Actual release predicate, eight negative data controls and one complete empty-array control; no unsafe child or process/lease/worker mock was executed.'
        }
        Invoke-CapTest 'actual journal reader selects the highest numeric published snapshot and ignores unpublished temporaries' {
            . ([scriptblock]::Create((Get-CapActualFunctionText $supervisorPath $journalSupervisorFunctions)))
            Set-CapJournalReaderContext
            $directory = New-CapJournalFixtureDirectory 'numeric-highest'
            $null = Write-CapJournalFixtureChain -Directory $directory -Count 11
            $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 12 -RawText '{"unpublished":' `
                -FileName ('process-journal.pending-{0}.tmp' -f ('a' * 32))
            try {
                Refresh-CapJournal -Path (Join-Path $directory 'process-journal.json')
                $phases = @($tracked.Keys | ForEach-Object { $_.Split(':')[2] })
                Assert-CapTest ($phases.Count -eq 1 -and $phases[0] -ceq 'chain-11') `
                    "The reader did not select sequence 11 over 9/10 (lexicographic) or the unpublished temporary: [$($phases -join ',')]"
                Assert-CapTest ($script:journalHighestSeen -eq 11) 'The highest observed published sequence was not recorded.'
            } finally { foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() } }
            return 'Actual supervisor reader over eleven numbered snapshots plus an unpublished temporary; real file listing, open and parse.'
        }
        Invoke-CapTest 'actual journal reader refuses a corrupt, foreign or mismatched highest snapshot without falling back' {
            . ([scriptblock]::Create((Get-CapActualFunctionText $supervisorPath $journalSupervisorFunctions)))
            $mutations = [ordered]@{
                'truncated-json' = @{ Expected = 'is malformed'; Raw = '{"schemaVersion":1,"sequence":4,' }
                'invalid-utf8' = @{ Expected = 'is malformed'; Bytes = [byte[]](0x7B, 0xFF, 0xFE, 0x7D) }
                'missing-sequence' = @{ Expected = 'is malformed'; Remove = @('sequence') }
                'name-body-sequence' = @{ Expected = 'differs from its published name'; Override = @{ sequence = 3 } }
                'foreign-lease' = @{ Expected = 'binding differs'; Override = @{ leaseId = [guid]::NewGuid().ToString() } }
                'foreign-job' = @{ Expected = 'binding differs'; Override = @{ jobSha256 = 'B' * 64 } }
                'foreign-worker' = @{ Expected = 'binding differs'; Override = @{ workerSha256 = 'B' * 64 } }
                'foreign-name' = @{ Expected = 'Unexpected file in the worker journal namespace'; Name = 'process-journal.007.json' }
            }
            foreach ($mutation in $mutations.Keys) {
                Set-CapJournalReaderContext
                $directory = New-CapJournalFixtureDirectory "refuse-$mutation"
                $chain = Write-CapJournalFixtureChain -Directory $directory -Count 3
                $spec = $mutations[$mutation]
                if ($spec.ContainsKey('Bytes')) {
                    [IO.File]::WriteAllBytes((Join-Path $directory 'process-journal.4.json'), $spec.Bytes)
                } elseif ($spec.ContainsKey('Raw')) {
                    $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 4 -RawText $spec.Raw
                } elseif ($spec.ContainsKey('Name')) {
                    $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 7 -FileName $spec.Name -PreviousSha256 $chain[2].Sha256
                } else {
                    $parameters = @{ Directory = $directory; Sequence = 4; Phase = 'mutated-highest'; PreviousSha256 = $chain[2].Sha256 }
                    if ($spec.ContainsKey('Override')) { $parameters.Override = $spec.Override }
                    if ($spec.ContainsKey('Remove')) { $parameters.Remove = $spec.Remove }
                    $null = Write-CapJournalFixtureSnapshot @parameters
                }
                try {
                    $null = Assert-CapRejects { Refresh-CapJournal -Path (Join-Path $directory 'process-journal.json') } $spec.Expected
                    Assert-CapTest ($tracked.Count -eq 0) "The reader fell back to an older snapshot after refusing $mutation."
                } finally { foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() } }
            }
            return [ordered]@{ refusedMutations = @($mutations.Keys); data = 'Real files and the actual reader; no fallback to the older valid snapshot 3.' }
        }
        Invoke-CapTest 'actual journal reader re-lists only for a just-listed FileNotFoundException within a bounded attempt budget' {
            . ([scriptblock]::Create((Get-CapActualFunctionText $supervisorPath $journalSupervisorFunctions)))
            Copy-Item -LiteralPath Function:\Open-CapJournalRead -Destination Function:\Open-CapJournalReadActual
            function Open-CapJournalRead {
                param([Parameter(Mandatory)][string]$Path)
                $script:openCalls.Add($Path)
                & $script:openHook $Path
                return Open-CapJournalReadActual -Path $Path
            }
            $evidence = [ordered]@{}
            # 1. The just-listed name vanishes and a newer snapshot is published: one bounded re-list succeeds.
            Set-CapJournalReaderContext
            $directory = New-CapJournalFixtureDirectory 'relist-supersede'
            $base = Join-Path $directory 'process-journal.json'
            $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 1 -Phase 'one'
            $script:openCalls = [Collections.Generic.List[string]]::new()
            $script:openHook = { param($Path)
                if ($script:openCalls.Count -eq 1) {
                    Remove-Item -LiteralPath $Path -Force
                    $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 2 -Phase 'two'
                }
            }
            try {
                Refresh-CapJournal -Path $base
                $phases = @($tracked.Keys | ForEach-Object { $_.Split(':')[2] })
                Assert-CapTest ($script:openCalls.Count -eq 2 -and $script:openCalls[0].EndsWith('process-journal.1.json') -and
                    $script:openCalls[1].EndsWith('process-journal.2.json') -and $phases.Count -eq 1 -and $phases[0] -ceq 'two') `
                    'A vanished just-listed snapshot was not recovered by exactly one bounded re-list.'
                $evidence.supersede = @($script:openCalls)
            } finally { foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() } }
            # 2. A sharing violation is a real I/O failure, never a missing file, and is not re-listed.
            Set-CapJournalReaderContext
            $directory = New-CapJournalFixtureDirectory 'relist-denied'
            $base = Join-Path $directory 'process-journal.json'
            $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 1 -Phase 'one'
            $script:openCalls = [Collections.Generic.List[string]]::new()
            $script:lockHandle = $null
            $script:openHook = { param($Path)
                $script:lockHandle = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            $thrown = $null
            try { Refresh-CapJournal -Path $base } catch { $thrown = Get-CapUnwrappedException $_ }
            finally {
                if ($script:lockHandle) { $script:lockHandle.Dispose() }
                foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() }
            }
            Assert-CapTest ($thrown -is [IO.IOException] -and $thrown -isnot [IO.FileNotFoundException] -and
                $script:openCalls.Count -eq 1 -and $tracked.Count -eq 0) `
                'A non-FileNotFound open failure was swallowed or re-listed as a missing file.'
            $evidence.sharingViolation = $thrown.GetType().FullName
            # 3. The highest vanishes with no successor: explicit failure, never an older snapshot.
            Set-CapJournalReaderContext
            $directory = New-CapJournalFixtureDirectory 'relist-vanished'
            $base = Join-Path $directory 'process-journal.json'
            $null = Write-CapJournalFixtureChain -Directory $directory -Count 2
            $script:openCalls = [Collections.Generic.List[string]]::new()
            $script:openHook = { param($Path) Remove-Item -LiteralPath $Path -Force }
            try {
                $null = Assert-CapRejects { Refresh-CapJournal -Path $base } 'regressed or vanished'
                Assert-CapTest ($tracked.Count -eq 0 -and $script:openCalls.Count -eq 1) 'A vanished highest snapshot fell back to an older one.'
            } finally { foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() } }
            # 4. Endless supersession exhausts the bounded budget instead of looping.
            Set-CapJournalReaderContext
            $directory = New-CapJournalFixtureDirectory 'relist-exhausted'
            $base = Join-Path $directory 'process-journal.json'
            $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence 1 -Phase 'seed'
            $script:openCalls = [Collections.Generic.List[string]]::new()
            $script:openHook = { param($Path)
                $next = [int](([IO.Path]::GetFileName($Path) -split '\.')[1]) + 1
                Remove-Item -LiteralPath $Path -Force
                $null = Write-CapJournalFixtureSnapshot -Directory $directory -Sequence $next -Phase "again-$next"
            }
            try {
                $null = Assert-CapRejects { Refresh-CapJournal -Path $base } 'budget exhausted'
                Assert-CapTest ($script:openCalls.Count -ge 2 -and $script:openCalls.Count -le 16) `
                    "The re-list budget was not bounded: $($script:openCalls.Count) opens."
                $evidence.exhaustedOpens = $script:openCalls.Count
            } finally { foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() } }
            return $evidence
        }
        Invoke-CapTest 'actual worker publisher and supervisor reader stay consistent through many concurrent publications with a held old reader' {
            . ([scriptblock]::Create((Get-CapActualFunctionText $supervisorPath $journalSupervisorFunctions)))
            Set-CapJournalReaderContext
            $publications = 300
            $directory = New-CapJournalFixtureDirectory 'concurrent-publications'
            $base = Join-Path $directory 'process-journal.json'
            $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
            $names = @{ ready = "Local\gcj-$id-ready"; go = "Local\gcj-$id-go"; mid = "Local\gcj-$id-mid"; cont = "Local\gcj-$id-cont" }
            $events = @{}
            foreach ($key in $names.Keys) {
                $events[$key] = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $names[$key])
            }
            $childScript = @'
$ErrorActionPreference = 'Stop'
Import-Module $env:CAP_J_MODULE -Force -WarningAction SilentlyContinue
. $env:CAP_J_WORKER -OwnedRoot $env:CAP_J_ROOT -DefinitionsOnly
$script:journalPath = $env:CAP_J_JOURNAL
$script:auth = [pscustomobject]@{ leaseId = $env:CAP_J_LEASE }
$script:jobHash = $env:CAP_J_JOB; $script:workerHash = $env:CAP_J_WORKERHASH; $script:moduleHash = $env:CAP_J_MODULEHASH
$ev = @{}
foreach ($key in @('ready', 'go', 'mid', 'cont')) {
    $ev[$key] = [Threading.EventWaitHandle]::OpenExisting([Environment]::GetEnvironmentVariable('CAP_J_EV_' + $key.ToUpperInvariant()))
}
$count = [int]$env:CAP_J_COUNT
$process = [Diagnostics.Process]::GetCurrentProcess()
$identity = Get-CapProcessIdentity -Process $process -ExpectedImagePath $process.MainModule.FileName -Role 'journal-concurrency-writer'
Write-CapProcessJournal -Identity $identity -Phase 'p0'
$null = $ev.ready.Set()
if (-not $ev.go.WaitOne(60000)) { throw 'go barrier timed out' }
for ($i = 1; $i -lt $count; $i++) {
    Write-CapProcessJournal -Identity $identity -Phase ('p{0}' -f ($i % 10))
    if ($i -eq [int]($count / 2)) {
        $null = $ev.mid.Set()
        if (-not $ev.cont.WaitOne(60000)) { throw 'cont barrier timed out' }
    }
}
Write-Output "WRITER_DONE publications=$count"
'@
            $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @(
                '-NoProfile', '-Command', '. ([scriptblock]::Create($env:CAP_J_CHILD))') `
                -WorkingDirectory $directory -Role 'journal-concurrency-writer' -Environment @{
                    CAP_J_CHILD = $childScript; CAP_J_MODULE = $modulePath; CAP_J_WORKER = $workerPath
                    CAP_J_ROOT = $scratch; CAP_J_JOURNAL = $base; CAP_J_LEASE = $lease.leaseId
                    CAP_J_JOB = $jobHash; CAP_J_WORKERHASH = $workerHash; CAP_J_MODULEHASH = $moduleHash
                    CAP_J_COUNT = [string]$publications; CAP_J_EV_READY = $names.ready; CAP_J_EV_GO = $names.go
                    CAP_J_EV_MID = $names.mid; CAP_J_EV_CONT = $names.cont
                }
            $errors = [Collections.Generic.List[string]]::new()
            $reads = 0; $midRead = $false; $held = $null; $heldBytes = $null; $heldFileName = $null
            try {
                $wait = $events.ready.WaitOne(60000)
                if (-not $wait) {
                    $null = $run.Identity.Process.WaitForExit(2000)
                    $null = $run.StdoutTask.Wait(2000); $null = $run.StderrTask.Wait(2000)
                    throw "The writer process never published its first snapshot: stderr=$($run.StderrTask.Result)"
                }
                $firstSnapshot = @(Get-ChildItem -LiteralPath $directory -Filter 'process-journal*.json' -File)[0]
                $heldFileName = $firstSnapshot.Name
                $held = Open-CapJournalRead -Path $firstSnapshot.FullName
                $null = $events.go.Set()
                while (-not $run.Identity.Process.HasExited) {
                    try { Refresh-CapJournal -Path $base; $reads++ } catch { $errors.Add($_.Exception.Message) }
                    if (-not $midRead -and $events.mid.WaitOne(0)) {
                        try { Refresh-CapJournal -Path $base; $reads++; $midRead = $true } catch { $errors.Add($_.Exception.Message) }
                        $null = $events.cont.Set()
                    }
                }
                try { Refresh-CapJournal -Path $base; $reads++ } catch { $errors.Add($_.Exception.Message) }
                $heldReader = [IO.StreamReader]::new($held)
                try { $heldBytes = $heldReader.ReadToEnd() } finally { $heldReader.Dispose() }
                Assert-CapTest ($run.StdoutTask.Wait(5000) -and $run.StderrTask.Wait(5000)) 'Writer EOF was incomplete.'
            } finally {
                $null = $events.cont.Set()
                if (-not $run.Identity.Process.HasExited) { $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000 }
                if ($held) { $held.Dispose() }
                foreach ($record in $tracked.Values) { $record.Identity.Process.Dispose() }
                foreach ($event in $events.Values) { $event.Dispose() }
                $run.Identity.Process.Dispose()
            }
            Assert-CapTest ($errors.Count -eq 0) "The supervisor reader failed $($errors.Count) of $reads reads during concurrent publication; first: $($errors | Select-Object -First 2)"
            Assert-CapTest ($run.Identity.Process.ExitCode -eq 0 -and ([string]$run.StdoutTask.Result).Contains('WRITER_DONE')) `
                "The real worker publisher failed: $($run.StderrTask.Result)"
            Assert-CapTest ($reads -gt 0 -and $midRead) 'No positive concurrent read count or mid-stream checkpoint was observed.'
            $snapshots = @(Get-ChildItem -LiteralPath $directory -Filter 'process-journal*.json' -File)
            Assert-CapTest ($snapshots.Count -eq $publications) "Expected $publications immutable snapshots, found $($snapshots.Count)."
            Assert-CapTest ($script:journalHighestSeen -eq $publications) "The reader's final highest sequence was $($script:journalHighestSeen)."
            Assert-CapTest ($heldBytes.Contains('"sequence": 1,') -and $heldFileName -ceq 'process-journal.1.json') `
                'The held old reader did not keep reading its immutable first snapshot.'
            return [ordered]@{ publications = $publications; reads = $reads; readerErrors = 0; midCheckpoint = $midRead
                snapshots = $snapshots.Count; highest = $script:journalHighestSeen
                data = 'Actual worker publisher in a distinct console child and actual supervisor reader here; named-event barriers; no process/lease mocks.' }
        }
        Invoke-CapTest 'actual terminal verification binds the exact final journal to the final manifest and refuses stale or incomplete proof' {
            . ([scriptblock]::Create((Get-CapActualFunctionText $supervisorPath $journalSupervisorFunctions)))
            Set-CapJournalReaderContext
            $expected = @{ LeaseId = $lease.leaseId; JobSha256 = $jobHash; ModuleSha256 = $moduleHash; WorkerSha256 = $workerHash }
            $newManifest = {
                param($Records, [hashtable]$Change = @{})
                $last = $Records[$Records.Count - 1]
                $manifest = [ordered]@{
                    leaseId = $lease.leaseId; jobManifestSha256 = $jobHash; moduleSha256 = $moduleHash; workerSha256 = $workerHash
                    processJournal = [ordered]@{ terminalSequence = $last.Sequence; terminalSha256 = $last.Sha256; snapshotCount = $Records.Count }
                    ownedProcessSurvivors = @(); pendingLaunchesRemaining = @(); cleanupFailures = @()
                }
                foreach ($key in $Change.Keys) { $manifest[$key] = $Change[$key] }
                return ([pscustomobject]$manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json -DateKind String)
            }
            $directory = New-CapJournalFixtureDirectory 'terminal-valid'
            $base = Join-Path $directory 'process-journal.json'
            $records = Write-CapJournalFixtureChain -Directory $directory -Count 4 -WithTerminal
            $proof = Assert-CapJournalTerminal -BasePath $base -Manifest (& $newManifest $records) -Expected $expected -TerminalRequired
            Assert-CapTest ($proof.Inventory.Count -eq 4 -and $proof.TerminalSequence -eq 4 -and $proof.TerminalSha256 -ceq $records[3].Sha256 -and
                $proof.TerminalPresent -and $proof.TerminalBoundToManifest) 'A complete chained terminal journal was not proven.'
            $directory = New-CapJournalFixtureDirectory 'terminal-not-required'
            $base = Join-Path $directory 'process-journal.json'
            $records = Write-CapJournalFixtureChain -Directory $directory -Count 3
            $notFinal = Assert-CapJournalTerminal -BasePath $base -Manifest $null -Expected $expected
            Assert-CapTest ($notFinal.Inventory.Count -eq 3 -and -not $notFinal.TerminalPresent) 'A failed-worker non-terminal chain was not inventoried without a terminal claim.'
            $negatives = [ordered]@{
                'stale-final' = @{ Expected = 'terminal snapshot is missing'; Build = { param($d) Write-CapJournalFixtureChain -Directory $d -Count 4 } }
                'no-snapshots' = @{ Expected = 'has no published snapshot'; Build = { param($d) @() } }
                'post-terminal-version' = @{ Expected = 'after its terminal snapshot'; Build = { param($d)
                    $chain = @(Write-CapJournalFixtureChain -Directory $d -Count 4 -WithTerminal)
                    $chain + (Write-CapJournalFixtureSnapshot -Directory $d -Sequence 5 -Phase 'late' -PreviousSha256 $chain[3].Sha256) } }
                'null-survivors' = @{ Expected = 'terminal arrays are incomplete'; Build = { param($d)
                    Write-CapJournalFixtureChain -Directory $d -Count 3
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 4 -Terminal -Override @{ ownedProcessSurvivors = $null } -PreviousSha256 (Get-FileHash (Join-Path $d 'process-journal.3.json')).Hash } }
                'missing-pending' = @{ Expected = 'terminal arrays are incomplete'; Build = { param($d)
                    Write-CapJournalFixtureChain -Directory $d -Count 3
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 4 -Terminal -Remove @('pendingLaunchesRemaining') -PreviousSha256 (Get-FileHash (Join-Path $d 'process-journal.3.json')).Hash } }
                'scalar-cleanup' = @{ Expected = 'terminal arrays are incomplete'; Build = { param($d)
                    Write-CapJournalFixtureChain -Directory $d -Count 3
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 4 -Terminal -Override @{ cleanupFailures = 0 } -PreviousSha256 (Get-FileHash (Join-Path $d 'process-journal.3.json')).Hash } }
                'sequence-gap' = @{ Expected = 'sequence gap'; Build = { param($d)
                    $first = Write-CapJournalFixtureChain -Directory $d -Count 2
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 4 -Terminal -PreviousSha256 $first[1].Sha256 } }
                'broken-hash-chain' = @{ Expected = 'hash chain is broken'; Build = { param($d)
                    Write-CapJournalFixtureChain -Directory $d -Count 3
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 4 -Terminal -PreviousSha256 ('0' * 64) } }
                'foreign-older-snapshot' = @{ Expected = 'binding differs'; Build = { param($d)
                    $one = Write-CapJournalFixtureSnapshot -Directory $d -Sequence 1
                    $two = Write-CapJournalFixtureSnapshot -Directory $d -Sequence 2 -PreviousSha256 $one.Sha256 -Override @{ leaseId = [guid]::NewGuid().ToString() }
                    Write-CapJournalFixtureSnapshot -Directory $d -Sequence 3 -Terminal -PreviousSha256 $two.Sha256 } }
            }
            foreach ($name in $negatives.Keys) {
                $directory = New-CapJournalFixtureDirectory "terminal-$name"
                $base = Join-Path $directory 'process-journal.json'
                $built = @(& $negatives[$name].Build $directory)
                $records = @($built | Where-Object { $_ -and $_.PSObject.Properties['Sha256'] })
                $manifest = if ($records.Count) { & $newManifest $records } else { $null }
                try {
                    $null = Assert-CapRejects { Assert-CapJournalTerminal -BasePath $base -Manifest $manifest -Expected $expected -TerminalRequired } $negatives[$name].Expected
                } catch { throw "Terminal negative '$name': $($_.Exception.Message)" }
            }
            $directory = New-CapJournalFixtureDirectory 'terminal-binding'
            $base = Join-Path $directory 'process-journal.json'
            $records = Write-CapJournalFixtureChain -Directory $directory -Count 4 -WithTerminal
            $bindingMutations = [ordered]@{
                'wrong-sequence' = @{ processJournal = [ordered]@{ terminalSequence = 3; terminalSha256 = $records[3].Sha256; snapshotCount = 4 } }
                'wrong-hash' = @{ processJournal = [ordered]@{ terminalSequence = 4; terminalSha256 = ('0' * 64); snapshotCount = 4 } }
                'wrong-count' = @{ processJournal = [ordered]@{ terminalSequence = 4; terminalSha256 = $records[3].Sha256; snapshotCount = 5 } }
                'missing-binding' = @{ processJournal = $null }
                'manifest-cleanup-differs' = @{ cleanupFailures = @('unreported cleanup failure') }
                'foreign-manifest-lease' = @{ leaseId = [guid]::NewGuid().ToString() }
            }
            foreach ($name in $bindingMutations.Keys) {
                $manifest = & $newManifest $records $bindingMutations[$name]
                try {
                    $null = Assert-CapRejects { Assert-CapJournalTerminal -BasePath $base -Manifest $manifest -Expected $expected -TerminalRequired } 'not bound to the final manifest'
                } catch { throw "Manifest binding negative '$name': $($_.Exception.Message)" }
            }
            return [ordered]@{ negatives = @($negatives.Keys); bindingNegatives = @($bindingMutations.Keys)
                data = 'Actual terminal verifier over real chained files; no worker/process mock.' }
        }
        Invoke-CapTest 'real capture command publishes immutable journal snapshots and proves their removal at release' {
            $run = Invoke-CapCaptureCommand -Name 'journal-release'
            $null = Assert-CapRehearsalSuccess -Run $run -Arguments @()
            $journal = Assert-CapJournalReleaseProof -Run $run -State 'SNAPSHOTS_REMOVED_AND_VERIFIED'
            $inventory = @($journal.preCleanupInventory)
            Assert-CapTest ($journal.positiveInventoryRequired -and $inventory.Count -ge 2 -and $journal.inventoryCount -eq $inventory.Count -and
                $journal.removedCount -eq $inventory.Count -and @($journal.removed).Count -eq $inventory.Count -and
                @($journal.remainingAfterCleanup).Count -eq 0 -and $journal.terminalVerified -and $journal.terminalBoundToManifest -and
                $journal.terminalSequence -eq $inventory.Count) 'The release lacks a positive pre-cleanup inventory, exact removal and terminal binding.'
            for ($i = 0; $i -lt $inventory.Count; $i++) {
                Assert-CapTest ($inventory[$i].sequence -eq ($i + 1) -and $inventory[$i].name -ceq "process-journal.$($i + 1).json" -and
                    $inventory[$i].sha256 -match '^[A-F0-9]{64}$' -and $journal.removed[$i].name -ceq $inventory[$i].name -and
                    $journal.removed[$i].sha256 -ceq $inventory[$i].sha256) "Inventory/removal metadata for snapshot $($i + 1) is not exact."
            }
            $runDirectories = @(Get-ChildItem -LiteralPath (Join-Path $run.owned 'runs') -Directory)
            Assert-CapTest ($runDirectories.Count -eq 1 -and @(Get-ChildItem -LiteralPath $runDirectories[0].FullName -Filter 'process-journal*' -Force).Count -eq 0) `
                'Journal snapshots or temporaries remain in the owned run directory after release.'
            $record = $journal.inventoryRecord
            Assert-CapTest ((Test-Path -LiteralPath $record.path -PathType Leaf) -and
                (Get-FileHash -LiteralPath $record.path -Algorithm SHA256).Hash -ceq $record.sha256) 'The preserved pre-removal inventory record is missing or altered.'
            $manifest = Get-Content -LiteralPath (Join-Path $run.output 'manifest.json') -Raw | ConvertFrom-Json -DateKind String
            Assert-CapTest ($manifest.processJournal.terminalSequence -eq $journal.terminalSequence -and
                $manifest.processJournal.terminalSha256 -ceq $journal.terminalSha256 -and
                $manifest.processJournal.snapshotCount -eq $inventory.Count) 'The final manifest does not bind the exact terminal journal.'
            return [ordered]@{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256; snapshots = $inventory.Count
                terminalSequence = $journal.terminalSequence; inventoryRecord = $record }
        }
        Invoke-CapTest 'no-worker refusal reports a distinct journal state instead of a fake cleanup zero' {
            $run = Invoke-CapCaptureCommand -Name 'journal-no-worker' -LeaseMutation 'hash'
            Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and $run.receipt.status -ceq 'REFUSED_NO_WORKER') 'Invalid lease did not produce a no-worker release.'
            $journal = Assert-CapJournalReleaseProof -Run $run -State 'NO_WORKER_STARTED'
            Assert-CapTest (-not $journal.positiveInventoryRequired -and $journal.inventoryCount -eq 0 -and $journal.removedCount -eq 0 -and
                -not $journal.terminalVerified) 'A no-worker refusal claimed journal cleanup.'
            return [ordered]@{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256; state = $journal.state }
        }
        Invoke-CapTest 'real capture command refuses a planted corrupt highest journal snapshot and retains it' {
            $run = Invoke-CapCaptureCommand -Name 'journal-corrupt-highest' -Arguments @('journal-corrupt-highest')
            Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and $run.receipt.status -ceq 'CLEANUP_UNPROVEN') `
                "A corrupt highest published journal snapshot was accepted: exit=$($run.child.exitCode) status=$($run.receipt.status)"
            Assert-CapTest ((@($run.receipt.primaryFailure) + @($run.receipt.cleanupFailures) -join "`n").Contains('Worker process journal')) `
                'The release does not attribute the failure to the corrupt journal snapshot.'
            $journal = Assert-CapJournalReleaseProof -Run $run -State 'RETAINED_VERIFICATION_FAILED'
            Assert-CapTest (-not $journal.terminalVerified -and $journal.removedCount -eq 0) 'Verification failure still claimed terminal proof or removed evidence.'
            $planted = @(Get-ChildItem -LiteralPath (Join-Path $run.owned 'runs') -Recurse -Filter 'process-journal.9999.json' -File)
            Assert-CapTest ($planted.Count -eq 1 -and [IO.File]::ReadAllText($planted[0].FullName) -ceq '{"corrupt":') 'The planted corrupt snapshot was not retained unchanged.'
            return [ordered]@{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256; state = $journal.state }
        }
        Invoke-CapTest 'real worker never overwrites a colliding foreign journal snapshot name' {
            $run = Invoke-CapCaptureCommand -Name 'journal-collision' -Arguments @('journal-plant-collision')
            Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and $run.receipt.status -ceq 'CLEANUP_UNPROVEN') `
                "A colliding foreign snapshot name did not fail closed: exit=$($run.child.exitCode) status=$($run.receipt.status)"
            $manifest = Get-Content -LiteralPath (Join-Path $run.output 'manifest.partial.json') -Raw | ConvertFrom-Json -DateKind String
            Assert-CapTest ((@($manifest.cleanupFailures) -join "`n").Contains('Final process journal update failed')) `
                'The worker did not report that its terminal publication collided.'
            $planted = @(Get-ChildItem -LiteralPath (Join-Path $run.owned 'runs') -Recurse -Filter 'process-journal.*.json' -File |
                Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq '{"corrupt":' })
            Assert-CapTest ($planted.Count -eq 1) 'The foreign snapshot at the colliding name was overwritten, replaced or removed.'
            $journal = Assert-CapJournalReleaseProof -Run $run -State 'RETAINED_VERIFICATION_FAILED'
            return [ordered]@{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256; state = $journal.state; foreign = $planted[0].Name }
        }
        Invoke-CapTest 'real release stays cleanup-unproven when a journal snapshot cannot be removed' {
            $run = Invoke-CapCaptureCommand -Name 'journal-readonly' -Arguments @('journal-readonly-snapshot')
            $locked = @(Get-ChildItem -LiteralPath (Join-Path $run.owned 'runs') -Recurse -Filter 'process-journal.1.json' -File)
            try {
                Assert-CapTest ($run.child.exitCode -ne 0 -and $null -ne $run.receipt -and $run.receipt.status -ceq 'CLEANUP_UNPROVEN') `
                    "A snapshot removal failure did not stay cleanup-unproven: exit=$($run.child.exitCode) status=$($run.receipt.status)"
                $journal = Assert-CapJournalReleaseProof -Run $run -State 'REMOVAL_UNPROVEN'
                Assert-CapTest ($locked.Count -eq 1 -and @($journal.remainingAfterCleanup) -contains 'process-journal.1.json' -and
                    -not (@($journal.removed | ForEach-Object name) -contains 'process-journal.1.json') -and
                    $journal.removedCount -eq ($journal.inventoryCount - 1) -and $journal.terminalVerified) 'The proof overstated the removal of a snapshot that remains on disk.'
                Assert-CapTest ((@($run.receipt.cleanupFailures) -join "`n").Contains('process-journal.1.json')) 'The removal failure is not in the release cleanup failures.'
            } finally { foreach ($file in $locked) { Set-ItemProperty -LiteralPath $file.FullName -Name IsReadOnly -Value $false } }
            return [ordered]@{ release = $run.receiptPath; releaseSha256 = $run.receiptSha256; state = $journal.state }
        }
        # Same frozen five-scene/two-phase mocks: component regression only, never launch/UI proof.
        # Test-CapCaptureOffline.ps1 SHA256 6C08A2029D9256405552BBA9B82B15A8A19359544433FD0E5928B4A7EA6C2592.
        try {
            $componentRoot = Join-Path $scratch 'component-only'
            . $workerPath -OwnedRoot $componentRoot -DefinitionsOnly
            $RunId = 'scene-components'
            $script:jobHash = 'D' * 64
            $script:moduleHash = $sourceHashesBefore[$modulePath]
            $script:workerHash = $sourceHashesBefore[$workerPath]
            $script:leaseHash = 'COMPONENT_ONLY_NOT_LEASED'
            $script:fixtureHash = 'A' * 64
            $script:fixtureSourceHash = 'B' * 64
            $script:fixtureMappingHash = 'C' * 64
            $script:leaseDeadlineUtc = [DateTime]::UtcNow.AddMinutes(3)
            $script:auth = [pscustomobject]@{ leaseId = [guid]::NewGuid().ToString(); supervisorSha256 = $sourceHashesBefore[$supervisorPath]; preflightReceiptSha256 = 'COMPONENT_ONLY' }
            $script:job = [pscustomobject]@{
                head = 'SYNTHETIC_AFTER'; base = 'SYNTHETIC_BEFORE'
                binaries = [pscustomobject]@{
                    before = [pscustomobject]@{ source = 'SYNTHETIC_BEFORE'; binaryBuiltAtSource = 'DISTINCT_BEFORE_BUILD'; sha256 = ('B' * 64) }
                    after = [pscustomobject]@{ source = 'SYNTHETIC_AFTER'; binaryBuiltAtSource = 'DISTINCT_AFTER_BUILD'; sha256 = ('C' * 64) }
                    offlineZmx = [pscustomobject]@{ seedArgumentOrder = @('run', 'graphcode-11111111-1111-4111-8111-000000000001', '-d', 'cmd.exe', '/Q', '/K', 'echo Offline card fixture - no backend') }
                }
                scenes = @(
                    [pscustomobject]@{ name = 'project-alpha'; zoomProbe = 'Name RefMain / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) },
                    [pscustomobject]@{ name = 'project-beta'; zoomProbe = 'Name RefComposite / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) },
                    [pscustomobject]@{ name = 'overview'; zoomProbe = 'Name RefMain / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(220,250) },
                    [pscustomobject]@{ name = 'workspace'; zoomProbe = $null },
                    [pscustomobject]@{ name = 'actions'; zoomProbe = 'Name UIA loop A / AutomationId prefix canvas-card-'; naturalWidthBeforeAfter = @(250,250) }
                )
            }
    $sceneTestRoot = Join-Path $root "preflight\$RunId\scene-functions"
    $script:runDirectory = $sceneTestRoot
    $script:outputDirectory = Join-Path $sceneTestRoot 'mock-output'
    $script:workerLog = Join-Path $sceneTestRoot 'mock-worker.log'
    $script:journalPath = Join-Path $sceneTestRoot 'mock-process-journal.json'
    $script:manifestPath = Join-Path $sceneTestRoot 'mock-manifest.partial.json'
    New-Item -ItemType Directory -Path $script:outputDirectory -Force | Out-Null
    [IO.File]::WriteAllText($script:workerLog, '', [Text.UTF8Encoding]::new($false))
    $script:images = [Collections.Generic.List[object]]::new()
    $script:runs = [Collections.Generic.List[object]]::new()
    $script:seedRuns = [Collections.Generic.List[object]]::new()
    $script:applicationRuns = [Collections.Generic.List[object]]::new()
    $script:descendantIdentities = [Collections.Generic.List[object]]::new()
    $script:journalEntries = [Collections.Generic.List[object]]::new()
    $script:cleanupReceipts = [Collections.Generic.List[object]]::new()
    $script:cleanupFailures = [Collections.Generic.List[string]]::new()
    $script:zmxSeedReceipts = [Collections.Generic.List[object]]::new()
    $script:mockSceneRun = $true
    $sceneMock = [ordered]@{
        appRuns = [Collections.Generic.List[object]]::new()
        appEnvironments = [Collections.Generic.List[object]]::new()
        actionCalls = [Collections.Generic.List[object]]::new()
        actionObservations = [Collections.Generic.List[object]]::new()
        capturePaths = [Collections.Generic.List[string]]::new()
        cleanupCalls = [Collections.Generic.List[object]]::new()
        cleanupAttempts = [Collections.Generic.List[object]]::new()
        deadlineStages = [Collections.Generic.List[string]]::new()
        peerPipes = [Collections.Generic.List[string]]::new()
        seedStarts = [Collections.Generic.List[object]]::new()
        seedCloses = [Collections.Generic.List[string]]::new()
        zoomMeasurements = [Collections.Generic.List[object]]::new()
        zoomSelectors = [Collections.Generic.List[object]]::new()
    }
    function Assert-CapWorkerDeadline {
        param([string]$Stage)
        $script:sceneMock.deadlineStages.Add($Stage)
    }
    function Test-CapPipeUnserved {
        param([string]$PipeName)
        $script:sceneMock.peerPipes.Add("UNSERVED:$PipeName")
        return [pscustomobject]@{ PipeName = $PipeName; Unserved = $true; Win32Error = 2 }
    }
    function Start-CapOfflinePeer {
        param($Roots, [string]$PipeName, [string]$Phase)
        $null = Test-CapPipeUnserved -PipeName $PipeName
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory $Roots.Peer -Role "offline-fixture-peer-$Phase" `
            -Environment @{ TEMP = $Roots.Temp; TMP = $Roots.Temp; USERPROFILE = $Roots.Profile }
        $script:runs.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:sceneMock.peerPipes.Add($PipeName)
        return $run
    }
    function Start-CapOfflineSeed {
        param($Roots, [string]$Phase)
        $arguments = @($script:job.binaries.offlineZmx.seedArgumentOrder)
        if ($arguments.Count -ne 7 -or $arguments[6] -cne 'echo Offline card fixture - no backend') {
            throw 'Scene runner did not retain the exact offline cmd-only seed contract.'
        }
        $workingDirectory = Join-Path $Roots.Peer 'mock-seed'
        New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory $workingDirectory -Role "offline-scene-seed-mock-$Phase" `
            -Environment @{ TEMP = $Roots.Temp; TMP = $Roots.Temp; USERPROFILE = $Roots.Profile }
        $run | Add-Member -NotePropertyName Phase -NotePropertyValue $Phase
        $run | Add-Member -NotePropertyName SessionName -NotePropertyValue $arguments[1]
        $run | Add-Member -NotePropertyName Descendants -NotePropertyValue @()
        $run | Add-Member -NotePropertyName CleanupComplete -NotePropertyValue $false
        $receipt = [pscustomobject]@{
            phase = $Phase; mockOnly = $true; exitCode = $null
            daemonReady = $false; daemonCount = 0; cmdCount = 0
            descendants = @(); stdoutEof = $false; stderrEof = $false
            cleanupStatus = 'MOCK_PENDING'; cleanup = @()
        }
        $run | Add-Member -NotePropertyName SeedReceipt -NotePropertyValue $receipt
        $script:runs.Add($run)
        $script:seedRuns.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:zmxSeedReceipts.Add($receipt)
        $script:sceneMock.seedStarts.Add([pscustomobject]@{
            Phase = $Phase; Root = $Roots.Root
            Zmx = $Roots.Zmx; Support = $Roots.Support; Arguments = $arguments
        })
        return $run
    }
    function Close-CapOfflineSeed {
        param($SeedRun)
        if ($SeedRun.CleanupComplete) { return }
        if (-not $SeedRun.Identity.Process.WaitForExit(3000)) {
            $null = Stop-CapManagedProcess -Identity $SeedRun.Identity -TimeoutMilliseconds 3000
        }
        if (-not $SeedRun.Identity.Process.WaitForExit(2000) -or
            $SeedRun.Identity.Process.ExitCode -ne 0) {
            throw 'Mock phase seed did not exit cleanly within its bounded no-GUI wait.'
        }
        Write-CapRunStreams -Run $SeedRun -Label "$($SeedRun.Phase)-mock-seed"
        $SeedRun.SeedReceipt.exitCode = $SeedRun.Identity.Process.ExitCode
        $SeedRun.SeedReceipt.stdoutEof = $SeedRun.StdoutTask.IsCompleted
        $SeedRun.SeedReceipt.stderrEof = $SeedRun.StderrTask.IsCompleted
        $SeedRun.SeedReceipt.cleanupStatus = 'CLEAN_ZERO_SURVIVORS_EOF'
        $SeedRun.CleanupComplete = $true
        $script:sceneMock.seedCloses.Add($SeedRun.SeedReceipt.phase)
    }
    function Start-CapGraphCodeApp {
        param($Roots, [string]$Phase, [string]$PipeName, [string]$SessionPrefix, [switch]$ActionsFixture)
        $environment = Get-CapBaseEnvironment -Roots $Roots -PipeName $PipeName `
            -SessionPrefix $SessionPrefix -ActionsFixture:$ActionsFixture
        if ($environment.ContainsKey('GRAPHCODE_UIA_SHOW_UPDATE') -or
            $environment.GRAPHCODE_UIA_UPDATE_AVAILABLE -ne '1' -or
            -not $environment.GRAPHCODE_GATE_CWD.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase) -or
            $environment.ZMX_DIR -cne $Roots.Zmx) {
            throw "Unsafe or incorrect $Phase app environment in the worker scene flow."
        }
        if ($ActionsFixture -and
            ($environment.GRAPHCODE_UIA_FIXTURE_ROWS -ne '1' -or
             $environment.GRAPHCODE_UIA_CONNECTION_FAILURE -ne '1' -or
             $environment.GRAPHCODE_UIA_RESET_SIDEBAR -ne '1')) {
            throw "Actions scene did not receive the isolated builtin UIA fixture environment for $Phase."
        }
        $script:sceneMock.appEnvironments.Add([pscustomobject]@{
            Phase = $Phase; ActionsFixture = [bool]$ActionsFixture; Pipe = $PipeName
            Support = $Roots.Support; Local = $Roots.Local; Zmx = $Roots.Zmx
            ShowUpdate = $environment.ContainsKey('GRAPHCODE_UIA_SHOW_UPDATE')
            UpdateAvailable = $environment.GRAPHCODE_UIA_UPDATE_AVAILABLE
        })
        $run = Start-CapManagedProcess -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 250; exit 0') `
            -WorkingDirectory (Join-Path $root 'fixtures\projects\Alpha') `
            -Role "offline-scene-mock-$Phase" -Environment $environment
        $run.Identity | Add-Member -NotePropertyName CapturePhase -NotePropertyValue $Phase
        $appRun = New-CapAppRunRecord -Run $run -Phase $Phase -SessionPrefix $SessionPrefix
        if ($appRun.CleanupComplete) { throw 'Production app-run record must start with cleanup incomplete.' }
        $script:runs.Add($run)
        Write-CapProcessJournal -Identity $run.Identity -Phase $Phase
        $script:applicationRuns.Add($appRun)
        $script:sceneMock.appRuns.Add($appRun)
        return $appRun
    }
    function Invoke-CapSceneAction {
        param($AppRun, [string]$Action, [string]$Name)
        if ($Action -in @('reply', 'reclaim', 'keep')) { throw "Mutating scene mock action is prohibited: $Action." }
        $script:sceneMock.actionCalls.Add([pscustomobject]@{
            Phase = $AppRun.Phase; Action = $Action; Name = $Name
        })
    }
    function Wait-CapVisibleElement {
        param($Window, $ProcessIdentity, [string]$Name, [string]$AutomationId, [string]$AutomationIdPrefix)
        $script:sceneMock.zoomSelectors.Add([pscustomobject]@{
            Phase = $ProcessIdentity.CapturePhase; Name = $Name; AutomationIdPrefix = $AutomationIdPrefix
        })
        return [pscustomobject]@{
            Name = $Name
            AutomationId = "$AutomationIdPrefix$Name"
            IsOffscreen = $false
            BoundingRectangle = [pscustomobject]@{ Left = 1.0; Top = 2.0; Width = 250.0; Height = 96.0 }
        }
    }
    function Measure-CapZoom {
        param($Element, [int]$NaturalWidth)
        $script:sceneMock.zoomMeasurements.Add([pscustomobject]@{
            Phase = $script:sceneMock.zoomSelectors[$script:sceneMock.zoomSelectors.Count - 1].Phase
            Name = $Element.Name; NaturalWidth = $NaturalWidth
        })
        return [pscustomobject]@{
            Name = $Element.Name; AutomationId = $Element.AutomationId
            NaturalWidth = $NaturalWidth; MeasuredWidth = [double]$NaturalWidth; ZoomPercent = 100.0
        }
    }
    function Get-CapWindowMetrics {
        param($Window, $ProcessIdentity)
        return [pscustomobject]@{
            OuterBounds = @(30, 30, 1486, 989)
            ClientBounds = @(0, 0, 1440, 900)
            Dpi = 96
        }
    }
    function Capture-CapWindow {
        param($Window, $ProcessIdentity, [string]$Path)
        $script:sceneMock.capturePaths.Add($Path)
        return [pscustomobject]@{
            IsMock = $true; Sha256 = ('A' * 64); Width = 1456; Height = 959
            SampledColors = 8; NonMagentaSamples = 30; Dpi = 96
        }
    }
    function Get-CapGraphActionObservations {
        param($RootHandle, $ProcessIdentity, [string[]]$RequiredNames)
        $script:sceneMock.actionObservations.Add([pscustomobject]@{
            Phase = $ProcessIdentity.CapturePhase; RequiredNames = @($RequiredNames)
        })
        return @($RequiredNames | ForEach-Object {
            [pscustomobject]@{ Name = $_; AutomationId = "action-$_"; ProcessId = $ProcessIdentity.Pid }
        })
    }
    function Close-CapGraphCodeApp {
        param($AppRun, [switch]$NormalExit)
        $script:sceneMock.cleanupAttempts.Add([pscustomobject]@{
            Phase = $AppRun.Phase; AlreadyComplete = [bool]$AppRun.CleanupComplete
        })
        if ($AppRun.CleanupComplete) { return }
        if (-not $AppRun.Run.Identity.Process.WaitForExit(3000)) {
            $null = Stop-CapManagedProcess -Identity $AppRun.Run.Identity -TimeoutMilliseconds 3000
        }
        if (-not $AppRun.Run.Identity.Process.WaitForExit(2000)) {
            throw 'Mocked app process did not exit within its bounded no-GUI test wait.'
        }
        if ($AppRun.Run.Identity.Process.ExitCode -ne 0 -or
            -not $AppRun.Run.StdoutTask.Wait(2000) -or -not $AppRun.Run.StderrTask.Wait(2000)) {
            throw 'Mocked app exit code or redirected stream EOF failed.'
        }
        $AppRun.CleanupComplete = $true
        $script:sceneMock.cleanupCalls.Add([pscustomobject]@{
            Phase = $AppRun.Phase; NormalExit = [bool]$NormalExit; CleanupComplete = $AppRun.CleanupComplete
        })
    }
    foreach ($phase in @('before', 'after')) {
        $null = Invoke-CapNormalScenes -Phase $phase
        $null = Invoke-CapActionsScene -Phase $phase
    }
    $mockManifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
    $expectedScenePairs = @(
        'before:project-alpha', 'before:project-beta', 'before:overview', 'before:workspace', 'before:actions',
        'after:project-alpha', 'after:project-beta', 'after:overview', 'after:workspace', 'after:actions'
    )
    $actualScenePairs = @($script:images | ForEach-Object { "$($_.phase):$($_.scene)" })
    $scenePairDifference = Compare-Object ($expectedScenePairs | Sort-Object) ($actualScenePairs | Sort-Object)
    if ($script:images.Count -ne 10 -or $scenePairDifference -or
        @($script:images | Where-Object {
            $_.captureMode -ne 'MOCK_NO_IMAGE' -or $_.privacyStatus -ne 'NOT_CAPTURED_MOCK_ONLY'
        }).Count -ne 0 -or
        @($script:sceneMock.zoomSelectors).Count -ne 8 -or
        @($script:sceneMock.zoomMeasurements).Count -ne 8 -or
        @($script:sceneMock.appRuns | Where-Object { -not $_.CleanupComplete }).Count -ne 0 -or
        $script:sceneMock.cleanupAttempts.Count -ne 8 -or
        @($script:sceneMock.cleanupAttempts | Where-Object AlreadyComplete).Count -ne 4 -or
        @($script:sceneMock.cleanupAttempts | Where-Object { -not $_.AlreadyComplete }).Count -ne 4 -or
        $script:sceneMock.seedStarts.Count -ne 2 -or $script:sceneMock.seedCloses.Count -ne 2 -or
        @($script:zmxSeedReceipts | Where-Object {
            -not $_.mockOnly -or $_.cleanupStatus -ne 'CLEAN_ZERO_SURVIVORS_EOF' -or
            $_.exitCode -ne 0 -or -not $_.stdoutEof -or -not $_.stderrEof
        }).Count -ne 0 -or
        @($script:sceneMock.appEnvironments | Where-Object ShowUpdate -eq $true).Count -ne 0 -or
        @($script:sceneMock.appEnvironments | Where-Object UpdateAvailable -ne '1').Count -ne 0 -or
        @($script:sceneMock.actionCalls | Where-Object Action -in @('reply', 'reclaim', 'keep')).Count -ne 0 -or
        @($script:sceneMock.actionObservations | Where-Object {
            ($_.RequiredNames | Sort-Object) -join ',' -cne 'Keep,Reclaim,Reply'
        }).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $script:outputDirectory -Filter '*.png' -File).Count -ne 0 -or
        @($script:runs | Where-Object {
            -not [CapNative]::IsExited($_.Identity.Process.Handle, $_.Identity.Pid) -or
            -not $_.StdoutTask.IsCompleted -or -not $_.StderrTask.IsCompleted
        }).Count -ne 0 -or
        $mockManifest.executionMode -ne 'OFFLINE_MOCK_ONLY') {
        throw 'Actual B normal/actions scene functions failed their no-GUI mocked execution contract.'
    }
    $expectedSelectors = @(
        'before:RefMain:canvas-card-', 'before:RefComposite:canvas-card-',
        'before:RefMain:canvas-card-', 'before:UIA loop A:canvas-card-',
        'after:RefMain:canvas-card-', 'after:RefComposite:canvas-card-',
        'after:RefMain:canvas-card-', 'after:UIA loop A:canvas-card-'
    )
    $actualSelectors = @($script:sceneMock.zoomSelectors | ForEach-Object {
        "$($_.Phase):$($_.Name):$($_.AutomationIdPrefix)"
    })
    $expectedNaturalWidths = @(250, 250, 220, 250, 250, 250, 250, 250)
    $actualNaturalWidths = @($script:sceneMock.zoomMeasurements | ForEach-Object NaturalWidth)
    if (($expectedSelectors -join '|') -cne ($actualSelectors -join '|')) {
        throw 'Scene functions did not resolve the exact B zoom-probe names and AutomationId prefixes.'
    }
    if (($expectedNaturalWidths -join ',') -cne ($actualNaturalWidths -join ',') -or
        @($script:images | Where-Object { $_.zoom -and $_.zoom.ZoomPercent -ne 100.0 }).Count -ne 0) {
        throw 'Scene functions did not preserve the B phase-specific 100% natural-width zoom contract.'
    }
    if (@($script:sceneMock.appEnvironments | ForEach-Object Support | Sort-Object -Unique).Count -ne 4 -or
        @($script:sceneMock.appEnvironments | ForEach-Object Local | Sort-Object -Unique).Count -ne 4 -or
        @($script:sceneMock.appEnvironments | ForEach-Object Zmx | Sort-Object -Unique).Count -ne 4) {
        throw 'Scene functions reused a before/after or normal/actions private profile root.'
    }
    foreach ($image in $script:images) {
        $provenance = if ($image.phase -eq 'before') { $script:job.binaries.before } else { $script:job.binaries.after }
        if ($image.sourceHead -ne $provenance.source -or
            $image.binaryBuiltAtSource -ne $provenance.binaryBuiltAtSource -or
            $image.binarySha256 -ne $provenance.sha256) {
            throw "Image source/binary provenance was mislabeled for $($image.phase)/$($image.scene)."
        }
    }
    $sceneFunctionEvidence = [ordered]@{
        mode = $mockManifest.executionMode
        normalAndActionsPhases = @('before', 'after')
        scenePairs = @($actualScenePairs)
        mockImageRecords = $script:images.Count
        actualImageFiles = 0
        zoomSelectors = @($script:sceneMock.zoomSelectors)
        zoomNaturalWidths = @($script:sceneMock.zoomMeasurements)
        appEnvironments = @($script:sceneMock.appEnvironments)
        appCleanup = @($script:sceneMock.cleanupCalls)
        appCleanupAttempts = @($script:sceneMock.cleanupAttempts)
        sceneActions = @($script:sceneMock.actionCalls)
        actionObservationMocks = @($script:sceneMock.actionObservations)
        phasePrivateSeedMocks = @($script:sceneMock.seedStarts | ForEach-Object {
            [pscustomobject]@{
                phase = $_.Phase; mockOnly = $true; zmxRoot = $_.Zmx
                supportRoot = $_.Support; argumentList = $_.Arguments
            }
        })
    }


            $results.Add([ordered]@{name='preserved B five-scene/two-phase mocked component regression';passed=$true;detail=$sceneFunctionEvidence})
            Write-Host 'PASS preserved B five-scene/two-phase mocked component regression (zero actual images)'
        } catch {
            $results.Add([ordered]@{name='preserved B five-scene/two-phase mocked component regression';passed=$false;error=$_.Exception.ToString();stack=$_.ScriptStackTrace})
            Write-Host "FAIL scene component regression: $($_.Exception.Message)"
        } finally {
            foreach ($run in $script:runs) {
                if (-not [CapNative]::IsExited($run.Identity.Process.Handle, $run.Identity.Pid)) {
                    $null = Stop-CapManagedProcess -Identity $run.Identity -TimeoutMilliseconds 5000
                }
                Assert-CapTest ($run.StdoutTask.Wait(2000) -and $run.StderrTask.Wait(2000)) 'Component process EOF was incomplete.'
                $run.Identity.Process.Dispose()
            }
        }

    }
} catch {
    $results.Add([ordered]@{ name = 'suite setup/execution'; passed = $false; error = $_.Exception.ToString() })
    Write-Host "FAIL suite setup/execution: $($_.Exception.Message)"
} finally {
    foreach ($path in $sourceHashesBefore.Keys) {
        Assert-CapTest ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $sourceHashesBefore[$path]) "Source changed during rehearsal: $path"
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in $results) {
        if (-not $names.Add($result.name)) { throw "Duplicate test case would inflate executed counts: $($result.name)" }
    }
    $passed = @($results | Where-Object passed -EQ $true).Count
    $failed = @($results | Where-Object passed -EQ $false).Count
    $report = [ordered]@{ suite = 'UiCaptureDriver'; executed = $results.Count; passed = $passed; failed = $failed
        mode = $mode; gui = 'NotExecuted'; nativeCompatibilityPreflight = 'NotExecuted'; images = 0
        backendTurns = 0; fixture = $target; sourceHashesBeforeImport = $sourceHashesBefore
        controls = [ordered]@{ moduleSha256 = $sourceHashesBefore[$modulePath]
            workerSha256 = $sourceHashesBefore[$workerPath]; supervisorSha256 = $sourceHashesBefore[$supervisorPath] }
        cases = @($results) }
    $report | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $scratch 'report.json') -Encoding utf8NoBOM
}
[ordered]@{ suite = 'UiCaptureDriver'; executed = $results.Count; passed = $passed; failed = $failed; artifacts = $scratch } |
    ConvertTo-Json -Compress
if ($results.Count -le 0 -or $failed -ne 0 -or $passed -ne $results.Count) { exit 1 }
exit 0
