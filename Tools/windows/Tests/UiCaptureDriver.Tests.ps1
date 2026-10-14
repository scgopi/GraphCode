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
        [string]$LeaseMutation = ''
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

$target = $null
try {
    $target = New-CapHarmlessTarget
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
