$ErrorActionPreference = "Stop"

function Test-MultiProjectProtocolContracts([string] $stubSource, [string] $gateSource, [string] $stubPath, [string] $pwsh) {
  foreach ($source in @($stubSource, $gateSource)) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
    if ($errors.Count -ne 0) { throw "RED: multi-project source does not parse" }
    foreach ($definition in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          ($node.Name -like "*-MultiProject*" -or $node.Name -cin @(
            "ConvertTo-SketchCanonicalJson",
            "Test-RetryableUiaError",
            "Test-UpdateBannerClickTarget"
          ))
      }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ("gc-mp-" + [guid]::NewGuid().ToString("N"))
  $alpha = Join-Path $scratch "Alpha"
  $beta = Join-Path $scratch "Beta"
  $null = New-Item -ItemType Directory -Path $alpha, $beta
  $a = "11111111-1111-4111-8111-111111111111"
  $b = "22222222-2222-4222-8222-222222222222"
  $listId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  $renameId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  $token = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  $results = [Collections.Generic.List[object]]::new()

  function Assert-MultiCase([bool] $condition, [string] $message) {
    if (-not $condition) { throw "RED: multi-project $message" }
  }
  function Invoke-MultiCase([string] $name, [scriptblock] $body, [switch] $Negative) {
    $detail = & $body
    $results.Add([ordered]@{ name = $name; negative = [bool]$Negative; detail = $detail })
  }
  function Reject-MultiCase([scriptblock] $body, [string] $prefix) {
    try { & $body | Out-Null } catch {
      Assert-MultiCase ($_.Exception.Message.StartsWith($prefix, [StringComparison]::Ordinal)) "wrong rejection: $($_.Exception.Message)"
      return $_.Exception.Message
    }
    throw "RED: multi-project expected actual $prefix rejection"
  }
  Invoke-MultiCase "compact overview narrow client retains the Mac lane and requires real pan" {
    $geometry = Get-MultiProjectLaneGeometry @(220,34,1028,900) @(382,134,632,230)
    Assert-MultiCase (($geometry.band -join ",") -ceq "300,96,1822,250" -and
      ($geometry.open -join ",") -ceq "1690,106,1746,126") "250x96 card or Mac minimum lane differs"
    $null = Reject-MultiCase { Get-MultiProjectClippedRectangle $geometry.open @(220,34,1028,900) } "MULTIPROJECT_BOUNDS"
    $geometry = Get-MultiProjectLaneGeometry @(220,34,1028,900) @(-390,134,-140,230)
    $worktrees = @(($geometry.band[2] - 72),106,($geometry.band[2] - 18),126)
    $clipped = Get-MultiProjectClippedRectangle $worktrees @(220,34,1028,900)
    Assert-MultiCase (($worktrees -join ",") -ceq "978,106,1032,126" -and
      ($clipped -join ",") -ceq "978,106,1028,126") "narrow Worktrees clipping was hidden"
    return "Source-only producer lane; offscreen action rejected, measured camera-pan projection retains partial-control clipping"
  }
  Invoke-MultiCase "compact overview wide client and DPI preserve exact geometry" {
    $geometry = Get-MultiProjectLaneGeometry @(220,34,1200,900) @(382,134,632,230)
    Assert-MultiCase (($geometry.band -join ",") -ceq "300,96,1822,250") "lane incorrectly collapsed to viewport width"
    $scaled = Get-MultiProjectLaneGeometry @(330,51,1542,1350) @(573,201,948,345)
    Assert-MultiCase (($scaled.band -join ",") -ceq "450,144,2733,375" -and
      ($scaled.open -join ",") -ceq "2535,159,2619,189") "144-DPI geometry was scaled more than once"
    $negativeX = Get-MultiProjectLaneGeometry @(358,215,1402,942) @(19,315,268,411) @(1032,287,1318,307)
    Assert-MultiCase ($negativeX.scale -eq 1 -and
      ($negativeX.open -join ",") -ceq "1326,287,1382,307") "horizontal-pan edge rounding corrupted the caption anchor"
    for ($index = 0; $index -lt 4; $index++) {
      Assert-MultiCase ([Math]::Abs($negativeX.summary[$index] - @(1032,287,1318,307)[$index]) -le 1) `
        "retained negative-X projection exceeds the existing one-pixel summary limit"
    }
    return "Literal narrow/wide and once-only 144-DPI source geometry"
  }
  Invoke-MultiCase "compact overview fitted rounding retains source geometry" {
    $geometry = Get-MultiProjectLaneGeometry @(228,85,1036,780) @(390,185,500,227)
    Assert-MultiCase ($geometry.scale -eq 0.44 -and $geometry.scaleSource -ceq "card-width-rounded" -and
      [Math]::Abs($geometry.normalizedHeight - 95.45454545454545) -lt $geometry.heightTolerance) `
      "sub-100% integer-rounded card height did not retain its source geometry"
    return "Sub-100% UIA height rounding bounded from the longer observed width denominator"
  }
  Invoke-MultiCase "compact overview rejects obsolete 220x86 card geometry" -Negative {
    $null = Reject-MultiCase { Get-MultiProjectLaneGeometry @(220,34,1200,900) @(262,118,482,204) } "MULTIPROJECT_BOUNDS"
    $null = Reject-MultiCase { Get-MultiProjectLaneGeometry @(358,215,1402,942) @(19,210,268,306) } "MULTIPROJECT_BOUNDS"
    $null = Reject-MultiCase { Get-MultiProjectLaneGeometry @(358,215,1402,942) @(19,315,268,400) } "MULTIPROJECT_BOUNDS"
    $null = Reject-MultiCase { Get-MultiProjectLaneGeometry @(358,215,1402,942) @(19,315,267,411) } "MULTIPROJECT_BOUNDS"
    return "Old card, vertical clipping, wrong scale/aspect, and a greater-than-one-pixel width discrepancy rejected"
  }
  Invoke-MultiCase "compact overview rejects the obsolete 760-pixel lane floor" -Negative {
    $geometry = Get-MultiProjectLaneGeometry @(220,34,1028,900) @(382,134,632,230)
    Assert-MultiCase (($geometry.band -join ",") -cne "244,72,1004,248" -and
      ($geometry.open -join ",") -cne "872,82,928,102") "old 760-pixel action geometry was accepted"
    return "New source geometry rejects the old narrow-window lane/action coordinates"
  }
  Invoke-MultiCase "dynamic Rename title uses the exact fixture title" {
    $expected = Get-MultiProjectRenameTitle "Alpha renamed"
    Assert-MultiCase ($expected -ceq 'Rename “Alpha renamed”' -and
      (Test-MultiProjectRenameTitle $expected $expected)) "exact fixture-derived Rename title drifted"
    return "Exact fixture title, curly quotes, and bounded title predicate"
  }
  foreach ($titleMutation in @(
      "Rename Loop",
      'Rename "Alpha renamed"',
      'Rename “Alpha renamed” extra',
      'Rename “”',
      ('Rename “Alpha' + "`n" + 'renamed”')
    )) {
    Invoke-MultiCase ("dynamic Rename title rejects " + ($titleMutation -replace "`n"," newline ")) -Negative {
      Assert-MultiCase (-not (Test-MultiProjectRenameTitle $titleMutation 'Rename “Alpha renamed”')) `
        "obsolete, malformed, or non-exact Rename title was accepted"
      return "Exact fixture-derived title mismatch rejected"
    }
  }
  Invoke-MultiCase "bounded Rename title pattern accepts one unavailable-fixture title" {
    Assert-MultiCase (Test-MultiProjectRenameTitle 'Rename “Owned loop”') `
      "bounded unavailable-fixture Rename pattern rejected a valid title"
    return "Tightly bounded fallback pattern only; fixture-driven paths use exact equality"
  }
  foreach ($titleMutation in @(
      "Rename Loop",
      'Rename “”',
      'Rename “nested “quote””',
      ('Rename “' + ("x" * 513) + '”')
    )) {
    Invoke-MultiCase ("bounded Rename title pattern rejects malformed case " + $titleMutation.Length) -Negative {
      Assert-MultiCase (-not (Test-MultiProjectRenameTitle $titleMutation)) `
        "bounded unavailable-fixture Rename pattern widened"
      return "Legacy, empty, nested-quote, or overlong title rejected"
    }
  }
  $ownedSheet = [ordered]@{
    processId = 4242
    handle = [long]42
    owner = [long]7
    className = "GraphCodeSheetHost"
    title = 'Delete “Alpha renamed”?'
    contentClass = "GraphCodeWindowsDialogContent"
    visible = $true
    captionless = $true
  }
  Invoke-MultiCase "Delete custom sheet accepts exact owned captionless identity" {
    Assert-MultiCase (Test-MultiProjectOwnedSheetIdentity $ownedSheet 4242 ([IntPtr]7) `
      'Delete “Alpha renamed”?' "GraphCodeWindowsDialogContent") `
      "exact Delete custom-sheet identity was rejected"
    return "Exact PID, native owner, host class, title, visibility, and captionless style"
  }
  foreach ($identityMutation in @(
      "pid", "owner", "class", "title", "content", "hidden", "captioned", "zero-handle"
    )) {
    Invoke-MultiCase ("Delete custom sheet rejects " + $identityMutation) -Negative {
      $candidate = [ordered]@{
        processId = $ownedSheet.processId
        handle = $ownedSheet.handle
        owner = $ownedSheet.owner
        className = $ownedSheet.className
        title = $ownedSheet.title
        contentClass = $ownedSheet.contentClass
        visible = $ownedSheet.visible
        captionless = $ownedSheet.captionless
      }
      switch ($identityMutation) {
        "pid" { $candidate.processId = 7777 }
        "owner" { $candidate.owner = [long]8 }
        "class" { $candidate.className = "#32770" }
        "title" { $candidate.title = "Delete Loop" }
        "content" { $candidate.contentClass = "GraphCodeNativeForm" }
        "hidden" { $candidate.visible = $false }
        "captioned" { $candidate.captionless = $false }
        "zero-handle" { $candidate.handle = [long]0 }
      }
      Assert-MultiCase (-not (Test-MultiProjectOwnedSheetIdentity $candidate 4242 ([IntPtr]7) `
        'Delete “Alpha renamed”?' "GraphCodeWindowsDialogContent")) `
        "foreign, legacy, hidden, captioned, or invalid Delete sheet identity was accepted"
      return "Identity guard rejected before any input"
    }
  }
  $updateBannerTarget = [ordered]@{
    processId = 4242
    automationId = "sidebar-update-banner-83fd6a5f429785e1"
    name = "Update available"
    controlType = "ControlType.Button"
    enabled = $true
    left = 208.0
    top = 704.0
    right = 412.0
    bottom = 754.0
  }
  Invoke-MultiCase "update banner click accepts owned foreground target after Later" {
    Assert-MultiCase (Test-UpdateBannerClickTarget $updateBannerTarget 4242 ([IntPtr]42) `
      ([IntPtr]42) 4242 "Update offer deferred") `
      "owned foreground update banner target was rejected"
    return "Published UIA bounds, shell foreground and focus, and source-confirmed Later status"
  }
  foreach ($targetMutation in @("process", "window", "focus", "status")) {
    Invoke-MultiCase ("update banner click rejects wrong " + $targetMutation) -Negative {
      $candidate = [ordered]@{
        processId = $updateBannerTarget.processId
        automationId = $updateBannerTarget.automationId
        name = $updateBannerTarget.name
        controlType = $updateBannerTarget.controlType
        enabled = $updateBannerTarget.enabled
        left = $updateBannerTarget.left
        top = $updateBannerTarget.top
        right = $updateBannerTarget.right
        bottom = $updateBannerTarget.bottom
      }
      $foreground = [IntPtr]42
      $focusedProcessId = 4242
      $status = "Update offer deferred"
      switch ($targetMutation) {
        "process" { $candidate.processId = 7777 }
        "window" { $foreground = [IntPtr]43 }
        "focus" { $focusedProcessId = 7777 }
        "status" { $status = "Update available" }
      }
      Assert-MultiCase (-not (Test-UpdateBannerClickTarget $candidate 4242 ([IntPtr]42) `
        $foreground $focusedProcessId $status)) `
        "foreign process, foreground window, focus, or stale status was accepted"
      return "Ownership and source-confirmed status guard rejected before input"
    }
  }
  Invoke-MultiCase "actual caption Open assignment consumes the exported caption snapshot" {
    $gateAst = [Management.Automation.Language.Parser]::ParseInput($gateSource, [ref]$null, [ref]$null)
    $openAssignments = @($gateAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq "laneOpenScreenX"
    }, $true))
    $worktreeAssignments = @($gateAst.FindAll({
      param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq "laneWorktreesScreenX"
    }, $true))
    Assert-MultiCase ($openAssignments.Count -eq 1) "actual caption Open assignment missing or ambiguous"
    Assert-MultiCase ($worktreeAssignments.Count -eq 0) "uninspected lane still prepares an obsolete Worktrees click"
    $evaluate = [scriptblock]::Create(
      'param($laneSnapshot) ' + $openAssignments[0].Extent.Text + '; return $laneOpenScreenX')
    foreach ($expected in @(614, 866, 1013)) {
      $snapshot = [pscustomobject]@{ OpenX = $expected }
      $actual = & $evaluate $snapshot
      Assert-MultiCase ($actual -eq $expected) `
        "actual caption Open point expected $expected, found $actual"
    }
    return "Executed production caption snapshot-consumer AST and rejected any uninspected Worktrees click"
  }
  $eventStart = [DateTime]::Parse("2026-10-01T18:29:43.1462496Z").ToUniversalTime()
  $eventEnd = $eventStart.AddSeconds(1)
  $eventProcess = [pscustomobject]@{ Id = 5832; StartTime = $eventStart }
  $eventExe = "D:\owned\graphcode-windows.exe"
  function New-MultiStartupEvent([string] $mutation = "") {
    $pidValue = "0x{0:x}" -f $eventProcess.Id
    $generation = "0x{0:x}" -f $eventStart.ToFileTimeUtc()
    $path = $eventExe; $provider = "Application Error"; $timestamp = $eventEnd.ToString("o")
    $module = "kernelbase.dll"; $code = "0xc0000142"; $extra = ""
    switch ($mutation) {
      "foreign-pid" { $pidValue = "0x7777"; $module = "SECRET_FOREIGN_MODULE" }
      "reused-pid" { $generation = "0x{0:x}" -f $eventStart.AddSeconds(-1).ToFileTimeUtc() }
      "foreign-path" { $path = "D:\foreign\other.exe"; $module = "SECRET_FOREIGN_MODULE" }
      "provider" { $provider = "Windows Error Reporting" }
      "outside-window" { $timestamp = $eventStart.AddSeconds(-1).ToString("o") }
      "duplicate-id" { $extra = '<Data Name="ProcessId">0x7777</Data>' }
      "module-path" { $module = "C:\private\SECRET_FOREIGN_MODULE.dll" }
      "code-type" { $code = "SECRET_COMMANDLINE" }
      "unnamed" { $extra = "<Data>SECRET_MESSAGE</Data>" }
    }
    $xml = @"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="$provider"/><EventID>1000</EventID><TimeCreated SystemTime="$timestamp"/><EventRecordID>42</EventRecordID><Execution ProcessID="9999"/></System><EventData><Data Name="ProcessId">$pidValue</Data><Data Name="ProcessCreationTime">$generation</Data><Data Name="AppPath">$path</Data><Data Name="ModuleName">$module</Data><Data Name="ExceptionCode">$code</Data><Data Name="FaultingOffset">0x1234</Data>$extra</EventData></Event>
"@
    if ($mutation -ceq "execution-only") { $xml = $xml.Replace('<Data Name="ProcessId">' + $pidValue + '</Data>', '') }
    if ($mutation -ceq "missing-generation") { $xml = $xml.Replace('<Data Name="ProcessCreationTime">' + $generation + '</Data>', '') }
    if ($mutation -ceq "oversized") { $xml += "x" * 65536 }
    if ($mutation -ceq "bad-xml") { $xml = "<Event>broken" }
    if ($mutation -ceq "dtd") { $xml = '<!DOCTYPE Event [<!ENTITY canary SYSTEM "file:///D:/foreign">]>' + $xml }
    $event = [pscustomobject]@{ Xml = $xml }
    $event | Add-Member ScriptMethod ToXml { return $this.Xml }
    $event | Add-Member ScriptProperty Message { throw "FORBIDDEN event Message read" }
    return $event
  }
  function Invoke-MultiStartupMock($records, $process = $eventProcess, $path = $eventExe, $when = $eventEnd,
      [string] $faults = "") {
    $script:startupQueryCalls = 0; $script:startupFileCalls = 0; $script:startupSummaryCalls = 0; $script:startupWarningCalls = 0
    $script:startupRecord = $null
    $original = [InvalidOperationException]::new("shell exited with code -1073741502")
    $caught = $null
    try {
      Invoke-MultiProjectOwnedStartupFailure $process -1073741502 $path $scratch { throw $original } -observedUtc $when -querySource {
        param($filterXml, $maxEvents)
        $script:startupQueryCalls++
        Assert-MultiCase ($maxEvents -eq 8) "startup query result bound not8"
        $doc = [xml]$filterXml
        $selects = @($doc.QueryList.Query.Select)
        Assert-MultiCase ($selects.Count -eq 1 -and $selects[0].Path -ceq "Application" -and
          $selects[0].InnerText.Contains("Provider[@Name='Application Error']") -and
          $selects[0].InnerText.Contains("EventID=1000") -and
          $selects[0].InnerText.Contains("Data[@Name='ProcessId']") -and
          $selects[0].InnerText.Contains("Data[@Name='ProcessCreationTime']") -and
          $selects[0].InnerText.Contains("Data[@Name='AppPath']") -and
          $selects[0].InnerText.Contains("Data[@Name='ProcessId']='5832'") -and
          $selects[0].InnerText.Contains("Data[@Name='ProcessCreationTime']='" + $eventStart.ToFileTimeUtc() + "'") -and
          $selects[0].InnerText.Contains($eventExe) -and
          $selects[0].InnerText.Contains($eventStart.ToString("o")) -and
          $selects[0].InnerText.Contains($eventEnd.ToString("o")) -and
          -not $selects[0].InnerText.Contains("Execution")) "server selector is missing held subject generation/path/time"
        if ($faults.Contains("query")) { throw [IO.IOException]::new("SECRET_QUERY_COMMANDLINE") }
        return $records
      } -fileSink {
        param($filePath, $json)
        $script:startupFileCalls++
        if ($faults.Contains("file")) { throw [IO.IOException]::new("SECRET_FILE_COMMANDLINE") }
        $script:startupRecord = $json | ConvertFrom-Json
      } -summarySink {
        param($line)
        $script:startupSummaryCalls++
        if ($faults.Contains("summary")) { throw [IO.IOException]::new("SECRET_SUMMARY_COMMANDLINE") }
        Assert-MultiCase (-not $line.Contains("SECRET") -and -not $line.Contains("<Event") -and
          -not $line.Contains("Execution")) "startup output retained foreign/raw event fields"
      } -warningSink {
        param($line)
        $script:startupWarningCalls++
        if ($faults.Contains("warning")) { throw [IO.IOException]::new("SECRET_WARNING_COMMANDLINE") }
        Assert-MultiCase (-not $line.Contains("SECRET")) "exception payload leaked to secondary warning"
      }
    } catch { $caught = $_ }
    Assert-MultiCase ([object]::ReferenceEquals($caught.Exception, $original) -and
      $caught.Exception.Message -ceq "shell exited with code -1073741502") "startup diagnostic replaced original exception"
    return [ordered]@{ primary = $caught; report = $caught.Exception.Data["OwnedStartupEvents"]
      secondary = @($caught.Exception.Data["OwnedStartupEventDiagnostics"]); queryCalls = $script:startupQueryCalls }
  }
  Invoke-MultiCase "canonical owned startup event retained without changing primary" {
    $result = Invoke-MultiStartupMock @((New-MultiStartupEvent))
    Assert-MultiCase ($result.queryCalls -eq 1 -and $result.report.events.Count -eq 1 -and
      $result.report.events[0].module.value -ceq "kernelbase.dll" -and $result.report.events[0].subjectPID -eq 5832 -and
      -not $result.report.rootCauseEstablished -and $result.report.providers[1].readCount -eq 0 -and
      $result.report.providers[2].readCount -eq 0) "canonical subject data lost or unproved provider queried"
    return "One mocked server query, exact-owned typed module observation, original startup still fails; no EventLog/native calls"
  }
  Invoke-MultiCase "canonical startup event absence is explicitly unknown" {
    $result = Invoke-MultiStartupMock @()
    Assert-MultiCase ($result.report.state -ceq "unknown-no-matching-canonical-events" -and
      $result.report.events.Count -eq 0 -and $result.queryCalls -eq 1) "empty query mislabeled module diagnosis"
    return "Positive query execution with zero matches is UNKNOWN, not passing startup"
  }
  Invoke-MultiCase "owned canonical event missing module fields retains explicit unavailability" {
    $event = New-MultiStartupEvent
    $event.Xml = $event.Xml.Replace('<Data Name="ModuleName">kernelbase.dll</Data>', '').Replace('<Data Name="ExceptionCode">0xc0000142</Data>', '')
    $result = Invoke-MultiStartupMock @($event)
    Assert-MultiCase ($result.report.events.Count -eq 1 -and $result.report.events[0].module.state -ceq "unavailable" -and
      $result.report.events[0].exceptionCode.state -ceq "unavailable" -and $null -eq $result.report.events[0].module.value -and
      -not $result.report.rootCauseEstablished) "missing module/code fields were manufactured from failed exit"
    return "Owned identity observed, optional module/code unavailable, no synthesized DLL cause"
  }
  Invoke-MultiCase "actual query no-match error remains unknown while startup primary survives" {
    $original = [InvalidOperationException]::new("shell exited with code -1073741502"); $caught = $null
    $script:noMatchQueryCalls = 0
    try {
      Invoke-MultiProjectOwnedStartupFailure $eventProcess -1073741502 $eventExe $scratch { throw $original } -observedUtc $eventEnd `
        -querySource {
          param($filter,$maximum)
          $script:noMatchQueryCalls++
          throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new("No events"),
            "NoMatchingEventsFound", [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
        } -fileSink {param($path,$json)} -summarySink {param($line)} -warningSink {param($line)}
    } catch { $caught = $_ }
    Assert-MultiCase ($script:noMatchQueryCalls -eq 1 -and [object]::ReferenceEquals($caught.Exception,$original) -and
      $caught.Exception.Data["OwnedStartupEvents"].state -ceq "unknown-no-matching-canonical-events") "no-match error changed primary or invented module"
    return "Actual PowerShell no-match ErrorRecord branch, mock transport only"
  }
  foreach ($mutation in @("foreign-pid", "reused-pid", "foreign-path", "provider", "outside-window", "duplicate-id",
      "module-path", "code-type", "unnamed", "execution-only", "missing-generation", "oversized", "bad-xml", "dtd")) {
    Invoke-MultiCase ("startup event refuses " + $mutation) -Negative {
      $result = Invoke-MultiStartupMock @((New-MultiStartupEvent $mutation))
      Assert-MultiCase ($result.queryCalls -eq 1 -and $result.report.state -ceq "refused-or-unavailable" -and
        $result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) "selected identity/schema/size refusal weakened"
      return "Actual parser/held-identity guard rejects; original primary survives and no event content retained"
    }
  }
  foreach ($mutation in @("missing-pid", "missing-start", "relative-path", "old-window", "future-start", "unsafe-quotes")) {
    Invoke-MultiCase ("startup query refuses invalid held " + $mutation) -Negative {
      $process = [pscustomobject]@{ Id = 5832; StartTime = $eventStart }; $path = $eventExe
      switch ($mutation) {
        "missing-pid" { $process.Id = 0 }
        "missing-start" { $process.StartTime = $null }
        "relative-path" { $path = "relative.exe" }
        "old-window" { $process.StartTime = $eventStart.AddSeconds(-31) }
        "future-start" { $process.StartTime = $eventEnd.AddSeconds(1) }
        "unsafe-quotes" { $path = 'D:\owned\a''"b.exe' }
      }
      $result = Invoke-MultiStartupMock @() $process $path
      Assert-MultiCase ($result.queryCalls -eq 0 -and $result.secondary.Count -eq 1 -and
        $result.report.events.Count -eq 0) "invalid held identity still queried foreign event log"
      return "No query, original failed exit retained"
    }
  }
  foreach ($faults in @("query", "file", "summary", "query-file-summary-warning")) {
    Invoke-MultiCase ("startup retains typed secondary writer failures " + $faults) -Negative {
      $result = Invoke-MultiStartupMock @((New-MultiStartupEvent)) -faults $faults
      $expected = if ($faults -ceq "query-file-summary-warning") { 4 } else { 1 }
      Assert-MultiCase ($result.secondary.Count -eq $expected -and $result.queryCalls -eq 1) "startup secondary fault dropped"
      foreach ($failure in $result.secondary) {
        Assert-MultiCase ($failure.operation.StartsWith("startup-event") -and $failure.errorType -ceq "System.IO.IOException" -and
          $failure.hresult -is [int] -and -not $failure.message.Contains("SECRET")) "typed privacy-sanitized error missing"
      }
      return "Same original exception object, all typed failures attached, no query/process/input replay"
    }
  }
  Invoke-MultiCase "startup refuses event transport exceeding eight results" -Negative {
    $event = New-MultiStartupEvent
    $result = Invoke-MultiStartupMock @($event,$event,$event,$event,$event,$event,$event,$event,$event)
    Assert-MultiCase ($result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) "over-count transport silently truncated"
    return "Nine mocked records refused, no content output"
  }
  Invoke-MultiCase "startup refuses duplicate actual record identity" -Negative {
    $event = New-MultiStartupEvent
    $result = Invoke-MultiStartupMock @($event,$event)
    Assert-MultiCase ($result.report.events.Count -eq 0 -and $result.secondary.Count -eq 1) "duplicate event inflated observed modules"
    return "Duplicate event record refused, no repeated evidence"
  }
  Invoke-MultiCase "startup default transport refuses non-hosted execution without event query" -Negative {
    $savedActions = $env:GITHUB_ACTIONS
    $script:forbiddenLocalEventQueries = 0
    function Get-WinEvent { $script:forbiddenLocalEventQueries++; throw "Forbidden actual event transport" }
    $original = [InvalidOperationException]::new("shell exited with code -1073741502"); $caught = $null
    try {
      $env:GITHUB_ACTIONS = "false"
      try {
        Invoke-MultiProjectOwnedStartupFailure $eventProcess -1073741502 $eventExe $scratch { throw $original } -observedUtc $eventEnd `
          -fileSink {param($path,$json)} -summarySink {param($line)} -warningSink {param($line)}
      } catch { $caught = $_ }
    } finally { $env:GITHUB_ACTIONS = $savedActions }
    Assert-MultiCase ($script:forbiddenLocalEventQueries -eq 0 -and [object]::ReferenceEquals($caught.Exception,$original) -and
      $caught.Exception.Data["OwnedStartupEvents"].state -ceq "refused-non-hosted-query") "default query ran outside hosted CI"
    return "Zero mocked command invocations; actual EventLog cmdlet never called"
  }
  Invoke-MultiCase "startup query escapes exact executable XPath and XML" {
    $path = "D:\owned\a'b&c.exe"
    $identity = New-MultiProjectStartupEventQuery $eventProcess $path $eventEnd
    $doc = [xml]$identity.filterXml
    Assert-MultiCase ($doc.QueryList.Query.Select.InnerText.Contains('Data[@Name=''AppPath'']="D:\owned\a''b&c.exe"') -and
      $identity.filterXml.Contains("&amp;")) "path literal escaped incorrectly"
    return "Structured XML + quoted literal, no broad path predicate or event query"
  }
  Invoke-MultiCase "actual first startup failure branch invokes diagnostic once" -Negative {
    $ast = [Management.Automation.Language.Parser]::ParseInput($gateSource,[ref]$null,[ref]$null)
    $branch = $ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
      $n.Extent.Text.StartsWith('if ($process.HasExited)') -and $n.Extent.Text.Contains("Invoke-MultiProjectOwnedStartupFailure")},$true)
    Assert-MultiCase ($null -ne $branch) "actual first failure branch missing new wrapper"
    $process = [pscustomobject]@{ HasExited = $true; Id = 5832; ExitCode = -1073741502; StartTime = $eventStart }
    $Shell = $eventExe; $logDirectory = $scratch; $settingsDirectory = $scratch
    $script:branchDiagnosticCalls = 0; $script:branchLegacyCalls = 0
    function Write-UiaStartupFailureDiagnostic {param($held,$exit,$exe,$cwd,$logs,$support) $script:branchLegacyCalls++}
    function Invoke-MultiProjectOwnedStartupFailure {
      param($held,$exit,$exe,$logs,$failure)
      $script:branchDiagnosticCalls++
      & $failure
    }
    $caught = $null
    try { . ([scriptblock]::Create($branch.Extent.Text)) } catch { $caught = $_ }
    Assert-MultiCase ($script:branchDiagnosticCalls -eq 1 -and $script:branchLegacyCalls -eq 1 -and
      $caught.Exception.Message -ceq "shell exited with code -1073741502") "first failure wrapper replayed or changed primary"
    return "Actual production branch extracted; no Start-Process/native invocation, one original throw"
  }
  Invoke-MultiCase "actual new caller streams all five records before unchanged fifth guard" -Negative {
    $ast=[Management.Automation.Language.Parser]::ParseInput($gateSource,[ref]$null,[ref]$null)
    $decision=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq "Get-EdgeTextAttemptDecision"},$true)
    . ([scriptblock]::Create($decision.Extent.Text))
    $caller=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq "Invoke-MultiProjectNativeRename"},$true)
    $call=$caller.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
      $n.Extent.Text.StartsWith('$null = Invoke-MultiProjectTypeText 9904 $typedTitle $inputEvidence -typeSource')},$true)
    Assert-MultiCase ($null -ne $call) "actual new streaming caller binding missing"
    function Invoke-MultiProjectSequencedEdit {
      param($modal,$pidValue,$prefill,$text)
      $script:actualStreamCalls++
      for($i=1;$i -le 5;$i++){
        Write-Host "UIA_EDGE_TEXT_STABLE id=9904 attempt=$i after='' expected='$text' inputAttempted=False textSent=0/0"
        $null=Get-EdgeTextAttemptDecision $true "" $text $i 5
      }
    }
    $script:actualStreamCalls=0; $script:actualStreamPrimary=$null
    $typedTitle="   "; $modal=[IntPtr]42;$multiProcess=[pscustomobject]@{Id=4242};$prefill="Alpha renamed"
    $inputEvidence=[Collections.Generic.List[string]]::new()
    $records=@(& { try { . ([scriptblock]::Create($call.Extent.Text)) } catch { $script:actualStreamPrimary=$_ } } 6>&1)
    $retained=@($records | Where-Object {$_ -is [Management.Automation.InformationRecord] -and
      ([string]$_.MessageData).StartsWith("UIA_EDGE_TEXT_STABLE ",[StringComparison]::Ordinal)})
    Assert-MultiCase ($script:actualStreamCalls -eq 1 -and $retained.Count -eq 5 -and $inputEvidence.Count -eq 5 -and
      $script:actualStreamPrimary.Exception.Message -ceq "edge text mismatch attempts=5/5 expected='   ' observed=''") "actual streaming caller changed guard/lost records/replayed"
    return [ordered]@{sourceCalls=1;retainedRecords=5;primary=$script:actualStreamPrimary.Exception.Message;compiledProxy=$false;nativeCauseEstablished=$false}
  }
  foreach ($scenario in @("focus-not-acquired","native-false-clear-only","native-false-full-six-empty",
      "partial-counts","stale-control","native-error","exact-three-spaces")) {
    Invoke-MultiCase ("streamed actual Edge-TypeText transport " + $scenario) -Negative:($scenario -cne "exact-three-spaces") {
      $gateAst = [Management.Automation.Language.Parser]::ParseInput($gateSource,[ref]$null,[ref]$null)
      foreach ($name in @("Require","Edge-TypeText","Get-EdgeTextAttemptDecision")) {
        $definition = $gateAst.Find({ param($n)
          $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name
        },$true)
        Assert-MultiCase ($null -ne $definition) "actual old edge transport definition missing"
        . ([scriptblock]::Create($definition.Extent.Text.Replace('[GraphCodeUiaGateState]::','$nativeTransport.')))
      }
      $nativeTransport = [pscustomobject]@{ scenario=$scenario; buffer=""; focus=[IntPtr]::Zero; typeCalls=0
        LastEditClearExpected=[uint32]0; LastEditClearSent=[uint32]0; LastEditTextExpected=[uint32]0; LastEditTextSent=[uint32]0 }
      $nativeTransport | Add-Member ScriptMethod EditTextById { param($window,$id) return $this.buffer }
      $nativeTransport | Add-Member ScriptMethod ControlById {
        param($window,$id)
        if ($this.scenario -ceq "stale-control") { return [IntPtr]::Zero }
        return [IntPtr]$id
      }
      $nativeTransport | Add-Member ScriptMethod WindowBounds { param($window) return @(10,20,510,44) }
      $nativeTransport | Add-Member ScriptMethod IsControlOwnedBy { param($window,$control,$id) return $control -eq [IntPtr]$id }
      $nativeTransport | Add-Member ScriptMethod HasVisibleBounds { param($control) return $control -ne [IntPtr]::Zero }
      $nativeTransport | Add-Member ScriptMethod WindowIsVisible { param($window) return $true }
      $nativeTransport | Add-Member ScriptMethod WindowTextOf { param($window) return 'Rename “Alpha renamed”' }
      $nativeTransport | Add-Member ScriptMethod WindowProcessId { param($window) return 4242 }
      $nativeTransport | Add-Member ScriptMethod ControlIdOf { param($window) return [int]$window.ToInt64() }
      $nativeTransport | Add-Member ScriptMethod FocusedControlInDialog { param($window) return $this.focus }
      $nativeTransport | Add-Member ScriptMethod FocusControl { param($window,$control) $this.focus=$control; return $true }
      $nativeTransport | Add-Member ScriptMethod TypeEditTextById {
        param($window,$id,$text)
        $this.typeCalls++
        if ($this.scenario -ceq "native-error") { throw "controlled original native adapter error" }
        $this.LastEditClearExpected=[uint32]2; $this.LastEditClearSent=[uint32]2
        $this.LastEditTextExpected=[uint32]0; $this.LastEditTextSent=[uint32]0
        if ($this.scenario -ceq "partial-counts") { $this.LastEditClearSent=[uint32]1; return $false }
        if ($this.scenario -cin @("native-false-full-six-empty","exact-three-spaces")) {
          $this.LastEditTextExpected=[uint32]6; $this.LastEditTextSent=[uint32]6
        }
        if ($this.scenario -ceq "exact-three-spaces") { $this.buffer=$text; return $true }
        return $false
      }
      function Ensure-ShellForeground { param($window,$label) return $scenario -cne "focus-not-acquired" }
      function Start-Sleep { param($Milliseconds) }
      $renameProcess=[pscustomobject]@{Id=4242}
      $renameProcess | Add-Member ScriptMethod WaitForInputIdle { param($timeout) return $true }
      $script:edgeWorkflowWindow=[IntPtr]42; $script:edgeWorkflowTitle='Rename “Alpha renamed”'
      $evidence=[Collections.Generic.List[string]]::new()
      $script:streamSourceCalls=0; $script:streamPrimary=$null; $primary=$null
      $records=@(& {
        try {
          $null=Invoke-MultiProjectTypeText 9904 "   " $evidence -typeSource {
            param($id,$text) $script:streamSourceCalls++; Edge-TypeText $id $text
          }
        } catch { $script:streamPrimary=$_ }
      } 6>&1)
      $primary=$script:streamPrimary
      $attempts=@($records | Where-Object { $_ -is [Management.Automation.InformationRecord] -and
          ([string]$_.MessageData).StartsWith("UIA_EDGE_TEXT_STABLE ",[StringComparison]::Ordinal) })
      Assert-MultiCase ($script:streamSourceCalls -eq 1) "stream collector replayed native helper"
      switch ($scenario) {
        "exact-three-spaces" {
          Assert-MultiCase ($attempts.Count -eq 1 -and $evidence.Count -eq 1 -and $nativeTransport.typeCalls -eq 1 -and
            $null -eq $primary -and $nativeTransport.buffer -ceq "   ") "exact spaces changed/coerced or native adapter repeated"
        }
        { $_ -cin @("focus-not-acquired","native-false-clear-only","native-false-full-six-empty") } {
          Assert-MultiCase ($attempts.Count -eq 5 -and $evidence.Count -eq 5 -and
            $primary.Exception.Message -ceq "edge text mismatch attempts=5/5 expected='   ' observed=''") "fifth guard/5 produced records not retained"
          $expectedTypeCalls=if($scenario -ceq "focus-not-acquired"){0}else{5}
          Assert-MultiCase ($nativeTransport.typeCalls -eq $expectedTypeCalls) "source/native transport counts differ"
          if($scenario -ceq "native-false-clear-only"){
            Assert-MultiCase (([string]$attempts[-1].MessageData).Contains("textSent=0/0") -and
              ([string]$attempts[-1].MessageData).Contains("inputCountsFull=True")) "clear-only typing availability mislabeled"
          }
        }
        "partial-counts" { Assert-MultiCase ($attempts.Count -eq 0 -and $nativeTransport.typeCalls -eq 1 -and
          $primary.Exception.Message.Contains("SendInput count mismatch")) "partial count primary weakened" }
        "stale-control" { Assert-MultiCase ($attempts.Count -eq 0 -and $nativeTransport.typeCalls -eq 0 -and
          $primary.Exception.Message.Contains("unavailable after layout wait")) "stale guard bypassed" }
        "native-error" { Assert-MultiCase ($attempts.Count -eq 0 -and $nativeTransport.typeCalls -eq 1 -and
          $primary.Exception.ToString().Contains("controlled original native adapter error")) "native error replaced/replayed" }
      }
      return [ordered]@{ sourceInvocations=1; retainedActualAttemptRecords=$attempts.Count; mockTypeCalls=$nativeTransport.typeCalls
        oldHelperBodyExtracted=$true; compiledProxy=$false; nativeCalls=0; actualHostedBlankCauseEstablished=$false }
    }
  }
  foreach($failureMode in @("source-primary","source-plus-sink","sink-only")) {
    Invoke-MultiCase ("stream preserves primary and explicit sink diagnostics " + $failureMode) -Negative {
      $script:streamCalls=0; $script:streamProduced=0; $script:streamSinks=0
      $evidence=[Collections.Generic.List[string]]::new()
      $script:streamFailure=$null; $primary=$null
      $records=@(& {
        try {
          $null=Invoke-MultiProjectTypeText 9904 "   " $evidence -typeSource {
            param($id,$text)
            $script:streamCalls++
            for($i=1;$i -le 5;$i++){
              $script:streamProduced++
              Write-Host "UIA_EDGE_TEXT_STABLE id=$id attempt=$i textSent=0/0"
              Assert-MultiCase ($script:streamSinks -eq $script:streamProduced) "record was not forwarded AS produced before next source step"
            }
            if($failureMode -cne "sink-only"){throw "controlled unchanged primary"}
          } -recordSink {
            param($message)
            $script:streamSinks++
            if($failureMode -cne "source-primary"){throw "controlled retention sink failure"}
            Write-Host $message
          }
        } catch { $script:streamFailure=$_ }
      } 6>&1)
      $primary=$script:streamFailure
      Assert-MultiCase ($script:streamCalls -eq 1 -and $script:streamProduced -eq 5 -and $script:streamSinks -eq 5 -and
        $evidence.Count -eq 5 -and $null -ne $primary) "sink/source error replayed or lost actual produced records"
      if($failureMode -ceq "sink-only"){
        Assert-MultiCase ($primary.Exception.Message.StartsWith("MULTIPROJECT_INPUT_RETENTION:")) "sink failure silently returned success"
      }else{
        Assert-MultiCase ($primary.Exception.Message -ceq "controlled unchanged primary") "original primary replaced"
        if($failureMode -ceq "source-plus-sink"){
          Assert-MultiCase (@($primary.Exception.Data["MultiProjectInputRetention"]).Count -eq 5) "secondary retention errors hidden"
        }
      }
      return [ordered]@{ sourceInvocations=1; produced=5; sinkInvocations=5; mockNativeCalls=0; primary=$primary.Exception.Message }
    }
  }
  Invoke-MultiCase "stream rethrows identical primary exception object" -Negative {
    $original=[InvalidOperationException]::new("exact original exception")
    $script:exceptionIdentityCalls=0; $caught=$null
    $evidence=[Collections.Generic.List[string]]::new()
    try {
      $null=Invoke-MultiProjectTypeText 9904 "   " $evidence -typeSource {
        param($id,$text)
        $script:exceptionIdentityCalls++
        Write-Host "UIA_EDGE_TEXT_STABLE id=9904 attempt=1 textSent=0/0"
        throw $original
      }
    } catch { $caught=$_ }
    Assert-MultiCase ($script:exceptionIdentityCalls -eq 1 -and
      [object]::ReferenceEquals($caught.Exception,$original) -and $evidence.Count -eq 1) "primary object identity changed"
    return "Same exception instance, one source invocation, one produced native-attempt record"
  }
  foreach($faults in @("attempt","summary","attempt-summary","attempt-warning","summary-warning","attempt-summary-warning")) {
    Invoke-MultiCase ("production stream catch preserves primary through " + $faults) -Negative {
      $original=[InvalidOperationException]::new("original fifth/native primary")
      $script:catchSourceCalls=0; $script:catchRecordCalls=0; $script:catchSummaryCalls=0; $script:catchWarningCalls=0
      $evidence=[Collections.Generic.List[string]]::new();$caught=$null
      try{
        $null=Invoke-MultiProjectTypeText 9904 "   " $evidence -typeSource {
          param($id,$text)
          $script:catchSourceCalls++
          for($i=1;$i -le 5;$i++){ Write-Host "UIA_EDGE_TEXT_STABLE id=9904 attempt=$i textSent=0/0" }
          throw $original
        } -recordSink {
          param($message)
          $script:catchRecordCalls++
          if($faults.Contains("attempt")){throw [IO.IOException]::new("attempt writer IO")}
          Write-Host $message
        } -failureSink {
          param($message)
          $script:catchSummaryCalls++
          if($faults.Contains("summary")){throw [IO.IOException]::new("summary writer IO")}
          Write-Host $message
        } -warningSink {
          param($message)
          $script:catchWarningCalls++
          if($faults.Contains("warning")){throw [IO.IOException]::new("warning writer IO")}
        }
      }catch{$caught=$_}
      $secondary=@($caught.Exception.Data["MultiProjectInputRetention"])
      $expectedErrors=$(if($faults.Contains("attempt")){5}else{0})+$(if($faults.Contains("summary")){1}else{0})+$(if($faults.Contains("warning")){1}else{0})
      Assert-MultiCase ([object]::ReferenceEquals($caught.Exception,$original) -and
        $caught.Exception.Message -ceq "original fifth/native primary" -and $script:catchSourceCalls -eq 1 -and
        $script:catchRecordCalls -eq 5 -and $script:catchSummaryCalls -eq 1 -and $script:catchWarningCalls -eq 1 -and
        $evidence.Count -eq 5 -and $secondary.Count -eq $expectedErrors) "production catch replaced primary/lost diagnostic error/replayed"
      foreach($error in $secondary){
        Assert-MultiCase ($error.operation -cin @("attempt-record","failure-summary","warning") -and
          $error.errorType -ceq "System.IO.IOException" -and $error.hresult -is [int] -and
          $error.message.Contains("writer IO")) "secondary native writer error lost exact type/HResult/message/operation"
      }
      return [ordered]@{sourceInvocations=1;retainedActualEvidence=5;typedSecondaryErrors=$secondary.Count
        sameExceptionObject=$true;mockNativeCalls=0}
    }
  }
  # Exact whole synthetic peer file from accepted 91dc PR run 36837690691, not the unavailable 95e success file.
  $receiptFixtureGzip = "H4sIAAAAAAACCu1b3W+jOBD/VyqeE4kQkkDe2uzpdNLpttfuPV2qypih5Uoxa0x2qyj/+9nGxKZNLiQlTW4XP1jxBzOe33wYj8nSyihhBJNkRtIUMIPQmjJaQM/ChFJIEO+5ga8F5CzXI3JqTNIZKVJmTZ2eRcs5qmMwED15RtIcjK4iRWn+DahJ8u87s39Gnp9RGqp+rFtWEufsBjCk7JqSfzj73OrJzj+LGD/NHtG6Y/csvjRGKHzOIDWmEd18J6UHirJHJcrrJhcLKCXUmqZFkvSsvAhyTONMwHkLkFYgU1Awfw5yoAutF0ntFgSmZUdQ5C96UoSSnHeiLEtigXOKnkHBqfpmFLhWN/XVtaKGfgkfYNMjov+vLNzYv4Nc+djGYY7iMxFYbOmuP8RBgpiL/auBsBhaVvb42ydratmq9GXlisoT1SgIxngCtj9xwFpbG39gORduIbR5jdjj3JrOrU/TOS9IVPcMnjPx46HoO8PAnoxDd+K4A9ezkT+2YQxoEPm+Zwdgi2nl5Mske0Rzqzev+HCynA+VCvqDhFC2723JbqBKX1auqLyqWRVJjMUsAfmIZHBR0uPEV6uVteo1BsILJqEXDiH6MYG4U34j6JcGEgv5mlDngEjafPotK4KLlJO4uBTBgJDsy0smBlhB0yuUg/B2LG0/vHopPVzoQPJyVOnLyhWVVzWrspHXVXNeIrhw/1LeoSIF13+K+ZM8AD8XCYtVoLoG4EFoufahWuhuEMyryLHeArIiSGKMjH1h8mYNE+2z+7ipGwZ47AbY5zJHlOtVLHwBNOe8JO+nWNqrImf1DiG8NvvlpuA/XXJD4vB+z+QueaMA2boQNXzQSmAhw3upG72G3/mqFG4Zd0dOTzgjWjtiIzcUE6WHcD6pRNKqmhR4jAW1hQi7fR+XK2AGE9Wq87gTmO5hBSFy/IHvtG8FmvArKzB2+60WULl5U24wGGEUhVHrYhiET2zMxko6Y94C0XCI7IHvtW8FmvBHGLOPfdsL24/MBmFDjE0v3G3JMrIHjj2e2OO2ZTEJG7KYB45pO27QFhCe7zr2KGofCE34tBHKXEkXobZAFIxRMHC89q1AEz5+hBrZkTNEMBq1L4Ym/EERyjyutirLxnPwsp65ECFKHwbf7w41zKrDn2jd2/sfzWqHPhEGjxo9TLjyAmPIVXJsdeCRu1VlbjzLd8psAtcrZeoE1KFJpVZBFukAybwhngFEPBJ9qaEapwxoAmghEwhbED/MiM9O1kqerXIK/arM86HpCNolAk6aCDgC/pr4Gv+v6/cSA3uZ1huq0peVKyqvalbldVpPUrvAnJwwXISfQK4VJ6gIYSYC5zq1d8nZ29xKMYsXMXsRa8nNjB6D70yKicIX6YKQl2NL4zdfaVLu7GkUh6qPQkYoK+NrlaN0Venryqt+VcUQ5gYWMXy7SIm4A6hJQrI4IawuxsAUo0xX7nli1kkF2mUsTpqxOAL+mnjndWfldToPcwSta+IHv0eb2RXafp5AE3/HCnWygXaZjJNmMo6AvybeRa4zilxmfuYIWtfED44L5kGRnn2Ogn7swdu4Ti5v7DEqcmmcacxilFj6EyU+pa0b5NKDe3WnWbt1mUJ5ROkDyFSHdAKkyo4DatZupn9XEJYH6MM/dSgPyuKzg+1fH+QMMSNaaGflI0VwcHQxP2JYlR5/ItU7u1QfqLLjm47WVN9gZ3yj+D2/OxFEfwy9N73Feqv3YefyP6vq3c7lz0Pv/BFGySa9Y892J25o9xFXdN+dBLjvIxT1kTNGEE38CDzYW++jn9jl61cCZ2MBZZZ+P8dvekH61gDGP7EB6HuS/7Xym16ovlX+pFP+yZUv/+8hY34pESNP4t8QTcP92V0+qg31v0JtDkn5P5rWruOrt4Vq/Q3fBHJSUKmfJF5Av4hRqR/pCoZ9dV5wXC/ode+YR0b4btuf0FarfwHVcnXmCzcAAA=="
  $compressed = [IO.MemoryStream]::new([Convert]::FromBase64String($receiptFixtureGzip))
  $decompressor = [IO.Compression.GZipStream]::new($compressed,[IO.Compression.CompressionMode]::Decompress)
  $output = [IO.MemoryStream]::new()
  try { $decompressor.CopyTo($output); $receiptFixtureBytes = $output.ToArray() }
  finally { $decompressor.Dispose(); $compressed.Dispose(); $output.Dispose() }
  Assert-MultiCase ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receiptFixtureBytes)) -ceq
    "361883611D172E3A884A3F6CBCD5918EBACB94F531DDDF921627B5E36A706241") "actual accepted peer fixture byte hash differs"
  $receiptFixture = [Text.Encoding]::UTF8.GetString($receiptFixtureBytes)
  function New-MultiReceiptReport { return ConvertFrom-MultiProjectReceiptJson $receiptFixture }
  Invoke-MultiCase "complete actual accepted whole peer receipt preserves bytes and all state" {
    $report = New-MultiReceiptReport
    $records = @(Write-MultiProjectPeerReceipt $receiptFixture $report.multiProjectPeer 6>&1)
    $record = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] })[0]
    $receipt = Read-MultiProjectPeerReceipt ([string]$record.MessageData)
    Assert-MultiCase ($receipt.utf8Sha256 -ceq "361883611D172E3A884A3F6CBCD5918EBACB94F531DDDF921627B5E36A706241" -and
      $receipt.report.protocolConnected -and $receipt.report.correlatedRequests -and
      $receipt.report.multiProjectPeer.received.Count -eq 11 -and $receipt.report.multiProjectPeer.answered.Count -eq 11 -and
      $receipt.report.multiProjectPeer.applied.Count -eq 2 -and $receipt.report.multiProjectPeer.publications.Count -eq 7 -and
      $receipt.report.multiProjectPeer.controls.Count -eq 1 -and $receipt.rawJson -ceq $receiptFixture) "whole actual receipt lost custody/bytes"
    return "Actual accepted91dc file fixture only; not claimed as95e success state or current native evidence"
  }
  function New-MultiReceiptWithResume {
    $report = New-MultiReceiptReport
    $peer = $report.multiProjectPeer
    $id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    $owner = $peer.graphs[1]
    $response = [ordered]@{ version = 2; kind = "response"; requestID = $id; success = $true }
    $frame = [ordered]@{ version = 2; kind = "request"; requestID = $id
      command = [ordered]@{ graphCommand = [ordered]@{ projectPath = $owner.project.path
        command = [ordered]@{ resumeSession = [ordered]@{ _0 = $owner.nodes[0].id } } } } }
    $peer.received += [ordered]@{ requestID = $id; frame = $frame; expectedResponse = $response }
    $peer.answered += [ordered]@{ requestID = $id; response = $response }
    $peer.receivedCount++; $peer.requestCount++; $peer.responseCount++
    $report.requestCount++; $report.responseCount++
    $report.commands += "graphCommand"
    return $report
  }
  Invoke-MultiCase "whole peer receipt accepts a correlated nonmutating session open" {
    $report = New-MultiReceiptWithResume
    Assert-MultiProjectCompleteReport $report
    Assert-MultiCase ($report.multiProjectPeer.applied.Count -eq 2) "session open changed rename accounting"
    return "Resume acknowledgement is accounted separately from the two exact renames"
  }
  Invoke-MultiCase "whole peer receipt rejects a session open for a foreign owner's node" -Negative {
    $report = New-MultiReceiptWithResume
    $report.multiProjectPeer.received[-1].frame.command.graphCommand.command.resumeSession._0 =
      $report.multiProjectPeer.graphs[0].nodes[0].id
    return Reject-MultiCase { Assert-MultiProjectCompleteReport $report } "MULTIPROJECT_PEER_RECEIPT:"
  }
  foreach ($mutation in @("missing-top", "unknown-top", "disconnected", "correlation-false", "global-error",
      "global-unanswered", "root-count", "connection-type", "graph-not-sent", "missing-peer", "unknown-peer", "count-type", "count-missing",
      "unanswered", "empty-requests", "request-duplicate", "request-id", "request-kind-type", "request-extra",
      "unknown-verb", "wrong-owner", "wrong-node", "rename-title-type", "missing-expectation",
      "answer-duplicate", "answer-missing", "answer-id", "answer-kind", "answer-success", "answer-type", "quick-chat-extra",
      "application-owner", "application-node", "application-title", "application-before", "application-duplicate",
      "publication-sequence", "publication-kind-type", "publication-owner", "publication-title", "publication-correlation",
      "publication-duplicate", "unknown-cause", "control-owner", "control-selection", "control-token",
      "graph-missing", "graph-duplicate", "graph-title", "graph-id", "graph-depth-loss")) {
    Invoke-MultiCase ("complete peer receipt rejects " + $mutation) -Negative {
      $report = New-MultiReceiptReport; $p = $report.multiProjectPeer
      switch ($mutation) {
        "missing-top" { $report.Remove("protocolConnected") }
        "unknown-top" { $report.unexpected = $true }
        "disconnected" { $report.protocolConnected = $false }
        "correlation-false" { $report.correlatedRequests = $false }
        "global-error" { $report.error = "actual error" }
        "global-unanswered" { $report.unansweredRequests = @("unanswered") }
        "root-count" { $report.requestCount++ }
        "connection-type" { $report.connectionCount = "2" }
        "graph-not-sent" { $report.graphSent = $false }
        "missing-peer" { $report.multiProjectPeer = $null }
        "unknown-peer" { $p.unexpected = $true }
        "count-type" { $p.requestCount = "11" }
        "count-missing" { $p.Remove("receivedCount") }
        "unanswered" { $p.unansweredRequests = @($p.received[0].requestID) }
        "empty-requests" { $p.received = @() }
        "request-duplicate" { $p.received[1] = $p.received[0] }
        "request-id" { $p.received[0].frame.requestID = "wrong" }
        "request-kind-type" { $p.received[0].frame.kind = $true }
        "request-extra" { $p.received[0].frame.extra = 1 }
        "unknown-verb" { $p.received[0].frame.command = @{ unknown = @{} } }
        "wrong-owner" { $p.received[-1].frame.command.graphCommand.projectPath = $p.graphs[1].project.path }
        "wrong-node" { $p.received[-1].frame.command.graphCommand.command.renameNode._0 = $p.graphs[1].nodes[0].id }
        "rename-title-type" { $p.received[-1].frame.command.graphCommand.command.renameNode.title = 7 }
        "missing-expectation" { $p.received[-1].expectedResponse = $null }
        "answer-duplicate" { $p.answered[1] = $p.answered[0] }
        "answer-missing" { $p.answered = @($p.answered[0]) }
        "answer-id" { $p.answered[-1].response.requestID = $p.answered[0].requestID }
        "answer-kind" { $p.answered[-1].response.kind = "event" }
        "answer-success" { $p.answered[-1].response.success = $false }
        "answer-type" { $p.answered[-1].response.success = "true" }
        "quick-chat-extra" { $p.answered[1].response.event.quickChatsListed[0].unknown = 1 }
        "application-owner" { $p.applied[0].projectPath = $p.graphs[1].project.path }
        "application-node" { $p.applied[0].nodeID = $p.graphs[1].nodes[0].id }
        "application-title" { $p.applied[0].title = "Not applied" }
        "application-before" { $p.applied[0].beforeTitle = "Not prior" }
        "application-duplicate" { $p.applied[1] = $p.applied[0] }
        "publication-sequence" { $p.publications[-1].frame.sequence = 99 }
        "publication-kind-type" { $p.publications[-1].frame.kind = $true }
        "publication-owner" { $p.publications[-1].frame.event.graphChanged.project.path = $p.graphs[1].project.path }
        "publication-title" { $p.publications[-1].frame.event.graphChanged.nodes[0].title = "Not published" }
        "publication-correlation" { $p.publications[-1].correlationID = $p.received[0].requestID }
        "publication-duplicate" { $p.publications[-1] = $p.publications[-2] }
        "unknown-cause" { $p.publications[-1].cause = "unknown" }
        "control-owner" { $p.controls[0].projectPath = $p.graphs[1].project.path }
        "control-selection" { $p.controls[0].selection.nodeID = $p.graphs[0].nodes[0].id }
        "control-token" { $p.controls[0].token = $p.received[0].requestID }
        "graph-missing" { $p.graphs = @($p.graphs[0]) }
        "graph-duplicate" { $p.graphs[1] = $p.graphs[0] }
        "graph-title" { $p.graphs[0].nodes[0].title = "Not final" }
        "graph-id" { $p.graphs[0].id = "bad" }
        "graph-depth-loss" { $p.graphs[0].nodes[0].presence = "@{presence=idle}" }
      }
      return Reject-MultiCase { New-MultiProjectPeerReceipt (ConvertTo-Json -InputObject $report -Depth 16 -Compress) } "MULTIPROJECT_PEER_RECEIPT:"
    }
  }
  foreach ($mutation in @("no-record", "duplicate-record", "bad-json", "duplicate-property", "bad-hash",
      "byte-count", "report-mismatch", "schema", "provenance", "json-depth", "settled-mismatch")) {
    Invoke-MultiCase ("retained complete receipt reader rejects " + $mutation) -Negative {
      $receipt = New-MultiProjectPeerReceipt $receiptFixture
      $json = ConvertTo-Json -InputObject $receipt -Depth 16 -Compress
      $line = "UIA_MULTIPROJECT_PEER_RECEIPT=" + $json
      $reject = {
        switch ($mutation) {
          "no-record" { Read-MultiProjectPeerReceipt "native job succeeded without retained peer" }
          "duplicate-record" { Read-MultiProjectPeerReceipt ($line + "`n" + $line) }
          "bad-json" { Read-MultiProjectPeerReceipt "UIA_MULTIPROJECT_PEER_RECEIPT={bad" }
          "duplicate-property" { Read-MultiProjectPeerReceipt ('UIA_MULTIPROJECT_PEER_RECEIPT={"x":1,"x":2}') }
          "bad-hash" { $receipt.utf8Sha256 = "bad"; Assert-MultiProjectPeerReceipt $receipt }
          "byte-count" { $receipt.utf8ByteCount++; Assert-MultiProjectPeerReceipt $receipt }
          "report-mismatch" { $receipt.report.protocolConnected = $false; Assert-MultiProjectPeerReceipt $receipt }
          "schema" { $receipt.schemaVersion = "1"; Assert-MultiProjectPeerReceipt $receipt }
          "provenance" { $receipt.provenance = "expected fixture"; Assert-MultiProjectPeerReceipt $receipt }
          "json-depth" { Read-MultiProjectPeerReceipt ("UIA_MULTIPROJECT_PEER_RECEIPT=" +
            (ConvertTo-Json -InputObject $receipt -Depth 2 -Compress -WarningAction SilentlyContinue)) }
          "settled-mismatch" { $peer = (New-MultiReceiptReport).multiProjectPeer; $peer.graphSequence++
            Write-MultiProjectPeerReceipt $receiptFixture $peer }
        }
      }
      return Reject-MultiCase $reject "MULTIPROJECT_PEER_RECEIPT:"
    }
  }
  function New-MultiRequest([string] $id = $renameId, [string] $title = "Alpha renamed") {
    return [ordered]@{ version = 2; kind = "request"; requestID = $id
      command = [ordered]@{ graphCommand = [ordered]@{ projectPath = $alpha
        command = [ordered]@{ renameNode = [ordered]@{ _0 = $a; title = $title } } } } }
  }
  function New-MultiBaseline {
    $peer = New-MultiProjectPeer $alpha $beta
    $pending = Invoke-MultiProjectRequest $peer ([ordered]@{ version = 2; kind = "request"; requestID = $listId
      command = [ordered]@{ listRecentProjects = [ordered]@{} } })
    Complete-MultiProjectResponse $peer $pending.response
    foreach ($path in @($alpha, $beta)) {
      Complete-MultiProjectPublication $peer (New-MultiProjectPublication $peer $path) "initial" $listId
    }
    return $peer
  }
  function New-MultiControl {
    return [ordered]@{ token = $token; projectPath = $alpha; nodeID = $a; title = "Alpha interleaved"
      selection = [ordered]@{ projectPath = $beta; nodeID = $b; source = "synthetic-client" } }
  }
  $productionRenameClick = (New-MultiProjectRenameNativeApi).PSObject.Methods["Click"].Script
  function New-MultiRenameNativeMock {
    $controls = @{}
    foreach ($id in @(9800,9808,9904)) {
      $controls["$id"] = @{ handle = [IntPtr]$id; processId = 4242; id = $id; root = [IntPtr]42
        visible = $true; enabled = $true; bounds = @(300,300,380,328) }
    }
    $controls["9904"].bounds = @(30,100,500,124)
    $api = [pscustomobject]@{ state = @{
      modalPID = 4242; title = 'Rename “Alpha renamed”'; visible = $true; enabled = $true
      client = @(10,40,600,400); work = @(0,0,1920,1080); foreground = $true
      buffer = "  Alpha renamed  "; secondBuffer = "  Alpha renamed  "; controls = $controls
      hitRoot = [IntPtr]42; hitPID = 4242; hitChild = [IntPtr]9800; late = $null; inputSent = 2; inputExpected = 2
    }; inputCalls = 0; bufferReads = 0; hitReads = 0; ExpectedTitle = ""
      order = [Collections.Generic.List[string]]::new(); requested = [Collections.Generic.List[int]]::new() }
    $api | Add-Member ScriptMethod ProcessId {
      param($window)
      $this.order.Add("PID:$window")
      if ($window -eq [IntPtr]42) { return $this.state.modalPID }
      return $this.state.controls["$window"].processId
    }
    $api | Add-Member ScriptMethod Title { param($window) $this.order.Add("TITLE:$window"); return $this.state.title }
    $api | Add-Member ScriptMethod Visible {
      param($window)
      if ($window -eq [IntPtr]42) { return $this.state.visible }
      return $this.state.controls["$window"].visible
    }
    $api | Add-Member ScriptMethod Enabled {
      param($window)
      if ($window -eq [IntPtr]42) { return $this.state.enabled }
      return $this.state.controls["$window"].enabled
    }
    $api | Add-Member ScriptMethod Root { param($window) return $this.state.controls["$window"].root }
    $api | Add-Member ScriptMethod Control {
      param($window,$id)
      $this.requested.Add($id); $this.order.Add("CONTROL:$id")
      if (-not $this.state.controls.ContainsKey("$id")) { return [IntPtr]::Zero }
      return $this.state.controls["$id"].handle
    }
    $api | Add-Member ScriptMethod ControlId { param($window) return $this.state.controls["$window"].id }
    $api | Add-Member ScriptMethod Bounds { param($window) return $this.state.controls["$window"].bounds }
    $api | Add-Member ScriptMethod ClientBounds {
      param($window)
      if ($this.state.ContainsKey("staleClient") -and $this.state.staleClient) {
        throw [ComponentModel.Win32Exception]::new(6,"controlled stale native client")
      }
      return $this.state.client
    }
    $api | Add-Member ScriptMethod WorkBounds { param($window) return $this.state.work }
    $api | Add-Member ScriptMethod Foreground { param($window) return $this.state.foreground }
    $api | Add-Member ScriptMethod Buffer {
      param($window,$id)
      $this.order.Add("BUFFER:$id"); $this.bufferReads++
      if ($this.bufferReads -eq 1) { return $this.state.buffer }
      return $this.state.secondBuffer
    }
    $api | Add-Member ScriptMethod Pause { if ($this.state.late) { & $this.state.late $this.state } }
    $api | Add-Member ScriptMethod Hit {
      param($window,$x,$y)
      $this.hitReads++
      if ($this.state.ContainsKey("finalDrift") -and $this.hitReads -eq 2) {
        & $this.state.finalDrift $this.state
      }
      $child = if ($this.state.ContainsKey("coveredFirst") -and $this.state.coveredFirst -and $this.hitReads -eq 1) {
        [IntPtr]9904
      } else { $this.state.hitChild }
      return @{ root = $this.state.hitRoot; processId = $this.state.hitPID; child = $child }
    }
    $api | Add-Member ScriptMethod SendMouse {
      param($window,$point)
      $this.order.Add("INPUT:mouse"); $this.inputCalls++
      return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],$this.state.inputSent,$this.state.inputExpected)
    }
    $api | Add-Member ScriptMethod Click $productionRenameClick
    return $api
  }
  $productionFocusMouse=(New-MultiProjectEditNativeApi).PSObject.Methods["FocusMouse"].Script
  function New-MultiSequencedEditMock {
    $api=New-MultiRenameNativeMock
    $api | Add-Member NoteProperty Now ([long]0)
    $api | Add-Member NoteProperty PhaseState @{buffer="Alpha renamed";selection=@(0,0);focus=[IntPtr]::Zero
      clearCalls=0;unicodeCalls=0;deleteProcessed=$false;clearPending=$false;observes=0;deleteDelay=3
      focusClicks=0;focusPending=$false;focusObserves=0;focusDelay=1;focusSent=2;neverFocus=$false
      neverClear=$false;finalWrong=$false;clearSent=2;unicodeShort=$false;prefillReads=0;emptyReads=0;rebound=$false}
    $api.state.hitChild=[IntPtr]9904
    $api | Add-Member NoteProperty PhaseOrder ([Collections.Generic.List[string]]::new())
    $api | Add-Member ScriptMethod Clock {return $this.Now}
    $api | Add-Member ScriptMethod FocusInsertion {
      param($modal,$point)
      $this.PhaseOrder.Add("focus-insert");$this.PhaseState.focusClicks++;$this.PhaseState.focusPending=$true
      return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],$this.PhaseState.focusSent,2)
    }
    $api | Add-Member ScriptMethod FocusMouse $productionFocusMouse
    $api | Add-Member ScriptMethod FocusHandle {param($modal) return $this.PhaseState.focus}
    $api | Add-Member ScriptMethod EditBuffer {
      param($edit,$remaining)
      $this.PhaseState.prefillReads++
      if($this.PhaseState.buffer -ceq ""){
        $this.PhaseState.emptyReads++
        if($this.PhaseState.rebound -and $this.PhaseState.emptyReads -eq 4){$this.PhaseState.buffer="Rebound"}
      }
      return $this.PhaseState.buffer
    }
    $api | Add-Member ScriptMethod Selection {param($edit,$remaining) return ,$this.PhaseState.selection}
    $api | Add-Member ScriptMethod SelectAll {
      param($edit,$remaining)
      $this.PhaseOrder.Add("select")
      $this.PhaseState.selection=if($this.PhaseState.ContainsKey("badSelection")){$this.PhaseState.badSelection}else{@(0,$this.PhaseState.buffer.Length)}
    }
    $api | Add-Member ScriptMethod Delete {
      $this.PhaseOrder.Add("clear-enqueue");$this.PhaseState.clearCalls++;$this.PhaseState.clearPending=$true
      return ,@($this.PhaseState.clearSent,2)
    }
    $api | Add-Member ScriptMethod Unicode {
      param($text)
      if(-not $this.PhaseState.deleteProcessed -or $this.PhaseState.clearPending -or $this.PhaseState.buffer -cne "" -or
        $this.PhaseState.clearCalls -ne 1){throw "Unicode before actual inert Delete transition"}
      $this.PhaseOrder.Add("unicode-enqueue");$this.PhaseState.unicodeCalls++
      $this.PhaseState.buffer=if($this.PhaseState.finalWrong){"lpha renamed"}else{$text}
      if($this.PhaseState.ContainsKey("unicodeDrift")){& $this.PhaseState.unicodeDrift $this}
      $count=2*$text.Length
      $sent=if($this.PhaseState.unicodeShort){$count-1}else{$count}
      return ,@($sent,$count)
    }
    $api | Add-Member ScriptMethod Observe {
      param($remaining)
      $this.Now+=[Math]::Min(25,$remaining);$this.PhaseState.observes++
      if($this.PhaseState.focusPending){
        $this.PhaseState.focusObserves++
        if(-not $this.PhaseState.neverFocus -and $this.PhaseState.focusObserves -ge $this.PhaseState.focusDelay){
          $this.PhaseState.focus=[IntPtr]9904;$this.PhaseState.focusPending=$false;$this.PhaseOrder.Add("focus-observed")
        }
      }
      if($this.PhaseState.clearPending -and -not $this.PhaseState.neverClear -and
        $this.PhaseState.observes -ge $this.PhaseState.deleteDelay){
        $this.PhaseState.buffer="";$this.PhaseState.selection=@(0,0);$this.PhaseState.clearPending=$false
        $this.PhaseState.deleteProcessed=$true;$this.PhaseOrder.Add("clear-processed")
        if($this.PhaseState.ContainsKey("clearDrift")){& $this.PhaseState.clearDrift $this}
      }
    }
    return $api
  }
  foreach($expected in @("   ","Alpha renamed","  Alpha renamed  ")){
    Invoke-MultiCase ("single sequenced entry exact target " + $expected.Length + ":" + $expected.Trim()) {
      $api=New-MultiSequencedEditMock
      $evidence=[Collections.Generic.List[string]]::new();$script:sequencedSourceCalls=0
      $null=Invoke-MultiProjectTypeText 9904 $expected $evidence -typeSource {
        param($id,$text)
        $script:sequencedSourceCalls++
        Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "Alpha renamed" $text -nativeApi $api
      }
      Assert-MultiCase ($script:sequencedSourceCalls -eq 1 -and $api.PhaseState.clearCalls -eq 1 -and $api.PhaseState.unicodeCalls -eq 1 -and
        ($api.PhaseOrder -join "|") -ceq "focus-insert|focus-observed|select|clear-enqueue|clear-processed|unicode-enqueue" -and
        $api.PhaseState.focusClicks -eq 1 -and
        $api.PhaseState.buffer -ceq $expected -and $api.Now -lt 5000 -and $evidence.Count -eq 1 -and
        $evidence[0].Contains("clearSent=2/2") -and $evidence[0].Contains("textSent=$([int](2*$expected.Length))/$([int](2*$expected.Length))")) `
        "actual production phases sent extra batches/Unicode before observed transition/lost exact target"
      return [ordered]@{sourceCalls=1;clearBatches=1;unicodeBatches=1;inertQueueOrder=$api.PhaseOrder.ToArray();observations=$api.PhaseState.observes
        nativeCalls=0;actualHistoricalALossReproduced=$false}
    }
  }
  Invoke-MultiCase "prompt viewport resolved edit preserves actual FocusMouse ownership guard" {
    $api=New-MultiSequencedEditMock
    $null=$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)
    Assert-MultiCase ($api.PhaseState.focusClicks -eq 1 -and $api.hitReads -eq 1 -and
      $api.state.hitRoot -eq [IntPtr]42 -and $api.state.hitPID -eq 4242) "resolved nested edit did not retain ownership/hit checks"
    return "Actual FocusMouse ScriptMethod accepts an injected exact edit hit; no native focus/input"
  }
  foreach($viewportMiss in @("background","foreign-root")){
    Invoke-MultiCase ("prompt viewport actual FocusMouse refuses " + $viewportMiss) -Negative {
      $api=New-MultiSequencedEditMock
      if($viewportMiss -ceq "background"){$api.state.hitChild=[IntPtr]9890}
      else{$api.state.hitRoot=[IntPtr]99}
      $caught=$null;try{$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)|Out-Null}catch{$caught=$_}
      Assert-MultiCase ($null -ne $caught -and $caught.Exception.ToString().Contains("MULTIPROJECT_EDIT_FOCUS:") -and
        $api.PhaseState.focusClicks -eq 0) "viewport miss or foreign root became an edit input target"
      return "Injected Hit refusal through actual FocusMouse ScriptMethod; no native WindowFromPoint or input"
    }
  }
  Invoke-MultiCase "already owned GUI edit focus uses zero focus input" {
    $api=New-MultiSequencedEditMock;$api.PhaseState.focus=[IntPtr]9904
    $null=Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "Alpha renamed" "Alpha renamed" -nativeApi $api
    Assert-MultiCase ($api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.clearCalls -eq 1 -and $api.PhaseState.unicodeCalls -eq 1 -and
      ($api.PhaseOrder -join "|") -ceq "select|clear-enqueue|clear-processed|unicode-enqueue") "alreadyFocused route inserted mouse"
    return "Actual observed focused EDIT avoids focus mouse; one clear/Unicode"
  }
  foreach($mutation in @("focus-short","focus-occluded","focus-foreign-hit","focus-outside","focus-timeout",
      "focus-post-owner","focus-switched","before-mouse-deadline","last-selection-deadline","last-selection-owner")){
    Invoke-MultiCase ("bounded focus and pre-input phase rejects " + $mutation) -Negative {
      $api=New-MultiSequencedEditMock
      switch($mutation){
        "focus-short"{$api.PhaseState.focusSent=1}
        "focus-occluded"{$api.state.hitChild=[IntPtr]9800}
        "focus-foreign-hit"{$api.state.hitPID=7777}
        "focus-outside"{$api.state.controls["9904"].bounds=@(700,700,900,724)}
        "focus-timeout"{$api.PhaseState.neverFocus=$true}
        "focus-post-owner"{
          $api|Add-Member ScriptMethod FocusInsertion {param($modal,$point)
            $this.PhaseState.focusClicks++;$this.state.controls["9904"].processId=7777
            return ,@($point[0],$point[1],($point[0]+1),($point[1]+1),$point[0],$point[1],2,2)} -Force
        }
        "focus-switched"{$api.PhaseState.clearDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
        "before-mouse-deadline"{
          $api|Add-Member ScriptMethod Hit {param($modal,$x,$y)$this.Now=5000;return @{root=[IntPtr]42;child=[IntPtr]9904;processId=4242}} -Force
        }
        "last-selection-deadline"{
          $api|Add-Member ScriptMethod Selection {param($edit,$remaining)
            if($this.PhaseState.emptyReads -ge 4){$this.Now=5000};return ,$this.PhaseState.selection} -Force
        }
        "last-selection-owner"{
          $api|Add-Member ScriptMethod Selection {param($edit,$remaining)
            if($this.PhaseState.emptyReads -ge 4){$this.state.controls["9904"].processId=7777};return ,$this.PhaseState.selection} -Force
        }
      }
      $caught=$null;try{Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "Alpha renamed" "Alpha renamed" -nativeApi $api|Out-Null}catch{$caught=$_}
      Assert-MultiCase ($null -ne $caught -and $api.PhaseState.focusClicks -le 1 -and $api.PhaseState.clearCalls -le 1 -and
        $api.PhaseState.unicodeCalls -eq 0) "focus/deadline/selection failure added/replayed input"
      if($mutation -ceq "before-mouse-deadline"){Assert-MultiCase ($api.PhaseState.focusClicks -eq 0) "deadlineBeforeMouse allowed focus insertion"}
      return [ordered]@{failure=$caught.Exception.Message;focusClicks=$api.PhaseState.focusClicks;clear=$api.PhaseState.clearCalls;unicode=0;elapsed=$api.Now}
    }
  }
  foreach($mutation in @("both-foreign","both-zero","both-type","id-wrong","title-wrong","foreground-false","hit-wrong","title-deadline")){
    Invoke-MultiCase ("actual production FocusMouse refuses late " + $mutation) -Negative {
      $api=New-MultiSequencedEditMock
      switch($mutation){
        "both-foreign"{$api.state.modalPID=7777;$api.state.controls["9904"].processId=7777}
        "both-zero"{$api.state.modalPID=0;$api.state.controls["9904"].processId=0}
        "both-type"{$api.state.modalPID="4242";$api.state.controls["9904"].processId="4242"}
        "id-wrong"{$api.state.controls["9904"].id=9800}
        "title-wrong"{$api.state.title="Different dialog"}
        "foreground-false"{$api.state.foreground=$false}
        "hit-wrong"{$api.state.hitChild=[IntPtr]9800}
        "title-deadline"{$api|Add-Member ScriptMethod Title {param($modal,$remaining)$this.order.Add("TITLE:$modal");$this.Now=5000;return 'Rename “Alpha renamed”'} -Force}
      }
      $caught=$null;try{$api.FocusMouse([IntPtr]42,[IntPtr]9904,@(100,110),4242,[long]0)|Out-Null}catch{$caught=$_}
      Assert-MultiCase ($null -ne $caught -and $api.PhaseState.focusClicks -eq 0) "actual production focus primitive adopted PID or latebudget"
      if($mutation -cin @("both-foreign","both-zero","both-type")){
        Assert-MultiCase (-not($api.order -contains "TITLE:42")) "foreign modal title read before expectedPID guard"
      }
      return "Actual FocusMouse ScriptMethod + PS primitive transport rejects with focusInsertion0"
    }
  }
  foreach($mutation in @("empty-initial","mismatch-prefill","selection-short","selection-offset","selection-type","never-clear","empty-rebound",
      "clear-short","unicode-short","final-wrong","focus-deadline","initial-foreign","initial-control","initial-hidden","initial-disabled",
      "initial-foreground","clear-foreign","clear-focus","preunicode-control","final-owner","final-focus","selection-nonzero-empty")){
    Invoke-MultiCase ("single sequenced edit rejects " + $mutation) -Negative {
      $api=New-MultiSequencedEditMock
      switch($mutation){
        "empty-initial" {$api.PhaseState.buffer="";$api.PhaseState.clearPending=$true}
        "mismatch-prefill" {$api.PhaseState.buffer="Other title"}
        "selection-short" {$api.PhaseState.badSelection=@(0,12)}
        "selection-offset" {$api.PhaseState.badSelection=@(1,13)}
        "selection-type" {$api.PhaseState.badSelection=@("0",13)}
        "never-clear" {$api.PhaseState.neverClear=$true}
        "empty-rebound" {$api.PhaseState.rebound=$true}
        "clear-short" {$api.PhaseState.clearSent=1}
        "unicode-short" {$api.PhaseState.unicodeShort=$true}
        "final-wrong" {$api.PhaseState.finalWrong=$true}
        "focus-deadline" {$api.PhaseState.neverFocus=$true}
        "initial-foreign" {$api.state.controls["9904"].processId=7777}
        "initial-control" {$api.state.controls["9904"].id=9105}
        "initial-hidden" {$api.state.controls["9904"].visible=$false}
        "initial-disabled" {$api.state.controls["9904"].enabled=$false}
        "initial-foreground" {$api.state.foreground=$false}
        "clear-foreign" {$api.PhaseState.clearDrift={param($a)$a.state.controls["9904"].processId=7777}}
        "clear-focus" {$api.PhaseState.clearDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
        "preunicode-control" {$api.PhaseState.clearDrift={param($a)$a.state.controls["9904"].id=9105}}
        "final-owner" {$api.PhaseState.unicodeDrift={param($a)$a.state.controls["9904"].root=[IntPtr]99}}
        "final-focus" {$api.PhaseState.unicodeDrift={param($a)$a.PhaseState.focus=[IntPtr]9800}}
        "selection-nonzero-empty" {$api.PhaseState.clearDrift={param($a)$a.PhaseState.selection=@(1,1)}}
      }
      $caught=$null
      try{Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "Alpha renamed" "Alpha renamed" -nativeApi $api|Out-Null}catch{$caught=$_}
      Assert-MultiCase ($null -ne $caught -and $caught.Exception.Message.StartsWith("MULTIPROJECT_EDIT_",[StringComparison]::Ordinal) -and
        $api.PhaseState.clearCalls -le 1 -and $api.PhaseState.unicodeCalls -le 1) "guard failed without exact refusal or added input batch"
      $expectedUnicode=if($mutation -cin @("unicode-short","final-wrong","final-owner","final-focus")){1}else{0}
      Assert-MultiCase ($api.PhaseState.unicodeCalls -eq $expectedUnicode) "refused clear/ownership/prefill allowed Unicode"
      if($mutation -ceq "empty-initial"){Assert-MultiCase ($api.PhaseState.clearCalls -eq 0 -and $api.PhaseState.observes -eq 0) "initialEMPTYbecame false transition ack"}
      return [ordered]@{refusal=$caught.Exception.Message;clear=$api.PhaseState.clearCalls;unicode=$api.PhaseState.unicodeCalls;elapsed=$api.Now
        noNativeOSCalls=$true;inertQueueOnly=$true}
    }
  }
  Invoke-MultiCase "new sequenced native declaration compile only" {
    $api=New-MultiProjectEditNativeApi
    Assert-MultiCase ($null -ne ("GraphCodeMultiProjectEditNative" -as [type]) -and $null -ne $api.PSObject.Methods["Selection"]) "new production interop declaration failed"
    return "Declaration compilation only, no PInvoke/window/input/native focus invocation"
  }
  Invoke-MultiCase "sequenced entry rejects unknown empty expected prefill before any input" -Negative {
    $api=New-MultiSequencedEditMock;$caught=$null
    try{Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "" "   " -nativeApi $api|Out-Null}catch{$caught=$_}
    Assert-MultiCase ($null -ne $caught -and $api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.clearCalls -eq 0 -and
      $api.PhaseState.unicodeCalls -eq 0) "empty expected prefill admitted an invented transition"
    return "No source-known nonempty prefill, no focus/clear/type"
  }
  Invoke-MultiCase "sequenced refusal diagnostic failure preserves exact primary" -Negative {
    $api=New-MultiSequencedEditMock;$api.PhaseState.buffer=""
    $caught=$null;try{Invoke-MultiProjectSequencedEdit ([IntPtr]42) 4242 "Alpha renamed" "   " -nativeApi $api -phaseSink {
      param($message) throw [IO.IOException]::new("phase refusal writer failed")
    }|Out-Null}catch{$caught=$_}
    $secondary=$caught.Exception.Data["MultiProjectEditDiagnostic"]
    Assert-MultiCase ($caught.Exception.Message -ceq "MULTIPROJECT_EDIT_PREFILL: fresh buffer differs from known nonempty prefill" -and
      $secondary.errorType -ceq "System.IO.IOException" -and $secondary.operation -ceq "sequenced-edit-refusal" -and
      $api.PhaseState.focusClicks -eq 0 -and $api.PhaseState.unicodeCalls -eq 0) "refusal writer replaced primary or sent input"
    return "Original prefill guard retained with typed secondary diagnostic failure"
  }
  $renameText = "  Alpha renamed  "
  $renameProof = @("UIA_EDGE_TEXT_STABLE id=9904 inputAttempted=True inputCountsFull=True clearSent=2/2 textSent=34/34")
  foreach ($cancelRoute in @($false,$true)) {
    Invoke-MultiCase ("actual new Rename caller uses native " + $(if ($cancelRoute) { "Cancel9808" } else { "OK9800" })) {
      $api = New-MultiRenameNativeMock
      if ($cancelRoute) { $api.state.hitChild = [IntPtr]9808 }
      function New-MultiProjectRenameNativeApi { return $api }
      $callerAst = [Management.Automation.Language.Parser]::ParseInput($gateSource,[ref]$null,[ref]$null).Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-MultiProjectNativeRename"
      },$true)
      $statement = $callerAst.Find({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$action'
      },$true)
      Assert-MultiCase ($null -ne $statement) "actual new caller has no action assignment"
      $modal = [IntPtr]42; $multiProcess = [pscustomobject]@{ Id = 4242 }
      $typedTitle = $renameText; $Cancel = $cancelRoute
      $inputEvidence = [Collections.Generic.List[string]]::new(); $inputEvidence.Add($renameProof[0])
      . ([scriptblock]::Create($statement.Extent.Text))
      $expectedButton = if ($cancelRoute) { 9808 } else { 9800 }
      Assert-MultiCase ($action.buttonId -eq $expectedButton -and $action.sent -eq 2 -and $action.expected -eq 2 -and
        $api.inputCalls -eq 1 -and -not ($api.requested -contains 1) -and $api.requested -contains 9904 -and
        $action.nativeTarget.observed.button.controlId -eq $expectedButton -and
        $action.nativeTarget.observed.button.topOwner -eq 42 -and
        ($api.order -join "|").StartsWith("PID:42|TITLE:42|CONTROL:",[StringComparison]::Ordinal)) `
        "actual new caller retained legacy button1, lost typed actual target, or entered input before owned capture"
      return [ordered]@{ buttonID = $action.buttonId; inputCalls = $api.inputCalls; compiledProxy = $false; nativeProof = $false }
    }
  }
  Invoke-MultiCase "Rename clips actual button to modal client and work rectangles" {
    $api = New-MultiRenameNativeMock
    $api.state.controls["9800"].bounds = @(580,380,680,430)
    $action = Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api
    Assert-MultiCase (($action.clippedBounds -join ",") -ceq "580,380,600,400" -and
      $action.point[0] -ge 580 -and $action.point[0] -lt 600 -and $action.point[1] -ge 380 -and $action.point[1] -lt 400) `
      "input point used un-clipped footer/outside bounds"
    return "Measured native-client/work clipping predicate only; mock input transport"
  }
  Invoke-MultiCase "Rename uses measured uncovered point without reading covering captions" {
    $api = New-MultiRenameNativeMock; $api.state.coveredFirst = $true
    $action = Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api
    Assert-MultiCase ($action.nativeTarget.hitSamples.Count -eq 2 -and
      -not $action.nativeTarget.hitSamples[0].hitTarget -and $action.nativeTarget.hitSamples[1].hitTarget -and
      $api.inputCalls -eq 1) "covered first point clicked or uncovered owned target not measured"
    return "Only PID/root/child hit metadata, no covering names; no Enter fallback"
  }
  foreach ($mutation in @("missing-button", "zero-handle", "invalid-handle", "hidden-button", "disabled-button",
      "wrong-id", "id-type", "foreign-button", "pid-zero", "pid-type", "wrong-top-owner", "owner-type",
      "missing-edit", "foreign-edit", "wrong-edit-id", "edit-disabled", "modal-foreign", "modal-zero",
      "modal-pid-type", "wrong-title", "title-type", "modal-hidden", "modal-disabled", "visibility-type",
      "bounds-missing", "bounds-zero", "bounds-negative-width", "bounds-type", "bounds-nan", "outside-client",
      "outside-work", "client-zero", "work-invalid", "foreground-false", "foreground-type", "buffer-wrong",
      "buffer-changing", "buffer-type", "proof-empty", "proof-wrong-id", "proof-short", "proof-clear-short",
      "proof-not-attempted", "fully-occluded", "foreign-hit", "hit-pid-type", "hit-root-wrong", "hit-child-type",
      "late-hidden", "late-disabled", "late-foreign", "late-id-drift", "late-owner-drift", "late-bounds-drift",
      "late-modal-foreign", "late-title-drift", "late-client-drift", "late-work-drift", "late-foreground")) {
    Invoke-MultiCase ("Rename native guard rejects " + $mutation) -Negative {
      $api = New-MultiRenameNativeMock; $proof = @($renameProof)
      $button = $api.state.controls["9800"]
      switch ($mutation) {
        "missing-button" { $api.state.controls.Remove("9800") }
        "zero-handle" { $button.handle = [IntPtr]::Zero }
        "invalid-handle" { $button.handle = "9800" }
        "hidden-button" { $button.visible = $false }
        "disabled-button" { $button.enabled = $false }
        "wrong-id" { $button.id = 1 }
        "id-type" { $button.id = "9800" }
        "foreign-button" { $button.processId = 7777 }
        "pid-zero" { $button.processId = 0 }
        "pid-type" { $button.processId = "4242" }
        "wrong-top-owner" { $button.root = [IntPtr]99 }
        "owner-type" { $button.root = "42" }
        "missing-edit" { $api.state.controls.Remove("9904") }
        "foreign-edit" { $api.state.controls["9904"].processId = 7777 }
        "wrong-edit-id" { $api.state.controls["9904"].id = 9105 }
        "edit-disabled" { $api.state.controls["9904"].enabled = $false }
        "modal-foreign" { $api.state.modalPID = 7777 }
        "modal-zero" { $api.state.modalPID = 0 }
        "modal-pid-type" { $api.state.modalPID = "4242" }
        "wrong-title" { $api.state.title = "New Loop" }
        "title-type" { $api.state.title = 1 }
        "modal-hidden" { $api.state.visible = $false }
        "modal-disabled" { $api.state.enabled = $false }
        "visibility-type" { $button.visible = "True" }
        "bounds-missing" { $button.bounds = @() }
        "bounds-zero" { $button.bounds = @(300,300,300,328) }
        "bounds-negative-width" { $button.bounds = @(300,300,299,328) }
        "bounds-type" { $button.bounds[0] = "300" }
        "bounds-nan" { $button.bounds[0] = [double]::NaN }
        "outside-client" { $button.bounds = @(700,700,780,728) }
        "outside-work" { $api.state.work = @(0,0,200,200) }
        "client-zero" { $api.state.client = @(10,40,10,400) }
        "work-invalid" { $api.state.work[0] = "0" }
        "foreground-false" { $api.state.foreground = $false }
        "foreground-type" { $api.state.foreground = "True" }
        "buffer-wrong" { $api.state.buffer = "Wrong"; $api.state.secondBuffer = "Wrong" }
        "buffer-changing" { $api.state.secondBuffer = "Changed" }
        "buffer-type" { $api.state.buffer = 1 }
        "proof-empty" { $proof = @() }
        "proof-wrong-id" { $proof[0] = $proof[0].Replace("id=9904","id=9105") }
        "proof-short" { $proof[0] = $proof[0].Replace("34/34","33/34") }
        "proof-clear-short" { $proof[0] = $proof[0].Replace("2/2","1/2") }
        "proof-not-attempted" { $proof[0] = $proof[0].Replace("inputAttempted=True","inputAttempted=False") }
        "fully-occluded" { $api.state.hitChild = [IntPtr]9904 }
        "foreign-hit" { $api.state.hitPID = 7777 }
        "hit-pid-type" { $api.state.hitPID = "4242" }
        "hit-root-wrong" { $api.state.hitRoot = [IntPtr]99 }
        "hit-child-type" { $api.state.hitChild = "9800" }
        "late-hidden" { $api.state.late = { param($state) $state.controls["9800"].visible = $false } }
        "late-disabled" { $api.state.late = { param($state) $state.controls["9800"].enabled = $false } }
        "late-foreign" { $api.state.late = { param($state) $state.controls["9800"].processId = 7777 } }
        "late-id-drift" { $api.state.late = { param($state) $state.controls["9800"].id = 1 } }
        "late-owner-drift" { $api.state.late = { param($state) $state.controls["9800"].root = [IntPtr]99 } }
        "late-bounds-drift" { $api.state.late = { param($state) $state.controls["9800"].bounds = @(310,300,390,328) } }
        "late-modal-foreign" { $api.state.late = { param($state) $state.modalPID = 7777 } }
        "late-title-drift" { $api.state.late = { param($state) $state.title = "New Loop" } }
        "late-client-drift" { $api.state.late = { param($state) $state.client = @(10,40,590,400) } }
        "late-work-drift" { $api.state.late = { param($state) $state.work = @(0,0,1900,1080) } }
        "late-foreground" { $api.state.late = { param($state) $state.foreground = $false } }
      }
      $prefix = if ($mutation -cin @("outside-client","outside-work")) { "MULTIPROJECT_BOUNDS:" } else { "MULTIPROJECT_RENAME_GUARD:" }
      $diagnosticRecords = @(& {
        $script:renameGuardRejection = Reject-MultiCase {
          Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $proof -nativeApi $api
        } $prefix
      } 6>&1)
      $typedDiagnostics = @($diagnosticRecords | Where-Object {
        $_ -is [Management.Automation.InformationRecord] -and
          ([string]$_.MessageData).StartsWith("UIA_MULTIPROJECT_RENAME_NATIVE_TARGET=",[StringComparison]::Ordinal)
      } |
        ForEach-Object { ([string]$_.MessageData).Substring("UIA_MULTIPROJECT_RENAME_NATIVE_TARGET=".Length) | ConvertFrom-Json })
      Assert-MultiCase ($api.inputCalls -eq 0 -and -not ($api.order | Where-Object { $_.StartsWith("INPUT:") }) -and
        $typedDiagnostics.Count -gt 0 -and $typedDiagnostics[0].expected.buttonId -eq 9800 -and
        -not $typedDiagnostics[0].inputAttempted) "rejected native Rename guard sent input or lost typed actual diagnostic: $mutation"
      if ($mutation -cin @("modal-foreign","modal-zero","modal-pid-type")) {
        Assert-MultiCase (-not ($api.order -contains "TITLE:42") -and $api.requested.Count -eq 0) "foreign/unavailable modal content read"
      }
      if ($mutation -cin @("missing-button","zero-handle")) {
        Assert-MultiCase ($typedDiagnostics[0].observed.button.handle -eq 0 -and
          $null -eq $typedDiagnostics[0].observed.button.controlId) "invented actual missing button ID/handle"
      }
      return [ordered]@{ rejection = $script:renameGuardRejection; inputCalls = $api.inputCalls; typedDiagnostics = $typedDiagnostics.Count }
    }
  }
  foreach ($mutation in @("short-count","typed-count")) {
    Invoke-MultiCase ("Rename actual input receipt rejects " + $mutation) -Negative {
      $api = New-MultiRenameNativeMock
      $api.state.inputSent = if ($mutation -ceq "short-count") { 1 } else { "2" }
      $rejection = Reject-MultiCase {
        Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api
      } "MULTIPROJECT_RENAME_INPUT:"
      Assert-MultiCase ($api.inputCalls -eq 1) "incomplete input was replayed"
      return "Actual mocked return/count rejection after one allowed mock input; no replay: $rejection"
    }
  }
  foreach ($mutation in @("foreign-button","wrong-title","covered-point")) {
    Invoke-MultiCase ("production Rename Click rejects final " + $mutation) -Negative {
      $api = New-MultiRenameNativeMock
      $api.state.finalDrift = switch ($mutation) {
        "foreign-button" { { param($state) $state.controls["9800"].processId = 7777 } }
        "wrong-title" { { param($state) $state.title = "Different modal" } }
        "covered-point" { { param($state) $state.hitChild = [IntPtr]9904 } }
      }
      try { Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api | Out-Null }
      catch {
        Assert-MultiCase ($_.Exception.ToString().Contains("native target changed immediately before input") -and
          $api.inputCalls -eq 0 -and $api.hitReads -eq 2) "production Click adapter entered primitive input after last-moment drift"
        return "Actual production ScriptMethod guard, PS primitive mock and zero input; native return unavailable"
      }
      throw "RED: final production-native guard accepted $mutation"
    }
  }
  Invoke-MultiCase "Rename stale native read retains exact error and unavailable actual fields" -Negative {
    $api = New-MultiRenameNativeMock; $api.state.staleClient = $true
    $records = @(& {
      try { Invoke-MultiProjectRenameAction ([IntPtr]42) 4242 $renameText $renameProof -nativeApi $api | Out-Null }
      catch {
        Assert-MultiCase ($_.Exception.ToString().Contains("controlled stale native client")) "primary stale error replaced"
      }
    } 6>&1)
    $failures = @($records | Where-Object { $_ -is [Management.Automation.InformationRecord] -and
        ([string]$_.MessageData).StartsWith("UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE=",[StringComparison]::Ordinal) } |
      ForEach-Object { ([string]$_.MessageData).Substring("UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE=".Length) | ConvertFrom-Json })
    Assert-MultiCase ($api.inputCalls -eq 0 -and $failures.Count -eq 1 -and
      $failures[0].failure.errorType -ceq "System.ComponentModel.Win32Exception" -and
      $failures[0].failure.nativeErrorCode -eq 6 -and -not $failures[0].inputAttempted -and
      $null -eq $failures[0].observed.button) "stale error hid unavailable actual fields or sent input"
    return "Typed original native read failure, unavailable button metadata and zero input; no native OS invocation"
  }
  Invoke-MultiCase "Rename production native bindings compile without native invocation" {
    $api = New-MultiProjectRenameNativeApi
    Assert-MultiCase ($null -ne ("GraphCodeMultiProjectRenameNative" -as [type]) -and
      $null -ne $api.PSObject.Methods["ClientBounds"] -and $null -ne $api.PSObject.Methods["Hit"]) "production adapter did not compile"
    return "Real interop declarations compile only; no PInvoke, HWND, native input or compiled test proxy"
  }
  function New-MultiMetadataMock($processIdValue, $identity, $afterPid = $null, [switch] $Unavailable) {
    $global:multiMetadataAccessOrder = [Collections.Generic.List[string]]::new()
    $global:multiMetadataPidReads = 0
    $global:multiMetadataPidBefore = $processIdValue
    $global:multiMetadataPidAfter = if ($null -eq $afterPid) { $processIdValue } else { $afterPid }
    $global:multiMetadataId = $identity
    $global:multiMetadataUnavailable = [bool]$Unavailable
    $current = New-Object PSObject
    $current | Add-Member ScriptProperty ProcessId {
      $global:multiMetadataAccessOrder.Add("PID")
      $global:multiMetadataPidReads++
      if ($global:multiMetadataPidReads -eq 1) { return $global:multiMetadataPidBefore }
      return $global:multiMetadataPidAfter
    }
    $current | Add-Member ScriptProperty AutomationId {
      $global:multiMetadataAccessOrder.Add("ID")
      if ($global:multiMetadataUnavailable) {
        throw [Runtime.InteropServices.COMException]::new("controlled stale UIA metadata", [int]0x80040201)
      }
      return $global:multiMetadataId
    }
    $current | Add-Member ScriptProperty Name {
      $global:multiMetadataAccessOrder.Add("FORBIDDEN_NAME")
      throw "Foreign or unresolved Name must not be read"
    }
    return [pscustomobject]@{ Current = $current }
  }
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
  function New-MultiCaptureState($processIdValue = 4242, $identity = "canvas-card-1983941480823304696") {
    return @{ pid = $processIdValue; id = $identity; runtime = @(3,42,17)
      name = "Alpha loop"; rect = [System.Windows.Rect]::new(248,118,220,86); error = $null }
  }
  function New-MultiCaptureMock($states) {
    $element = [pscustomobject]@{ states = $states; calls = 0; order = [Collections.Generic.List[string]]::new() }
    $element | Add-Member ScriptMethod Capture {
      param([bool] $includeContent)
      $state = $this.states[$this.calls]; $this.calls++
      $this.order.Add($(if ($includeContent) { "CONTENT_CACHE" } else { "OWNERSHIP_CACHE" }))
      if ($state.error) { throw $state.error }
      $cache = [pscustomobject]@{ state = $state; order = $this.order; content = $includeContent }
      $cache | Add-Member ScriptMethod GetCachedPropertyValue {
        param($property, [bool] $ignoreDefault)
        if (-not $ignoreDefault) { throw "controlled cache requires ignoreDefaultValue=true" }
        if ($property -eq [System.Windows.Automation.AutomationElement]::ProcessIdProperty) {
          $this.order.Add("PID"); return $this.state.pid
        }
        if ($property -eq [System.Windows.Automation.AutomationElement]::AutomationIdProperty) {
          $this.order.Add("ID"); return $this.state.id
        }
        if (-not $this.content) { throw "controlled ownership cache forbids content" }
        if ($property -eq [System.Windows.Automation.AutomationElement]::BoundingRectangleProperty) {
          $this.order.Add("BOUNDS"); return $this.state.rect
        }
        if ($property -eq [System.Windows.Automation.AutomationElement]::NameProperty) {
          $this.order.Add("NAME"); return $this.state.name
        }
        throw "controlled cache received unexpected property"
      }
      $cache | Add-Member ScriptMethod GetRuntimeId { $this.order.Add("RUNTIME"); return ,$this.state.runtime }
      return $cache
    }
    return $element
  }
  $captureReader = { param($element, [bool] $includeContent) $element.Capture($includeContent) }
  $capturePrior = @{ ownership = "owned"; finalPID = @{ value = 4242 }
    automationID = @{ value = "canvas-card-1983941480823304696" } }
  Invoke-MultiCase "fresh cached capture verifies owned metadata before and after content" {
    $mock = New-MultiCaptureMock @((New-MultiCaptureState),(New-MultiCaptureState),(New-MultiCaptureState))
    $evidence = Get-MultiProjectElementEvidence $mock 4242 $capturePrior "functional/owned" $captureReader
    Assert-MultiCase ($evidence.processId -eq 4242 -and $evidence.automationId -ceq $capturePrior.automationID.value -and
      $evidence.name -ceq "Alpha loop" -and ($evidence.bounds -join ",") -ceq "248,118,468,204" -and
      ($mock.order -join "|") -ceq "OWNERSHIP_CACHE|PID|ID|RUNTIME|CONTENT_CACHE|PID|ID|RUNTIME|BOUNDS|NAME|OWNERSHIP_CACHE|PID|ID|RUNTIME") `
      "actual extracted cache capture read-order/shape differs"
    return "Functional cache transport only; no live UIA. Content cache requested after owned preflight; cached ownership checked before extraction."
  }
  Invoke-MultiCase "fresh snapshot distinguishes unsupported property from zero default" {
    $unsupported = New-MultiCaptureState ([System.Windows.Automation.AutomationElement]::NotSupported)
    $zero = New-MultiCaptureState 0
    $first = Read-MultiProjectOwnershipSnapshot (New-MultiCaptureMock @($unsupported)) $captureReader
    $second = Read-MultiProjectOwnershipSnapshot (New-MultiCaptureMock @($zero)) $captureReader
    Assert-MultiCase ($first.pidState.state -ceq "unsupported" -and $null -eq $first.processId -and
      $second.pidState.state -ceq "zero" -and $second.processId -eq 0 -and
      $first.state -ceq "unavailable" -and $second.state -ceq "unavailable") "unsupported/default states conflated"
    return "ignoreDefaultValue=true sentinel typed separately; neither proves ownership"
  }
  foreach ($mutation in @("fresh-zero", "fresh-null-pid", "fresh-unsupported-pid", "fresh-pid-type", "fresh-foreign",
      "fresh-null-id", "fresh-empty-id", "fresh-id-type", "fresh-id-drift", "fresh-null-runtime", "fresh-runtime-type",
      "fresh-retired", "prior-owner-changed", "prior-pid-changed",
      "content-foreign", "content-zero", "content-unsupported", "content-id-drift", "content-runtime-drift",
      "after-foreign", "after-zero", "after-id-drift", "after-runtime-drift", "after-retired", "name-type",
      "name-unsupported", "bounds-null", "bounds-zero", "bounds-empty")) {
    Invoke-MultiCase ("fresh capture rejects " + $mutation) -Negative {
      $states = @((New-MultiCaptureState),(New-MultiCaptureState),(New-MultiCaptureState))
      $prior = @{ ownership = "owned"; finalPID = @{ value = 4242 }; automationID = @{ value = $capturePrior.automationID.value } }
      switch ($mutation) {
        "fresh-zero" { $states[0].pid = 0 }
        "fresh-null-pid" { $states[0].pid = $null }
        "fresh-unsupported-pid" { $states[0].pid = [System.Windows.Automation.AutomationElement]::NotSupported }
        "fresh-pid-type" { $states[0].pid = "4242" }
        "fresh-foreign" { $states[0].pid = 7777 }
        "fresh-null-id" { $states[0].id = $null }
        "fresh-empty-id" { $states[0].id = "" }
        "fresh-id-type" { $states[0].id = 7 }
        "fresh-id-drift" { $states[0].id = "canvas-card-unknown" }
        "fresh-null-runtime" { $states[0].runtime = @() }
        "fresh-runtime-type" { $states[0].runtime = @("3",42,17) }
        "fresh-retired" { $states[0].error = [Runtime.InteropServices.COMException]::new("controlled retirement", [int]0x80040201) }
        "prior-owner-changed" { $prior.ownership = "changed" }
        "prior-pid-changed" { $prior.finalPID.value = 7777 }
        "content-foreign" { $states[1].pid = 7777 }
        "content-zero" { $states[1].pid = 0 }
        "content-unsupported" { $states[1].pid = [System.Windows.Automation.AutomationElement]::NotSupported }
        "content-id-drift" { $states[1].id = "canvas-card-unknown" }
        "content-runtime-drift" { $states[1].runtime = @(3,42,99) }
        "after-foreign" { $states[2].pid = 7777 }
        "after-zero" { $states[2].pid = 0 }
        "after-id-drift" { $states[2].id = "canvas-card-unknown" }
        "after-runtime-drift" { $states[2].runtime = @(3,42,99) }
        "after-retired" { $states[2].error = [Runtime.InteropServices.COMException]::new("controlled retirement", [int]0x80040201) }
        "name-type" { $states[1].name = 7 }
        "name-unsupported" { $states[1].name = [System.Windows.Automation.AutomationElement]::NotSupported }
        "bounds-null" { $states[1].rect = $null }
        "bounds-zero" { $states[1].rect = [System.Windows.Rect]::new(248,118,0,86) }
        "bounds-empty" { $states[1].rect = [System.Windows.Rect]::Empty }
      }
      $mock = New-MultiCaptureMock $states
      $prefix = if ($mutation -cin @("fresh-foreign", "content-foreign", "after-foreign")) { "MULTIPROJECT_PRIVACY:" } else { "MULTIPROJECT_METADATA:" }
      $rejection = Reject-MultiCase { Get-MultiProjectElementEvidence $mock 4242 $prior "functional/$mutation" $captureReader } $prefix
      $mayHaveReadContent = $mutation.StartsWith("after-", [StringComparison]::Ordinal) -or
        $mutation.StartsWith("name-", [StringComparison]::Ordinal) -or $mutation.StartsWith("bounds-", [StringComparison]::Ordinal)
      Assert-MultiCase (($mock.order -contains "NAME") -eq $mayHaveReadContent -and
        ($mock.order -contains "BOUNDS") -eq $mayHaveReadContent) "content read before fresh/cached ownership or runtime guard: $mutation"
      if ($mutation.StartsWith("fresh-", [StringComparison]::Ordinal) -or $mutation.StartsWith("prior-", [StringComparison]::Ordinal)) {
        Assert-MultiCase (-not ($mock.order -contains "CONTENT_CACHE")) "content cache requested before fresh owned proof"
      }
      return [ordered]@{ rejection = $rejection; accessOrder = $mock.order.ToArray(); discardedWholeCapture = $true
        nativeCauseEstablished = $false }
    }
  }
  Invoke-MultiCase "unknown cache error is not converted to retryable metadata" -Negative {
    $state = New-MultiCaptureState
    $state.error = [InvalidOperationException]::new("controlled unexpected cache error")
    $mock = New-MultiCaptureMock @($state)
    try { Read-MultiProjectOwnershipSnapshot $mock $captureReader | Out-Null }
    catch {
      Assert-MultiCase ($_.Exception.ToString().Contains("controlled unexpected cache error") -and
        -not ($mock.order -contains "NAME")) "unknown error swallowed or content read"
      return "Actual unexpected cache error retained, not a successful/unavailable fallback"
    }
    throw "RED: unexpected cache failure was silently accepted"
  }
  Invoke-MultiCase "retired snapshot retains typed availability error before content" {
    $state = New-MultiCaptureState
    $state.error = [Runtime.InteropServices.COMException]::new("controlled retirement", [int]0x80040201)
    $mock = New-MultiCaptureMock @($state)
    $snapshot = Read-MultiProjectOwnershipSnapshot $mock $captureReader
    Assert-MultiCase ($snapshot.state -ceq "unavailable" -and $snapshot.pidState.state -ceq "unavailable" -and
      $snapshot.errorType -ceq "System.Runtime.InteropServices.COMException" -and $snapshot.hresult -eq [int]0x80040201 -and
      ($mock.order -join "|") -ceq "OWNERSHIP_CACHE") "known retirement swallowed its exact typed diagnostic"
    return $snapshot
  }
  Invoke-MultiCase "other COM failure is not a retirement-shaped fallback" -Negative {
    $state = New-MultiCaptureState
    $state.error = [Runtime.InteropServices.COMException]::new("controlled unexpected COM", [int]0x80004005)
    $mock = New-MultiCaptureMock @($state)
    try { Read-MultiProjectOwnershipSnapshot $mock $captureReader | Out-Null }
    catch {
      Assert-MultiCase ($_.Exception.ToString().Contains("controlled unexpected COM") -and $mock.calls -eq 1 -and
        -not ($mock.order -contains "NAME")) "unknown COM error weakened to unavailable/success"
      return "Unexpected HRESULT remains a real exception"
    }
    throw "RED: unrelated COM failure was silently accepted"
  }
  foreach ($scenario in @("transient", "persistent", "positive-foreign")) {
    Invoke-MultiCase ("whole observation reacquisition " + $scenario) -Negative:($scenario -cne "transient") {
      $multiProcess = [pscustomobject]@{ Id = 4242 }
      $script:multiCaptureObservationAttempts = 0
      $script:multiCaptureSleeps = 0
      $script:multiCaptureObservationScenario = $scenario
      function Start-Sleep { param([int] $Milliseconds) $script:multiCaptureSleeps++ }
      function Get-MultiProjectObservation {
        param([string] $surface, $selectedOwner)
        $script:multiCaptureObservationAttempts++
        $state = New-MultiCaptureState
        if ($script:multiCaptureObservationScenario -ceq "positive-foreign") { $state.pid = 7777 }
        elseif ($script:multiCaptureObservationScenario -ceq "persistent" -or $script:multiCaptureObservationAttempts -eq 1) { $state.pid = 0 }
        $mock = New-MultiCaptureMock @($state,(New-MultiCaptureState),(New-MultiCaptureState))
        $evidence = Get-MultiProjectElementEvidence $mock 4242 $capturePrior "functional/whole-observation" $captureReader
        return @{ matched = $true; requestedSurface = $surface; evidence = $evidence }
      }
      if ($scenario -ceq "transient") {
        $observation = Wait-MultiProjectObservation "overview"
        Assert-MultiCase ($observation.matched -and $script:multiCaptureObservationAttempts -eq 2 -and
          $script:multiCaptureSleeps -eq 1) "transient whole snapshot not reacquired exactly once"
      } else {
        $prefix = if ($scenario -ceq "positive-foreign") { "MULTIPROJECT_PRIVACY:" } else { "MULTIPROJECT_METADATA:" }
        $null = Reject-MultiCase { Wait-MultiProjectObservation "overview" } $prefix
        $expectedAttempts = if ($scenario -ceq "positive-foreign") { 1 } else { 100 }
        Assert-MultiCase ($script:multiCaptureObservationAttempts -eq $expectedAttempts -and
          $script:multiCaptureSleeps -eq ($expectedAttempts - 1)) "foreign guard retried or persistent ambiguity escaped its exact bound"
      }
      return [ordered]@{ attempts = $script:multiCaptureObservationAttempts; maximum = 100
        commandOrInputCalls = 0; scope = "extracted observation helper with synthetic cache transport, not native selection" }
    }
  }
  Invoke-MultiCase "whole capture collection rejects later provider runtime replacement" -Negative {
    $snapshots = [Collections.Generic.List[object]]::new()
    $mock = New-MultiCaptureMock @((New-MultiCaptureState),(New-MultiCaptureState),(New-MultiCaptureState))
    $null = Get-MultiProjectElementEvidence $mock 4242 $capturePrior "functional/collection" $captureReader $snapshots
    Assert-MultiCase ($snapshots.Count -eq 1) "verified capture not registered for collection verification"
    $changed = New-MultiCaptureState
    $changed.runtime = @(3,42,99)
    $after = Read-MultiProjectOwnershipSnapshot (New-MultiCaptureMock @($changed)) $captureReader
    return Reject-MultiCase { Confirm-MultiProjectOwnedSnapshot $snapshots[0].snapshot $after 4242 "functional/whole-observation" } "MULTIPROJECT_METADATA:"
  }
  Invoke-MultiCase "guarded prefix handles null without pretending metadata is ready" {
    Assert-MultiCase (-not (Test-MultiProjectAutomationPrefix $null "workspace-loop-bar-") -and
      -not (Test-MultiProjectAutomationPrefix 7 "canvas-card-")) "guarded prefix coerced unavailable/invalid IDs"
    return "Null and wrong typed IDs are not prefix matches; metadata readiness is separately mandatory"
  }
  Invoke-MultiCase "owned available semantic metadata reads PID first and again" {
    $mock = New-MultiMetadataMock 4242 "canvas-card-1983941480823304696"
    $metadata = Get-MultiProjectFragmentMetadata $mock 4242
    Assert-MultiCase ($metadata.observationReady -and $metadata.ownership -ceq "owned" -and
      $metadata.automationID.state -ceq "available" -and $metadata.family -ceq "canvas-fragment" -and
      ($global:multiMetadataAccessOrder -join "|") -ceq "PID|ID|PID") "PID-first/stable semantic metadata shape differs"
    return "Exact owned semantic ID, stable PID; no Name access"
  }
  Invoke-MultiCase "owned source-supported static chrome is classified explicitly" {
    $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock 4242 "actual-size") 4242
    Assert-MultiCase ($metadata.observationReady -and $metadata.family -ceq "source-supported-chrome") "known static source chrome rejected"
    return "Provider static Graph control, not semantic card"
  }
  Invoke-MultiCase "owned restart session chrome remains in the complete workspace metadata batch" {
    $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock 4242 "workspace-restart-session-2140902926206787169") 4242
    Assert-MultiCase ($metadata.observationReady -and $metadata.ownership -ceq "owned" -and
      $metadata.family -ceq "source-supported-chrome" -and (Test-MultiProjectMetadataBatch @($metadata)) -and
      ($global:multiMetadataAccessOrder -join "|") -ceq "PID|ID|PID") `
      "source-published restart action is unresolved despite stable owned PID and exact numeric identity"
    return "App workspace-restart-session action retained and classified without Name or invented owner metadata"
  }
  foreach ($case in @(
      @{ name = "foreign restart"; pid = 7777; after = 7777; id = "workspace-restart-session-2140902926206787169" },
      @{ name = "changed restart owner"; pid = 4242; after = 7777; id = "workspace-restart-session-2140902926206787169" },
      @{ name = "missing restart PID"; pid = 0; after = 0; id = "workspace-restart-session-2140902926206787169" },
      @{ name = "missing restart ID"; pid = 4242; after = 4242; id = $null },
      @{ name = "invalid typed restart ID"; pid = 4242; after = 4242; id = 7 },
      @{ name = "empty restart suffix"; pid = 4242; after = 4242; id = "workspace-restart-session-" },
      @{ name = "nonnumeric restart suffix"; pid = 4242; after = 4242; id = "workspace-restart-session-foreign" },
      @{ name = "restart extra suffix"; pid = 4242; after = 4242; id = "workspace-restart-session-2140902926206787169-extra" }
    )) {
    Invoke-MultiCase ("restart metadata rejects " + $case.name) -Negative {
      $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock $case.pid $case.id $case.after) 4242
      Assert-MultiCase (-not $metadata.observationReady -and -not (Test-MultiProjectMetadataBatch @($metadata)) -and
        -not ($global:multiMetadataAccessOrder -contains "FORBIDDEN_NAME")) `
        "restart taxonomy weakened exact owned identity: $($case.name)"
      return "Unresolved or foreign restart stays counted and cannot make its metadata batch ready"
    }
  }
  foreach ($case in @(
      @{ name = "null native candidate"; pid = 0; id = $null; after = 0; state = "unavailable"; owner = "unavailable" },
      @{ name = "foreign null ID"; pid = 7777; id = $null; after = 7777; state = "unavailable"; owner = "foreign" },
      @{ name = "empty owned ID"; pid = 4242; id = ""; after = 4242; state = "empty"; owner = "owned" },
      @{ name = "invalid typed ID"; pid = 4242; id = 7; after = 4242; state = "invalid"; owner = "owned" },
      @{ name = "unavailable stale ID"; pid = 4242; id = "unused"; after = 4242; state = "unavailable"; owner = "owned"; unavailable = $true },
      @{ name = "changed ownership"; pid = 4242; id = "canvas-card-1983941480823304696"; after = 7777; state = "available"; owner = "changed" },
      @{ name = "unknown native-boundary ID"; pid = 7777; id = "native-boundary"; after = 7777; state = "available"; owner = "foreign" }
    )) {
    Invoke-MultiCase ("metadata batch rejects " + $case.name) -Negative {
      $unavailable = $case.ContainsKey("unavailable") -and $case.unavailable
      $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock $case.pid $case.id $case.after -Unavailable:$unavailable) 4242
      Assert-MultiCase (-not $metadata.observationReady -and $metadata.automationID.state -ceq $case.state -and
        $metadata.ownership -ceq $case.owner -and -not (Test-MultiProjectMetadataBatch @($metadata)) -and
        -not ($global:multiMetadataAccessOrder -contains "FORBIDDEN_NAME") -and $metadata.proofLimit.Length -gt 0) `
        "unresolved native/stale metadata silently dropped or foreign name read: $($case.name)"
      return "Actual metadata readiness predicate rejects $($case.name); native semantic cause unestablished"
    }
  }
  Invoke-MultiCase "foreign semantic fragment stays counted and fails strict roster" -Negative {
    $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock 7777 "canvas-card-1983941480823304696") 4242
    Assert-MultiCase ($metadata.observationReady -and $metadata.ownership -ceq "foreign" -and
      (Test-MultiProjectAutomationPrefix $metadata.automationID.value "canvas-card-") -and
      -not ($global:multiMetadataAccessOrder -contains "FORBIDDEN_NAME")) "foreign semantic fragment lost before PID-only classification"
    $actual = @([ordered]@{ automationId = $metadata.automationID.value; name = "Owned fixture placeholder"
      processId = 7777; bounds = @(248,118,468,204) })
    Assert-MultiCase (-not (Test-MultiProjectFragmentRoster $actual @([ordered]@{
      automationId = "canvas-card-1983941480823304696"; name = "Owned fixture placeholder"
    }) 4242)) "wrong PID semantic fragment accepted"
    return "Foreign semantic PID contributes failure, not filtered Name/content"
  }
  Invoke-MultiCase "two exact positive owner publications" {
    $peer = Get-MultiProjectPeerSnapshot (New-MultiBaseline)
    Assert-MultiCase ($peer.requestCount -eq 1 -and $peer.responseCount -eq 1 -and
      $peer.graphSequence -eq 2 -and $peer.graphs.Count -eq 2 -and
      $peer.graphs[0].project.path -ceq $alpha -and $peer.graphs[1].project.path -ceq $beta -and
      $peer.graphs[0].nodes[0].id -ceq $a -and $peer.graphs[1].nodes[0].id -ceq $b) "positive fixture/counts differ"
    return "2 distinct ordinary owners, 2 distinct graph/node UUIDs, sequences 1/2"
  }
  $peer = New-MultiBaseline
  $before = Get-MultiProjectPeerSnapshot $peer
  $request = New-MultiRequest
  $pending = Invoke-MultiProjectRequest $peer $request
  Complete-MultiProjectResponse $peer $pending.response
  Complete-MultiProjectPublication $peer (New-MultiProjectPublication $peer $alpha) "rename" $renameId
  $after = Get-MultiProjectPeerSnapshot $peer
  Invoke-MultiCase "whole typed correlated rename receipt" {
    Assert-MultiCase (Test-MultiProjectRenameReceipt $before $after $alpha $a "Alpha renamed") "canonical rename rejected"
    Assert-MultiCase ($after.graphs[1].nodes[0].title -ceq "Beta loop") "rename mutated Beta"
    return "request/reply/applied/publication all correlated, Beta unchanged"
  }
  Invoke-MultiCase "one-shot interleaved event with synthetic selection" {
    $state = New-MultiBaseline
    $frame = Invoke-MultiProjectPublicationControl $state (New-MultiControl)
    Complete-MultiProjectPublication $state $frame "control" $token
    $snapshot = Get-MultiProjectPeerSnapshot $state
    Assert-MultiCase ($snapshot.requestCount -eq 1 -and $snapshot.responseCount -eq 1 -and
      $snapshot.appliedCount -eq 0 -and $snapshot.graphSequence -eq 3 -and
      $snapshot.graphs[1].nodes[0].title -ceq "Beta loop") "control invented requests or changed Beta"
    return "synthetic identity only; no live app selection claim"
  }
  Invoke-MultiCase "unchanged title still dispatches" {
    $state = New-MultiBaseline
    $baseline = Get-MultiProjectPeerSnapshot $state
    $pending = Invoke-MultiProjectRequest $state (New-MultiRequest $renameId "Alpha loop")
    Complete-MultiProjectResponse $state $pending.response
    Complete-MultiProjectPublication $state (New-MultiProjectPublication $state $alpha) "rename" $renameId
    Assert-MultiCase (Test-MultiProjectRenameReceipt $baseline (Get-MultiProjectPeerSnapshot $state) $alpha $a "Alpha loop") "unchanged dispatch was suppressed"
    return "Windows unchanged-title dispatch preserved"
  }
  Invoke-MultiCase "hash identity is owner and surface scoped" {
    $ids = @(
      (Get-MultiProjectAutomationId "loop" $alpha $a),
      (Get-MultiProjectAutomationId "project-card" $alpha $a),
      (Get-MultiProjectAutomationId "overview-card" $alpha $a),
      (Get-MultiProjectAutomationId "overview-card" $beta $b)
    )
    Assert-MultiCase (@($ids | Sort-Object -Unique).Count -eq 4) "surface/owner IDs collapsed"
    Assert-MultiCase ((Get-MultiProjectAutomationId "project-card" "graphcode://stub/project" $a) -ceq "canvas-card-1510499067760483540") "provider FNV row-key golden differs"
    return $ids
  }
  $retainedAlpha = "D:\a\_temp\gu-239af6fb60ce40b5b2846baf38b9a9d7\mp\Alpha"
  $retainedBeta = "D:\a\_temp\gu-239af6fb60ce40b5b2846baf38b9a9d7\mp\Beta"
  $retainedOwners = @(
    @{ path = $retainedAlpha; name = "Alpha"; node = $a; title = "Alpha loop" },
    @{ path = $retainedBeta; name = "Beta"; node = $b; title = "Beta loop" }
  )
  $retainedProjection = [ordered]@{
    projectRows = @(
      [ordered]@{ automationId = "open-project-1729193928419568695"; name = "Alpha"; processId = 3140; bounds = @(20,222,240,248) },
      [ordered]@{ automationId = "open-project-2225278778924952707"; name = "Beta"; processId = 3140; bounds = @(20,308,240,334) }
    )
    cards = @(
      [ordered]@{ automationId = Get-MultiProjectAutomationId "overview-project" $retainedAlpha; name = "Alpha, 1 loop"; processId = 3140; bounds = @(246,133,1754,153) },
      [ordered]@{ automationId = "canvas-card-1662987038540838399"; name = "Alpha loop"; processId = 3140; bounds = @(270,169,490,255) },
      [ordered]@{ automationId = Get-MultiProjectAutomationId "overview-project" $retainedBeta; name = "Beta, 1 loop"; processId = 3140; bounds = @(246,329,1754,349) },
      [ordered]@{ automationId = "canvas-card-1884655564485847249"; name = "Beta loop"; processId = 3140; bounds = @(270,365,490,451) }
    )
    foreignCardFragmentCount = 0; foreignProjectFragmentCount = 0
    canvasBounds = @(228,85,1036,780)
  }
  Invoke-MultiCase "retained hosted identities with current compact geometry" {
    Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $retainedProjection $retainedOwners $null 3140)) `
      "historical 220x86 hosted geometry passed the current compact-card predicate"
    $compactProjection = Copy-MultiProjectValue $retainedProjection
    $compactProjection.cards[0].bounds = @(326,157,1812,177)
    $compactProjection.cards[1].bounds = @(390,185,640,281)
    $compactProjection.cards[2].bounds = @(326,335,1812,355)
    $compactProjection.cards[3].bounds = @(390,363,640,459)
    Assert-MultiCase (Test-MultiProjectObservedRoster "overview" $compactProjection $retainedOwners $null 3140) `
      "compact geometry rejected the same exact two-node/two-caption identities and names"
    $projection = Copy-MultiProjectValue $retainedProjection
    $projection.canvasBounds = @(228,85,1036,780)
    $projection.cards[0].bounds = @(37,308,1226,324)
    $projection.cards[1].bounds = @(88,330,288,406)
    $projection.cards[2].bounds = @(37,450,1226,466)
    $projection.cards[3].bounds = @(88,472,288,548)
    Assert-MultiCase (Test-MultiProjectObservedRoster "overview" $projection $retainedOwners $null 3140) `
      "complete admitted 80 percent roster was rejected because rounded card height displaced caption geometry"
    return "Historical 220x86 bounds rejected; synthetic source geometry and exact admitted 80 percent node/caption roster accepted"
  }
  Invoke-MultiCase "source summary identity independent fixture and hosted goldens" {
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-project" "A") -ceq
      "canvas-card-1331915895917204893") "Alpha overview caption public hash differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-project" "B") -ceq
      "canvas-card-1331912597382320260") "Beta overview caption public hash differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-worktree-notice" "A") -ceq
      "canvas-card-1294898434078301384") "Alpha source summary public hash differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-worktree-notice" "B") -ceq
      "canvas-card-1294901732613186017") "Beta source summary public hash differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-worktree-notice" $retainedAlpha) -ceq
      "canvas-card-1669006899659070917") "retained hosted Alpha summary identity differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "overview-worktree-notice" $retainedBeta) -ceq
      "canvas-card-1518601899186967385") "retained hosted Beta summary identity differs"
    return "Exact overview-project and overview-worktree-notice projectPath identities; native parent4 canvas-card prefix"
  }
  Invoke-MultiCase "workspace marker independent prefix and row-key goldens" {
    Assert-MultiCase ((Get-MultiProjectAutomationId "workspace-loop-bar" $a) -ceq
      "workspace-loop-bar-1320898360543276851") "workspace loop-bar A prefix/row-key golden differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "workspace-loop-bar" $b) -ceq
      "workspace-loop-bar-2044737300313126929") "workspace loop-bar B prefix/row-key golden differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "workspace-toolbar" "A") -ceq
      "workspace-toolbar-2086745613872223135") "workspace toolbar A prefix/row-key golden differs"
    Assert-MultiCase ((Get-MultiProjectAutomationId "workspace-toolbar" "B") -ceq
      "workspace-toolbar-2086746713383851346") "workspace toolbar B prefix/row-key golden differs"
    return "Literal provider-prefix/FNV64 goldens independently derived from native identity strings"
  }
  Invoke-MultiCase "unknown automation kind rejected" -Negative {
    return Reject-MultiCase { Get-MultiProjectAutomationId "unsupported-marker" "A" $a } "MULTIPROJECT_KIND"
  }
  $workspaceOwner = @{ path = "A"; node = $a; name = "Alpha"; title = "Alpha loop" }
  function New-MultiWorkspaceProjection {
    return [ordered]@{
      loopBars = @([ordered]@{ automationId = "workspace-loop-bar-1320898360543276851"
        name = "Selected loop workspace"; processId = 4242; bounds = @(220,34,1200,80) })
      toolbars = @([ordered]@{ automationId = "workspace-toolbar-2086745613872223135"
        name = "Alpha"; processId = 4242; bounds = @(8,1,280,33) })
      foreignWorkspaceFragmentCount = 0
    }
  }
  Invoke-MultiCase "workspace projection requires both positively owned source markers" {
    Assert-MultiCase (Test-MultiProjectObservedSurface "workspace" $true (New-MultiWorkspaceProjection) $workspaceOwner 4242) `
      "literal expected workspace marker shape rejected"
    return "Functional mock only: exact node-bound constant loop bar and project-bound named toolbar"
  }
  Invoke-MultiCase "classified restart chrome alone cannot prove workspace owner identity" -Negative {
    $metadata = Get-MultiProjectFragmentMetadata (New-MultiMetadataMock 4242 "workspace-restart-session-2140902926206787169") 4242
    Assert-MultiCase ($metadata.observationReady -and -not (Test-MultiProjectObservedSurface "workspace" $true `
      ([ordered]@{ loopBars = @(); toolbars = @(); foreignWorkspaceFragmentCount = 0 }) $workspaceOwner 4242)) `
      "restart action replaced the exact node-bound loop bar and project-bound toolbar proof"
    return "Classified action is not an owner/node/project marker; both exact source markers remain mandatory"
  }
  foreach ($mutation in @("project-only", "missing-loop", "missing-toolbar", "wrong-prefix", "wrong-node", "wrong-project",
      "wrong-pid", "pid-type", "loop-name", "toolbar-name", "loop-duplicate", "toolbar-duplicate",
      "bounds-empty", "bounds-type", "bounds-zero", "selection-unmatched", "foreign-marker-count")) {
    Invoke-MultiCase ("workspace projection rejects " + $mutation) -Negative {
      $projection = New-MultiWorkspaceProjection
      $selectionMatches = $true
      switch ($mutation) {
        "project-only" { $projection.loopBars = @(); $projection.toolbars = @() }
        "missing-loop" { $projection.loopBars = @() }
        "missing-toolbar" { $projection.toolbars = @() }
        "wrong-prefix" { $projection.loopBars[0].automationId = "canvas-card-1320898360543276851" }
        "wrong-node" { $projection.loopBars[0].automationId = "workspace-loop-bar-2044737300313126929" }
        "wrong-project" { $projection.toolbars[0].automationId = "workspace-toolbar-2086746713383851346" }
        "wrong-pid" { $projection.toolbars[0].processId = 7777 }
        "pid-type" { $projection.loopBars[0].processId = "4242" }
        "loop-name" { $projection.loopBars[0].name = "Alpha loop" }
        "toolbar-name" { $projection.toolbars[0].name = "Alpha loop" }
        "loop-duplicate" { $projection.loopBars = @($projection.loopBars[0], $projection.loopBars[0]) }
        "toolbar-duplicate" { $projection.toolbars = @($projection.toolbars[0], $projection.toolbars[0]) }
        "bounds-empty" { $projection.loopBars[0].bounds = @() }
        "bounds-type" { $projection.toolbars[0].bounds[0] = "8" }
        "bounds-zero" { $projection.loopBars[0].bounds = @(220,34,220,80) }
        "selection-unmatched" { $selectionMatches = $false }
        "foreign-marker-count" { $projection.foreignWorkspaceFragmentCount = 1 }
      }
      Assert-MultiCase (-not (Test-MultiProjectObservedSurface "workspace" $selectionMatches $projection $workspaceOwner 4242)) `
        "project-only or wrong-bound marker projection accepted as actual workspace: $mutation"
      return "Actual functional predicate rejected $mutation; no native app claim"
    }
  }
  Invoke-MultiCase "project request rejects actual workspace chrome" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectObservedSurface "project" $true (New-MultiWorkspaceProjection) $workspaceOwner 4242)) `
      "requested project label accepted actual workspace marker shape"
    return "Actual surface predicate rejects workspace chrome under a project expectation"
  }
  $rosterOwners = @($workspaceOwner, @{ path = "B"; node = $b; name = "Beta"; title = "Beta loop" })
  Invoke-MultiCase "matching project surface selects its parent and selected loop" {
    Assert-MultiCase (Test-MultiProjectOwnerSelection "project" $workspaceOwner $workspaceOwner $true $true) `
      "matching project parent/loop selection rejected"
    return "Matching project surface selects its owner and selected loop"
  }
  Invoke-MultiCase "other project owner stays unselected on project surface" {
    Assert-MultiCase (Test-MultiProjectOwnerSelection "project" $rosterOwners[1] $workspaceOwner $false $false) `
      "nonmatching project owner expected unselected"
    return "Only the matching project owner and loop are selected"
  }
  Invoke-MultiCase "workspace keeps selected loop without parent-project selection" {
    Assert-MultiCase (Test-MultiProjectOwnerSelection "workspace" $workspaceOwner $workspaceOwner $false $true) `
      "workspace parent/loop selection expectation rejected"
    return "Workspace preserves selected loop without selecting its parent project"
  }
  Invoke-MultiCase "overview keeps selected loop without parent-project selection" {
    Assert-MultiCase (Test-MultiProjectOwnerSelection "overview" $workspaceOwner $workspaceOwner $false $true) `
      "overview parent/loop selection expectation rejected"
    return "Overview preserves selected loop without selecting its parent project"
  }
  Invoke-MultiCase "Quick Chats keeps selected loop without parent-project selection" {
    Assert-MultiCase (Test-MultiProjectOwnerSelection "quick_chats" $workspaceOwner $workspaceOwner $false $true) `
      "Quick Chats parent/loop selection expectation rejected"
    return "Quick Chats does not select a stale parent project"
  }
  Invoke-MultiCase "workspace rejects selected parent project row" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectOwnerSelection "workspace" $workspaceOwner $workspaceOwner $true $true)) `
      "workspace accepted selected parent project row"
    return "Stale workspace parent-project selection rejected"
  }
  Invoke-MultiCase "project surface rejects missing selected parent row" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectOwnerSelection "project" $workspaceOwner $workspaceOwner $false $true)) `
      "project surface accepted missing selected parent row"
    return "Missing matching project selection rejected"
  }
  Invoke-MultiCase "overview rejects stale selected parent project row" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectOwnerSelection "overview" $workspaceOwner $workspaceOwner $true $true)) `
      "overview accepted stale selected parent project row"
    return "Stale overview parent-project selection rejected"
  }
  Invoke-MultiCase "Quick Chats rejects stale selected parent project row" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectOwnerSelection "quick_chats" $workspaceOwner $workspaceOwner $true $true)) `
      "Quick Chats accepted stale selected parent project row"
    return "Stale Quick Chats parent-project selection rejected"
  }
  Invoke-MultiCase "workspace rejects loss of selected loop owner" -Negative {
    Assert-MultiCase (-not (Test-MultiProjectOwnerSelection "workspace" $workspaceOwner $workspaceOwner $false $false)) `
      "workspace accepted loss of expected loop selection"
    return "Missing selected loop-owner state rejected"
  }
  function New-MultiRosterProjection {
    return [ordered]@{
      projectRows = @(
        [ordered]@{ automationId = "open-project-1737218920896369762"; name = "Alpha"; processId = 4242; bounds = @(12,100,232,126) },
        [ordered]@{ automationId = "open-project-1737217821384741551"; name = "Beta"; processId = 4242; bounds = @(12,148,232,174) }
      )
      cards = @(
        [ordered]@{ automationId = "canvas-card-1331915895917204893"; name = "Alpha, 1 loop"; processId = 4242; bounds = @(318,106,1804,126) },
        [ordered]@{ automationId = "canvas-card-1929002346198335884"; name = "Alpha loop"; processId = 4242; bounds = @(382,134,632,230) },
        [ordered]@{ automationId = "canvas-card-1331912597382320260"; name = "Beta, 1 loop"; processId = 4242; bounds = @(318,284,1804,304) },
        [ordered]@{ automationId = "canvas-card-1616358459734844849"; name = "Beta loop"; processId = 4242; bounds = @(382,312,632,408) }
      )
      foreignCardFragmentCount = 0; foreignProjectFragmentCount = 0
      canvasBounds = @(220,34,1200,900)
    }
  }
  Invoke-MultiCase "unfiltered ordinary overview roster exactly two owners and cards" {
    Assert-MultiCase (Test-MultiProjectObservedRoster "overview" (New-MultiRosterProjection) $rosterOwners $null 4242) `
      "literal two-owner/two-node plus two-caption whole roster rejected"
    return "Historical two-card case counts NODE cards: complete owned canvas roster is four (two nodes plus two captions); no live app claim"
  }
  Invoke-MultiCase "compact overview roster rejects obsolete card dimensions" -Negative {
    $projection = New-MultiRosterProjection
    $projection.cards[1].bounds = @(262,118,482,204)
    Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
      "old 220x86 card passed the actual complete-roster predicate"
    return "Named Alpha node geometry rejected; no broad canvas count"
  }
  Invoke-MultiCase "compact overview roster rejects obsolete narrow caption position" -Negative {
    $projection = New-MultiRosterProjection
    $projection.canvasBounds = @(220,34,1028,900)
    $projection.cards[0].bounds = @(578,82,864,102)
    $projection.cards[2].bounds = @(578,278,864,298)
    Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
      "old 760-pixel floor caption positions passed the actual complete-roster predicate"
    $projection.cards[0].bounds = @(624,82,910,102)
    $projection.cards[2].bounds = @(624,278,910,298)
    Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
      "obsolete 806-pixel grid caption positions were accepted"
    $projection.cards[0].bounds = @(318,106,1804,126)
    $projection.cards[2].bounds = @(318,284,1804,304)
    Assert-MultiCase (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242) `
      "Mac producer-derived captions were rejected"
    return "Exact four-fragment mock roster: old760 and806 grids rejected, shared lane geometry accepted"
  }
  Invoke-MultiCase "fresh owned content cannot bless an overview missing its peer card" -Negative {
    $mock = New-MultiCaptureMock @((New-MultiCaptureState),(New-MultiCaptureState),(New-MultiCaptureState))
    $evidence = Get-MultiProjectElementEvidence $mock 4242 $capturePrior "functional/missing-peer" $captureReader
    $projection = New-MultiRosterProjection
    $projection.cards = @($projection.cards[0], $projection.cards[1], $projection.cards[2])
    Assert-MultiCase ($evidence.processId -eq 4242 -and
      -not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
      "fresh ownership bypassed mandatory full four-fragment peer roster"
    return "Positive fresh capture plus three-of-four projection is still rejected; no hidden peer fragment"
  }
  Invoke-MultiCase "project roster retains two owners and exactly one selected project card" {
    $projection = New-MultiRosterProjection
    $projection.cards = @([ordered]@{ automationId = "canvas-card-1983941480823304696"
      name = "Alpha loop"; processId = 4242; bounds = @(248,118,468,204) })
    Assert-MultiCase (Test-MultiProjectObservedRoster "project" $projection $rosterOwners $workspaceOwner 4242) `
      "surface-specific one-project card roster rejected"
    Assert-MultiCase (Test-MultiProjectObservedSurface "project" $true ([ordered]@{
      loopBars = @(); toolbars = @(); foreignWorkspaceFragmentCount = 0
    }) $workspaceOwner 4242) "project-only marker shape rejected"
    return "Two ordinary project rows, one exact project-card projection"
  }
  foreach ($mutation in @("extra-card", "extra-project", "duplicate-card", "duplicate-project",
      "foreign-card-pid", "foreign-project-pid", "foreign-card-count", "foreign-project-count")) {
    Invoke-MultiCase ("unfiltered roster rejects " + $mutation) -Negative {
      $projection = New-MultiRosterProjection
      switch ($mutation) {
        "extra-card" {
          $projection.cards += [ordered]@{ automationId = "canvas-card-1999999999999999999"
            name = "Unexpected cached loop"; processId = 4242; bounds = @(508,118,728,204) }
        }
        "extra-project" {
          $projection.projectRows += [ordered]@{ automationId = "open-project-1999999999999999999"
            name = "Unexpected project"; processId = 4242; bounds = @(12,196,232,222) }
        }
        "duplicate-card" { $projection.cards += $projection.cards[0] }
        "duplicate-project" { $projection.projectRows += $projection.projectRows[0] }
        "foreign-card-pid" { $projection.cards[0].processId = 7777 }
        "foreign-project-pid" { $projection.projectRows[0].processId = 7777 }
        "foreign-card-count" { $projection.foreignCardFragmentCount = 1 }
        "foreign-project-count" { $projection.foreignProjectFragmentCount = 1 }
      }
      Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
        "whitelisting hid actual extra/duplicate/foreign roster fragments: $mutation"
      return "Actual whole-roster predicate rejected $mutation"
    }
  }
  Invoke-MultiCase "project caption classification keeps full four distinct from two nodes" {
    $expected = Get-MultiProjectExpectedCanvasRoster "overview" $rosterOwners $null
    Assert-MultiCase ($expected.Count -eq 4 -and @($expected | Where-Object { $_.classification -ceq "node" }).Count -eq 2 -and
      @($expected | Where-Object { $_.classification -ceq "project-caption" }).Count -eq 2) "source taxonomy collapsed total/loop count"
    Assert-MultiCase ($expected[0].projectPath -ceq "A" -and $expected[0].nodeID -eq $null -and
      $expected[0].identityKind -ceq "overview-project") "caption not explicitly owner/kind bound"
    return "Full roster four, node two, per-owner caption two"
  }
  Invoke-MultiCase "source project caption geometry is separate from node geometry" {
    $geometry = Get-MultiProjectCaptionGeometry @(228,85,1036,780) @(390,185,640,281) @(326,157,1812,177)
    Assert-MultiCase (($geometry.caption -join ",") -ceq "326,157,1812,177") `
      "producer project caption and supplied caption differ"
    return "Derived from actual NODE bounds and canvas; caption is the Open target"
  }
  foreach ($mutation in @("two-nodes-unknown", "unknown-caption", "duplicate-caption", "wrong-caption-owner",
      "wrong-caption-pid", "wrong-caption-name", "wrong-caption-bounds", "caption-as-node-bounds", "hidden-chrome")) {
    Invoke-MultiCase ("classified roster rejects " + $mutation) -Negative {
      $projection = New-MultiRosterProjection
      switch ($mutation) {
        "two-nodes-unknown" {
          $projection.cards = @($projection.cards[1], $projection.cards[3],
            [ordered]@{ automationId = "canvas-card-1999999999999999999"; name = "Unknown loop"; processId = 4242; bounds = @(508,118,728,204) })
        }
        "unknown-caption" { $projection.cards[0].automationId = "canvas-card-1999999999999999999" }
        "duplicate-caption" { $projection.cards += $projection.cards[0] }
        "wrong-caption-owner" { $projection.cards[0].automationId = "canvas-card-1331912597382320260" }
        "wrong-caption-pid" { $projection.cards[0].processId = 7777 }
        "wrong-caption-name" { $projection.cards[0].name = "Last inspected" }
        "wrong-caption-bounds" { $projection.cards[0].bounds = @(750,278,1036,298) }
        "caption-as-node-bounds" { $projection.cards[1].bounds = $projection.cards[0].bounds }
        "hidden-chrome" { $projection.cards = @($projection.cards[1], $projection.cards[3]) }
      }
      Assert-MultiCase (-not (Test-MultiProjectObservedRoster "overview" $projection $rosterOwners $null 4242)) `
        "source taxonomy ignored unknown/duplicate/wrong-bound/hidden chrome: $mutation"
      return "Actual classified complete-roster predicate rejected $mutation"
    }
  }
  Invoke-MultiCase "literal lane geometry and DPI scaling" {
    $geometry = Get-MultiProjectLaneGeometry @(220,34,1200,900) @(382,134,632,230)
    Assert-MultiCase (($geometry.band -join ",") -ceq "300,96,1822,250" -and
      ($geometry.open -join ",") -ceq "1690,106,1746,126") "96-DPI literal source-derived bounds differ"
    $scaled = Get-MultiProjectLaneGeometry @(330,51,1800,1350) @(573,201,948,345)
    Assert-MultiCase (($scaled.open -join ",") -ceq "2535,159,2619,189") "144-DPI source-derived bounds differ"
    return "literal band/Open bounds; not UIA caption evidence"
  }
  Invoke-MultiCase "live target clipped to viewport" {
    $clipped = Get-MultiProjectClippedRectangle @(100,100,400,400) @(220,34,1200,250)
    Assert-MultiCase (($clipped -join ",") -ceq "220,100,400,250") "visible target clipping differs"
    return "literal clipped intersection"
  }
  Invoke-MultiCase "offscreen target rejected" -Negative {
    return Reject-MultiCase { Get-MultiProjectClippedRectangle @(0,0,50,50) @(220,34,1200,900) } "MULTIPROJECT_BOUNDS"
  }
  Invoke-MultiCase "resumeSession acknowledges an exact fixture owner without changing its graph" {
    $state = New-MultiBaseline
    $before = ConvertTo-MultiProjectCanonicalJson $state.graphs
    $frame = Copy-MultiProjectValue (New-MultiRequest)
    $frame.command.graphCommand.command = [ordered]@{ resumeSession = [ordered]@{ _0 = $a } }
    $result = Invoke-MultiProjectRequest $state $frame
    Assert-MultiCase ($result.response.success -eq $true -and $null -eq $result.publishPath -and
      $state.applied.Count -eq 0 -and
      (ConvertTo-MultiProjectCanonicalJson $state.graphs) -ceq $before) "session open mutated the fixture graph"
    return "Exact owner accepted; acknowledgement only, no agent launch or graph mutation"
  }
  Invoke-MultiCase "resumeSession refuses a node belonging to another project" -Negative {
    $state = New-MultiBaseline
    $before = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)
    $frame = Copy-MultiProjectValue (New-MultiRequest)
    $frame.command.graphCommand.command = [ordered]@{ resumeSession = [ordered]@{ _0 = $b } }
    $result = Reject-MultiCase { Invoke-MultiProjectRequest $state $frame } "MULTIPROJECT_OWNER"
    Assert-MultiCase ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)) -ceq $before) `
      "foreign session open changed peer state"
    return $result
  }
  $requestMutations = [ordered]@{
    owner = @{ prefix = "MULTIPROJECT_OWNER"; change = { param($f) $f.command.graphCommand.projectPath = $beta } }
    node = @{ prefix = "MULTIPROJECT_OWNER"; change = { param($f) $f.command.graphCommand.command.renameNode._0 = $b } }
    missing = @{ prefix = "MULTIPROJECT_SCHEMA"; change = { param($f) $f.command.graphCommand.command.renameNode.Remove("title") } }
    extra = @{ prefix = "MULTIPROJECT_SCHEMA"; change = { param($f) $f.command.graphCommand.command.renameNode.extra = 1 } }
    type = @{ prefix = "MULTIPROJECT_TYPE"; change = { param($f) $f.command.graphCommand.command.renameNode.title = 7 } }
    version = @{ prefix = "MULTIPROJECT_TYPE"; change = { param($f) $f.version = "2" } }
    boolean = @{ prefix = "MULTIPROJECT_TYPE"; change = { param($f) $f.version = $true } }
    requestID = @{ prefix = "MULTIPROJECT_UUID"; change = { param($f) $f.requestID = "bad" } }
    blank = @{ prefix = "MULTIPROJECT_TITLE"; change = { param($f) $f.command.graphCommand.command.renameNode.title = "  " } }
  }
  foreach ($entry in $requestMutations.GetEnumerator()) {
    Invoke-MultiCase ("request " + $entry.Key) -Negative {
      $state = New-MultiBaseline
      $original = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)
      $bad = Copy-MultiProjectValue (New-MultiRequest)
      & $entry.Value.change $bad | Out-Null
      $errorText = Reject-MultiCase { Invoke-MultiProjectRequest $state $bad } $entry.Value.prefix
      Assert-MultiCase ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)) -ceq $original) "rejected request mutated state"
      return $errorText
    }
  }
  foreach ($json in @("{", '{"x":1,"x":2}', '[]')) {
    Invoke-MultiCase ("JSON " + $json) -Negative { Reject-MultiCase { ConvertFrom-MultiProjectJson $json } "MULTIPROJECT_JSON" }
  }
  Invoke-MultiCase "duplicate request" -Negative {
    $state = New-MultiBaseline
    Invoke-MultiProjectRequest $state (New-MultiRequest) | Out-Null
    return Reject-MultiCase { Invoke-MultiProjectRequest $state (New-MultiRequest) } "MULTIPROJECT_DUPLICATE"
  }
  Invoke-MultiCase "unanswered publication" -Negative {
    $state = New-MultiBaseline
    Invoke-MultiProjectRequest $state (New-MultiRequest) | Out-Null
    return Reject-MultiCase { Complete-MultiProjectPublication $state (New-MultiProjectPublication $state $alpha) "rename" $renameId } "MULTIPROJECT_UNANSWERED"
  }
  foreach ($mutation in @("owner", "selection", "extra", "type", "duplicate", "second")) {
    Invoke-MultiCase ("control " + $mutation) -Negative {
      $state = New-MultiBaseline
      $control = New-MultiControl
      $prefix = "MULTIPROJECT_OWNER"
      switch ($mutation) {
        "owner" { $control.projectPath = $beta; $control.nodeID = $b }
        "selection" { $control.selection.nodeID = $a; $prefix = "MULTIPROJECT_SELECTION" }
        "extra" { $control.extra = 1; $prefix = "MULTIPROJECT_SCHEMA" }
        "type" { $control.title = 7; $prefix = "MULTIPROJECT_TYPE" }
        "duplicate" { Invoke-MultiProjectPublicationControl $state $control | Out-Null; $prefix = "MULTIPROJECT_DUPLICATE" }
        "second" { Invoke-MultiProjectPublicationControl $state $control | Out-Null; $control.token = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"; $prefix = "MULTIPROJECT_ONE_SHOT" }
      }
      $original = ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)
      $errorText = Reject-MultiCase { Invoke-MultiProjectPublicationControl $state $control } $prefix
      Assert-MultiCase ((ConvertTo-MultiProjectCanonicalJson (Get-MultiProjectPeerSnapshot $state)) -ceq $original) "rejected control mutated state"
      return $errorText
    }
  }
  foreach ($mutation in @("unknown", "extra", "type", "duplicate")) {
    Invoke-MultiCase ("response " + $mutation) -Negative {
      $state = New-MultiBaseline
      $pending = Invoke-MultiProjectRequest $state (New-MultiRequest)
      $response = Copy-MultiProjectValue $pending.response
      $prefix = "MULTIPROJECT_CORRELATION"
      switch ($mutation) {
        "unknown" { $response.requestID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }
        "extra" { $response.extra = 1; $prefix = "MULTIPROJECT_SCHEMA" }
        "type" { $response.success = "true"; $prefix = "MULTIPROJECT_TYPE" }
        "duplicate" { Complete-MultiProjectResponse $state $response; $prefix = "MULTIPROJECT_DUPLICATE" }
      }
      return Reject-MultiCase { Complete-MultiProjectResponse $state $response } $prefix
    }
  }
  foreach ($mutation in @("value", "missing", "type", "extra", "requestID", "unanswered", "sequence", "publicationExtra", "answerType", "zero")) {
    Invoke-MultiCase ("receipt rejects " + $mutation) -Negative {
      $bad = Copy-MultiProjectValue $after
      switch ($mutation) {
        "value" { $bad.received[-1].frame.command.graphCommand.command.renameNode.title = "wrong" }
        "missing" { $bad.received[-1].frame.command.graphCommand.command.renameNode.Remove("title") | Out-Null }
        "type" { $bad.appliedCount = "1" }
        "extra" { $bad.received[-1].frame.command.graphCommand.extra = 1 }
        "requestID" { $bad.answered[-1].requestID = $listId }
        "unanswered" { $bad.unansweredRequests = @($renameId) }
        "sequence" { $bad.publications[-1].frame.sequence = "3" }
        "publicationExtra" { $bad.publications[-1].frame.extra = 1 }
        "answerType" { $bad.answered[-1].response.success = 1 }
        "zero" { $bad.publicationCount = 0 }
      }
      Assert-MultiCase (-not (Test-MultiProjectRenameReceipt $before $bad $alpha $a "Alpha renamed")) "canonical negative $mutation accepted"
      return "actual receipt predicate rejected $mutation"
    }
  }
  $helper = $null
  $capture = $null
  $primaryError = $null
  $client = $null
  $jobSourcePath = Join-Path (Split-Path $stubPath -Parent) "Tests\Packaging.Standalone.Tests.ps1"
  $resultPath = Join-Path $scratch "peer.json"
  $controlPath = Join-Path $scratch "publish.json"
  $pipeName = "graphcode-contract-mp-" + [guid]::NewGuid().ToString("N")
  function Send-MultiTestFrame($frame) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($frame | ConvertTo-Json -Depth 16 -Compress))
    $size = $bytes.Length
    $header = [byte[]]@((($size -shr 24) -band 255), (($size -shr 16) -band 255), (($size -shr 8) -band 255), ($size -band 255))
    $client.Write($header, 0, 4)
    for ($offset = 0; $offset -lt $size; $offset += 7) {
      $count = [Math]::Min(7, $size - $offset)
      $client.Write($bytes, $offset, $count)
    }
    $client.Flush()
  }
  function Read-MultiTestBytes([int] $length) {
    $bytes = [byte[]]::new($length)
    $offset = 0
    while ($offset -lt $length) {
      $task = $client.ReadAsync($bytes, $offset, $length - $offset)
      Assert-MultiCase ($task.Wait(5000)) "owned pipe read timeout"
      $count = $task.GetAwaiter().GetResult()
      Assert-MultiCase ($count -gt 0) "owned pipe ended"
      $offset += $count
    }
    return ,$bytes
  }
  function Read-MultiTestFrame {
    $header = Read-MultiTestBytes 4
    $length = ([int]$header[0] -shl 24) -bor ([int]$header[1] -shl 16) -bor ([int]$header[2] -shl 8) -bor [int]$header[3]
    Assert-MultiCase ($length -gt 0 -and $length -le 2097152) "owned pipe invalid frame length"
    return ConvertFrom-MultiProjectJson ([Text.Encoding]::UTF8.GetString((Read-MultiTestBytes $length)))
  }
  try {
    $environment = @{ TEMP = $scratch; TMP = $scratch }
    $capture = Start-MultiProjectOwnedProcess $pwsh @("-NoProfile", "-File", $stubPath, "-PipeName", $pipeName, "-ResultPath", $resultPath,
      "-SeedMultiProjects", "-ProjectAPath", $alpha, "-ProjectBPath", $beta, "-PublicationControlPath", $controlPath) `
      $environment "multiproject" $jobSourcePath
    $helper = $capture.process
    $client = [IO.Pipes.NamedPipeClientStream]::new(".", $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect(5000)
    Send-MultiTestFrame ([ordered]@{ version = 2; kind = "hello"; supportedVersions = @(1,2) })
    $hello = Read-MultiTestFrame
    Invoke-MultiCase "owned real pipe hello" { Assert-MultiCase ($hello.selectedVersion -eq 2) "v2 hello missing"; return "owned pipe ready" }
    Send-MultiTestFrame ([ordered]@{ version = 2; kind = "request"; requestID = $listId; command = [ordered]@{ listRecentProjects = [ordered]@{} } })
    $response = Read-MultiTestFrame; $first = Read-MultiTestFrame; $second = Read-MultiTestFrame
    Invoke-MultiCase "fragmented real two-owner frames" {
      Assert-MultiCase ($response.requestID -ceq $listId -and $first.sequence -eq 1 -and $second.sequence -eq 2 -and
        $first.event.graphChanged.project.path -ceq $alpha -and $second.event.graphChanged.project.path -ceq $beta) "wire owners/sequence differ"
      return "2 graph frames actually read"
    }
    Send-MultiTestFrame (New-MultiRequest)
    $response = Read-MultiTestFrame; $event = Read-MultiTestFrame
    Invoke-MultiCase "real rename application response publication" {
      Assert-MultiCase ($response.requestID -ceq $renameId -and $event.sequence -eq 3 -and
        $event.event.graphChanged.nodes[0].title -ceq "Alpha renamed") "real rename reply differs"
      return "actual request/reply/frame"
    }
    $temporary = $controlPath + ".pending"
    New-MultiControl | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $temporary -NoNewline
    Move-Item -LiteralPath $temporary -Destination $controlPath
    $event = Read-MultiTestFrame
    Invoke-MultiCase "idle real pipe publication control" {
      Assert-MultiCase ($event.sequence -eq 4 -and $event.event.graphChanged.project.path -ceq $alpha -and
        $event.event.graphChanged.nodes[0].title -ceq "Alpha interleaved") "idle Alpha publication missing"
      return "synthetic selection token; not live app proof"
    }
    $client.Dispose()
    $client = $null
    $null = Complete-MultiProjectCapture $capture $scratch 5000
    $capture = $null
    $helper = $null
    $defaultResult = Join-Path $scratch "default-peer.json"
    $defaultPipe = "graphcode-contract-default-" + [guid]::NewGuid().ToString("N")
    $capture = Start-MultiProjectOwnedProcess $pwsh @("-NoProfile", "-File", $stubPath, "-PipeName", $defaultPipe, "-ResultPath", $defaultResult) `
      $environment "default-peer" $jobSourcePath
    $helper = $capture.process
    $client = [IO.Pipes.NamedPipeClientStream]::new(".", $defaultPipe, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect(5000)
    Send-MultiTestFrame ([ordered]@{ version = 2; kind = "hello"; supportedVersions = @(1,2) })
    $hello = Read-MultiTestFrame
    Send-MultiTestFrame ([ordered]@{ version = 2; kind = "request"; requestID = $listId; command = [ordered]@{ listRecentProjects = [ordered]@{} } })
    $response = Read-MultiTestFrame; $event = Read-MultiTestFrame
    Invoke-MultiCase "default fixture unchanged over real pipe" {
      Assert-MultiCase ($hello.selectedVersion -eq 2 -and $response.requestID -ceq $listId -and
        $response.event.recentProjectsListed.Count -eq 1 -and $event.sequence -eq 1 -and
        $event.event.graphChanged.project.path -ceq "graphcode://stub/project" -and
        $event.event.graphChanged.nodes.Count -eq 2 -and
        $event.event.graphChanged.nodes[0].id -ceq $a -and $event.event.graphChanged.nodes[0].title -ceq "Stub node A" -and
        $event.event.graphChanged.nodes[1].id -ceq $b -and $event.event.graphChanged.nodes[1].title -ceq "Stub node B") "legacy default fixture changed"
      return "default one-project/two-node fixture read through unchanged protocol"
    }
  } catch {
    $primaryError = $_
    throw
  } finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try { if ($client) { $client.Dispose() } } catch { $cleanupErrors.Add("disposing owned protocol client: $($_.Exception.Message)") }
    try { $null = Complete-MultiProjectCapture $capture $scratch 5000 $primaryError }
    catch { $cleanupErrors.Add($_.Exception.Message) }
    try { $results.ToArray() | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $scratch "cases.json") }
    catch { $cleanupErrors.Add("persisting protocol case diagnostics: $($_.Exception.Message)") }
    if ($cleanupErrors.Count -gt 0) {
      $message = "MULTIPROJECT_PROTOCOL_TEARDOWN: $($cleanupErrors -join '; ')"
      if ($primaryError) {
        $primaryError.Exception.Data["MultiProjectProtocolTeardown"] = $message
        Write-Warning $message -WarningAction Continue
      } else { throw $message }
    }
  }
  $drainSource = @'
param([string] $hostPath, [string] $caseRoot, [string] $mode)
$ErrorActionPreference = "Stop"
Start-Sleep -Milliseconds 300
[Console]::Out.WriteLine("owned-capture-stdout")
[Console]::Error.WriteLine("owned-capture-stderr")
if ($mode -in @("inherited", "inherited-timeout")) {
  $ready = Join-Path $caseRoot "descendant-ready"
  $command = "[IO.File]::WriteAllText('" + $ready.Replace("'", "''") + "', 'ready'); [Threading.Thread]::Sleep(30000)"
  $start = [Diagnostics.ProcessStartInfo]::new($hostPath)
  $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  foreach ($argument in @("-NoProfile", "-NonInteractive", "-EncodedCommand",
      [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) { $start.ArgumentList.Add($argument) }
  $child = [Diagnostics.Process]::Start($start)
  @{ pid = $child.Id; startUtcTicks = $child.StartTime.ToUniversalTime().Ticks } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $caseRoot "descendant.json")
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while (-not [IO.File]::Exists($ready)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "Controlled descendant not ready" }
    Start-Sleep -Milliseconds 10
  }
  $child.Dispose()
}
[IO.File]::WriteAllText((Join-Path $caseRoot "ready"), "ready")
if ($mode -in @("stop", "timeout")) { [Threading.Thread]::Sleep(30000) }
if ($mode -eq "abrupt") { [Environment]::Exit(23) }
'@
  foreach ($mode in @("normal", "stop", "inherited", "abrupt", "timeout", "inherited-timeout", "primary-secondary", "cleanup-only")) {
    Invoke-MultiCase ("bounded capture " + $mode) -Negative:($mode -in @("timeout", "inherited-timeout", "primary-secondary", "cleanup-only")) {
      $caseRoot = Join-Path $scratch ("drain-" + $mode)
      $null = New-Item -ItemType Directory -Path $caseRoot
      $entry = Join-Path $caseRoot "helper.ps1"
      [IO.File]::WriteAllText($entry, $drainSource)
      $ownedCapture = $null
      $lock = $null
      $primary = $null
      try {
        $ownedCapture = Start-MultiProjectOwnedProcess $pwsh @("-NoProfile", "-File", $entry, $pwsh, $caseRoot, $mode) `
          @{ TEMP = $caseRoot; TMP = $caseRoot } "controlled" $jobSourcePath
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [IO.File]::Exists((Join-Path $caseRoot "ready"))) {
          Assert-MultiCase ([DateTime]::UtcNow -lt $deadline) "controlled helper did not become ready"
          Start-Sleep -Milliseconds 10
        }
        if ($mode -in @("timeout", "inherited-timeout")) {
          $code = if ($mode -eq "timeout") { "MULTIPROJECT_CAPTURE_EXIT" } else { "MULTIPROJECT_CAPTURE_DRAIN" }
          try { Wait-MultiProjectCapture $ownedCapture 500 }
          catch { $primary = $_ }
          Assert-MultiCase ($null -ne $primary -and $primary.Exception.Message.StartsWith($code, [StringComparison]::Ordinal)) `
            "actual controlled $code timeout missing"
        } elseif ($mode -notin @("stop", "inherited")) {
          Wait-MultiProjectCapture $ownedCapture 5000
          if ($mode -eq "abrupt") {
            Assert-MultiCase ($ownedCapture.rootProcess.ExitCode -eq 23) "controlled abrupt-close exit was not actually exercised"
          } else {
            Assert-MultiCase ($ownedCapture.rootProcess.ExitCode -eq 0) "controlled normal-exit helper failed"
          }
        } else {
          if ($mode -eq "inherited") {
            Assert-MultiCase ($ownedCapture.rootProcess.WaitForExit(5000) -and -not $ownedCapture.stdout.IsCompleted -and
              [StandaloneProcessJob]::Active($ownedCapture.job) -gt 0) "real inherited-open-pipe condition absent"
          }
        }
        if ($mode -in @("primary-secondary", "cleanup-only")) {
          $lock = [IO.File]::Open((Join-Path $caseRoot "controlled-stdout.log"), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
          if ($mode -eq "primary-secondary") {
            try { throw "controlled original primary failure" } catch { $primary = $_ }
          }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($mode -eq "cleanup-only") {
          $message = Reject-MultiCase { Complete-MultiProjectCapture $ownedCapture $caseRoot 3000 } "MULTIPROJECT_TEARDOWN"
          Assert-MultiCase ($message.Contains("stdout capture persistence") -and $message.Contains("pid=") -and
            $message.Contains("start=") -and $message.Contains("job=")) "cleanup-only exact identity diagnostic missing"
          $ownedCapture = $null
          return $message
        }
        $diagnostic = Complete-MultiProjectCapture $ownedCapture $caseRoot 3000 $primary
        $ownedCapture = $null
        Assert-MultiCase ($diagnostic.rootExited -and $diagnostic.ownedJobEmpty -and
          $diagnostic.redirectedReadersDrained -and $clock.ElapsedMilliseconds -lt 5000) "shared bounded teardown not proved"
        if ($mode -eq "primary-secondary") {
          Assert-MultiCase ($primary.Exception.Message -ceq "controlled original primary failure" -and
            $primary.Exception.Data["MultiProjectTeardown:controlled"].Contains("stdout capture persistence")) `
            "original primary or explicit secondary diagnostic lost"
        } elseif ($primary) {
          Assert-MultiCase ($diagnostic.failures.Count -eq 0 -and
            $primary.Exception.Data["MultiProjectCapture:controlled"].redirectedReadersDrained) `
            "timeout primary lost its explicit drained-capture diagnostics"
        }
        if ($mode -in @("inherited", "inherited-timeout")) {
          $identity = Get-Content -LiteralPath (Join-Path $caseRoot "descendant.json") -Raw | ConvertFrom-Json
          $survivor = Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
          if ($survivor) {
            try { Assert-MultiCase ($survivor.StartTime.ToUniversalTime().Ticks -ne $identity.startUtcTicks) "owned inherited writer survived" }
            finally { $survivor.Dispose() }
          }
        }
        return $diagnostic
      } catch {
        if (-not $primary) { $primary = $_ }
        throw
      } finally {
        if ($lock) { $lock.Dispose() }
        if ($ownedCapture) { $null = Complete-MultiProjectCapture $ownedCapture $caseRoot 3000 $primary }
      }
    }
  }
  $results.ToArray() | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $scratch "cases.json")
  $positive = @($results | Where-Object { -not $_.negative }).Count
  $negative = @($results | Where-Object { $_.negative }).Count
  Assert-MultiCase ($positive -gt 0 -and $negative -gt 0) "empty protocol controls"
  $caseNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($result in $results) {
    Assert-MultiCase ($caseNames.Add($result.name)) "duplicate case labels inflate executed counts"
  }
  Write-Host ("MULTIPROJECT_PROTOCOL_CONTRACTS=" + ([ordered]@{
    executed = $results.Count; positive = $positive; negative = $negative; artifacts = $scratch
    liveAppSelectionProved = $false
  } | ConvertTo-Json -Compress))
}

function Assert-MultiProjectPeerEmissionContract([string] $source) {
  $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
  $phase = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-MultiProjectRenamePhase"
  },$true)
  $calls = @($phase.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq "Write-MultiProjectPeerReceipt"
  },$true))
  if ($calls.Count -ne 1 -or $calls[0].Extent.Text -cne 'Write-MultiProjectPeerReceipt (Read-DaemonCommandLog $peerPath) $afterUnchanged' -or
      $phase.Extent.Text.IndexOf($calls[0].Extent.Text) -ge $phase.Extent.Text.IndexOf('multi-project shell rejected Exit') -or
      $phase.Extent.Text.IndexOf($calls[0].Extent.Text) -le $phase.Extent.Text.IndexOf('$finalOverview = Wait-MultiProjectObservation "overview"')) {
    throw "RED: actual complete peer receipt not bound once to final owned file before teardown"
  }
  foreach ($token in @("UIA_MULTIPROJECT_PEER_RECEIPT=", "owned-stub-final-file-read", "rawJson", "utf8Sha256",
      "Assert-MultiProjectCompleteReport", "WarningAction Stop")) {
    if (-not $source.Contains($token)) { throw "RED: complete actual peer emission lacks $token" }
  }
}

function Assert-MultiProjectRenameSubmitContract([string] $source, [string] $dialogSource, [string] $formSource) {
  $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
  $caller = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Invoke-MultiProjectNativeRename"
  },$true)
  if (-not $caller -or -not $caller.Extent.Text.Contains("Invoke-MultiProjectRenameAction") -or
      $caller.Extent.Text.Contains("Sketch-Submit") -or $caller.Extent.Text.Contains("Sketch-Cancel")) {
    throw "RED: NEW Rename caller still submits through the wrong native form family"
  }
  if ($dialogSource -notmatch 'const ok_id = 9800;' -or $dialogSource -notmatch 'const cancel_id = 9808;' -or
      $dialogSource -notmatch '9904 \+ index \* 8' -or $formSource -notmatch 'const ok_id = 1;') {
    throw "RED: independently sourced Rename versus Sketch native control goldens drifted"
  }
  foreach ($required in @("function Invoke-MultiProjectRenameAction", "function Read-MultiProjectRenameField",
      "function Test-MultiProjectRenameField", "UIA_MULTIPROJECT_RENAME_NATIVE_TARGET=",
      "UIA_MULTIPROJECT_RENAME_NATIVE_FAILURE=", "UIA_MULTIPROJECT_RENAME_NATIVE_ACTION=",
      '$buttonId = if ($Cancel) { 9808 } else { 9800 }', "ClientBounds", "WorkBounds", "topOwner", "rectState",
      "hitSamples", "beforeInput", "enterFallbackUsed = `$false", "actualPriorButton1ReturnEstablished = `$false",
      'Get-MultiProjectRenameTitle $owner.title', "-expectedTitle `$renameTitle",
      "Only the name changes — the loop keeps its session, its edges, and its work.")) {
    if (-not $source.Contains($required)) { throw "RED: strict native Rename family route lacks $required" }
  }
}

function Assert-MultiProjectFreshCaptureContract([string] $source) {
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$errors)
  if ($errors.Count) { throw "RED: fresh capture source does not parse" }
  foreach ($required in @("function Read-MultiProjectElementCache", "function Read-MultiProjectOwnershipSnapshot",
      "function ConvertTo-MultiProjectPropertyState", "function Confirm-MultiProjectOwnedSnapshot",
      "UIA_MULTIPROJECT_FRESH_OWNERSHIP=", "UIA_MULTIPROJECT_CACHED_OWNERSHIP=", "UIA_MULTIPROJECT_CAPTURE_VERIFY=",
      "UIA_MULTIPROJECT_CONTAINER_OWNERSHIP=", "UIA_MULTIPROJECT_SNAPSHOT_DRIFT=",
      "priorStablePID", "priorIdentity", "semanticCauseEstablished", "wholeObservationDiscarded",
      "::ProcessIdProperty, `$true", "::AutomationIdProperty, `$true", "::NotSupported",
      "row identity, not a graph publication generation")) {
    if (-not $source.Contains($required)) { throw "RED: source-backed fresh ownership capture lacks $required" }
  }
  $observer = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Get-MultiProjectObservation"
  },$true)
  if (-not $observer -or $observer.Extent.Text -match '\.Current\.(Name|BoundingRectangle|AutomationId)' -or
      -not $observer.Extent.Text.Contains("verifiedOwnedSnapshotCount") -or
      -not $observer.Extent.Text.Contains("Confirm-MultiProjectOwnedSnapshot") -or
      -not $observer.Extent.Text.Contains("graph container ownership unavailable before child capture") -or
      -not $observer.Extent.Text.Contains("projects container ownership unavailable before child capture")) {
    throw "RED: observer bypasses fresh/cached ownership or whole-observation/container verification"
  }
}

function Assert-ShellHostPrerequisite([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Validation driver does not parse" }
  $clauses = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true).Clauses | Where-Object { $_.Item1.Value -eq "windows-shell" })
  if ($clauses.Count -ne 1) { throw "Expected one windows-shell validation branch" }
  $body = $clauses[0].Item2
  $commands = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst]
    }, $true))
  $build = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned Winghostty host build for App contracts"'
    })
  $contracts = @($commands | Where-Object {
      $_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
        $_.CommandElements[0].Extent.Text -match 'Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1'
    })
  $smoke = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned GraphCode Windows shell build and smoke"'
    })
  $guards = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.IfStatementAst]
    }, $true))
  $pin = @($guards | Where-Object { $_.Extent.Text -match '\$actualWinghosttyPin -ne \$pins\.winghostty\.sha' })
  $clean = @($guards | Where-Object { $_.Extent.Text -match '\$providerStatus\.Count -ne 0' })
  $library = @($guards | Where-Object { $_.Extent.Text -match 'Test-Path -LiteralPath \$winghosttyLib -PathType Leaf' })
  foreach ($stage in @(@{ Values = $build }, @{ Values = $contracts }, @{ Values = $smoke },
      @{ Values = $pin }, @{ Values = $clean }, @{ Values = $library })) {
    if ($stage.Values.Count -ne 1) { throw "Missing or repeated App host prerequisite stage" }
  }
  if ($clean[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $pin[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $build[0].Extent.EndOffset -ge $library[0].Extent.StartOffset -or
      $library[0].Extent.EndOffset -ge $contracts[0].Extent.StartOffset -or
      $contracts[0].Extent.EndOffset -ge $smoke[0].Extent.StartOffset -or
      $build[0].Extent.Text -notmatch '(?s)Push-Location \$winghosttyRoot.*& \$zig0152 build -Demit-win32-host=true.*finally \{ Pop-Location \}') {
    throw "Pinned host validation/build must precede App contracts, which must precede live smoke"
  }
}

function Get-WorkflowJobs([string] $text) {
  # Windows checkouts may convert workflow files to CRLF.
  $text = $text.Replace("`r`n", "`n")
  $jobsAt = [regex]::Match($text, '(?m)^jobs:\s*$')
  if (-not $jobsAt.Success) { throw "Workflow has no jobs block" }
  $body = $text.Substring($jobsAt.Index + $jobsAt.Length)
  $heads = @([regex]::Matches($body, '(?m)^  ([A-Za-z0-9_-]+):[ \t]*$'))
  $jobs = [ordered]@{}
  for ($index = 0; $index -lt $heads.Count; $index++) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $body.Length }
    $jobs[$heads[$index].Groups[1].Value] = $body.Substring($heads[$index].Index, $end - $heads[$index].Index)
  }
  $jobs
}

# Every validate.ps1 invocation a pull request runs, expanded over its matrix,
# must together cover exactly what `validate.ps1 -Task all` covers: every task,
# every Windows shell unit shard plus the integration part, and both packaging
# parts. Jobs gated to schedule/dispatch (a positive event_name test) are not
# pull request coverage.
function Test-CiPartitionCoverage([string] $runner, [string] $pwsh, [string] $repoRoot) {
  $expectedTasks = @(& $runner -List)
  $lines = [Collections.Generic.List[string]]::new()
  foreach ($file in @("windows-shell.yml", "windows-port-validation.yml", "windows-hardening.yml")) {
    $jobs = Get-WorkflowJobs (Get-Content (Join-Path $repoRoot ".github\workflows\$file") -Raw)
    foreach ($job in $jobs.GetEnumerator()) {
      if ($job.Value -match '(?m)^    if:.*github\.event_name ==') { continue }
      $shards = @("")
      $matrix = [regex]::Match($job.Value, '(?m)^\s+shard:\s*\[([0-9, ]+)\]')
      if ($matrix.Success) { $shards = @($matrix.Groups[1].Value -split ',\s*') }
      foreach ($run in [regex]::Matches($job.Value, '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 (.+)$')) {
        foreach ($shard in $shards) {
          $arguments = $run.Groups[1].Value.Replace('${{ matrix.shard }}', $shard)
          if ($arguments -match '\$\{\{') { throw "Unsupported workflow expression in validate.ps1 arguments: $arguments" }
          $output = @(& $pwsh -NoProfile -Command "& '$runner' $arguments -DryRun")
          if ($LASTEXITCODE -ne 0) { throw "Workflow validate.ps1 arguments failed a dry run: $arguments" }
          foreach ($line in $output) { if ("$line" -match '^task=') { $lines.Add("$line") } }
        }
      }
    }
  }
  $coveredTasks = @($lines | ForEach-Object { ($_ -split ' ')[0].Substring(5) } | Sort-Object -Unique)
  $missingTasks = @($expectedTasks | Where-Object { $coveredTasks -notcontains $_ })
  if ($missingTasks.Count -ne 0) {
    throw "RED: pull request CI no longer runs validation tasks: $($missingTasks -join ', ')"
  }
  Assert-PartCoverage $lines
}

function Assert-PartCoverage([string[]] $lines) {
  $shell = @($lines | Where-Object { $_ -like "task=windows-shell *" } | ForEach-Object {
      $match = [regex]::Match($_, 'part=(\w+) shard=(\d+)/(\d+)')
      [pscustomobject]@{ Part = $match.Groups[1].Value; Shard = [int]$match.Groups[2].Value; Count = [int]$match.Groups[3].Value }
    })
  if (-not @($shell | Where-Object { $_.Part -ne "unit" }).Count) {
    throw "RED: pull request CI does not run the Windows shell integration part"
  }
  $unitComplete = $false
  foreach ($group in @($shell | Where-Object { $_.Part -ne "integration" } | Group-Object Count)) {
    $count = [int]$group.Name
    $seen = @($group.Group | ForEach-Object { $_.Shard } | Sort-Object -Unique)
    if ($seen.Count -eq $count -and ($seen -join ',') -eq ((0..($count - 1)) -join ',')) { $unitComplete = $true }
  }
  if (-not $unitComplete) { throw "RED: pull request CI does not run every Windows shell unit shard" }
  $packaging = @($lines | Where-Object { $_ -like "task=packaging *" } | ForEach-Object { ($_ -split 'part=')[1] })
  if ($packaging -notcontains "all" -and ($packaging -notcontains "contracts" -or $packaging -notcontains "real")) {
    throw "RED: pull request CI does not run both packaging parts"
  }
}

function Test-CiAggregateGates([string] $repoRoot, [string] $pwsh) {
  foreach ($gate in @(
      @{ File = "windows-shell.yml"; Job = "windows-shell"; Exempt = @() },
      @{ File = "windows-port-validation.yml"; Job = "windows-spikes"; Exempt = @("investigation-privacy") })) {
    $jobs = Get-WorkflowJobs (Get-Content (Join-Path $repoRoot ".github\workflows\$($gate.File)") -Raw)
    if (-not $jobs.Contains($gate.Job)) { throw "RED: required check job '$($gate.Job)' is missing" }
    $aggregate = $jobs[$gate.Job]
    if ($aggregate -match '(?m)^    name:') { throw "RED: '$($gate.Job)' must keep its job id as the required check name" }
    $needs = [regex]::Match($aggregate, '(?m)^    needs:\s*\[([^\]]+)\]')
    if (-not $needs.Success) { throw "RED: '$($gate.Job)' does not need its parts" }
    $needed = @($needs.Groups[1].Value -split ',\s*' | ForEach-Object { $_.Trim() })
    foreach ($name in $jobs.Keys) {
      if ($name -ne $gate.Job -and $gate.Exempt -notcontains $name -and $needed -notcontains $name) {
        throw "RED: '$($gate.Job)' does not wait for part '$name'"
      }
    }
    if ($aggregate -notmatch '(?m)^    if: \$\{\{ !cancelled\(\) \}\}\s*$' -or
        $aggregate -notmatch 'NEEDS_JSON: \$\{\{ toJSON\(needs\) \}\}' -or
        $aggregate -notmatch 'Assert-CiPartResults\.ps1 -NeedsJson \$env:NEEDS_JSON -Required \$env:WINDOWS_REQUIRED') {
      throw "RED: '$($gate.Job)' does not fail unless every part succeeded"
    }
  }
  $gateScript = Join-Path $repoRoot "Tools\windows\Assert-CiPartResults.ps1"
  foreach ($case in @(
      @{ Required = "true"; Results = @{ changes = "success"; a = "success"; b = "success" }; Pass = $true },
      @{ Required = "true"; Results = @{ changes = "success"; a = "success"; b = "skipped" }; Pass = $false },
      @{ Required = "true"; Results = @{ changes = "failure"; a = "success"; b = "failure" }; Pass = $false },
      @{ Required = "true"; Results = @{ changes = "success"; a = "cancelled"; b = "success" }; Pass = $false },
      @{ Required = "false"; Results = @{ changes = "success"; a = "skipped"; b = "skipped" }; Pass = $true },
      @{ Required = "false"; Results = @{ changes = "success"; a = "failure"; b = "skipped" }; Pass = $false },
      @{ Required = "false"; Results = @{ changes = "failure"; a = "skipped"; b = "skipped" }; Pass = $false })) {
    $needsJson = [ordered]@{}
    foreach ($entry in $case.Results.GetEnumerator()) { $needsJson[$entry.Key] = @{ result = $entry.Value; outputs = @{} } }
    & $pwsh -NoProfile -File $gateScript -NeedsJson ($needsJson | ConvertTo-Json -Compress -Depth 4) -Required $case.Required *> $null
    if (($LASTEXITCODE -eq 0) -ne $case.Pass) {
      throw "RED: aggregate gate decided wrongly for required=$($case.Required) $($case.Results | ConvertTo-Json -Compress)"
    }
  }
}

function Get-WorkflowSteps([string] $jobText) {
  $jobText = $jobText.Replace("`r`n", "`n")
  $heads = @([regex]::Matches($jobText, '(?m)^      - '))
  $steps = [Collections.Generic.List[string]]::new()
  for ($index = 0; $index -lt $heads.Count; $index++) {
    $end = if ($index + 1 -lt $heads.Count) { $heads[$index + 1].Index } else { $jobText.Length }
    $steps.Add($jobText.Substring($heads[$index].Index, $end - $heads[$index].Index))
  }
  , $steps.ToArray()
}

# A cold provider cache miss must be able to seed its own immutable key even
# when a later gate fails or is cancelled, but never from a partial tree: the
# single save runs after a successful bootstrap, pin check, and build-only
# provider compile, and before any gate. Implicit success() gating (an `if:`
# without a status-check function) or an explicit success()/always() would
# reinstate whole-job gating or publish a failed build.
$script:ProviderCacheSaveCondition = "`${{ !cancelled() && steps.bootstrap.conclusion == 'success' && steps.verify-pins.conclusion == 'success' && steps.provider-build.conclusion == 'success' && steps.provider-cache.outputs.cache-hit != 'true' }}"
function Assert-ProviderCacheSeeding([string] $jobText, [string] $label, [bool] $requireGate) {
  $steps = Get-WorkflowSteps $jobText
  function Find-Step([scriptblock] $predicate) {
    for ($index = 0; $index -lt $steps.Count; $index++) {
      if (& $predicate $steps[$index]) { return $index }
    }
    return -1
  }
  $restore = Find-Step { param($s) $s -match '(?m)^        id: provider-cache\s*$' -and $s -match 'actions/cache/restore@' }
  $bootstrap = Find-Step { param($s) $s -match '(?m)^        id: bootstrap\s*$' -and $s -match '(?m)^        run: \./Tools/windows/bootstrap\.ps1 ' }
  $verify = Find-Step { param($s) $s -match '(?m)^        id: verify-pins\s*$' -and $s -match '(?m)^        run: \./Tools/windows/Assert-ProviderCheckout\.ps1 -ProviderRoot \.ci-providers\s*$' }
  $build = Find-Step { param($s) $s -match '(?m)^        id: provider-build\s*$' -and $s -match '(?m)^        run: \./Tools/windows/validate\.ps1 -Task provider-build\s*$' }
  $saves = @(for ($index = 0; $index -lt $steps.Count; $index++) { if ($steps[$index] -match 'actions/cache/save@') { $index } })
  $gate = Find-Step { param($s) $s -match '(?m)^        run: \./Tools/windows/validate\.ps1 -Task windows-shell\b' }
  foreach ($required in @(
      @{ Index = $restore; Name = "provider cache restore (id provider-cache)" },
      @{ Index = $bootstrap; Name = "bootstrap (id bootstrap)" },
      @{ Index = $verify; Name = "pin verification (id verify-pins)" },
      @{ Index = $build; Name = "build-only provider compile (id provider-build, validate.ps1 -Task provider-build)" })) {
    if ($required.Index -lt 0) { throw "RED: $label has no $($required.Name) before its provider cache save" }
  }
  if ($saves.Count -ne 1) { throw "RED: $label must have exactly one provider cache save, found $($saves.Count)" }
  $save = $saves[0]
  if ($requireGate -and $gate -lt 0) { throw "RED: $label has no downstream windows-shell gate" }
  if (-not ($restore -lt $bootstrap -and $bootstrap -lt $verify -and $verify -lt $build -and $build -lt $save)) {
    throw "RED: $label does not save only after restore, bootstrap, pin verification, and build-only compile"
  }
  if ($requireGate -and $save -gt $gate) {
    throw "RED: $label saves the provider cache after the gate, so a failed or cancelled gate discards a cold build"
  }
  $saveText = $steps[$save]
  $condition = [regex]::Match($saveText, '(?m)^        if:\s*(.+?)\s*$')
  if (-not $condition.Success) { throw "RED: $label provider cache save has no explicit condition" }
  $conditionText = $condition.Groups[1].Value
  if ($conditionText -match '(?<![\w.])(success|always)\(\)') {
    throw "RED: $label provider cache save uses whole-job success()/always() gating"
  }
  if ($conditionText -notmatch '!cancelled\(\)') {
    throw "RED: $label provider cache save omits a status-check function, which implicitly reinstates whole-job success() gating"
  }
  if ($conditionText -cne $script:ProviderCacheSaveCondition) {
    throw "RED: $label provider cache save is not gated on bootstrap, pin, and build-only success on a cache miss: $conditionText"
  }
  if ($saveText -notmatch '(?m)^            \.ci-providers\s*$' -or
      $saveText -notmatch '(?m)^            \.ci-tools/zig-global\s*$' -or
      $saveText -notmatch '(?m)^          key: \$\{\{ steps\.provider-cache\.outputs\.cache-primary-key \}\}\s*$') {
    throw "RED: $label provider cache save does not publish the complete immutable provider tree under its restored key"
  }
  if ($jobText -match 'continue-on-error') {
    throw "RED: $label lets a failed provider step continue into the cache save"
  }
}

function Test-ProviderCacheSeeding([string] $shellWorkflow, [string] $warmerWorkflow) {
  $shellJobs = Get-WorkflowJobs $shellWorkflow
  $warmerJobs = Get-WorkflowJobs $warmerWorkflow
  Assert-ProviderCacheSeeding $shellJobs["shell-integration"] "windows-shell integration" $true
  Assert-ProviderCacheSeeding $warmerJobs["warm"] "Windows cache warmer" $false
  if ([regex]::Matches($shellWorkflow, 'actions/cache/save@').Count -ne 1) {
    throw "RED: windows-shell integration must stay the sole provider cache writer"
  }
  foreach ($job in $shellJobs.GetEnumerator()) {
    if ($job.Key -eq "shell-integration") { continue }
    foreach ($step in (Get-WorkflowSteps $job.Value)) {
      if ($step -match '(?m)^\s+\.ci-providers\s*$' -and $step -notmatch 'actions/cache/restore@') {
        throw "RED: $($job.Key) must restore the provider cache read-only"
      }
    }
  }
  $bootstrapCap = [regex]::Match($warmerJobs["warm"], '(?s)id: bootstrap.*?timeout-minutes: (\d+)')
  $buildCap = [regex]::Match($warmerJobs["warm"], '(?s)id: provider-build.*?timeout-minutes: (\d+)')
  $outerCap = [regex]::Match($warmerJobs["warm"], '(?m)^    timeout-minutes: (\d+)\s*$')
  if (-not $bootstrapCap.Success -or -not $buildCap.Success -or -not $outerCap.Success) {
    throw "RED: Windows cache warmer bootstrap, build-only, and job caps must all be explicit"
  }
  # Healthy cold bootstrap measured 26m34s (job 109675286607); the warmer's own
  # 30m cap was exceeded on run 36645791783 attempt 1.
  if ([int]$bootstrapCap.Groups[1].Value -lt 35) {
    throw "RED: Windows cache warmer bootstrap cap leaves no headroom over a healthy 26m34s cold bootstrap"
  }
  if ([int]$outerCap.Groups[1].Value -le [int]$bootstrapCap.Groups[1].Value + [int]$buildCap.Groups[1].Value) {
    throw "RED: Windows cache warmer job cap truncates a bootstrap and build-only phase that both stay within their step caps"
  }
  # Cold integration, measured per phase: setup and Swift 1m54s (job 109703426776),
  # bootstrap 26m34s (job 109675286607), build-only 4m01s and save 10s
  # (job 109703426776), gate without the provider build up to 7m17s
  # (job 109694707284), post 10s: 40m06s. The former 35m cap cancelled 109675286607.
  $integrationCap = [regex]::Match($shellJobs["shell-integration"], '(?m)^    timeout-minutes: (\d+)\s*$')
  if (-not $integrationCap.Success -or [int]$integrationCap.Groups[1].Value -lt 41) {
    throw "RED: windows-shell integration job cap truncates a measured cold bootstrap, build-only, save, and gate (40m08s)"
  }
}

function Test-ProviderCacheSeedingMutations([string] $shellWorkflow, [string] $warmerWorkflow) {
  $shell = $shellWorkflow.Replace("`r`n", "`n")
  $warmer = $warmerWorkflow.Replace("`r`n", "`n")
  $condition = $script:ProviderCacheSaveCondition
  $integration = (Get-WorkflowJobs $shell)["shell-integration"]
  $steps = Get-WorkflowSteps $integration
  $saveStep = @($steps | Where-Object { $_ -match 'actions/cache/save@' })[0]
  $gateStep = @($steps | Where-Object { $_ -match 'validate\.ps1 -Task windows-shell\b' })[0]
  $buildStep = @($steps | Where-Object { $_ -match 'id: provider-build' })[0]
  if (-not $saveStep -or -not $gateStep -or -not $buildStep) { throw "Cannot construct provider cache seeding mutations" }
  $afterGate = $integration.Replace($saveStep, "").Replace($gateStep, $gateStep + $saveStep)
  $mutations = [ordered]@{
    "explicit whole-job success()" = $shell.Replace($condition, "`${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}")
    "implicit success() (no status-check function)" = $shell.Replace($condition, $condition.Replace("!cancelled() && ", ""))
    "always() saves a failed build" = $shell.Replace($condition, $condition.Replace("!cancelled()", "always()"))
    "build outcome not required" = $shell.Replace($condition, $condition.Replace(" && steps.provider-build.conclusion == 'success'", ""))
    "cache hit re-saved" = $shell.Replace($condition, $condition.Replace(" && steps.provider-cache.outputs.cache-hit != 'true'", ""))
    "save after gate" = $shell.Replace($integration, $afterGate)
    "clone-only tree (no build-only step)" = $shell.Replace($buildStep, "")
    "build step replaced by bootstrap" = $shell.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build", "run: ./Tools/windows/bootstrap.ps1 -ToolRoot .ci-tools -ProviderRoot .ci-providers")
    "partial tree without zig-global" = $shell.Replace($saveStep, $saveStep.Replace("            .ci-tools/zig-global`n", ""))
    "failed build continues" = $shell.Replace($buildStep, $buildStep.Replace("        shell: pwsh", "        continue-on-error: true`n        shell: pwsh"))
    "second provider cache writer" = $shell.Replace("uses: actions/cache/restore@", "uses: actions/cache@")
  }
  foreach ($mutation in $mutations.GetEnumerator()) {
    if ($mutation.Value -ceq $shell) { throw "Provider cache seeding mutation did not apply: $($mutation.Key)" }
    $rejected = $false
    try { Test-ProviderCacheSeeding $mutation.Value $warmer } catch { $rejected = $true }
    if (-not $rejected) { throw "RED: provider cache seeding contract accepted mutation: $($mutation.Key)" }
  }
  $warmerMutations = [ordered]@{
    "warmer runs terminal tests" = $warmer.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build", "run: ./Tools/windows/validate.ps1 -Task terminal-gate")
    "warmer whole-job success()" = $warmer.Replace($condition, "`${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}")
    "warmer 30m bootstrap cap" = [regex]::Replace($warmer, '(?s)(id: bootstrap.*?timeout-minutes: )\d+', '${1}30')
  }
  foreach ($mutation in $warmerMutations.GetEnumerator()) {
    if ($mutation.Value -ceq $warmer) { throw "Warmer mutation did not apply: $($mutation.Key)" }
    $rejected = $false
    try { Test-ProviderCacheSeeding $shell $mutation.Value } catch { $rejected = $true }
    if (-not $rejected) { throw "RED: provider cache seeding contract accepted warmer mutation: $($mutation.Key)" }
  }
}

# provider-build.ps1 must compile both pinned providers, report a positive
# executed build count, run no terminal tests, and reject a partial build.
function Test-ProviderBuildScript([string] $repoRoot, [string] $pwsh) {
  $script = Join-Path $repoRoot "Tools\windows\provider-build.ps1"
  if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "RED: build-only provider script is missing: $script"
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) "gc-provider-build-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force $scratch | Out-Null
  try {
    $fakeZig = Join-Path $scratch "fake-zig.cmd"
    Set-Content -LiteralPath $fakeZig -Encoding ascii -Value @(
      '@echo off',
      'echo FAKE_ZIG %*>> "%FAKE_ZIG_LOG%"',
      'if "%FAKE_ZIG_FAIL%"=="1" exit /b 7',
      'if "%FAKE_ZIG_SKIP_ARTIFACT%"=="1" exit /b 0',
      'echo %* | findstr /c:"-Demit-win32-host=true" >nul && (mkdir zig-out\lib 2>nul & type nul > zig-out\lib\winghostty-win32-host.lib)',
      'echo %* | findstr /c:"-Dtarget=x86_64-windows-gnu" >nul && (mkdir zig-out\bin 2>nul & type nul > zig-out\bin\zmx.exe)',
      'exit /b 0')
    $pins = [ordered]@{ schemaVersion = 1 }
    foreach ($name in @("winghostty", "zmx")) {
      $root = Join-Path $scratch $name
      New-Item -ItemType Directory -Force $root | Out-Null
      git -C $root init -q 2>$null
      "zig-out/`n" | Set-Content -LiteralPath (Join-Path $root ".gitignore") -NoNewline
      git -C $root add .gitignore
      git -C $root -c user.name=t -c user.email=t@example.invalid commit -q -m pin 2>$null
      $pins[$name] = [ordered]@{ sha = (git -C $root rev-parse HEAD) }
    }
    $pinsPath = Join-Path $scratch "provider-pins.json"
    $pins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
    function Invoke-ProviderBuildCase([hashtable] $environment) {
      foreach ($name in @("winghostty", "zmx")) {
        Remove-Item -LiteralPath (Join-Path $scratch "$name\zig-out") -Recurse -Force -ErrorAction SilentlyContinue
      }
      $log = Join-Path $scratch "zig-$([guid]::NewGuid().ToString('N')).log"
      $saved = @{}
      $all = @{ FAKE_ZIG_LOG = $log; FAKE_ZIG_FAIL = $null; FAKE_ZIG_SKIP_ARTIFACT = $null }
      foreach ($entry in $environment.GetEnumerator()) { $all[$entry.Key] = $entry.Value }
      foreach ($entry in $all.GetEnumerator()) {
        $saved[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
      }
      try {
        $output = @(& $pwsh -NoProfile -File $script `
            -WinghosttyRoot (Join-Path $scratch "winghostty") -ZmxRoot (Join-Path $scratch "zmx") `
            -Zig0152 $fakeZig -Zig0160 $fakeZig -PinsPath $pinsPath -ZmxAttempts 1 2>&1 | ForEach-Object { "$_" })
        $exit = $LASTEXITCODE
      } finally {
        foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value) }
      }
      $invocations = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
      [pscustomobject]@{ ExitCode = $exit; Output = $output; Invocations = $invocations }
    }
    $pass = Invoke-ProviderBuildCase @{}
    $text = $pass.Output -join "`n"
    $executed = [regex]::Match($text, '(?m)^PROVIDER_BUILD_EXECUTED=(\d+)\s*$')
    $stepLines = @($pass.Output | Where-Object { $_ -match '^PROVIDER_BUILD_STEP=' })
    if ($pass.ExitCode -ne 0 -or -not $executed.Success -or [int]$executed.Groups[1].Value -ne 2 -or
        $stepLines.Count -ne 2 -or $pass.Invocations.Count -ne 2) {
      throw "RED: provider-build.ps1 did not execute exactly two pinned provider builds (exit=$($pass.ExitCode)): $text"
    }
    if ($pass.Invocations[0] -notmatch '^FAKE_ZIG build -Demit-win32-host=true\s*$' -or
        $pass.Invocations[1] -notmatch '^FAKE_ZIG build -Dtarget=x86_64-windows-gnu\s*$') {
      throw "RED: provider-build.ps1 changed the canonical provider build flags: $($pass.Invocations -join '; ')"
    }
    if ($text -match '(?i)terminal gate|smoke|TerminalGate\.Tests|zmx send|uia') {
      throw "RED: provider-build.ps1 ran terminal tests or smoke: $text"
    }
    foreach ($case in @(
        @{ Name = "missing artifact"; Environment = @{ FAKE_ZIG_SKIP_ARTIFACT = "1" } },
        @{ Name = "failed compiler"; Environment = @{ FAKE_ZIG_FAIL = "1" } })) {
      $result = Invoke-ProviderBuildCase $case.Environment
      if ($result.ExitCode -eq 0 -or ($result.Output -join "`n") -match '(?m)^PROVIDER_BUILD_EXECUTED=') {
        throw "RED: provider-build.ps1 accepted a partial build ($($case.Name))"
      }
    }
    "untracked" | Set-Content -LiteralPath (Join-Path $scratch "zmx\dirty.txt")
    $dirty = Invoke-ProviderBuildCase @{}
    Remove-Item -LiteralPath (Join-Path $scratch "zmx\dirty.txt") -Force
    if ($dirty.ExitCode -eq 0 -or $dirty.Invocations.Count -ne 0) {
      throw "RED: provider-build.ps1 built from a dirty provider worktree"
    }
    $wrongPins = [ordered]@{ schemaVersion = 1; winghostty = $pins.winghostty; zmx = [ordered]@{ sha = ("0" * 40) } }
    $wrongPins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinsPath
    $wrong = Invoke-ProviderBuildCase @{}
    if ($wrong.ExitCode -eq 0 -or $wrong.Invocations.Count -ne 0) {
      throw "RED: provider-build.ps1 built an unpinned provider"
    }
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The Windows shell Zig sections are sharded across runners. A section passes
# only with a positive test count per `zig test` (a filter that matches nothing
# still exits 0), the shard plan is a complete disjoint partition, and the
# aggregate manifest check rejects missing, duplicated, or empty sections.
function Test-ShellSectionGate([string] $repoRoot, [string] $pwsh) {
  $shellTests = Join-Path $repoRoot "Tools\windows\Tests\WindowsShell.Tests.ps1"
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($shellTests, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-Native"
      }, $true)
    if (-not $definition) { throw "RED: WindowsShell.Tests.ps1 has no Invoke-Native section runner" }
    . ([scriptblock]::Create($definition.Extent.Text))
    $sectionCatalog = @("Probe section")
    $sectionPlan = [pscustomobject]@{ Assignment = @{ "Probe section" = 0 } }
    $Shard = 0
    $ShardCount = 1
    $executedSections = [Collections.Generic.List[object]]::new()
    foreach ($summary in @("All 0 tests passed.", "0 passed; 0 skipped; 1 failed.", "0 passed; 2 skipped; 0 failed.")) {
      $accepted = $true
      try {
        Invoke-Native "Probe section" ([scriptblock]::Create(
            "# `$zig test src\Probe.zig --test-filter nothing`nWrite-Output '$summary'; `$global:LASTEXITCODE = 0")) 6> $null
      } catch { $accepted = $false }
      if ($accepted) { throw "RED: a Windows shell section passed with no executed tests ($summary)" }
    }
    Invoke-Native "Probe section" {
      # $zig test src\Probe.zig
      # $zig test src\Other.zig
      Write-Output "All 3 tests passed."
      Write-Output "2 passed; 1 skipped; 0 failed."
      $global:LASTEXITCODE = 0
    } 6> $null
    if ($executedSections.Count -ne 1 -or $executedSections[0].positiveSummaries -ne 2 -or
        $executedSections[0].zigTestInvocations -ne 2) {
      throw "A Windows shell section with positive test counts was not recorded"
    }
  }

  $plans = @(0..2 | ForEach-Object {
      & $pwsh -NoProfile -File $shellTests -PlanOnly -Shard $_ -ShardCount 3 | Out-String | ConvertFrom-Json
    })
  $whole = & $pwsh -NoProfile -File $shellTests -PlanOnly | Out-String | ConvertFrom-Json
  $catalog = @($whole.catalog)
  if ($catalog.Count -lt 40 -or (@($whole.assigned) -join "`n") -cne ($catalog -join "`n")) {
    throw "RED: an unsharded Windows shell run does not execute the whole section catalog"
  }
  $assigned = @($plans | ForEach-Object { @($_.assigned) })
  if ($assigned.Count -ne $catalog.Count -or @($assigned | Sort-Object -Unique).Count -ne $catalog.Count -or
      @($catalog | Where-Object { $assigned -cnotcontains $_ }).Count -ne 0 -or
      @($plans | Where-Object { @($_.assigned).Count -eq 0 }).Count -ne 0) {
    throw "RED: the Windows shell shard plan is not a complete disjoint partition"
  }
  $shellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  if ($shellWorkflow -notmatch '(?m)^\s+shard: \[0, 1, 2\]\s*$' -or
      $shellWorkflow -notmatch '-ShellTestShardCount 3 ' -or
      $shellWorkflow -notmatch 'Test-ShellSectionManifests\.ps1 -Directory \.ci-sections -ShardCount 3') {
    throw "RED: the Windows shell shard matrix, plan, and coverage check disagree on the shard count"
  }

  $verifier = Join-Path $repoRoot "Tools\windows\Test-ShellSectionManifests.ps1"
  $scratch = Join-Path ([IO.Path]::GetTempPath()) "graphcode-shell-sections-$([guid]::NewGuid())"
  try {
    $mutations = @(
      @{ Name = "complete"; Pass = $true; Edit = { param($manifests) } },
      @{ Name = "missing section"; Pass = $false; Edit = { param($manifests)
          $manifests[1].executed = @($manifests[1].executed | Select-Object -Skip 1)
          $manifests[1].assigned = @($manifests[1].assigned | Select-Object -Skip 1) } },
      @{ Name = "duplicate section"; Pass = $false; Edit = { param($manifests)
          $manifests[0].executed = @($manifests[0].executed) + @($manifests[1].executed[0])
          $manifests[0].assigned = @($manifests[0].assigned) + @($manifests[1].assigned[0]) } },
      @{ Name = "zero tests"; Pass = $false; Edit = { param($manifests)
          $manifests[2].executed[0].positiveSummaries = 0 } },
      @{ Name = "skipped assignment"; Pass = $false; Edit = { param($manifests)
          $manifests[2].executed = @($manifests[2].executed | Select-Object -SkipLast 1) } },
      @{ Name = "missing shard"; Pass = $false; Edit = { param($manifests) $manifests[2] = $null } }
    )
    foreach ($mutation in $mutations) {
      $directory = Join-Path $scratch ($mutation.Name -replace ' ', '-')
      New-Item -ItemType Directory -Force $directory | Out-Null
      $manifests = @($plans | ForEach-Object {
          [pscustomobject]@{
            schemaVersion = 1
            shard = $_.shard
            shardCount = 3
            catalog = @($_.catalog)
            assigned = @($_.assigned)
            executed = @($_.assigned | ForEach-Object {
                [pscustomobject]@{ name = $_; seconds = 1; zigTestInvocations = 1; positiveSummaries = 1 }
              })
          }
        })
      & $mutation.Edit $manifests
      foreach ($manifest in @($manifests | Where-Object { $null -ne $_ })) {
        $manifest | ConvertTo-Json -Depth 6 |
          Set-Content -LiteralPath (Join-Path $directory "shard-$($manifest.shard).json")
      }
      & $pwsh -NoProfile -File $verifier -Directory $directory -ShardCount 3 *> $null
      if (($LASTEXITCODE -eq 0) -ne $mutation.Pass) {
        throw "RED: Windows shell section coverage decided wrongly for the $($mutation.Name) case"
      }
    }
  } finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}
function Test-ZigResolverDiagnostics([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Resolver source does not parse" }
  foreach ($name in @("Invoke-ZigResolverProbe", "Write-ZigResolverDiagnostic", "Resolve-ZigVersion")) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
      }, $true)
    if ($null -eq $definition) { throw "Missing actual resolver helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  function Assert-Resolver([bool] $condition, [string] $message) {
    if (-not $condition) { throw "Zig diagnostic contract: $message" }
  }
  $environmentName = "GRAPHCODE_ZIG_RESOLVER_TEST"
  $priorEnvironment = [Environment]::GetEnvironmentVariable($environmentName)
  $priorExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
  $priorExitValue = if ($null -ne $priorExit) { $priorExit.Value } else { $null }
  try {
    function InMemoryZigProbe([string] $operation) {
      if ($operation -eq "throw") { throw [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY") }
      $global:LASTEXITCODE = -1073741502
      Write-Output "0.15.2"
      Write-Error "ghp_PRIVATE_CANARY" -ErrorAction Continue
    }
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "version"
    Assert-Resolver ($probe.Output -ceq "0.15.2" -and $probe.ExitCode -eq -1073741502) "actual probe lost stdout or native exit"
    Assert-Resolver ($probe.ErrorText -match "ghp_PRIVATE_CANARY" -and $null -eq $probe.Failure) "actual probe did not separate stderr"
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "throw"
    Assert-Resolver ($null -eq $probe.ExitCode -and $null -ne $probe.Failure) "launch failure reused stale LASTEXITCODE"

    $a = "C:\fixture\configured\zig.exe"
    $b = "C:\fixture\path\zig.exe"
    $c = "C:\fixture\discovered\zig.exe"
    $repoRoot = "C:\fixture\repo"
    $state = @{
      PathCandidate = $b; Discovered = @($c); Exists = @{}; Probes = @{}
      Calls = [Collections.Generic.List[string]]::new()
      Diagnostics = [Collections.Generic.List[string]]::new()
      Warnings = [Collections.Generic.List[string]]::new()
      WriterFails = $false
      WarningFails = $false
    }
    function Get-Command($Name, $ErrorAction) { [pscustomobject]@{ Source = $state.PathCandidate } }
    function Get-ChildItem($Path, [switch] $Recurse, $Filter, [switch] $File, $ErrorAction) {
      foreach ($entry in $state.Discovered) { [pscustomobject]@{ FullName = $entry } }
    }
    function Test-Path($LiteralPath, $PathType, $ErrorAction) { $state.Exists[$LiteralPath] -eq $true }
    function Resolve-Path($LiteralPath) { [pscustomobject]@{ Path = $LiteralPath } }
    function Invoke-ZigResolverProbe([string] $candidate, [string] $operation) {
      $key = "$candidate|$operation"
      $state.Calls.Add($key)
      if (-not $state.Probes.ContainsKey($key)) { throw "Unplanned in-memory probe" }
      $state.Probes[$key]
    }
    function Write-Host($Object) {
      if ($state.WriterFails) { throw "ghp_PRIVATE_CANARY" }
      $state.Diagnostics.Add([string]$Object)
    }
    function Write-Warning($Message, $WarningAction) {
      $state.Warnings.Add([string]$Message)
      if ($state.WarningFails) { throw "ghp_PRIVATE_CANARY" }
    }
    function New-Probe($output, $exitCode = 0, $stderr = "") {
      [pscustomobject]@{ Output = $output; ExitCode = $exitCode; ErrorText = $stderr; Failure = $null }
    }
    function Reset-ResolverCase {
      $state.Calls.Clear(); $state.Diagnostics.Clear(); $state.Warnings.Clear()
      $state.WriterFails = $false
      $state.WarningFails = $false
      $state.PathCandidate = $b
      $state.Discovered = @($a, $c)
      $state.Exists = @{ $a = $true; $b = $true; $c = $true }
      $state.Probes = @{}
      foreach ($candidate in @($a, $b, $c)) {
        $state.Probes["$candidate|version"] = New-Probe "0.15.2"
        $state.Probes["$candidate|env"] = New-Probe '{"version":"0.15.2","lib_dir":"C:\\fixture\\lib"}'
      }
      [Environment]::SetEnvironmentVariable($environmentName, $a)
    }
    function Invoke-ResolverCase {
      $result = @()
      $failure = $null
      try { $result = @(Resolve-ZigVersion "0.15.2" $environmentName) } catch { $failure = $_ }
      [pscustomobject]@{ Result = $result; Failure = $failure }
    }
    function Read-Diagnostic([int] $index = 0) {
      $line = $state.Diagnostics[$index]
      Assert-Resolver ($line.StartsWith("ZIG_RESOLVER_DIAGNOSTIC ") -and $line.Length -lt 2500) "diagnostic tag or bound"
      Assert-Resolver ($line -notmatch "ghp_PRIVATE_CANARY|userinfo|GITHUB_TOKEN") "secret canary escaped diagnostic"
      $line.Substring("ZIG_RESOLVER_DIAGNOSTIC ".Length) | ConvertFrom-Json
    }

    Reset-ResolverCase
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $a -and $null -eq $case.Failure) "success return changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$a|env" -and $state.Diagnostics.Count -eq 0) "success probes repeated or diagnosed"
    Reset-ResolverCase
    $state.Exists[$a] = $false
    $state.Probes["$b|version"] = New-Probe "0.16.0"
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $c) "fallback selection changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$b|version,$c|version,$c|env") "fallback order/deduplication/env skipping changed"
    $missing = Read-Diagnostic
    $mismatch = Read-Diagnostic 1
    Assert-Resolver (-not $missing.exists -and $null -eq $missing.version -and $missing.source -eq "configured") "missing candidate fabricated probe"
    Assert-Resolver ($mismatch.source -eq "PATH" -and $mismatch.version.observedVersion -eq "0.16.0" -and $null -eq $mismatch.env) "mismatch evidence wrong"

    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "ghp_PRIVATE_CANARY" -1073741502 "ghp_PRIVATE_CANARY"
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.version.exitCodeHex -eq "0xC0000142") "nonzero exit/fallback changed"
    Assert-Resolver ($null -eq $diagnostic.version.observedVersion -and $diagnostic.version.stderr.reason -eq "unclassified") "unsafe version or stderr surfaced"
    foreach ($envText in @("invalid ghp_PRIVATE_CANARY", '{"version":"0.15.2","lib_dir":"C:\\fixture\\absent","env":{"GITHUB_TOKEN":"ghp_PRIVATE_CANARY"}}')) {
      Reset-ResolverCase
      $state.Probes["$a|env"] = New-Probe $envText 9 "error: unable to find zig installation directory ghp_PRIVATE_CANARY"
      $case = Invoke-ResolverCase
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.reason -eq "env-exit" -and $diagnostic.env.exitCode -eq 9) "env failure selection changed"
      Assert-Resolver ($diagnostic.env.stderr.reason -eq "unable to find zig installation directory") "safe known reason missing"
      if ($envText.StartsWith("{")) {
        Assert-Resolver ($diagnostic.env.parse -eq "parsed" -and $diagnostic.env.libDirectoryPresent -eq $false) "library metadata missing"
      } else {
        Assert-Resolver ($diagnostic.env.parse -eq "metadata-unavailable") "parse metadata missing"
      }
      $state.Probes["$a|env"] = New-Probe $envText
      $state.Diagnostics.Clear()
      $case = Invoke-ResolverCase
      Assert-Resolver ($case.Result[0] -ceq $a -and $state.Diagnostics.Count -eq 0) "new JSON/lib gate was introduced"
    }

    Reset-ResolverCase
    $failure = [Management.Automation.ErrorRecord]::new(
      [Management.Automation.RuntimeException]::new("ghp_PRIVATE_CANARY",
        [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY")),
      "Launch", [Management.Automation.ErrorCategory]::OpenError, $null)
    $state.Probes["$a|version"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 1 -and $case.Failure.ToString() -notmatch "ghp_PRIVATE_CANARY") "exception changed stop behavior or exposed secret"
    Assert-Resolver ($null -eq $diagnostic.version.exitCode -and $diagnostic.version.nativeErrorCode -eq 5) "exception fabricated exit"
    Reset-ResolverCase
    $state.Probes["$a|env"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 2 -and $diagnostic.reason -eq "env-exception") "env exception did not stop after one probe"
    Assert-Resolver ($null -eq $diagnostic.env.exitCode -and $diagnostic.env.nativeErrorCode -eq 5) "env exception lost nullable exit/native code"
    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "0.16.0"
    $state.WriterFails = $true
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result[0] -ceq $b -and $state.Warnings.Count -eq 1) "writer failure changed fallback"
    $state.WarningFails = $true
    $state.Calls.Clear()
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $b -and $null -eq $case.Failure) "both writer failures changed fallback"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$b|version,$b|env") "both writer failures changed probe order"
    foreach ($candidate in @($a, $b, $c)) { $state.Exists[$candidate] = $false }
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 0 -and $case.Failure.ToString() -eq "Zig 0.15.2 is required for the pinned Windows provider; set $environmentName.") "both writer failures masked original guard"

    Reset-ResolverCase
    $nonAsciiVersion = ([string][char]0x0661) + ".2.3"
    $overLimitVersion = "1.2.3+" + ("a" * 65)
    foreach ($unsafeVersion in @($nonAsciiVersion, $overLimitVersion)) {
      foreach ($probeName in @("version", "env")) {
        $state.Diagnostics.Clear()
        $text = if ($probeName -eq "version") { $unsafeVersion } else { @{ version = $unsafeVersion } | ConvertTo-Json -Compress }
        $probe = New-Probe $text 1
        if ($probeName -eq "version") {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "version-exit" $probe $null
        } else {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "env-exit" (New-Probe "0.15.2") $probe
        }
        $diagnostic = Read-Diagnostic
        $summary = $diagnostic.$probeName
        Assert-Resolver ($null -eq $summary.observedVersion -and
          $summary.stdout.bytes -eq [Text.Encoding]::UTF8.GetByteCount($text) -and
          $summary.stdout.sha256.Length -eq 64) "non-ASCII or over-limit version was not reduced to hash/length"
        Assert-Resolver (-not $state.Diagnostics[0].Contains($unsafeVersion)) "unsafe version appeared literally"
      }
    }
    Assert-Resolver ([Text.Encoding]::UTF8.GetByteCount($overLimitVersion) -gt 64) "version size control is not over limit"
    $state.WriterFails = $false
    foreach ($candidate in @("https://userinfo@github.com/zig", "C:\ghp_PRIVATE_CANARY\zig.exe", ("C:\" + ("x" * 520)))) {
      $state.Diagnostics.Clear()
      Write-ZigResolverDiagnostic $candidate "configured" "0.15.2" $true "version-exit" (New-Probe ("ghp_PRIVATE_CANARY" * 2000) 1) $null
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($diagnostic.candidate -eq "[omitted]" -and $diagnostic.version.stdout.bytes -gt 16384) "candidate/output cap or redaction failed"
    }
  } finally {
    [Environment]::SetEnvironmentVariable($environmentName, $priorEnvironment)
    if ($null -eq $priorExit) { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    else { $global:LASTEXITCODE = $priorExitValue }
  }
}

& (Join-Path $PSScriptRoot "PesterVersion.Tests.ps1")

$runner = Join-Path $PSScriptRoot "..\validate.ps1"
if (-not (Test-Path $runner)) {
  throw "RED: validation runner does not exist at $runner"
}

$tasks = & $runner -List
$expected = @(
  "swift-portable",
  "swift-contracts",
  "swift-production",
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
  "remote-bridge",
  "remote-e2e",
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy",
  "terminal-gate",
  "windows-shell",
  "packaging",
  "hardening"
)
foreach ($task in $expected) {
  if ($tasks -notcontains $task) {
    throw "Validation task '$task' is missing"
  }
}

$dryRun = & $runner -Task swift-paths -DryRun
if ($LASTEXITCODE -ne 0) {
  throw "Dry run failed with exit code $LASTEXITCODE"
}
if (($dryRun -join "`n") -notmatch "swift-paths") {
  throw "Dry run did not name the selected task"
}

# provider-build is the build-only entry point for provider cache seeding: it is
# selectable on its own but never part of -Task all (terminal-gate reuses it).
if ($tasks -notcontains "provider-build") {
  throw "RED: validation runner has no build-only provider-build task"
}
$providerDryRun = @(& $runner -Task provider-build -DryRun)
if ($LASTEXITCODE -ne 0 -or $providerDryRun.Count -ne 1 -or $providerDryRun[0] -cne "task=provider-build") {
  throw "RED: -Task provider-build does not select exactly the build-only task: $($providerDryRun -join ', ')"
}
$allDryRun = @(& $runner -Task all -DryRun)
if ($allDryRun.Count -lt 10 -or $allDryRun -contains "task=provider-build" -or $allDryRun -notcontains "task=terminal-gate") {
  throw "RED: -Task all must keep terminal-gate and exclude the build-only provider-build task: $($allDryRun -join ', ')"
}
$providerRunnerSource = Get-Content $runner -Raw
$providerClause = [regex]::Match($providerRunnerSource, '(?s)\n    "provider-build" \{(.*?)\n    \}')
if (-not $providerClause.Success -or $providerClause.Groups[1].Value -notmatch 'Invoke-ProviderBuild' -or
    $providerClause.Groups[1].Value -match '(?i)terminal-gate\.ps1|TerminalGate\.Tests|windows-shell\.ps1|uia|Stress') {
  throw "RED: provider-build task does not run only the shared build-only provider compile"
}
$terminalClause = [regex]::Match($providerRunnerSource, '(?s)\n    "terminal-gate" \{(.*?)\n    \}')
if (-not $terminalClause.Success -or
    $terminalClause.Groups[1].Value -notmatch '(?s)Invoke-ProviderBuild.*?terminal-gate\.ps1.*?-SkipProviderBuild.*?-Stress') {
  throw "RED: terminal-gate does not reuse the build-only provider compile before its full gate"
}
$providerScriptSource = Get-Content (Join-Path $PSScriptRoot "..\provider-build.ps1") -Raw -ErrorAction SilentlyContinue
foreach ($consumer in @("terminal-gate.ps1", "windows-shell.ps1")) {
  $consumerSource = Get-Content (Join-Path $PSScriptRoot "..\$consumer") -Raw
  if ($consumerSource -notmatch 'provider-build\.ps1' -or
      $consumerSource -match '-Demit-win32-host=true' -or
      $consumerSource -match '-Dtarget=x86_64-windows-gnu') {
    throw "RED: $consumer duplicates the pinned provider build instead of calling provider-build.ps1"
  }
}
if ($providerScriptSource -notmatch '-Demit-win32-host=true' -or $providerScriptSource -notmatch '-Dtarget=x86_64-windows-gnu') {
  throw "RED: provider-build.ps1 does not own the canonical provider build flags"
}

$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -File $runner -Task not-a-task *> $null
if ($LASTEXITCODE -eq 0) {
  throw "An unknown validation task succeeded"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$untrackedDirectory = Join-Path $repoRoot "investigation\spikes\validation-runner-untracked"
New-Item -ItemType Directory -Force $untrackedDirectory | Out-Null
try {
  "let value=1" | Set-Content (Join-Path $untrackedDirectory "Unformatted.swift")
  & $pwsh -NoProfile -File $runner -Task swift-format *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "An unformatted untracked Swift source was ignored"
  }
} finally {
  Remove-Item -LiteralPath $untrackedDirectory -Recurse -Force
}

$foreignJunction = Join-Path $repoRoot `
  "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\OwnershipSentinel"
New-Item -ItemType Directory -Force $foreignJunction | Out-Null
try {
  & $runner -Task swift-format -DryRun *> $null
  if (-not (Test-Path $foreignJunction)) {
    throw "A validation task removed resources owned by another task"
  }

  $windowsWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
  if ($windowsWorkflow -notmatch "(?s)full-pinned:.*bootstrap\.ps1.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment") {
    throw "RED: full-pinned Windows CI does not run real hardening after provider setup"
  }
  if ($windowsWorkflow -notmatch "GRAPHCODE_HARDENING_TARGET") {
    throw "RED: full-pinned Windows CI does not provide an owned environment harness"
  }
  $hardeningSource = Get-Content (Join-Path $PSScriptRoot "Hardening.Tests.ps1") -Raw
  foreach ($stage in @("real zmx/ConPTY terminal matrix", "real GraphCode shell matrix")) {
    if ($hardeningSource -notmatch ([regex]::Escape($stage) + ' failed \(exit=\$LASTEXITCODE; hex=')) {
      throw "Hardening stage failure omits the native exit code: $stage"
    }
  }
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
      $hardeningSource, [ref]$tokens, [ref]$errors)
    foreach ($name in @("Find-Bytes", "Get-HighOutputDiagnostics", "Get-HighOutputPayloadText")) {
      $function = $ast.Find({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true)
      if (-not $function) { throw "RED: high-output diagnostics helper is missing: $name" }
      . ([scriptblock]::Create($function.Extent.Text))
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("START" + ("A" * 1024) + "END")
    $diagnostics = Get-HighOutputDiagnostics $bytes "START" "END"
    if ($diagnostics.capturedBytes -ne $bytes.Length -or
        $diagnostics.startOffset -ne 0 -or $diagnostics.endOffset -ne 1029 -or
        $diagnostics.prefix.Length -ne 512 -or $diagnostics.suffix.Length -ne 512) {
      throw "High-output diagnostics lost marker positions or exceeded transcript bounds"
    }
    $partial = Get-HighOutputDiagnostics ([Text.Encoding]::ASCII.GetBytes("END")) "START" "END"
    if ($partial.startOffset -ne -1 -or $partial.endOffset -ne 0) {
      throw "High-output diagnostics hide an end marker when the start marker is missing"
    }
    $empty = Get-HighOutputDiagnostics ([byte[]]::new(0)) "START" "END"
    if ($empty.capturedBytes -ne 0 -or $empty.startOffset -ne -1 -or
        $empty.endOffset -ne -1 -or $empty.prefix -ne "" -or $empty.suffix -ne "") {
      throw "High-output diagnostics cannot report an empty capture"
    }
    $escape = [string][char]27
    $captures = @(
      "STARTAAAAEND",
      "ST${escape}[0mARTAA${escape}[31mAAEN${escape}[0mD",
      "STA`r`nRTAAAAE`r`nND",
      "START${escape}]0;END$([char]7)AAAAEND",
      "ST${escape}]0;title${escape}\ARTAAAAEND",
      "${escape}]0;before${escape}\STARTAAAAEND${escape}]0;after${escape}\"
    )
    foreach ($capture in $captures) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($payload -cne "AAAA") {
        throw "RED: high-output completion must survive terminal framing inside markers"
      }
    }
    foreach ($capture in @("", "STARTAAAA", "AAAAEND", "ENDSTARTAAAA",
        "${escape}]0;STARTAAAAEND")) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($null -ne $payload) { throw "Incomplete or reversed output markers were accepted" }
    }
    $emptyPayload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes("STARTEND")) "START" "END"
    if ($null -eq $emptyPayload -or $emptyPayload -cne "") {
      throw "Empty completed output must reach the length/hash checks, not look pending"
    }
  }
  if ($hardeningSource -notmatch
      '(?s)if \(-not \$completed\).*?Get-HighOutputDiagnostics.*?HARDENING_OUTPUT_DIAGNOSTICS_JSON=.*?Assert-True \$completed') {
    throw "RED: real high-output failure omits bounded transcript diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)if \(\$LASTEXITCODE -ne 0\) \{\s*\$output \| Write-Output\s*throw "hardening repeated run') {
    throw "RED: failed repeated hardening discards its child diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)\$shellVersion\s*=\s*\(& \$shell --version.*?-Version \$shellVersion') {
    throw "RED: post-release hardening does not preserve the built shell version"
  }
  $windowsShellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  $windowsPortWorkflow = Get-Content `
    (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
  $windowsCacheWarmerPath = Join-Path $repoRoot ".github\workflows\windows-cache-warmer.yml"
  if (-not (Test-Path -LiteralPath $windowsCacheWarmerPath -PathType Leaf)) {
    throw "RED: Windows CI has no main-scoped cache warmer"
  }
  $windowsCacheWarmerWorkflow = Get-Content $windowsCacheWarmerPath -Raw
  $shellJobs = Get-WorkflowJobs $windowsShellWorkflow
  $portJobs = Get-WorkflowJobs $windowsPortWorkflow
  foreach ($expected in @(
      @{ Text = $portJobs["spikes-swift"]; Job = "windows-spikes Swift"; Timeout = 45; Steps = 5 },
      @{ Text = $portJobs["spikes-other"]; Job = "windows-spikes terminal and contracts"; Timeout = 40; Steps = 6 },
      @{ Text = $shellJobs["packaging-real"]; Job = "windows-shell packaging (real products)"; Timeout = 50; Steps = 6 })) {
    if ($expected.Text -notmatch "(?m)^    timeout-minutes: $($expected.Timeout)$") {
      throw "RED: $($expected.Job) does not retain measured cold-cache headroom"
    }
    $stepTimeouts = [regex]::Matches($expected.Text, '(?m)^        timeout-minutes: \d+$').Count
    if ($stepTimeouts -lt $expected.Steps) {
      throw "RED: $($expected.Job) leaves a long-running phase without a step timeout"
    }
    if ($expected.Text -notmatch '(?s)name: Bootstrap exact Windows dependencies.*?timeout-minutes: 30') {
      throw "RED: $($expected.Job) bootstrap cap cannot cover the observed cold download and clone time"
    }
  }
  # The runner contract grows with every new case. On 2026-10-14 it measured up to
  # 302s in windows-spikes Swift (run 38663273264, against the former 5-minute cap)
  # and 341s in deterministic hardening (run 38659424901); a 1-2s overrun failed CI.
  # Keep at least about twice the measured worst case.
  $runnerContractStep = (Get-WorkflowSteps $portJobs["spikes-swift"]) |
    Where-Object { $_ -match 'name: Verify validation runner contract' } | Select-Object -First 1
  $runnerContractCap = [regex]::Match([string]$runnerContractStep, '(?m)^        timeout-minutes: (\d+)\s*$')
  if (-not $runnerContractCap.Success -or [int]$runnerContractCap.Groups[1].Value -lt 12) {
    throw "RED: windows-spikes Swift runner-contract step cap leaves no headroom over the measured 341s worst case"
  }
  foreach ($key in @(
      "windows-zig-v1-`${{ hashFiles('Tools/windows/bootstrap.ps1') }}",
      "windows-providers-v1-`${{ hashFiles('graphcode-windows/provider-pins.json', 'Tools/windows/bootstrap.ps1') }}-emit-win32-host-x86_64-windows-gnu")) {
    if ($windowsCacheWarmerWorkflow -notmatch [regex]::Escape($key)) {
      throw "RED: Windows cache warmer does not write the exact production key: $key"
    }
  }
  if ($windowsCacheWarmerWorkflow -notmatch '(?m)^  push:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^    branches: \[main\]\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^  schedule:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^    - cron: "23 4 \* \* 1"\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?m)^  workflow_dispatch:\s*$' -or
      $windowsCacheWarmerWorkflow -notmatch '(?s)validate\.ps1 -Task provider-build.*?actions/cache/save@' -or
      $windowsCacheWarmerWorkflow -match 'validate\.ps1 -Task terminal-gate') {
    throw "RED: Windows cache warmer does not cover main, weekly, manual, and build-only canonical provider builds"
  }
  Test-ProviderCacheSeeding $windowsShellWorkflow $windowsCacheWarmerWorkflow
  Test-ProviderCacheSeedingMutations $windowsShellWorkflow $windowsCacheWarmerWorkflow
  Test-ProviderBuildScript $repoRoot $pwsh
  foreach ($workflow in @($windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        '(?s)if: failure\(\).*?actions/upload-artifact@.*?gu-\*.*?logs\\\*\.json') {
      throw "RED: Windows CI does not retain failed UIA sandbox diagnostics as an artifact"
    }
  }
  foreach ($workflow in @($windowsWorkflow, $windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        "compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6" -or
        $workflow -notmatch "swift-version: swift-6\.3\.3-release" -or
        $workflow -notmatch "swift-build: 6\.3\.3-RELEASE") {
      throw "RED: pinned Windows CI does not install Swift 6.3.3 without WinGet"
    }
  }
  if ($windowsShellWorkflow -notmatch "bootstrap\.ps1") {
    throw "RED: Windows shell CI does not bootstrap exact dependencies"
  }
  if ($windowsShellWorkflow -notmatch "validate\.ps1 -Task windows-shell -SkipTrayLive" -or
      $windowsPortWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "Hardening\.Tests\.ps1 -Environment -SkipTrayLive") {
    throw "RED: hosted Windows CI does not explicitly declare unsupported interactive or WSL fixtures"
  }
  if ($windowsShellWorkflow -notmatch '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 -Task windows-shell\b') {
    throw "RED: Windows shell CI does not invoke the shell task containing live UI Automation"
  }
  $runnerSource = Get-Content $runner -Raw
  if ($runnerSource -notmatch
      '(?s)WINDOWS_SHELL_PRE_UIA_PROCESS_SNAPSHOT=.*?Stop-Process -Id.*?WINDOWS_SHELL_PRE_UIA_CLEANUP=verified.*?Native UI Automation live gate') {
    throw "RED: Windows shell validation does not snapshot and reap run-owned product processes before UIA"
  }
  Test-ZigResolverDiagnostics $runnerSource
  Assert-ShellHostPrerequisite $runnerSource
  $contractCall = [regex]::Match($runnerSource,
    '(?s)& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1"\)\s*`\s*-ZigExecutable \$zig0152').Value
  if (-not $contractCall) { throw "Cannot construct the host prerequisite ordering control" }
  $earlyContracts = $runnerSource.Replace($contractCall, "").Replace(
    'Invoke-Native "Pinned Winghostty host build for App contracts"',
    $contractCall + "`n      " + 'Invoke-Native "Pinned Winghostty host build for App contracts"')
  foreach ($mutation in @(
      $runnerSource.Replace('& $zig0152 build -Demit-win32-host=true', 'Write-Output "deliberately skipped build"'),
      $runnerSource.Replace('"Pinned Winghostty host build for App contracts"', '"deliberately removed prerequisite"'),
      $earlyContracts
    )) {
    $rejected = $false
    try { Assert-ShellHostPrerequisite $mutation } catch { $rejected = $true }
    if (-not $rejected) { throw "Host prerequisite contract accepted a deliberate missing-build control" }
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Signing\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run signed catalog integrity contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Rollback\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run rollback preservation contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?Packaging\.Standalone\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run standalone setup contracts"
  }
  foreach ($contract in @("Packaging.ScriptSigning.Tests.ps1", "Packaging.Scheduler.Tests.ps1", "Packaging.Uninstall.Tests.ps1")) {
    if ($runnerSource -notmatch ('(?s)"packaging" \{\s*if \(\$PackagingPart -ne "real"\) \{\s*& .*?' + [regex]::Escape($contract) + '.*?Packaging\.Tests\.ps1')) {
      throw "RED: packaging validation does not run $contract"
    }
  }
  if ($runnerSource -notmatch '(?s)if \(\$PackagingPart -ne "contracts"\) \{\s*Initialize-PackagingInputs\s*& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\Packaging\.Tests\.ps1"\)') {
    throw "RED: real packaging does not rebuild its own inputs before Packaging.Tests.ps1"
  }
  Test-CiPartitionCoverage $runner $pwsh $repoRoot
  Test-ShellSectionGate $repoRoot $pwsh
  Test-CiAggregateGates $repoRoot $pwsh
  if ($runnerSource -notmatch '(?s)"terminal-gate" \{\s*& .*?ProviderPins\.Tests\.ps1.*?TerminalGate\.Tests\.ps1') {
    throw "RED: terminal validation does not run provider pin no-divergence contracts"
  }
  foreach ($source in @($runnerSource, $hardeningSource)) {
    if ($source -notmatch '-StubResponseDelayMilliseconds 150') {
      throw "RED: shell validation does not exercise delayed correlated responses"
    }
  }
  if ($runnerSource -notmatch '(?s)Pinned GraphCode Windows shell build and smoke.*?Native UI Automation live gate.*?uia-live-gate\.ps1') {
    throw "RED: Windows shell validation does not execute the UI Automation live gate"
  }
  $uiaLiveGateSource = Get-Content (Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1") -Raw
  $laneCaptionStart = $uiaLiveGateSource.IndexOf(
    '$laneProjectId = Get-MultiProjectAutomationId "overview-project" $fixtureProjectPath',
    [StringComparison]::Ordinal)
  $laneCaptionEnd = if ($laneCaptionStart -ge 0) {
    $uiaLiveGateSource.IndexOf(
      '$surfaceActionPatterns["quick-chats-destination"].Invoke()',
      $laneCaptionStart,
      [StringComparison]::Ordinal)
  } else { -1 }
  if ($laneCaptionStart -lt 0 -or $laneCaptionEnd -le $laneCaptionStart) {
    throw "RED: lane caption gate does not bind the source-derived overview-project identity"
  }
  $laneCaptionSource = $uiaLiveGateSource.Substring(
    $laneCaptionStart, $laneCaptionEnd - $laneCaptionStart)
  foreach ($required in @(
      '$captions = @($children | Where-Object',
      '$_.Current.AutomationId -ceq $laneProjectId',
      'lane caption snapshot must expose exactly one project caption',
      'lane caption snapshot must not expose an uninspected worktree chip',
      'CaptionBounds = $caption',
      'OpenX = [int][Math]::Round(($caption.Left + $caption.Right) / 2)',
      'UIA_LANE_NO_WORKTREE_CHIP_EVIDENCE=')) {
    if (-not $laneCaptionSource.Contains($required)) {
      throw "RED: lane caption gate lacks the no-summary caption/open-project contract: $required"
    }
  }
  foreach ($obsolete in @(
      'Worktrees not inspected',
      '$laneOpenNoticeOffset',
      '$laneWorktreesNoticeOffset',
      '$laneActionsRightNoticeOffset',
      'overview lane Worktrees click')) {
    if ($laneCaptionSource.Contains($obsolete)) {
      throw "RED: lane caption gate retains obsolete summary/button contract: $obsolete"
    }
  }
  if ($uiaLiveGateSource -notmatch 'function Get-UiaStartupFileDiagnostic' -or
      $uiaLiveGateSource -notmatch 'RedirectStandardOutput' -or
      $uiaLiveGateSource -notmatch 'function Get-UiaPrelaunchDiagnostics' -or
      $uiaLiveGateSource -notmatch 'prelaunch-diagnostics\.json' -or
      $uiaLiveGateSource -notmatch 'startup-failure\.json') {
    throw "RED: UIA startup failure does not capture both child streams, app log, and prelaunch host diagnostics"
  }
  $prelaunchDiagnostic = $uiaLiveGateSource.LastIndexOf('Get-UiaPrelaunchDiagnostics')
  $shellLaunch = $uiaLiveGateSource.IndexOf('Start-Process -FilePath $Shell')
  if ($prelaunchDiagnostic -lt 0 -or $shellLaunch -lt 0 -or
      $prelaunchDiagnostic -gt $shellLaunch -or
      $uiaLiveGateSource -notmatch 'GetCurrentWindowStationName|WindowStation' -or
      $uiaLiveGateSource -notmatch 'GetCurrentDesktopName|DesktopName' -or
      $uiaLiveGateSource -notmatch 'desktopHeap' -or
      $uiaLiveGateSource -notmatch 'sessionId') {
    throw "RED: UIA prelaunch diagnostics omit process, desktop heap, window station, or session evidence"
  }
  if ($uiaLiveGateSource -notmatch 'function Get-UiaOwnedProcessDescendants' -or
      $uiaLiveGateSource -notmatch 'UIA_PROCESS_TREE_CLEANUP=verified') {
    throw "RED: UIA teardown does not enumerate, reap, and verify all owned descendants"
  }
  $uiaTokens = $null
  $uiaParseErrors = $null
  $uiaAst = [Management.Automation.Language.Parser]::ParseInput(
    $uiaLiveGateSource, [ref]$uiaTokens, [ref]$uiaParseErrors)
  if ($uiaParseErrors.Count -ne 0) {
    throw "RED: UIA live gate no longer parses after startup diagnostic changes"
  }
  $sidebarOracleHelper = $uiaAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Get-SidebarNavigationSnapshot"
    }, $true)
  if ($null -eq $sidebarOracleHelper) {
    throw "RED: UIA live gate is missing its functional sidebar navigation snapshot oracle"
  }
  $sidebarBoundsHelper = $uiaAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Get-SidebarNavigationBoundsProof"
    }, $true)
  if ($null -eq $sidebarBoundsHelper) {
    throw "RED: UIA live gate is missing its bounded sidebar scroll/reacquire proof"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$sidebarScrollTargets = @\(.*?ScrollIntoView\(\).*?Wait-ForRootReconnect.*?Get-SidebarNavigationBoundsProof.*?UIA_SIDEBAR_BOUNDS_EVIDENCE=') {
    throw "RED: UIA live gate does not scroll, reacquire, and prove each exact sidebar row in a bounded sequence"
  }
  $sidebarCaptureHelper = $uiaAst.Find({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "New-SidebarNavigationCapture"
    }, $true)
  if ($null -eq $sidebarCaptureHelper -or
      $uiaLiveGateSource -notmatch '\$sidebarCaptures\.Add\(\(New-SidebarNavigationCapture \$sidebarNavigationChildren\)\)') {
    throw "RED: UIA live gate retains mutable sidebar handles instead of freezing each reacquired capture"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$needsYouIds = .*?ScrollIntoView\(\).*?Needs-you row remained offscreen after bounded scroll/reacquire.*?UIA_SIDEBAR_SCROLL_RESTORED=overview-destination') {
    throw "RED: UIA live gate does not bound the later Needs-you row proof and restore the sidebar viewport"
  }
  . ([scriptblock]::Create($sidebarOracleHelper.Extent.Text))
  . ([scriptblock]::Create($sidebarCaptureHelper.Extent.Text))
  . ([scriptblock]::Create($sidebarBoundsHelper.Extent.Text))
  & {
    $sidebarFixtureCount = 0
    $sidebarPositiveCount = 0
    $sidebarNegativeCount = 0
    function New-SidebarNavigationElement(
      [string] $automationId,
      [string] $name,
      [double] $left,
      [double] $top,
      [double] $right,
      [double] $bottom,
      [int] $processId = 4242
    ) {
      return [pscustomobject]@{
        Current = [pscustomobject]@{
          AutomationId = $automationId
          Name = $name
          ProcessId = $processId
          BoundingRectangle = [pscustomobject]@{
            Left = $left; Top = $top; Right = $right; Bottom = $bottom
            Width = $right - $left; Height = $bottom - $top
          }
        }
      }
    }
    $sidebarFixture = @(
      (New-SidebarNavigationElement "overview-destination:graph" "Graph" 12 20 220 52),
      (New-SidebarNavigationElement "quick-chats-destination:quick-chats" "Quick Chats" 12 56 220 88),
      (New-SidebarNavigationElement "sidebar-section-1" "Local Projects" 12 100 220 121),
      (New-SidebarNavigationElement "open-project-1" "UIA project" 12 121 220 153),
      (New-SidebarNavigationElement "sidebar-section-2" "Remote Repositories" 12 168 220 189),
      (New-SidebarNavigationElement "open-project-2" "Temporary remote" 12 192 220 224),
      (New-SidebarNavigationElement "overview-destination" "Graph" 12 17 220 49),
      (New-SidebarNavigationElement "quick-chats-destination" "Quick Chats" 12 53 220 85),
      (New-SidebarNavigationElement "project-new-loop-1" "New Loop" 174 17 198 49),
      (New-SidebarNavigationElement "project-disclosure-2" "Collapse project" 198 17 220 49),
      (New-SidebarNavigationElement "quick-chat-new-3" "New Chat" 174 53 198 85),
      (New-SidebarNavigationElement "quick-chats-disclosure-4" "Collapse Quick Chats" 198 53 220 85),
      (New-SidebarNavigationElement "project-new-loop-5" "New Loop" 174 121 198 153),
      (New-SidebarNavigationElement "project-disclosure-6" "Collapse project" 198 121 220 153)
    )
    $initial = Get-SidebarNavigationSnapshot $sidebarFixture
    if (($initial.destinationIds -join "|") -cne "overview-destination|quick-chats-destination" -or
        ($initial.destinationNames -join "|") -cne "Graph|Quick Chats" -or
        $initial.ownerNames.Count -ne 2 -or
        ($initial.ownerNames -join "|") -cne "UIA project|Temporary remote" -or
        ($initial.sectionNames -join "|") -cne "Local Projects|Remote Repositories" -or
        $initial.recentRowIds.Count -ne 0 -or
        -not $initial.rowBoundsValid -or -not $initial.controlsValid -or
        $initial.controlsChecked -ne 6) {
      throw "RED: Sidebar navigation oracle missed destination order, open owners, section names, or contained controls"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $mutableCaptureChildren = @($sidebarFixture | ForEach-Object {
      $bounds = $_.Current.BoundingRectangle
      New-SidebarNavigationElement $_.Current.AutomationId $_.Current.Name `
        $bounds.Left $bounds.Top $bounds.Right $bounds.Bottom
    })
    $frozenCapture = New-SidebarNavigationCapture $mutableCaptureChildren
    foreach ($element in $mutableCaptureChildren) {
      $element.Current.BoundingRectangle.Left = 0
      $element.Current.BoundingRectangle.Top = 0
      $element.Current.BoundingRectangle.Right = 0
      $element.Current.BoundingRectangle.Bottom = 0
      $element.Current.BoundingRectangle.Width = 0
      $element.Current.BoundingRectangle.Height = 0
    }
    $frozenProof = Get-SidebarNavigationBoundsProof @($frozenCapture) 4242
    if (-not $frozenProof.structureValid -or -not $frozenProof.rowBoundsValid -or
        -not $frozenProof.controlsValid) {
      throw "RED: Sidebar capture retained mutable UIA handles instead of point-in-time evidence"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $dpiInitial = @($sidebarFixture | ForEach-Object {
      if ($_.Current.Name -in @("Remote Repositories", "Temporary remote")) {
        New-SidebarNavigationElement $_.Current.AutomationId $_.Current.Name 0 0 0 0
      } else {
        $_
      }
    })
    $dpiRemote = @($sidebarFixture | ForEach-Object {
      if ($_.Current.Name -in @("Remote Repositories", "Temporary remote")) {
        $_
      } else {
        New-SidebarNavigationElement $_.Current.AutomationId $_.Current.Name 0 0 0 0
      }
    })
    $dpiProof = Get-SidebarNavigationBoundsProof @(
      [pscustomobject]@{ Children = $dpiInitial },
      [pscustomobject]@{ Children = $dpiRemote }
    ) 4242
    if (-not $dpiProof.structureValid -or -not $dpiProof.rowBoundsValid -or
        -not $dpiProof.controlsValid -or $dpiProof.rowsChecked -ne 6 -or
        $dpiProof.controlsChecked -ne 6) {
      throw "RED: Sidebar bounds proof rejected exact DPI192 identities observed across bounded viewport captures"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $missingProof = Get-SidebarNavigationBoundsProof @(
      [pscustomobject]@{ Children = $dpiInitial },
      [pscustomobject]@{
        Children = @($dpiRemote | Where-Object { $_.Current.AutomationId -ne "open-project-2" })
      }
    ) 4242
    if ($missingProof.structureValid) {
      throw "RED: Sidebar bounds proof accepted a missing owned row"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $foreignProof = Get-SidebarNavigationBoundsProof @(
      [pscustomobject]@{ Children = $dpiInitial },
      [pscustomobject]@{
        Children = @($dpiRemote | ForEach-Object {
          if ($_.Current.AutomationId -eq "open-project-2") {
            New-SidebarNavigationElement $_.Current.AutomationId $_.Current.Name 12 192 220 224 9999
          } else {
            $_
          }
        })
      }
    ) 4242
    if ($foreignProof.structureValid) {
      throw "RED: Sidebar bounds proof accepted a foreign-process row"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $duplicateProof = Get-SidebarNavigationBoundsProof @(
      [pscustomobject]@{ Children = $dpiInitial },
      [pscustomobject]@{
        Children = @($dpiRemote + (New-SidebarNavigationElement "open-project-2" "Temporary remote" 12 192 220 224))
      }
    ) 4242
    if ($duplicateProof.structureValid) {
      throw "RED: Sidebar bounds proof accepted a duplicate owned row"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $wrongOrder = @($dpiInitial | Where-Object {
      $_.Current.AutomationId -notin @("open-project-1", "open-project-2")
    }) + @(
      ($dpiInitial | Where-Object { $_.Current.AutomationId -eq "open-project-2" }),
      ($dpiInitial | Where-Object { $_.Current.AutomationId -eq "open-project-1" })
    )
    $wrongOrderProof = Get-SidebarNavigationBoundsProof @(
      [pscustomobject]@{ Children = $wrongOrder },
      [pscustomobject]@{ Children = $dpiRemote }
    ) 4242
    if ($wrongOrderProof.structureValid) {
      throw "RED: Sidebar bounds proof accepted wrong open-owner order"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $localCollapsed = @($sidebarFixture | Where-Object {
      $_.Current.AutomationId -notin @(
        "open-project-1",
        "project-new-loop-5",
        "project-disclosure-6"
      )
    })
    $afterLocalCollapse = Get-SidebarNavigationSnapshot $localCollapsed
    if (($afterLocalCollapse.ownerNames -join "|") -cne "Temporary remote") {
      throw "RED: Sidebar navigation oracle did not isolate local owner collapse"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $remoteCollapsed = @($sidebarFixture | Where-Object {
      $_.Current.AutomationId -ne "open-project-2"
    })
    $afterRemoteCollapse = Get-SidebarNavigationSnapshot $remoteCollapsed
    if (($afterRemoteCollapse.ownerNames -join "|") -cne "UIA project") {
      throw "RED: Sidebar navigation oracle did not isolate remote owner collapse"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $restoredFixture = @($sidebarFixture | Where-Object {
      $_.Current.AutomationId -notin @(
        "sidebar-section-2",
        "open-project-2"
      )
    })
    $restored = Get-SidebarNavigationSnapshot $restoredFixture
    if (($restored.ownerNames -join "|") -cne "UIA project" -or
        ($restored.sectionNames -join "|") -cne "Local Projects" -or
        $restored.recentRowIds.Count -ne 0) {
      throw "RED: Sidebar navigation oracle accepted a temporary remote owner after fixture restore"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    $recentMutation = Get-SidebarNavigationSnapshot @(
      $sidebarFixture + (New-SidebarNavigationElement "project-row-recent" "Recent folder" 12 228 220 260)
    )
    if ($recentMutation.recentRowIds.Count -ne 1) {
      throw "RED: Sidebar navigation oracle failed to detect a projected unopened recent folder"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $clippedMutation = @($sidebarFixture | Where-Object {
      $_.Current.AutomationId -ne "project-new-loop-5"
    }) + (New-SidebarNavigationElement "project-new-loop-5" "New Loop" 174 121 228 153)
    $clipped = Get-SidebarNavigationSnapshot $clippedMutation
    if ($clipped.controlsValid) {
      throw "RED: Sidebar navigation oracle accepted a row control extending beyond its owner"
    }
    $sidebarFixtureCount++
    $sidebarNegativeCount++
    $reorderedOwners = @($sidebarFixture | Where-Object {
      $_.Current.AutomationId -notin @(
        "open-project-1",
        "open-project-2"
      )
    }) + @(
      (New-SidebarNavigationElement "open-project-2" "Temporary remote" 12 124 220 156),
      (New-SidebarNavigationElement "open-project-1" "UIA project" 12 192 220 224)
    )
    $reordered = Get-SidebarNavigationSnapshot $reorderedOwners
    if (($reordered.ownerNames -join "|") -cne "Temporary remote|UIA project") {
      throw "RED: Sidebar navigation oracle failed to preserve the owner order evidence"
    }
    $sidebarFixtureCount++
    $sidebarPositiveCount++
    if ($sidebarFixtureCount -ne 13 -or $sidebarPositiveCount -ne 7 -or $sidebarNegativeCount -ne 6) {
      throw "RED: Sidebar navigation fixture execution count changed unexpectedly"
    }
    Write-Host ("SIDEBAR_NAVIGATION_FIXTURES={0} ({1} positive, {2} negative; App 22->20 restoration has a separate hidden test)" -f `
      $sidebarFixtureCount, $sidebarPositiveCount, $sidebarNegativeCount)
  }
  foreach ($helperName in @(
      "Protect-UiaStartupDiagnosticText",
      "Get-UiaStartupDiagnosticValue",
      "Get-UiaStartupFileDiagnostic",
      "Get-UiaStartupImageHash",
      "Write-UiaStartupFailureDiagnostic",
      "Get-UiaPrelaunchDiagnostics",
      "Get-UiaOwnedProcessDescendants",
      "Stop-UiaOwnedProcessTrees"
    )) {
    $helper = $uiaAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $helperName
      }, $true)
    if ($null -eq $helper) { throw "RED: UIA startup capture helper is missing: $helperName" }
    . ([scriptblock]::Create($helper.Extent.Text))
  }
  $startupCapturePath = Join-Path $env:TEMP "uia-startup-capture-$PID.log"
  try {
    [IO.File]::WriteAllText($startupCapturePath, "loader failed`npassword=private-canary`n")
    $capture = Get-UiaStartupFileDiagnostic $startupCapturePath "logs\shell-stderr.log"
    if ($capture.state -ne "available" -or
        $capture.content -notmatch "loader failed" -or
        $capture.content -match "private-canary" -or
        $capture.readBytes -ne $capture.lengthBytes) {
      throw "RED: UIA startup capture does not retain bounded, redacted child output"
    }
    $truncatedCapture = Get-UiaStartupFileDiagnostic $startupCapturePath `
      "logs\shell-stderr.log" 8
    if ($truncatedCapture.state -ne "truncated" -or
        $truncatedCapture.readBytes -ne 8 -or $truncatedCapture.lengthBytes -le 8) {
      throw "RED: UIA startup capture does not bound oversized diagnostics"
    }
    $missingCapture = Get-UiaStartupFileDiagnostic `
      (Join-Path $env:TEMP "uia-missing-$PID.log") "logs\missing.log"
    if ($missingCapture.state -ne "missing") {
      throw "RED: UIA startup capture does not distinguish a missing child log"
    }
    $startupLogDirectory = Join-Path $env:TEMP "uia-startup-logs-$PID"
    $startupSupportDirectory = Join-Path $env:TEMP "uia-startup-support-$PID"
    New-Item -ItemType Directory -Path $startupLogDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $startupSupportDirectory -Force | Out-Null
    [IO.File]::WriteAllText(
      (Join-Path $startupLogDirectory "shell-stderr.log"),
      "loader failed`npassword=stderr-canary`n"
    )
    [IO.File]::WriteAllText(
      (Join-Path $startupLogDirectory "shell-stdout.log"),
      "child output captured"
    )
    [IO.File]::WriteAllText(
      (Join-Path $startupSupportDirectory "graphcode-windows.log"),
      "app initialization failed`nsecret=app-canary`n"
    )
    Write-UiaStartupFailureDiagnostic (Get-Process -Id $PID) 0 `
      $startupCapturePath $env:TEMP $startupLogDirectory $startupSupportDirectory
    $startupRecord = Get-Content -LiteralPath `
      (Join-Path $startupLogDirectory "startup-failure.json") -Raw | ConvertFrom-Json
    if ($startupRecord.stderr.content -notmatch "loader failed" -or
        $startupRecord.stdout.content -notmatch "child output captured" -or
        $startupRecord.applicationLog.content -notmatch "app initialization failed" -or
        $startupRecord.stderr.content -match "stderr-canary" -or
        $startupRecord.applicationLog.content -match "app-canary") {
      throw "RED: retained UIA startup report omits or exposes captured child and app output"
    }
  } finally {
    Remove-Item -LiteralPath (Join-Path $env:TEMP "uia-startup-logs-$PID") `
      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP "uia-startup-support-$PID") `
      -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupCapturePath -Force -ErrorAction SilentlyContinue
  }
  $hostInfoClassAt = $uiaLiveGateSource.IndexOf("public static class GraphCodeUiaHostInfo")
  if ($hostInfoClassAt -lt 0) {
    throw "RED: UIA host context native diagnostics type is missing"
  }
  $hostInfoAddTypeAt = $uiaLiveGateSource.LastIndexOf(
    'Add-Type -TypeDefinition @"', $hostInfoClassAt
  )
  $hostInfoBodyAt = $uiaLiveGateSource.IndexOf("`n", $hostInfoAddTypeAt) + 1
  $hostInfoCloseAt = $uiaLiveGateSource.IndexOf('"@', $hostInfoClassAt)
  if ($hostInfoAddTypeAt -lt 0 -or $hostInfoBodyAt -le 0 -or
      $hostInfoCloseAt -lt 0) {
    throw "RED: UIA host context native diagnostics type is missing"
  }
  $hostInfoBody = $uiaLiveGateSource.Substring(
    $hostInfoBodyAt, $hostInfoCloseAt - $hostInfoBodyAt
  ).TrimEnd("`r", "`n")
  Add-Type -TypeDefinition $hostInfoBody
  $hostSessionId = [GraphCodeUiaHostInfo]::CurrentSessionId()
  if ($hostSessionId -isnot [uint32]) {
    throw "RED: UIA host context did not resolve the current Windows session"
  }
  $hostDiagnostics = Get-UiaPrelaunchDiagnostics
  if ($hostDiagnostics.sessionId.state -ne "available" -or
      $hostDiagnostics.currentProcessId -ne $PID -or
      $hostDiagnostics.desktopHeap.state -ne "usage_unavailable") {
    throw "RED: UIA host context diagnostics omitted explicit session or desktop-heap status"
  }
  $treeFixturePath = Join-Path $env:TEMP "uia-process-tree-$PID.ps1"
  $treeRoot = $null
  try {
    [IO.File]::WriteAllText($treeFixturePath, @'
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME "pwsh.exe"))
$start.ArgumentList.Add("-NoProfile")
$start.ArgumentList.Add("-Command")
$start.ArgumentList.Add("Start-Sleep -Seconds 60")
[void][Diagnostics.Process]::Start($start)
Start-Sleep -Seconds 60
'@)
    $treeRoot = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-File", $treeFixturePath) -PassThru
    $treeObserved = $false
    for ($attempt = 0; $attempt -lt 20 -and -not $treeObserved; $attempt++) {
      Start-Sleep -Milliseconds 100
      $treeObserved = @(Get-UiaOwnedProcessDescendants @($treeRoot.Id)).Count -gt 0
    }
    if (-not $treeObserved) { throw "RED: UIA owned-process traversal missed a controlled child" }
    Stop-UiaOwnedProcessTrees @($treeRoot)
    if (-not $treeRoot.HasExited) {
      throw "RED: UIA owned-process teardown returned before the controlled root exited"
    }
  } finally {
    if ($treeRoot -and -not $treeRoot.HasExited) {
      Stop-UiaOwnedProcessTrees @($treeRoot)
    }
    Remove-Item -LiteralPath $treeFixturePath -Force -ErrorAction SilentlyContinue
  }
  $pidReuseAdopted = & {
    $rootCreated = [datetime]"2026-01-01T12:00:00"
    function Get-CimInstance {
      @(
        [pscustomobject]@{ ProcessId = 624; ParentProcessId = 7416; Name = "conhost.exe"; ExecutablePath = ""; CreationDate = $rootCreated }
        [pscustomobject]@{ ProcessId = 700; ParentProcessId = 624; Name = "child.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddSeconds(5) }
        [pscustomobject]@{ ProcessId = 636; ParentProcessId = 624; Name = "csrss.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddHours(-3) }
        [pscustomobject]@{ ProcessId = 732; ParentProcessId = 636; Name = "wininit.exe"; ExecutablePath = ""; CreationDate = $rootCreated.AddHours(-2) }
      )
    }
    @(Get-UiaOwnedProcessDescendants @(624) | ForEach-Object { $_.Name })
  }
  if (($pidReuseAdopted -join ",") -ne "child.exe") {
    throw "RED: UIA owned-process traversal adopts processes older than a reused parent PID: $($pidReuseAdopted -join ',')"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_ROOT_ACCESS' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'maxSandboxRootUtf16' -or
      $uiaLiveGateSource -notmatch 'Require \(\[GraphCodeUiaGateState\]::WindowIsVisible\(\$shellWindow\)\)') {
    throw "RED: UIA gate does not identify visible shell HWND, background root access, missing modal and short TEMP remedy"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIRECT' -or
      $uiaLiveGateSource -notmatch 'FromHandle\(\$nativeUpdateWindow\)' -or
      $uiaLiveGateSource -notmatch 'Wait-UiaOwnedSheetByContentClass \$process\.Id \$shellWindow' -or
      $uiaLiveGateSource -notmatch 'Get-UiaOwnedSheetIdentity \$updateDialog' -or
      $uiaLiveGateSource -notmatch '\[System\.Windows\.Automation\.AutomationElement\]::NameProperty, "An update is available\."' -or
      $uiaLiveGateSource -match '\[System\.Windows\.Automation\.AutomationElement\]::NameProperty, "GraphCode Update Available"') {
    throw "RED: UIA gate does not use and verify the shared owned update sheet when desktop-tree lookup omits it"
  }
  if ($uiaLiveGateSource -notmatch 'function Test-UpdateBannerClickTarget' -or
      $uiaLiveGateSource -notmatch '\$updateBanner\.Current\.BoundingRectangle' -or
      $uiaLiveGateSource -notmatch 'Test-UpdateBannerClickTarget \$updateBannerTarget \$process\.Id \$shellWindow' -or
      $uiaLiveGateSource -notmatch 'ScreenToClientPoint\(\s*\$shellWindow, \$updateBannerScreenX, \$updateBannerScreenY' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_BANNER_CLICK_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch 'Wait-UiaOwnedSheetGoneByContentClass \$process\.Id \$shellWindow "GraphCodeUpdateOffer"' -or
      $uiaLiveGateSource -notmatch '\$status\.Current\.Name -ceq "Update offer deferred"' -or
      $uiaLiveGateSource -notmatch 'RawView after update banner root' -or
      $uiaLiveGateSource -notmatch '\$projects = Find-FragmentById \$root "projects" \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$loops = Find-FragmentById \$root "loops" \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$graph = Find-FragmentById \$root "graph" \$rawWalker' -or
      $uiaLiveGateSource -match '\$updateBannerViewportBottom|\$updateBannerTop|\$updateBannerBottom') {
    throw "RED: UIA update-banner click does not use the owned published bounds and source-defined Later contract"
  }
  function Test-BoundedIngressSource([string] $source) {
    function Test-TextOrder([string] $text, [string[]] $needles) {
      $offset = 0
      foreach ($needle in $needles) {
        $next = $text.IndexOf($needle, $offset, [StringComparison]::Ordinal)
        if ($next -lt 0) { return $false }
        $offset = $next + $needle.Length
      }
      return $true
    }
    $sendCommand = [regex]::Match(
      $source,
      '(?s)public static bool SendCommand\(IntPtr window, uint command\)\s*\{(?<body>.*?)\n\s*\}'
    )
    $sendCommandBody = if ($sendCommand.Success) {
      ([regex]::Replace($sendCommand.Groups["body"].Value, '\s+', ' ')).Trim()
    } else { "" }
    $expectedSendCommand = "if (window == IntPtr.Zero) return false; UIntPtr result; " +
      "return SendMessageTimeout( window, 0x0111, (UIntPtr)command, IntPtr.Zero, " +
      "0x0001 | 0x0002, 5000, out result ) != IntPtr.Zero;"
    $ingressStart = $source.IndexOf('foreach ($ingress in @(')
    $ingressEnd = if ($ingressStart -ge 0) {
      $source.IndexOf('foreach ($nativeForm in @(', $ingressStart)
    } else { -1 }
    $ingressBody = if ($ingressStart -ge 0 -and $ingressEnd -gt $ingressStart) {
      $source.Substring($ingressStart, $ingressEnd - $ingressStart)
    } else { "" }
    return $sendCommand.Success -and
      $sendCommandBody -ceq $expectedSendCommand -and
      $ingressBody.Length -gt 0 -and
      (Test-TextOrder $ingressBody @(
        "action=submit-invalid phase=before",
        "[GraphCodeUiaGateState]::SendCommand(",
        "action=submit-invalid phase=after"
      )) -and
      (Test-TextOrder $ingressBody @(
        "action=validation-enumeration phase=before",
        '$validationContent = @(',
        ".FindAll(",
        "action=validation-enumeration phase=after"
      )) -and
      (Test-TextOrder $ingressBody @(
        "[GraphCodeUiaGateState]::PostClose(",
        "action=close-wait phase=before",
        "Wait-UiaOwnedSheetGoneByContentClass",
        "action=close-wait phase=after"
      ))
  }
  $deadCallMutant = $uiaLiveGateSource.Replace(
    "return SendMessageTimeout(",
    "if (false) return SendMessageTimeout("
  )
  $reorderedMarkerMutant = $uiaLiveGateSource.Replace(
    "action=submit-invalid phase=after",
    "action=submit-invalid phase=before"
  )
  if (-not (Test-BoundedIngressSource $uiaLiveGateSource) -or
      (Test-BoundedIngressSource $deadCallMutant) -or
      (Test-BoundedIngressSource $reorderedMarkerMutant)) {
    throw "RED: UIA ingress commands and scene transitions are not bounded and attributable"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$nativeFormWindow = Wait-UiaOwnedSheetByContentClass \$process\.Id \$shellWindow\s*`\s*[\r\n]+\s*"GraphCodeNativeForm" \$nativeForm\.Title' -or
      $uiaLiveGateSource -notmatch '(?s)Wait-UiaOwnedSheetGoneByContentClass \$process\.Id \$shellWindow\s*`\s*[\r\n]+\s*"GraphCodeNativeForm"') {
    throw "RED: UIA native-form checks still depend on desktop Window control discovery instead of the owned captionless sheet"
  }
  function Test-OwnedSheetRetrySource([string] $source) {
    $start = $source.IndexOf("function Wait-UiaOwnedSheetByContentClass(")
    $end = if ($start -ge 0) {
      $source.IndexOf("function Wait-UiaOwnedSheetGoneByContentClass(", $start)
    } else { -1 }
    if ($start -lt 0 -or $end -le $start) { return $false }
    $body = $source.Substring($start, $end - $start)
    $verifiedReturn = [regex]::Matches(
      $body,
      '(?s)if \(Test-MultiProjectOwnedSheetIdentity \$identity \$processId \$owner\s*`\s*[\r\n]+\s*\$expectedHostTitle \$contentClass\) \{\s*return \$element\s*\}'
    )
    return $verifiedReturn.Count -eq 1 -and
      ([regex]::Matches($body, 'return \$element').Count -eq 1) -and
      $body -match 'Get-UiaOwnedSheetIdentity \$element' -and
      $body -match 'UIA_OWNED_SHEET_RETRY' -and
      $body -match 'Start-Sleep -Milliseconds 50' -and
      $body -match '\$watch\.ElapsedMilliseconds -lt \$timeoutMilliseconds' -and
      $body -notmatch 'Assert-UiaOwnedSheet \$element'
  }
  $unconditionalOwnedSheetReturnMutant = [regex]::Replace(
    $uiaLiveGateSource,
    '(?s)if \(Test-MultiProjectOwnedSheetIdentity \$identity \$processId \$owner\s*`\s*[\r\n]+\s*\$expectedHostTitle \$contentClass\) \{\s*return \$element\s*\}',
    "if (Test-MultiProjectOwnedSheetIdentity `$identity `$processId `$owner ```r`n" +
      "    `$expectedHostTitle `$contentClass) { `$null = `$true }`r`n" +
      "return `$element",
    1
  )
  if (-not (Test-OwnedSheetRetrySource $uiaLiveGateSource) -or
      (Test-OwnedSheetRetrySource $unconditionalOwnedSheetReturnMutant)) {
    throw "RED: UIA owned-sheet acquisition throws on stale handles instead of retrying exact identity"
  }
  if ($uiaLiveGateSource -notmatch '(?s)function Wait-UiaOwnedSheetGoneByContentClass\(.*?\$sheetGone = \[GraphCodeUiaGateState\]::FindVisibleOwnedSheetByContentClass\(.*?if \(\$sheetGone -and \[GraphCodeUiaGateState\]::WindowIsEnabled\(\$owner\)\)') {
    throw "RED: UIA sheet-close waits return before modal teardown re-enables the owner"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$renameDialog = Wait-UiaOwnedSheetByContentClass \$process\.Id \$shellWindow\s*`\s*[\r\n]+\s*"GraphCodeWindowsDialogContent" \$fixtureRenameTitle' -or
      $uiaLiveGateSource -notmatch '(?s)Wait-UiaOwnedSheetGoneByContentClass \$process\.Id \$shellWindow\s*`\s*[\r\n]+\s*"GraphCodeWindowsDialogContent"') {
    throw "RED: UIA Rename checks still depend on desktop Window control discovery instead of the owned captionless prompt sheet"
  }
  function Test-DeleteLoopContextSource([string] $source) {
    $start = $source.IndexOf('$deleteLoopTitle =')
    $end = if ($start -ge 0) {
      $source.IndexOf('Require ([GraphCodeUiaGateState]::PostFixtureMutation($shellWindow, 21))', $start)
    } else { -1 }
    if ($start -lt 0 -or $end -le $start) { return $false }
    $block = ([regex]::Replace($source.Substring($start, $end - $start), '\s+', ' ')).Trim()
    if ($block -match 'SendCommand\(\$shellWindow,\s*5103\)') { return $false }
    $required = @(
      '$deleteTarget = Find-FragmentByIdWithRetry $root $renameGraphIdentity $rawWalker',
      '$deleteTargetSelection.Select()',
      'Require $deleteTargetSelection.Current.IsSelected',
      'UIA_DELETE_LOOP_TARGET',
      '[GraphCodeUiaGateState]::PostContextMenu($shellWindow, 3)',
      '$deleteLoopPopup = Wait-ForPopupMenu $process $shellWindow "Delete Loop"',
      '$deleteLoopItems = @(Get-PopupMenuItems $deleteLoopPopup)',
      '$_.Id -eq 5103 -and $_.Enabled',
      'Require ($null -ne $deleteLoopItem)',
      '$deleteLoopPopup, $shellWindow, [int]$deleteLoopItem.Position, [int]$deleteLoopItem.Id',
      'Require ($null -ne $deleteLoopClick)',
      'UIA_DELETE_LOOP_MENU',
      '"GraphCodeWindowsDialogContent" $deleteLoopTitle "Delete Loop custom sheet"',
      '[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 9808',
      'Wait-UiaOwnedSheetGoneByContentClass $process.Id $shellWindow ` "GraphCodeWindowsDialogContent") "Delete Loop custom sheet remained open after Cancel"'
    )
    $offset = 0
    foreach ($needle in $required) {
      $next = $block.IndexOf($needle, $offset, [StringComparison]::Ordinal)
      if ($next -lt 0) { return $false }
      $offset = $next + $needle.Length
    }
    return $true
  }
  $directDeleteMutant = $uiaLiveGateSource.Replace(
    '[GraphCodeUiaGateState]::PostContextMenu($shellWindow, 3)',
    '[GraphCodeUiaGateState]::SendCommand($shellWindow, 5103)'
  )
  $missingItemAssertionMutant = $uiaLiveGateSource.Replace(
    'Require ($null -ne $deleteLoopItem)',
    '$null = ($null -ne $deleteLoopItem)'
  )
  $wrongClickMutant = $uiaLiveGateSource.Replace(
    '$deleteLoopPopup, $shellWindow, [int]$deleteLoopItem.Position, [int]$deleteLoopItem.Id',
    '$deleteLoopPopup, $shellWindow, 0, 5103'
  )
  $wrongCancelMutant = $uiaLiveGateSource.Replace(
    '[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 9808',
    '[IntPtr]$deleteLoopDialog.Current.NativeWindowHandle, 7'
  )
  $missingTeardownMutant = $uiaLiveGateSource.Replace(
    'Wait-UiaOwnedSheetGoneByContentClass $process.Id $shellWindow',
    'Wait-UiaOwnedSheetGoneDisabled $process.Id $shellWindow'
  )
  if (-not (Test-DeleteLoopContextSource $uiaLiveGateSource) -or
      (Test-DeleteLoopContextSource $directDeleteMutant) -or
      (Test-DeleteLoopContextSource $missingItemAssertionMutant) -or
      (Test-DeleteLoopContextSource $wrongClickMutant) -or
      (Test-DeleteLoopContextSource $wrongCancelMutant) -or
      (Test-DeleteLoopContextSource $missingTeardownMutant)) {
    throw "RED: UIA Delete Loop invocation does not re-establish the stable fixture selection after Rename"
  }
  if ($uiaLiveGateSource -notmatch '(?s)function Wait-DaemonCommandLog\(.*?\[Diagnostics\.Stopwatch\]::StartNew\(\).*?\$watch\.ElapsedMilliseconds -lt \$timeoutMilliseconds.*?throw "\$label did not reach the daemon command log within' -or
      $uiaLiveGateSource -notmatch '(?s)\$renameCommandJson = Wait-DaemonCommandLog \$daemonCommandLogPath.*?"Rename submission"' -or
      $uiaLiveGateSource -notmatch '(?s)\$updateCommandJson = Wait-DaemonCommandLog \$daemonCommandLogPath.*?"Edit Details submission"' -or
      $uiaLiveGateSource -notmatch '(?s)\$renameLiveCommand = ConvertFrom-Json -InputObject \(Wait-DaemonCommandLog.*?"connected-daemon Rename submission"\)') {
    throw "RED: UIA Rename and Update evidence reads the daemon log before the asynchronous command is recorded"
  }
  if ($uiaLiveGateSource -match '\$(deleteLoopCondition|updateWindowCondition|nodeFormCondition|sidebarNodeFormCondition|templatePickerCondition|deleteLoopsCondition|deleteEdgeCondition|edgeDialogCondition|renameLiveCondition)\b' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeWindowsDialogContent"\s+\$deleteLoopTitle' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeNativeForm"\s+"Update node"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeNativeForm"\s+"Create or edit node"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeNativeForm"\s+"Choose a saved template"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeWindowsDialogContent"\s+"Delete All Loops"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeWindowsDialogContent"\s+"Delete Edge"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeNativeForm"\s+"Edit edge"' -or
      $uiaLiveGateSource -notmatch '(?s)"GraphCodeWindowsDialogContent"\s+\$renameLiveTitle') {
    throw "RED: migrated captionless sheets still use desktop Window discovery instead of owned content-class lookup"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_RENAME_DISPATCH' -or
      $uiaLiveGateSource -notmatch 'UIA_RENAME_INPUT' -or
      $uiaLiveGateSource -notmatch 'UIA_RENAME_OUTCOME' -or
      $uiaLiveGateSource -notmatch 'SetEditTextById' -or
      $uiaLiveGateSource -notmatch 'Native Title edit control \(id 9904\)' -or
      $uiaLiveGateSource -notmatch 'Goal summary edit control \(id 9100\)' -or
      $uiaLiveGateSource -notmatch 'Update node dialog did not open' -or
      $uiaLiveGateSource -notmatch 'Update node cancellation left the dialog open' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_NODE_SUBMIT_STATE' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_NODE_DISPATCH' -or
      $uiaLiveGateSource -notmatch 'UIA_DELETE_LOOP_SHEET_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch ([regex]::Escape('Delete “UIA loop A”?')) -or
      $uiaLiveGateSource -notmatch ([regex]::Escape("Its terminal session is ended and every edge touching it is removed. This can't be undone.")) -or
      $uiaLiveGateSource -notmatch 'cancelId = 9808' -or
      $uiaLiveGateSource -notmatch 'deleteId = 9800') {
    throw "RED: UIA gate does not verify dynamic Rename, custom Delete, or Edit Details sheet behavior"
  }
  if ($uiaLiveGateSource -match '"Rename Loop"' -or
      $uiaLiveGateSource -notmatch 'function Test-MultiProjectRenameTitle' -or
      $uiaLiveGateSource -notmatch 'function Get-MultiProjectRenameTitle' -or
      $uiaLiveGateSource -notmatch 'GraphCodeSheetHost' -or
      $uiaLiveGateSource -notmatch 'GraphCodeSheetViewport' -or
      $uiaLiveGateSource -notmatch 'function Test-MultiProjectOwnedSheetIdentity' -or
      $uiaLiveGateSource -notmatch 'IsCaptionlessSheet' -or
      $uiaLiveGateSource -notmatch 'WindowOwner' -or
      $uiaLiveGateSource -notmatch 'SheetContentClass') {
    throw "RED: shared sheet title/hierarchy/identity contracts are missing or retain the obsolete Rename Loop title"
  }
  if ($uiaLiveGateSource -match 'FindTopLevel\("GraphCode(UpdateOffer|ProductSettings)"' -or
      $uiaLiveGateSource -notmatch 'FindVisibleOwnedSheetByContentClass\(\s*\[uint32\]\$settingsProcess\.Id, \$settingsShellWindow, "GraphCodeProductSettings"\s*\)' -or
      $uiaLiveGateSource -notmatch 'Assert-UiaOwnedSheet \$nativeFormWindow \$process\.Id \$shellWindow \$nativeForm\.Title') {
    throw "RED: update, Product Settings, or native form discovery still assumes a migrated content class is top-level"
  }
  if ($uiaLiveGateSource -match '"GraphCode sheet"' -or
      $uiaLiveGateSource -notmatch '"GraphCodeUpdateOffer" "GraphCode Update Available"' -or
      $uiaLiveGateSource -notmatch '"GraphCodeRepositoryIngressDialog" \$ingress\.Title' -or
      $uiaLiveGateSource -notmatch '\$settingsShellWindow "GraphCode Settings" "GraphCodeProductSettings"') {
    throw "RED: migrated sheet identity checks do not retain exact surface-specific host titles"
  }
  if ($uiaLiveGateSource -notmatch 'SendMessageString\(edit, 0x000C' -or
      $uiaLiveGateSource -notmatch 'SendMessageText\(edit, 0x000D' -or
      $uiaLiveGateSource -match '(?s)SetEditTextById\(IntPtr parent, int controlId, string text\) \{[^}]*SetWindowText\(') {
    throw "RED: UIA gate writes or reads cross-process edit text through the window caption instead of WM_SETTEXT/WM_GETTEXT"
  }
  if ($uiaLiveGateSource -notmatch 'function Read-DaemonCommandLog' -or
      $uiaLiveGateSource -notmatch '\[IO\.FileShare\]::ReadWrite -bor \[IO\.FileShare\]::Delete' -or
      $uiaLiveGateSource -match 'ReadAllText\(\$daemonCommandLogPath\)') {
    throw "RED: UIA gate reads the daemon command log without tolerating the recorder's open write handle"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_DAEMON_MODEL' -or
      $uiaLiveGateSource -notmatch '-ApplyGraphCommands' -or
      $uiaLiveGateSource -notmatch 'Remove-Item Env:GRAPHCODE_UIA_CONNECTION_FAILURE' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION_CONFIRMED' -or
      $uiaLiveGateSource -notmatch 'UIA_CONNECTED_RENAME_PROPAGATION_UNCONFIRMED' -or
      $uiaLiveGateSource -notmatch 'rename stub daemon never applied the dispatched rename') {
    throw "RED: UIA gate never observes a rename result returned by a connected daemon"
  }
  # The connected-daemon graph-card/sidebar propagation outcome is intentionally
  # non-blocking (proven intermittent by repeated CI evidence; see
  # investigation/ui-parity-matrix.md, Node update/rename row): the gate must log
  # UIA_CONNECTED_RENAME_PROPAGATION_CONFIRMED or _UNCONFIRMED on every run
  # instead of throwing on a mismatch, so a known-flaky, unresolved render-path
  # gap never blocks CI while still surfacing honest evidence either way.
  if ($uiaLiveGateSource -match '(?s)Require \(\$renameLiveGraphTitle -eq \$renameFinalTitle\)' -or
      $uiaLiveGateSource -match '(?s)Require \(\$renameLiveSidebarTitle -eq \$renameFinalTitle\)') {
    throw "RED: UIA gate throws on the known-intermittent graph card/sidebar propagation outcome instead of logging it"
  }
  if ($uiaLiveGateSource -notmatch '\$env:GRAPHCODE_UIA_CONNECTION_FAILURE = "1"' -or
      $uiaLiveGateSource -notmatch '(?s)\$connectionFailureBannerEvidence = \[ordered\]@\{\s*name = \[string\]\$connectionAlert\.Current\.Name' -or
      $uiaLiveGateSource -notmatch 'Write-Host \("UIA_CONNECTION_FAILURE_BANNER_EVIDENCE="' -or
      $uiaLiveGateSource -notmatch 'connectionFailureBanner = \$connectionFailureBannerEvidence') {
    throw "RED: UIA gate no longer exercises the forced disconnected connection-failure path or reports the banner it observed"
  }
  $stubDaemonSource = Get-Content (Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1") -Raw
  if ($stubDaemonSource -notmatch '\[switch\] \$SeedMultiProjects' -or
      $stubDaemonSource -notmatch 'function New-MultiProjectPeer' -or
      $stubDaemonSource -notmatch 'function Invoke-MultiProjectRequest' -or
      $stubDaemonSource -notmatch 'function Invoke-MultiProjectPublicationControl' -or
      $uiaLiveGateSource -notmatch 'UIA_MULTIPROJECT_RENAME_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch 'function Get-MultiProjectAutomationId' -or
      $uiaLiveGateSource -notmatch '(?s)multiProjectRename = \$multiProjectRenameEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress') {
    throw "RED: N3e lacks opt-in independent owner/receipt/publication state and the simultaneous live multi-project rename evidence"
  }
  foreach ($required in @("Test-MultiProjectRenameReceipt", "Get-MultiProjectClippedRectangle", "ClickOwnedScreenRectangle",
      "PostOwnedScreenPoint", '[int] $maximumAttempts = 100', 'postedFallback = $postedFallback',
      'rightClickFallback = $rightClickFallback',
      "SetTextMessage", '$api.PSObject.Methods["SetText"]', "messageFallbacks",
      "LastFocusPostedFallback", "LastFocusControlFallback",
      "renameButtonFallback",
      "Wait-MultiProjectPeerSettled", 'Sketch-Field 9904 "rename stable immediately before submit"',
      'Invoke-MultiProjectTypeText 9904 $typedTitle $inputEvidence', 'source = "live-uia"', "beforeSelection", "afterSelection",
      "Windows unchanged-title rename was incorrectly treated as a no-op", "observedOwnerCount", "observedCardCount",
      "projectBounds", "sidebarBounds", "source-derived, not a UIA caption")) {
    if (-not $uiaLiveGateSource.Contains($required)) { throw "RED: multi-project live evidence lacks $required" }
  }
  if (-not $uiaLiveGateSource.Contains('$matches = Test-MultiProjectObservedSurface $surface $matches $workspaceProjection $selectedOwner $multiProcess.Id') -or
      $uiaLiveGateSource.Contains('if ($null -ne $loopBar) { $matches = $matches -and')) {
    throw "RED: workspace observation still accepts a project-only projection without mandatory owned loop-bar and toolbar proof"
  }
  foreach ($required in @('Test-MultiProjectObservedRoster $surface $fragmentProjection $owners $selectedOwner $multiProcess.Id',
      "totalObservedCardCount", "totalObservedProjectRowCount", "expectedMatchedOwners", "unexpectedCardIds", "unexpectedProjectIds",
      "foreignProjectFragmentCount", "static Graph destination is not an ordinary project row")) {
    if (-not $uiaLiveGateSource.Contains($required)) { throw "RED: unfiltered multi-project observer roster lacks $required" }
  }
  foreach ($required in @("Get-MultiProjectExpectedCanvasRoster", "Get-MultiProjectCaptionGeometry",
      "expectedNodeCardCount", "expectedProjectCaptionCount", "projectCaptionCount", "canvasFragmentClasses",
      "overview-project", "project-caption", "workspace navigation was not requested",
      'Get-MultiProjectCaptionGeometry $overview.canvasBounds $row.card.bounds (@($overview.canvasFragmentClasses | Where-Object { $_.classification -ceq "project-caption" -and $_.projectPath -ceq $owner.path })[0].bounds)')) {
    if (-not $uiaLiveGateSource.Contains($required)) { throw "RED: explicit complete overview taxonomy lacks $required" }
  }
  foreach ($required in @('$pixelWidth = $card[2] - $card[0]', '$pixelHeight = $card[3] - $card[1]',
      '$scaleSource = if ([Math]::Abs($pixelHeight - 96) -le 1)', '$pixelWidth / 250',
      '$normalizedHeight = $pixelHeight / $scale', '$heightTolerance = if ($scaleSource -ceq "card-width-rounded" -and $scale -lt 1)',
      '[Math]::Max(1, $pixelWidth - 1) + 0.01', 'scaleSource = $scaleSource',
      'normalizedHeight = $normalizedHeight', 'heightTolerance = $heightTolerance')) {
    if (-not $uiaLiveGateSource.Contains($required)) {
      throw "RED: multi-project fitted card geometry lacks denominator-derived rounding budget: $required"
    }
  }
  $metadataObserverAst = [Management.Automation.Language.Parser]::ParseInput($uiaLiveGateSource,[ref]$null,[ref]$null)
  $metadataObserver = $metadataObserverAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq "Get-MultiProjectObservation"
  },$true)
  if (-not $metadataObserver -or $metadataObserver.Extent.Text.Contains(".StartsWith(") -or
      -not $metadataObserver.Extent.Text.Contains("Test-MultiProjectMetadataBatch") -or
      -not $metadataObserver.Extent.Text.Contains("unresolvedMetadataCount") -or
      -not $metadataObserver.Extent.Text.Contains("Test-MultiProjectOwnerSelection `$surface `$owner `$selectedOwner `$projectSelected `$loopSelected") -or
      $metadataObserver.Extent.Text.Contains("`$projectSelected -eq `$selected") -or
      -not $uiaLiveGateSource.Contains("UIA_MULTIPROJECT_METADATA_REACQUIRE=")) {
    throw "RED: new observer prefix/typed metadata/active-surface selection boundary remains unguarded or silently omitted"
  }
  foreach ($required in @("function Complete-MultiProjectCapture", "function Wait-MultiProjectCapture",
      "function Initialize-MultiProjectProcessJob", "StandaloneProcessJob", "rootStartUtcTicks", "targetStartUtcTicks",
      'if (-not $capture.rootProcess.WaitForExit($remaining))', "MULTIPROJECT_CAPTURE_DRAIN", "MULTIPROJECT_CAPTURE_TEARDOWN=",
      "MultiProjectTeardown:", "WaitAll", "ownedJobEmpty", '$null = Complete-MultiProjectCapture $child $logDirectory 5000 $primaryError')) {
    if (-not $uiaLiveGateSource.Contains($required)) { throw "RED: bounded multi-project capture lacks $required" }
  }
  Assert-MultiProjectFreshCaptureContract $uiaLiveGateSource
  Assert-MultiProjectPeerEmissionContract $uiaLiveGateSource
  Assert-MultiProjectRenameSubmitContract $uiaLiveGateSource `
    ([IO.File]::ReadAllText((Join-Path $repoRoot "graphcode-windows\src\WindowsNativeDialogs.zig"))) `
    ([IO.File]::ReadAllText((Join-Path $repoRoot "graphcode-windows\src\NativeForms.zig")))
  Test-MultiProjectProtocolContracts $stubDaemonSource $uiaLiveGateSource `
    (Join-Path $repoRoot "Tools\windows\Stub-Daemon.ps1") $pwsh
  if ($stubDaemonSource -notmatch '\$ApplyGraphCommands' -or
      $stubDaemonSource -notmatch '\$frame\.command\.graphCommand\.command\.renameNode' -or
      $stubDaemonSource -notmatch 'appliedRenames' -or
      $stubDaemonSource -notmatch 'function New-StubGraphEvent') {
    throw "RED: stub daemon cannot apply a renameNode command and republish its graph"
  }
  if ($uiaLiveGateSource -notmatch 'function Wait-UiaOwnedSheetByContentClass' -or
      $uiaLiveGateSource -notmatch 'function Wait-UiaOwnedSheetGoneByContentClass' -or
      $uiaLiveGateSource -notmatch 'GraphCodeRepositoryIngressDialog' -or
      $uiaLiveGateSource -match '(?s)\$ingressDialog = Wait-ForDesktopElement.*?\$ingress\.Title') {
    throw "RED: migrated standalone dialogs are not discovered by exact owner/PID/direct content class"
  }
  if ($uiaLiveGateSource -notmatch 'LastActivationDiagnostic' -or
      $uiaLiveGateSource -notmatch 'SetForegroundWindow\(window\).*?Marshal.GetLastWin32Error\(\)' -or
      $uiaLiveGateSource -notmatch 'AttachThreadInput\(currentThread, targetThread, true\).*?Marshal.GetLastWin32Error\(\)') {
    throw "RED: UIA foreground failure hides native return values and last-error diagnostics"
  }
  if ($uiaLiveGateSource -notmatch 'AttachThreadInput' -or
  $uiaLiveGateSource -notmatch 'keybd_event\(0x12, 0, 0, UIntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch 'SetActiveWindow\(window\)' -or
  $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x0101, \(UIntPtr\)key, IntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch '\[DllImport\("kernel32\.dll"\)\]\s*private static extern uint GetCurrentThreadId' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOCUS_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch '(?s)function Hide-TestProviderZmxWindows.*?\[string\]\$_\.ExecutablePath\)\s+-eq\s+\$providerZmx.*?HideProcessWindows.*?HideWindow\(\$foreground\)' -or
      $uiaLiveGateSource -notmatch 'function Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Test-FocusedElementIdentity \$candidate \$element \$expectedAutomationId' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch '\$element\.SetFocus\(\)' -or
      $uiaLiveGateSource -notmatch 'Retain-FocusWithRetry \$shellWindow \$safeFocusRow \$safeRowId "before-retention"' -or
      $uiaLiveGateSource -notmatch '\$backendFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings backend control could not retain foreground focus' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(\[GraphCodeUiaGateState\]::IsForegroundWindow\(\$settingsWindow\)\).*?Product Settings window lost foreground ownership before accepting backend focus') {
    throw "RED: UIA live gate does not prove foreground ownership before accepting row focus"
  }
  function Test-ImmediateProductSettingsSource([string] $source) {
    $start = $source.IndexOf('$backendFocus = Retain-FocusWithRetry')
    $end = if ($start -ge 0) {
      $source.IndexOf('Require ([GraphCodeUiaGateState]::PostCommand($settingsShellWindow, 0x5002))', $start)
    } else { -1 }
    if ($start -lt 0 -or $end -le $start) { return $false }
    $block = ([regex]::Replace($source.Substring($start, $end - $start), '\s+', ' ')).Trim()
    $required = @(
      '$backendFocus = Retain-FocusWithRetry',
      'Require ($null -ne $backendFocus.Focused)',
      'Require ([GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow))',
      'Product Settings window lost foreground ownership before accepting backend focus',
      'PostKeyboard( [IntPtr]$backendButton.Current.NativeWindowHandle, 0x0D',
      'Require ($remainingSettings -eq $settingsHandle)',
      '$savedSettings.defaultBackend -eq "copilotCLI"',
      '$savedSettings.gateSentinel -eq "preserve"',
      '$savedSettingsBytes = [IO.File]::ReadAllBytes($settingsPath)',
      'PostKeyboard( [IntPtr]$backendButton.Current.NativeWindowHandle, 0x1B',
      'Wait-UiaOwnedSheetGoneByContentClass $settingsProcess.Id $settingsShellWindow',
      '"GraphCodeProductSettings"',
      '[Convert]::ToBase64String($savedSettingsBytes)',
      'Escape changed already-persisted Product Settings'
    )
    $offset = 0
    foreach ($needle in $required) {
      $next = $block.IndexOf($needle, $offset, [StringComparison]::Ordinal)
      if ($next -lt 0) { return $false }
      $offset = $next + $needle.Length
    }
    return $true
  }
  $missingForegroundMutant = $uiaLiveGateSource.Replace(
    'Require ([GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow))',
    '$null = [GraphCodeUiaGateState]::IsForegroundWindow($settingsWindow)'
  )
  $closingReturnMutant = $uiaLiveGateSource.Replace(
    'Require ($remainingSettings -eq $settingsHandle)',
    '$null = ($remainingSettings -eq $settingsHandle)'
  )
  if (-not (Test-ImmediateProductSettingsSource $uiaLiveGateSource) -or
      (Test-ImmediateProductSettingsSource $missingForegroundMutant) -or
      (Test-ImmediateProductSettingsSource $closingReturnMutant)) {
    throw "RED: UIA live gate does not prove immediate Product Settings persistence, foreground focus, Return retention, and Escape close"
  }
  if ($uiaLiveGateSource -notmatch 'function Wait-ForDesktopElement' -or
      $uiaLiveGateSource -notmatch 'function Wait-ForDesktopElementGone' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'empty global New Loop node form' -or
      $uiaLiveGateSource -notmatch 'empty project New Loop node form' -or
      $uiaLiveGateSource -notmatch 'project-row New Loop node form' -or
      $uiaLiveGateSource -notmatch 'Open Folder picker close') {
    throw "RED: UIA live gate does not wait deterministically for asynchronous modal windows"
  }
  if ($uiaLiveGateSource -match '(?s)New Loop command was rejected.*?for \(\$index = 0; \$index -lt 40 -and \$null -eq \$.*NodeForm' -or
      $uiaLiveGateSource -match '(?s)Open Folder command was rejected.*?Start-Sleep -Milliseconds 200\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)') {
    throw "RED: UIA live gate reintroduced short fixed polling around New Loop modal commands"
  }
  if ($uiaLiveGateSource -notmatch 'function Ensure-ShellForeground' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)\s*[\r\n]+\s*\$acquired = \$activated -and \[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOREGROUND_DIAGNOSTICS phase=\$label \$\(Get-FocusDiagnostics \$window\)' -or
      $uiaLiveGateSource -notmatch '(?s)function Ensure-ShellForeground\(.*?if \(\[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)\) \{\s*[\r\n]+\s*return \$true\s*[\r\n]+\s*\}') {
    throw "RED: UIA live gate does not reacquire GraphCode shell foreground within a bounded deadline before command paths, or performs the invasive Alt-tap activation even when already foreground"
  }
  if ($uiaLiveGateSource -notmatch '(?s)function Wait-ForDesktopElement\(.*?\[switch\] \$RecoverForeground.*?\$remainingMilliseconds = \[Math\]::Max\(.*?\$recoveryTimeout = \[Math\]::Min\(1000, \$remainingMilliseconds\).*?UIA_WAIT_FOREGROUND_RECOVERY label=\$label.*?Ensure-ShellForeground.*?-TimeoutMilliseconds \$recoveryTimeout' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS label=\$label foregroundRecoveries=\$foregroundRecoveries') {
    throw "RED: UIA modal waits do not boundedly reacquire foreground after a post-command foreground loss"
  }
  if ($uiaLiveGateSource -notmatch '(?s)Require \(\$null -ne \$projectNewLoop\) "project row omitted New Loop"\s*[\r\n]+\s*Require \(Ensure-ShellForeground \$shellWindow "project-row New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before invoking project-row New Loop"\s*[\r\n]+\s*\$projectNewLoop\.GetCurrentPattern' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty global New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty global New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty global New Loop command was rejected"' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty project New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty project New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty project New Loop command was rejected"') {
    throw "RED: UIA live gate New Loop invocation is not preceded by verified foreground recovery at every site"
  }
  $shellTests = Get-Content (Join-Path $PSScriptRoot "WindowsShell.Tests.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'function Wait-ForPopupMenu' -or
      $uiaLiveGateSource -notmatch 'function Get-PopupMenuItems' -or
      $uiaLiveGateSource -notmatch 'function Close-PopupMenu' -or
      $uiaLiveGateSource -notmatch 'FindPopupMenuWindow' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(popup, 0x01E1, UIntPtr\.Zero, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x802C, \(UIntPtr\)target, IntPtr\.Zero\)') {
    throw "RED: UIA live gate cannot open, read, or dismiss a native TrackPopupMenu popup"
  }
  if ($uiaLiveGateSource -notmatch '\$moveProjectMenuText = "Move Project\.\.\. \(unavailable: daemon support required\)"' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 1\).*?Wait-ForPopupMenu \$process \$shellWindow "project"' -or
      $uiaLiveGateSource -notmatch 'Require \(-not \$moveProjectItem\.Enabled\)' -or
      $uiaLiveGateSource -notmatch '\$moveProjectItem\.Text -eq \$moveProjectMenuText' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 2\).*?\$_\.Id -in @\(5149, 5151, 5144\)' -or
      $uiaLiveGateSource -notmatch 'project context menu did not dismiss, leaving the shell blocked in its modal loop') {
    throw "RED: UIA live gate does not assert the live project context menu's disabled Move item and deterministic dismissal"
  }
  if ($shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\GraphContextMenu\.zig' -or
      $shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\MainWindow\.zig') {
    throw "RED: Windows shell validation does not run the context menu and gate fixture message tests"
  }
  $appSource = Get-Content (Join-Path $repoRoot "graphcode-windows\src\App.zig") -Raw
  if ($appSource -notmatch 'fn showUiaContextMenu' -or
      $appSource -notmatch 'MainWindow\.wm_uia_context_menu => \{' -or
      $appSource -notmatch '(?s)wparam == MainWindow\.menu_watchdog_timer_id.*?c\.EndMenu\(\)') {
    throw "RED: the shell cannot open a gate-requested context menu, or an abandoned popup can block its message loop forever"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_CANVAS_CONTEXT_MENU_EVIDENCE' -or
      $uiaLiveGateSource -notmatch '\$canvasContextMenuEvidence' -or
      $uiaLiveGateSource -notmatch 'canvasContextMenu = \$canvasContextMenuEvidence' -or
      $uiaLiveGateSource -notmatch '"canvas background"' -or
      $uiaLiveGateSource -notmatch '"canvas node"' -or
      $uiaLiveGateSource -notmatch '"canvas edge"' -or
      $uiaLiveGateSource -notmatch '(?s)Find-FragmentByIdWithRetry \$root "actual-size" \$rawWalker.*?\.Invoke\(\).*?\$graph = Find-FragmentByIdWithRetry \$root "graph" \$rawWalker.*?\$canvasContextCards' -or
      $uiaLiveGateSource -notmatch 'canvas \$\(\$probe\.Label\) context menu point .*? is outside live graph bounds' -or
      $uiaLiveGateSource -notmatch 'BoundingRectangle' -or
      $uiaLiveGateSource -notmatch 'PostRightClickAt\(\$ownerWindow' -or
      $uiaLiveGateSource -notmatch 'PostRightClickAt\(\$shellWindow' -or
      $uiaLiveGateSource -notmatch 'PopupMenuItemState' -or
      $uiaLiveGateSource -notmatch 'Checked\s+=\s+\(\(\$state -band 0x8\) -ne 0\)' -or
      $uiaLiveGateSource -notmatch 'function ConvertTo-PopupMenuEvidence' -or
      $uiaLiveGateSource -notmatch 'checked = \$_.Checked' -or
      $uiaLiveGateSource -notmatch 'state = \$_.State' -or
      $uiaLiveGateSource -notmatch 'Close-PopupMenu' -or
      $uiaLiveGateSource -notmatch 'GetMenuItemRect' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch 'SetCursorPos' -or
      $uiaLiveGateSource -notmatch 'GetCursorPos' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(popup, 0x0200, UIntPtr\.Zero, MouseLParam\(point\.X, point\.Y\)\)' -or
      $uiaLiveGateSource -notmatch '(?s)private static extern void Sleep\(uint milliseconds\).*?for \(int attempt = 0; attempt < 50 && !hilite; attempt\+\+\).*?GetMenuState\(menu, \(uint\)position, 0x0400\).*?Sleep\(10\).*?if \(!hilite\).*?throw new InvalidOperationException' -or
      $uiaLiveGateSource -notmatch 'public bool Hilite, UsedKeyboardFallback' -or
      $uiaLiveGateSource -notmatch 'UsedSelectItemFallback' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(popup, 0x01E5, \(UIntPtr\)position, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch '(?s)SendInput\(\(uint\)inputs\.Length.*?for \(int attempt = 0; attempt < 20 && IsWindowVisible\(popup\); attempt\+\+\).*?PostMessage\(popup, 0x0100, \(UIntPtr\)0x0D, IntPtr\.Zero\).*?PostMessage\(popup, 0x0101, \(UIntPtr\)0x0D, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'SendInput' -or
      $uiaLiveGateSource -notmatch 'cursorBefore = @\(\$editEdgeClick\.CursorBeforeX' -or
      $uiaLiveGateSource -notmatch 'hilite = \$editEdgeClick\.Hilite' -or
      $uiaLiveGateSource -notmatch 'keyboardFallback = \$editEdgeClick\.UsedKeyboardFallback' -or
      $uiaLiveGateSource -notmatch 'directCommandFallback = \$editEdgeDirectCommandFallback' -or
      $uiaLiveGateSource -notmatch 'actionPopupClosed = \$edgePopupClosed' -or
      $uiaLiveGateSource -notmatch 'UIA_CANVAS_EDGE_ACTION_CLICK_EVIDENCE' -or
      $uiaLiveGateSource -notmatch 'actionClick = \$editEdgeClickEvidence' -or
      $uiaLiveGateSource -notmatch '(?s)Wait-UiaOwnedSheetByContentClass \$process\.Id \$shellWindow\s*`\s*[\r\n]+\s*"GraphCodeNativeForm" "Edit edge"' -or
      $uiaLiveGateSource -notmatch 'Create or edit edge' -or
      $uiaLiveGateSource -notmatch 'editActionDialogOpened = \$canvasEdgeEditDialogOpened' -or
      $uiaLiveGateSource -notmatch 'daemonCommandUnchanged = \$canvasEdgeDaemonCommandUnchanged' -or
      $uiaLiveGateSource -notmatch 'UIA loop A|UIA loop B') {
    throw "RED: UIA live gate does not measure blank-canvas, node-card, and edge context menus from live geometry"
  }
  if ($uiaLiveGateSource -notmatch '(?s)canvasContextMenu = \$canvasContextMenuEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress') {
    throw "RED: UIA final summary loses nested canvas menu items and edge action measurements"
  }
  # Enter with no hilited item ends TrackPopupMenu with command 0, so a closed
  # popup is not proof of selection; the Enter fallback must re-select and
  # prove the intended item's hilite first.
  if ($uiaLiveGateSource -notmatch '(?s)for \(int attempt = 0; attempt < 20 && IsWindowVisible\(popup\); attempt\+\+\) Sleep\(10\);.*?hiliteAtEnterFallback = \(GetMenuState\(menu, \(uint\)position, 0x0400\) & 0x0080\) != 0;\s*SendMessage\(popup, 0x01E5, \(UIntPtr\)position, IntPtr\.Zero\);\s*hiliteBeforeEnter = \(GetMenuState\(menu, \(uint\)position, 0x0400\) & 0x0080\) != 0;.*?if \(!hiliteBeforeEnter\)\s*throw new InvalidOperationException.*?PostMessage\(popup, 0x0100, \(UIntPtr\)0x0D, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'public bool HiliteAtEnterFallback, HiliteBeforeEnter;' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_MENU_CLICK command=\$command .*?hiliteBeforeEnter=\$\(\$click\.HiliteBeforeEnter\)' -or
      $uiaLiveGateSource -notmatch 'UIA_SKETCH_MENU_CLICK command=\$id .*?hiliteBeforeEnter=\$\(\$click\.HiliteBeforeEnter\)') {
    throw "RED: UIA popup Enter fallback can close the menu without choosing the intended item"
  }
  if ($uiaLiveGateSource -notmatch 'function Write-UiaWaitAttribution' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_TIMEOUT_ATTRIBUTION=' -or
      $uiaLiveGateSource -notmatch 'PrintWindow\(\$window, \$hdc, 2\)' -or
      $uiaLiveGateSource -notmatch '(?s)function Get-FocusDiagnostics.*?\$foregroundTitle = if \(\$expectedProcessId -ne 0 -and \$foregroundProcessId -eq \$expectedProcessId\)' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "popup menu: \$label"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "desktop element: \$label"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "desktop element gone: \$label"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "foreground: \$label"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "edge modal: \$title"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "sketch/custody modal: \$title"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "multi-project observation: \$surface"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaWaitAttribution "gate failure: \$failureStep"' -or
      $uiaLiveGateSource -notmatch 'Write-UiaLateEventAttribution "ElementSelected after Select"') {
    throw "RED: UIA wait timeouts are not attributed to step, deadline, foreground owner, shell windows, and a shell-only capture"
  }
  if ($stubDaemonSource -notmatch '\$frame\.command\.graphCommand\.command\.createNode\._0' -or
      $stubDaemonSource -notmatch 'appliedCreates' -or
      $stubDaemonSource -notmatch '\$nodeLoopTypes\[\$id\]' -or
      $stubDaemonSource -notmatch '(?s)function Get-StubResultWriteWin32Error.*?if \(\$current -is \[IO\.IOException\]\).*?\$current\.HResult -band 0xFFFF.*?if \(\$nativeCode -in @\(32, 33\)\).*?return 0' -or
      $stubDaemonSource -notmatch '(?s)function Write-StubResultFile.*?for \(\$attempt = 0; \$attempt -lt 40; \$attempt\+\+\).*?Set-Content -LiteralPath \$path -Value \$json -NoNewline -ErrorAction Stop.*?catch \[IO\.IOException\].*?\$nativeCode = Get-StubResultWriteWin32Error \$exception.*?if \(\$nativeCode -notin @\(32, 33\)\).*?STUB_RESULT_WRITE_FAILURE.*?throw.*?STUB_RESULT_WRITE_EXHAUSTED.*?STUB_RESULT_WRITE_RETRY.*?Start-Sleep -Milliseconds 25' -or
      $stubDaemonSource -notmatch '\$null = Write-StubResultFile \$ResultPath \$json' -or
      $stubDaemonSource -notmatch 'if \(\$renameApplied -or \$createApplied -or \$edgeApplied(?: -or \$promotionApplied)?\)') {
    throw "RED: stub daemon cannot apply exactly the createNode it received and republish the created loop type"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_SHEET_EVIDENCE' -or
      $uiaLiveGateSource -notmatch '\$nodeCreationSheetEvidence = \[ordered\]@\{' -or
      $uiaLiveGateSource -notmatch 'ClickScreenPoint' -or
      $uiaLiveGateSource -notmatch 'VisibleChildIds\(' -or
      $uiaLiveGateSource -notmatch '9600 \+ \$tileIndex' -or
      $uiaLiveGateSource -notmatch 'Say what done looks like and use positive timing values\.' -or
      $uiaLiveGateSource -notmatch 'Say what to do each time to continue\.' -or
      $uiaLiveGateSource -notmatch 'commandLogUnchanged = ' -or
      $uiaLiveGateSource -notmatch 'reasonClearedOnTypeChange = ' -or
      $uiaLiveGateSource -notmatch 'SendKeyInput\(' -or
      $uiaLiveGateSource -notmatch 'ComboSelection\(' -or
      $uiaLiveGateSource -notmatch '\$wireNode\s*=\s*\$nodeSheetDispatchedCommand\.command\.createNode\._0' -or
      $uiaLiveGateSource -notmatch 'node creation dispatched modelTier' -or
      $uiaLiveGateSource -notmatch 'appliedCreates' -or
      $uiaLiveGateSource -match 'Test-NodeCreationLogHasCreate' -or
      $uiaLiveGateSource -match '(?s)for \(\$index = 0; \$index -lt 100 -and \$null -eq \$nodeSheetDispatchedCommand; \$index\+\+\).*?Start-Sleep -Milliseconds 50' -or
      $uiaLiveGateSource -notmatch '\$nodeSheetReceivedCommands\s*=\s*@\(\$nodeSheetStubAfter\.receivedGraphCommands\s*\|\s*Where-Object' -or
      $uiaLiveGateSource -notmatch '\$nodeSheetReceivedCommands\.Count -eq 1' -or
      $uiaLiveGateSource -notmatch '\$nodeSheetReceivedCommands\[0\]\.command\s*\|\s*ConvertFrom-Json' -or
      $uiaLiveGateSource -notmatch '\[double\]\$wireNode\.heartbeatIntervalSeconds -eq \$expectedHeartbeatIntervalSeconds' -or
      $uiaLiveGateSource -notmatch '(?s)UIA_NODE_CREATION_SHEET_EVIDENCE=.*?\$postCreateWorkspaceId = Get-MultiProjectAutomationId "workspace-loop-bar" \$createdNodeId.*?\$postCreateWorkspace = Wait-ForGraphChildren \$renameRoot \$rawWalker.*?\^workspace-\(loop-bar\|show-graph\)-.*?AutomationId -ceq \$postCreateWorkspaceId.*?Selected loop workspace.*?\^workspace-show-graph-.*?Show in Graph.*?\$postCreateShowGraph = @\(.*?workspace-show-graph-.*?Show in Graph.*?GetCurrentPattern\(\[System\.Windows\.Automation\.InvokePattern\]::Pattern\)\.Invoke\(\).*?\$postCreateOverview = Wait-ForGraphChildren \$renameRoot \$rawWalker.*?\^workspace-\(loop-bar\|show-graph\)-.*?Count -eq 0.*?\^canvas-card-.*?Count -gt 0.*?New Loop exact-ID workspace did not settle on an active graph before sketch/custody.*?# --- Connected sketch promotion and custody child' -or
      $uiaLiveGateSource -notmatch 'afterTileClick = ' -or
      $uiaLiveGateSource -notmatch 'afterEdit = ' -or
      $uiaLiveGateSource -notmatch 'renderedSidebarCount -gt 0' -or
      $uiaLiveGateSource -notmatch 'renderedCardCount -gt 0') {
    throw "RED: UIA live gate does not drive the node creation sheet through conditional fields, rejected input, and a daemon-rendered create"
  }
  $retainedNodeHistory = @(
    [pscustomobject]@{
      requestID = "create-request"
      command = '{"projectPath":"graphcode://stub/project","command":{"createNode":{"_0":{"id":"11111111-1111-4111-8111-111111111111","title":"UIA created timed loop","loopType":"timeBased","triggerPrompt":"Summarize new commits","heartbeatIntervalSeconds":3600,"backend":"copilotCLI","modelTier":"capable"}}}}'
    },
    [pscustomobject]@{
      requestID = "outcome-request"
      command = '{"projectPath":"graphcode://stub/project","command":{"openNode":{"_0":"11111111-1111-4111-8111-111111111111"}}}'
    }
  )
  $retainedCreate = @($retainedNodeHistory | Where-Object { $_.requestID -ceq "create-request" })
  $retainedCreateCommand = $retainedCreate[0].command | ConvertFrom-Json
  $retainedCreateNode = $retainedCreateCommand.command.createNode._0
  if ($retainedCreate.Count -ne 1 -or
      [string]$retainedCreateCommand.projectPath -cne "graphcode://stub/project" -or
      [string]$retainedCreateNode.triggerPrompt -cne "Summarize new commits" -or
      [double]$retainedCreateNode.heartbeatIntervalSeconds -ne 3600) {
    throw "RED: retained New Loop request history cannot select the create after a later outcome command"
  }
  $firstCustodyOpen = $uiaLiveGateSource.IndexOf(
    '$custodyMenuClick = Sketch-ClickMenu $custodyParent 5119',
    [StringComparison]::Ordinal)
  $firstCustodyCancel = $uiaLiveGateSource.IndexOf(
    '$custodyCancel = Sketch-Cancel "New Child"',
    [Math]::Max(0, $firstCustodyOpen), [StringComparison]::Ordinal)
  $secondCustodyOpen = $uiaLiveGateSource.IndexOf(
    '$custodyParent = Open-SketchNodeMenu $renameFinalTitle',
    [Math]::Max(0, $firstCustodyCancel + 1), [StringComparison]::Ordinal)
  $custodyTurnSelection = $uiaLiveGateSource.IndexOf(
    '$custodyTurnTile = Assert-SketchControl 9600',
    [StringComparison]::Ordinal)
  $custodyInstructionType = $uiaLiveGateSource.IndexOf(
    'Sketch-Type 9104 $custodyFirstInstruction',
    [Math]::Max(0, $custodyTurnSelection), [StringComparison]::Ordinal)
  $custodyBackendChange = $uiaLiveGateSource.IndexOf(
    '$null = Sketch-Combo 9112 1 "Claude Code"',
    [Math]::Max(0, $custodyInstructionType), [StringComparison]::Ordinal)
  $custodyInstructionReadback = $uiaLiveGateSource.IndexOf(
    '$custodyInstructionAfterBackend = Sketch-Field 9104',
    [Math]::Max(0, $custodyBackendChange), [StringComparison]::Ordinal)
  $custodyCountIndex = $uiaLiveGateSource.IndexOf(
    '(Edge-GraphCount $custodyAfter) -eq (Edge-GraphCount $custodyBefore) + 2',
    [Math]::Max(0, $custodyInstructionReadback), [StringComparison]::Ordinal)
  $custodyNewCommandsIndex = $uiaLiveGateSource.IndexOf(
    '$custodyNewCommands = @($custodyAfter.receivedGraphCommands |',
    [Math]::Max(0, $custodyCountIndex), [StringComparison]::Ordinal)
  $custodyExpectedOutcomeIndex = $uiaLiveGateSource.IndexOf(
    '$custodyExpectedOutcome = [ordered]@{',
    [Math]::Max(0, $custodyNewCommandsIndex), [StringComparison]::Ordinal)
  $custodyOutcomeSelectionIndex = $uiaLiveGateSource.IndexOf(
    '$custodyOutcomes = @($custodyNewCommands | Where-Object {',
    [Math]::Max(0, $custodyExpectedOutcomeIndex), [StringComparison]::Ordinal)
  $custodyOutcomeRequireIndex = $uiaLiveGateSource.IndexOf(
    '[string]$custodyOutcomes[0].requestID -cne $custodyRequest -and',
    [Math]::Max(0, $custodyOutcomeSelectionIndex), [StringComparison]::Ordinal)
  $custodyOutcomeAnsweredIndex = $uiaLiveGateSource.IndexOf(
    '@($custodyAfter.unansweredRequests) -notcontains [string]$custodyOutcomes[0].requestID -and',
    [Math]::Max(0, $custodyOutcomeRequireIndex), [StringComparison]::Ordinal)
  $custodyRenderWaitIndex = $uiaLiveGateSource.IndexOf(
    '$custodyRenderWait = Wait-SketchGraphCard',
    [Math]::Max(0, $custodyOutcomeAnsweredIndex), [StringComparison]::Ordinal)
  $custodyWorkspaceIdIndex = $uiaLiveGateSource.IndexOf(
    '$custodyWorkspaceId = Get-MultiProjectAutomationId "workspace-loop-bar" $custodyId',
    [Math]::Max(0, $custodyRenderWaitIndex), [StringComparison]::Ordinal)
  $custodyWorkspaceWaitIndex = $uiaLiveGateSource.IndexOf(
    '$custodyWorkspace = Wait-ForGraphChildren $renameRoot $rawWalker',
    [Math]::Max(0, $custodyWorkspaceIdIndex), [StringComparison]::Ordinal)
  $custodyShowGraphInvokeIndex = $uiaLiveGateSource.IndexOf(
    '$custodyShowGraph.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()',
    [Math]::Max(0, $custodyWorkspaceWaitIndex), [StringComparison]::Ordinal)
  $custodyGraphReturnIndex = $uiaLiveGateSource.IndexOf(
    '$custodyGraphReturn = Wait-ForGraphChildren $renameRoot $rawWalker',
    [Math]::Max(0, $custodyShowGraphInvokeIndex), [StringComparison]::Ordinal)
  $custodyFinalMenuIndex = $uiaLiveGateSource.IndexOf(
    '$custodyRendered = Open-SketchNodeMenu "UIA custody child"',
    [Math]::Max(0, $custodyGraphReturnIndex), [StringComparison]::Ordinal)
  if ($firstCustodyOpen -lt 0 -or $firstCustodyCancel -le $firstCustodyOpen -or
      $secondCustodyOpen -le $firstCustodyCancel -or
      $custodyTurnSelection -le $secondCustodyOpen -or
      $custodyInstructionType -le $custodyTurnSelection -or
      $custodyBackendChange -le $custodyInstructionType -or
      $custodyInstructionReadback -le $custodyBackendChange -or
      $custodyCountIndex -le $custodyInstructionReadback -or
      $custodyNewCommandsIndex -le $custodyCountIndex -or
      $custodyExpectedOutcomeIndex -le $custodyNewCommandsIndex -or
      $custodyOutcomeSelectionIndex -le $custodyExpectedOutcomeIndex -or
      $custodyOutcomeRequireIndex -le $custodyOutcomeSelectionIndex -or
      $custodyOutcomeAnsweredIndex -le $custodyOutcomeRequireIndex -or
      $custodyRenderWaitIndex -le $custodyOutcomeAnsweredIndex -or
      $custodyWorkspaceIdIndex -le $custodyRenderWaitIndex -or
      $custodyWorkspaceWaitIndex -le $custodyWorkspaceIdIndex -or
      $custodyShowGraphInvokeIndex -le $custodyWorkspaceWaitIndex -or
      $custodyGraphReturnIndex -le $custodyShowGraphInvokeIndex -or
      $custodyFinalMenuIndex -le $custodyGraphReturnIndex -or
      $uiaLiveGateSource.IndexOf(
        '$custodyTurnTile = Assert-SketchControl 9600',
        $custodyTurnSelection + 1, [StringComparison]::Ordinal) -ge 0) {
    throw "RED: custody reopened path must select Turn once, type instruction, change backend and prove unchanged instruction"
  }
  if ($uiaLiveGateSource -notmatch '(?s)nodeCreationSheet = \$nodeCreationSheetEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress') {
    throw "RED: UIA final summary omits the parsable node creation sheet evidence"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_SKETCH_CUSTODY_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch '(?s)sketchCustody = \$sketchCustodyEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress' -or
      $uiaLiveGateSource -notmatch 'promotion\.goal' -or
      $uiaLiveGateSource -notmatch 'promotion\.turn' -or
      $uiaLiveGateSource -notmatch 'promotion\.timed' -or
      $uiaLiveGateSource -notmatch 'createdBy' -or
      $uiaLiveGateSource -notmatch 'commandLogBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'appliedPromotions' -or
      $uiaLiveGateSource -notmatch 'appliedPromotionRequests' -or
      $uiaLiveGateSource -notmatch 'UIA_SKETCH_PROMOTION_RENDER_ATTEMPT=' -or
      $uiaLiveGateSource -notmatch 'public static bool RevealSubmenuByKeyboard\(IntPtr popup, IntPtr menu, int position\)' -or
      $uiaLiveGateSource -notmatch '\$submenuKeyboardReveal = \[GraphCodeUiaGateState\]::RevealSubmenuByKeyboard\(' -or
      $uiaLiveGateSource -notmatch 'real Promote to submenu popup did not open by hover or keyboard' -or
      $uiaLiveGateSource -notmatch '(?s)\$reopen = Open-SketchNodeMenu \$title.*?\$reopenKeyboardReveal = \[GraphCodeUiaGateState\]::RevealSubmenuByKeyboard\(.*?Turn promotion submenu did not reopen by hover or keyboard' -or
      $uiaLiveGateSource -match 'SendCommand\(\s*\$renameShellWindow, \[uint32\]\$case\.Command\)' -or
      $uiaLiveGateSource -notmatch 'modalCommandFallback' -or
      $uiaLiveGateSource -notmatch 'function Stop-UiaOwnedProviderProcesses' -or
      $uiaLiveGateSource -notmatch 'UIA_PROVIDER_PROCESS_CLEANUP=' -or
      $uiaLiveGateSource -notmatch '\$providerZmxBaseline' -or
      $uiaLiveGateSource -notmatch '(?s)function Sketch-Submit.*?Start-Sleep -Milliseconds 200.*?\$buttonFallback = \[GraphCodeUiaGateState\]::ClickButton\(\$button\).*?buttonFallback = \$buttonFallback' -or
      $uiaLiveGateSource -notmatch '(?s)function Sketch-Cancel.*?Start-Sleep -Milliseconds 200.*?\$keyboardFallback = \[GraphCodeUiaGateState\]::PostKeyboard\(\$script:edgeWorkflowWindow, 0x1B\).*?keyboardFallback = \$keyboardFallback' -or
      $uiaLiveGateSource -notmatch '\$sameCardAutomationId = \$renderMenu\.cardId -ceq \$menu\.cardId' -or
      $uiaLiveGateSource -notmatch '(?s)\$renderedPromotedState = \$sameCardAutomationId -and\s*\$promotionChoices\.Count -eq 0 -and \$newChildChoices\.Count -eq 1' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch '(?s)public static bool HoverPopupMenuItem.*?FindPopupForMenu\(ownerProcess, menu\).*?SendMessage\(popup, 0x0200, UIntPtr\.Zero, MouseLParam\(client\.X, client\.Y\)\).*?GetMenuState\(menu, \(uint\)position, 0x0400\)' -or
      $uiaLiveGateSource -notmatch 'IsControlOwnedBy' -or
      $uiaLiveGateSource -notmatch 'TypeEditTextById' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText' -or
      $uiaLiveGateSource -notmatch 'renderedHitTests' -or
      $uiaLiveGateSource -notmatch 'function ConvertTo-SketchCanonicalJson' -or
      $uiaLiveGateSource -notmatch 'function Test-SketchPromotionReceipt' -or
      $uiaLiveGateSource -notmatch 'Test-SketchPromotionReceipt \$after \$request \$expectedWire' -or
      $uiaLiveGateSource -notmatch 'receivedWireRaw = \$receivedWireRaw' -or
      $uiaLiveGateSource -notmatch '\$custodyFirstInstruction = "Work on the requested Windows shell task\."' -or
      $uiaLiveGateSource -notmatch 'Sketch-Type 9104 \$custodyFirstInstruction' -or
      $uiaLiveGateSource -notmatch '\$custodyInstructionAfterBackend = Sketch-Field 9104' -or
      $uiaLiveGateSource -notmatch '\$custodyReceived = @\(\$custodyAfter\.receivedGraphCommands \| Where-Object \{ \$_.requestID -ceq \$custodyRequest \}\)' -or
      $uiaLiveGateSource -notmatch '\$custodyReceived\.Count -eq 1' -or
      $uiaLiveGateSource -notmatch '\$custodyCommand = \[string\]\$custodyReceived\[0\]\.command \| ConvertFrom-Json' -or
      $uiaLiveGateSource -notmatch '\$custodyWire = \$custodyCommand\.command\.createNode\._0' -or
      $uiaLiveGateSource -notmatch '\[int\]\$custodyAfter\.requestCount -eq \[int\]\$custodyBefore\.requestCount \+ 2' -or
      $uiaLiveGateSource -notmatch '\[int\]\$custodyAfter\.responseCount -eq \[int\]\$custodyBefore\.responseCount \+ 2' -or
      $uiaLiveGateSource -notmatch '\$custodyNewCommands\.Count -eq 2' -or
      $uiaLiveGateSource -notmatch 'Select-Object -Skip @\(\$custodyBefore\.receivedGraphCommands\)\.Count' -or
      $uiaLiveGateSource -notmatch '\$custodyExpectedOutcomeJson = ConvertTo-SketchCanonicalJson \$custodyExpectedOutcome' -or
      $uiaLiveGateSource -notmatch '\$custodyOutcomes\.Count -eq 1' -or
      $uiaLiveGateSource -notmatch '\(ConvertTo-SketchCanonicalJson \$custodyOutcomeCommand\) -ceq \$custodyExpectedOutcomeJson' -or
      $uiaLiveGateSource -notmatch '-not \[string\]::IsNullOrWhiteSpace\(\[string\]\$custodyOutcomes\[0\]\.requestID\)' -or
      $uiaLiveGateSource -notmatch 'exactIdOutcome = @\{' -or
      $uiaLiveGateSource -notmatch '\$custodyCommand\.projectPath -ceq "graphcode://stub/project"' -or
      $uiaLiveGateSource -match '\$custodyLogged = \(Read-DaemonCommandLog' -or
      $uiaLiveGateSource -match '\(\$custodyLogged \| ConvertTo-Json' -or
      $uiaLiveGateSource -notmatch '\$custodyWorkspaceId = Get-MultiProjectAutomationId "workspace-loop-bar" \$custodyId' -or
      $uiaLiveGateSource -notmatch '\$custodyWorkspace = Wait-ForGraphChildren \$renameRoot \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$custodyShowGraph\.GetCurrentPattern\(\[System\.Windows\.Automation\.InvokePattern\]::Pattern\)\.Invoke\(\)' -or
      $uiaLiveGateSource -notmatch '\$custodyGraphReturn = Wait-ForGraphChildren \$renameRoot \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$custodyRendered = Open-SketchNodeMenu "UIA custody child"' -or
      $uiaLiveGateSource -notmatch 'instructionUnchanged = \(\$custodySubmitFields\.firstInstruction -ceq \$custodyFirstInstruction\)' -or
      $uiaLiveGateSource -notmatch 'firstInstruction -ceq \$custodyFirstInstruction' -or
      $uiaLiveGateSource -notmatch 'daemonCountsBefore = \$beforeCounts; daemonCountsAfter = \$afterCounts' -or
      $uiaLiveGateSource -notmatch 'appliedPromotionRequests = @\(\$before\.appliedPromotionRequests\)\.Count' -or
      $uiaLiveGateSource -notmatch 'requestCount = \[int\]\$before\.requestCount' -or
      $uiaLiveGateSource -notmatch 'instructionEditing = "validated by native Sketch-Type exact readback before and after backend change"' -or
      $uiaLiveGateSource -match 'editing is not validated and that result does not establish a dropped key' -or
      $uiaLiveGateSource -notmatch 'rejected/cancelled no-dispatch evidence combines unchanged UIA-recorder bytes with unchanged stub received/applied/request/response/graph counts' -or
      $stubDaemonSource -notmatch 'appliedPromotions' -or
      $stubDaemonSource -notmatch 'appliedPromotionRequests' -or
      $stubDaemonSource -notmatch 'promoteNode' -or
      $stubDaemonSource -notmatch 'createdBy') {
    throw "RED: UIA gate does not prove all sketch promotions and custody child through native interaction, correlated wire, no mutation and rendered hit tests"
  }
  $uiaLiveGateType = [regex]::Match(
    $uiaLiveGateSource, '(?s)Add-Type -TypeDefinition @"\s*(?<source>.*?)\r?\n"@'
  )
  if (-not $uiaLiveGateType.Success) {
    throw "RED: UIA gate embedded C# type source is missing"
  }
  $uiaGateSource = $uiaLiveGateType.Groups[1].Value
  $uiaGateDefinedMembers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($member in [regex]::Matches(
      $uiaGateSource,
      '(?m)^\s*public\s+(?:(?:static|volatile|readonly)\s+)*(?:[\w<>\[\],.?]+\s+)+(?<member>[\w]+)\s*(?:\(|[;=])')) {
    [void]$uiaGateDefinedMembers.Add($member.Groups["member"].Value)
  }
  $uiaGateMissingMembers = @(
    [regex]::Matches($uiaLiveGateSource, '\[GraphCodeUiaGateState\]::(?<member>[\w]+)') |
      ForEach-Object { $_.Groups["member"].Value } |
      Sort-Object -Unique |
      Where-Object { -not $uiaGateDefinedMembers.Contains($_) }
  )
  if ($uiaGateMissingMembers.Count -gt 0) {
    throw "RED: UIA gate calls undefined embedded C# member(s): $($uiaGateMissingMembers -join ', ')"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_EDGE_WORKFLOW_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch '(?s)edgeWorkflow = \$edgeWorkflowEvidence.*?\}\s*\|\s*ConvertTo-Json -Depth 8 -Compress' -or
      $uiaLiveGateSource -notmatch 'createEdge' -or
      $uiaLiveGateSource -notmatch 'updateEdge' -or
      $uiaLiveGateSource -notmatch 'Enter the template or script that should carry context\.' -or
      $uiaLiveGateSource -notmatch 'WindowIsVisible\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'ClickPopupMenuItem' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeCreates' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeUpdates' -or
      $uiaLiveGateSource -notmatch 'commandLogBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'renderedEdgeId' -or
      $uiaLiveGateSource -notmatch 'graphCommandsBefore' -or
      $uiaLiveGateSource -notmatch 'graphCommandsAfter') {
    throw "RED: UIA live gate does not prove the native edge create/edit round trip and no-mutation paths"
  }
  if ($uiaLiveGateSource -notmatch 'FindVisibleProcessWindow\(\[uint32\]\$renameProcess\.Id, \$title\)' -or
      $uiaLiveGateSource -notmatch 'WindowIsVisible\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_MODAL_CENSUS' -or
      $uiaLiveGateSource -notmatch 'commandFallback = \$commandFallback' -or
      $uiaLiveGateSource -notmatch 'waitCommandFallback' -or
      $uiaLiveGateSource -notmatch '\$delta = \$index - \[int\]\(\$after\.Split\("\|"\)\[0\]\)' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_COMBO id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch '(?s)\$postedFallbacks = 0.*?\$fallbackDelta = \$index - \[int\]\(\$after\.Split\("\|"\)\[0\]\).*?\[GraphCodeUiaGateState\]::PostKeyboard\(\$control, \$fallbackKey\).*?\$postedFallbacks\+\+' -or
      $uiaLiveGateSource -notmatch 'postedFallbacks=\$postedFallbacks' -or
      $uiaLiveGateSource -notmatch 'Require \(\$after -eq "\$index\|\$expected"\)' -or
      $uiaLiveGateSource -match '\$Matches\[1\] -in @\(') {
    throw "RED: UIA edge retry/modal/identity proof regressed"
  }
  if ($uiaLiveGateSource -notmatch 'function Edge-TypeText\(' -or
      $uiaLiveGateSource -notmatch 'function Get-EdgeTextAttemptDecision\(' -or
      $uiaLiveGateSource -notmatch 'public static bool ClickButton\(IntPtr button\)' -or
      $uiaLiveGateSource -notmatch '(?s)function Edge-Click.*?Start-Sleep -Milliseconds 200.*?\$buttonFallback = \[GraphCodeUiaGateState\]::ClickButton\(\$control\).*?buttonFallback = \$buttonFallback' -or
      $uiaLiveGateSource -notmatch 'Edge-TypeText \$field\.Id \$field\.Text' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_TEXT_STABLE id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::TypeEditTextById\(\$edgeWorkflowWindow, \$id, \$text\)' -or
      $uiaLiveGateSource -notmatch 'LastEditUsedMessageFallback' -or
      $uiaLiveGateSource -notmatch 'SendMessageString\(edit, 0x000C, UIntPtr\.Zero, text\)' -or
      $uiaLiveGateSource -notmatch '(?s)if \(\$messageFallback\).*?\$renameProcess\.WaitForInputIdle\(1000\).*?SetEditTextById\(\$edgeWorkflowWindow, \$id, \$text\)' -or
      $uiaLiveGateSource -notmatch 'messageFallback=\$messageFallback' -or
      $uiaLiveGateSource -notmatch 'Require \$completed' -or
      $uiaLiveGateSource -notmatch 'IsControlOwnedBy\(\$edgeWorkflowWindow, \$control, \$id\)' -or
      $uiaLiveGateSource -notmatch 'HasVisibleBounds\(\$control\)' -or
      $uiaLiveGateSource -notmatch 'FocusedControlInDialog\(\$edgeWorkflowWindow\)' -or
      $uiaLiveGateSource -notmatch 'WindowProcessId\(\$edgeWorkflowWindow\) -eq \$renameProcess\.Id' -or
      $uiaLiveGateSource -notmatch 'WindowTextOf\(\$edgeWorkflowWindow\) -eq \$script:edgeWorkflowTitle' -or
      $uiaLiveGateSource -notmatch 'VirtualKey = 0x2E' -or
      $uiaLiveGateSource -notmatch 'SendMessageText\(edit, 0x000D' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(edit, 0x00B1, UIntPtr\.Zero, new IntPtr\(-1\)\)' -or
      $uiaLiveGateSource -notmatch '(?s)var clear = new KeyInputRecord\[2\].*?EditBufferText\(edit\).*?var records = new KeyInputRecord\[text\.Length \* 2\]' -or
      $uiaLiveGateSource -notmatch 'for \(\$stableRetry = 0; \$stableRetry -lt 10' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_TEXT_STABLE id=\$id attempt=\$attempt' -or
      $uiaLiveGateSource -notmatch '\$renameProcess\.WaitForInputIdle\(1000\)' -or
      $uiaLiveGateSource -notmatch 'function Read-EdgeStableText\(' -or
      $uiaLiveGateSource -notmatch 'UIA_EDGE_SUBMIT_FIELD name=\$label id=\$id' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9105 "payload"' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9106 "cycle guard until"' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9107 "cycle guard max"' -or
      $uiaLiveGateSource -notmatch 'LastEditClearExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditClearSent' -or
      $uiaLiveGateSource -notmatch 'LastEditTextExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditTextSent' -or
      $uiaLiveGateSource -notmatch 'LastEditClearSent = SendKeyInputs\(LastEditClearExpected' -or
      $uiaLiveGateSource -notmatch 'LastEditTextSent = SendKeyInputs\(LastEditTextExpected' -or
      $uiaLiveGateSource -notmatch 'Require \(\$inputCountsFull\)' -or
      $uiaLiveGateSource -notmatch 'clearSent=\$clearSent/\$clearExpected textSent=\$textSent/\$textExpected' -or
      $uiaLiveGateSource -notmatch 'for \(\$attempt = 1; \$attempt -le 5; \$attempt\+\+\)' -or
      $uiaLiveGateSource -notmatch 'Get-EdgeTextAttemptDecision \$stable \$after \$text \$attempt 5' -or
      $uiaLiveGateSource -notmatch 'attempts=\$attemptsExecuted/5' -or
      $uiaLiveGateSource -notmatch 'for \(\$layoutRetry = 0; \$layoutRetry -lt 20') {
    throw "RED: edge native text entry lacks native ownership, live layout, focus, clear/retype, or exact verification"
  }
  $edgeTextGateAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $uiaLiveGateSource, [ref]$null, [ref]$null
  )
  $edgeTextHelperAst = $edgeTextGateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-EdgeTextAttemptDecision"
    }, $true)
  if (-not $edgeTextHelperAst) {
    throw "RED: stable-but-wrong native text has no extracted retry-decision helper"
  }
  . ([scriptblock]::Create($edgeTextHelperAst.Extent.Text))
  $edgeTextAttempts = 0
  $edgeTextValue = $null
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $edgeTextAttempts++
    $edgeTextValue = if ($edgeTextAttempts -eq 1) { "" } else { "expected text" }
    $decision = Get-EdgeTextAttemptDecision $true $edgeTextValue "expected text" $attempt 5
    if ($decision -eq "complete") { break }
    if ($decision -ne "retry") { throw "Unexpected edge text retry decision '$decision'" }
  }
  if ($edgeTextAttempts -ne 2 -or $edgeTextValue -cne "expected text") {
    throw "RED: stable empty text did not retry exactly once before the expected second attempt"
  }
  $edgeTextHelperSource = $edgeTextHelperAst.Extent.Text
  if ($edgeTextHelperSource -notmatch '\$actual -ceq \$expected') {
    throw "RED: edge retry-decision helper lost exact expected-text verification"
  }
  $mutatedEdgeTextHelperSource = $edgeTextHelperSource.Replace(
    'if ($actual -ceq $expected) { return "complete" }',
    'if ($stable) { return "complete" }'
  )
  if ($mutatedEdgeTextHelperSource -ceq $edgeTextHelperSource) {
    throw "RED: exact-match mutation negative did not find the expected helper branch"
  }
  $mutationAttempts = 0
  $mutationValue = $null
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $mutationAttempts++
    $mutationValue = if ($mutationAttempts -eq 1) { "" } else { "expected text" }
    $mutationDecision = & {
      param($helperSource, $observed, $requested, $ordinal)
      . ([scriptblock]::Create($helperSource))
      Get-EdgeTextAttemptDecision $true $observed $requested $ordinal 5
    } $mutatedEdgeTextHelperSource $mutationValue "expected text" $attempt
    if ($mutationDecision -eq "complete") { break }
  }
  if ($mutationAttempts -eq 2 -and $mutationValue -ceq "expected text") {
    throw "RED: removing exact expected-text comparison evaded the stable-wrong retry regression"
  }
  $edgeTextAttempts = 0
  $edgeTextExhaustion = $null
  try {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      $edgeTextAttempts++
      $null = Get-EdgeTextAttemptDecision $true "" "expected text" $attempt 5
    }
  } catch {
    $edgeTextExhaustion = $_
  }
  if ($edgeTextAttempts -ne 5 -or $null -eq $edgeTextExhaustion -or
      $edgeTextExhaustion.Exception.Message -notmatch 'attempts=5/5') {
    throw "RED: stable-wrong edge text did not exhaust and report exactly five attempts; calls=$edgeTextAttempts error=$($edgeTextExhaustion.Exception.Message)"
  }
  if ($uiaLiveGateSource -notmatch 'function Wait-SketchGraphCard\(' -or
      $uiaLiveGateSource -notmatch 'function Get-SketchCardAutomationId\(' -or
      $uiaLiveGateSource -notmatch 'UIA_SKETCH_CUSTODY_CARD_WAIT=' -or
      $uiaLiveGateSource -notmatch 'Wait-SketchGraphCard "UIA custody child" \$custodyId' -or
      $uiaLiveGateSource -notmatch 'Open-SketchNodeMenu "UIA custody child" -SkipActualSize -ExpectedCardId') {
    throw "RED: custody child render check has no bounded observation-only card reacquisition"
  }
  $custodyCardWaitAst = $edgeTextGateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Wait-SketchGraphCard"
    }, $true)
  if (-not $custodyCardWaitAst) {
    throw "RED: custody graph-card wait helper is not extractable"
  }
  $custodyCardWaitSource = $custodyCardWaitAst.Extent.Text
  if ($custodyCardWaitSource -notmatch '\$baselineCount -gt 0' -or
      $custodyCardWaitSource -notmatch '\$lastTitleCount -eq 1 -and \$lastIdentityCount -eq 1' -or
      $custodyCardWaitSource -notmatch '\$expectedNodeId' -or
      $custodyCardWaitSource -notmatch '\$expectedAutomationId' -or
      $custodyCardWaitSource -notmatch '\$_.Current\.AutomationId -ceq \$expectedAutomationId' -or
      $custodyCardWaitSource -notmatch '\$graphSequence' -or
      $custodyCardWaitSource -match 'Invoke\(\)|PostRightClick|Actual Size') {
    throw "RED: custody card wait lacks a positive baseline, unique UUID-bound observation, or action-free polling"
  }
  $sketchCardIdAst = $edgeTextGateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-SketchCardAutomationId"
    }, $true)
  if (-not $sketchCardIdAst) {
    throw "RED: source-derived sketch-card AutomationId helper is missing"
  }
  . ([scriptblock]::Create($sketchCardIdAst.Extent.Text))
  $expectedSketchCardIds = @(
    [pscustomobject]@{
      NodeId = "66666666-6666-4666-8666-000000000001"
      AutomationId = "canvas-card-1213325934034940293"
    },
    [pscustomobject]@{
      NodeId = "66666666-6666-4666-8666-000000000002"
      AutomationId = "canvas-card-1213322635500055660"
    },
    [pscustomobject]@{
      NodeId = "66666666-6666-4666-8666-000000000003"
      AutomationId = "canvas-card-1213323735011683871"
    }
  )
  foreach ($expectedCard in $expectedSketchCardIds) {
    if ((Get-SketchCardAutomationId $expectedCard.NodeId) -cne $expectedCard.AutomationId) {
      throw "RED: source-derived UIA card identity differs for $($expectedCard.NodeId)"
    }
  }
  $openSketchMenuAst = $edgeTextGateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Open-SketchNodeMenu"
    }, $true)
  if (-not $openSketchMenuAst -or
      $openSketchMenuAst.Extent.Text -notmatch '\$cards\.Count -eq 1' -or
      $openSketchMenuAst.Extent.Text -notmatch '\$ExpectedCardId' -or
      $openSketchMenuAst.Extent.Text -notmatch '\$cards\[0\]\.Current\.AutomationId -ceq \$ExpectedCardId' -or
      $openSketchMenuAst.Extent.Text -notmatch 'Get-DirectChildren \$graph \$rawWalker') {
    throw "RED: custody right-click can bypass fresh-fragment, unique-card, or hashed child-identity checks"
  }
  if ($uiaLiveGateSource -match 'Open-EdgeMenu \$false\s+5120' -or
      $uiaLiveGateSource -match 'Edge-Combo 9100\b' -or
      $uiaLiveGateSource -match 'Edge-Combo 9101\b' -or
      $uiaLiveGateSource -match '\$edgeCreateMenu\b' -or
      $uiaLiveGateSource -match '\$edgeSourceChoice\b|\$edgeTargetChoice\b' -or
      $uiaLiveGateSource -match 'if \(\$title -eq "Create or edit edge"\)\s*\{\s*5120' -or
      $uiaLiveGateSource -notmatch 'function Select-EdgeConnectorCardPair\(' -or
      $uiaLiveGateSource -notmatch 'function Open-EdgeCreateDialogByConnectorDrag\b' -or
      $uiaLiveGateSource -notmatch 'Select-EdgeConnectorCardPair \$cards \$sourceTitle "Stub node B"' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::PostMouseButtonAt\(\s*\$renameShellWindow,\s*0x0201' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::PostMouseButtonAt\(\s*\$renameShellWindow,\s*0x0202' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9100 "locked source identity"' -or
      $uiaLiveGateSource -notmatch 'Read-EdgeStableText 9101 "locked target identity"' -or
      $uiaLiveGateSource -notmatch 'Open-EdgeMenu \$true 5110' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9102 0' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9103 2 "Only after failure"' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9103 1 "Only after success"' -or
      $uiaLiveGateSource -notmatch 'Edge-Combo 9104 1 "Apply a text template"' -or
      $uiaLiveGateSource -notmatch 'Edge-TypeText \$field\.Id \$field\.Text' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "invalid edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "valid edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 1 "update edge OK"' -or
      $uiaLiveGateSource -notmatch 'Edge-Click 2 "cancel changed edge"' -or
      $uiaLiveGateSource -notmatch 'Assert-EdgePrefill "2\|Only after failure"' -or
      $uiaLiveGateSource -notmatch 'Assert-EdgePrefill "1\|Only after success"' -or
      $uiaLiveGateSource -notmatch 'Get-DirectChildren \$graph \$rawWalker' -or
      $uiaLiveGateSource -notmatch 'edgeCreateWire\.command\.createEdge\.from' -or
      $uiaLiveGateSource -notmatch 'edgeChange\.expectedSpec\.condition -eq "onFailure"' -or
      $uiaLiveGateSource -notmatch 'edgeChange\.spec\.condition -eq "onSuccess"' -or
      $uiaLiveGateSource -notmatch 'edgeCancelBytesUnchanged' -or
      $uiaLiveGateSource -notmatch 'appliedEdgeUpdateRequests' -or
      $stubDaemonSource -notmatch 'appliedEdgeCreateRequests' -or
      $stubDaemonSource -notmatch 'appliedEdgeUpdateRequests' -or
      $stubDaemonSource -notmatch 'if \(\$renameApplied -or \$createApplied -or \$edgeApplied(?: -or \$promotionApplied)?\)') {
    throw "RED: edge workflow does not use unique connector dragging and locked endpoints while preserving edit/CAS and no-mutation proofs"
  }
  $compositeEvidenceIndex = $uiaLiveGateSource.IndexOf(
    'UIA_COMPOSITE_NAVIGATION_EVIDENCE=', [StringComparison]::Ordinal)
  $connectorActualIndex = $uiaLiveGateSource.IndexOf(
    '$connectorActual = Find-FragmentByIdWithRetry $root "actual-size" $rawWalker',
    [Math]::Max(0, $compositeEvidenceIndex), [StringComparison]::Ordinal)
  $connectorActualInvokeIndex = $uiaLiveGateSource.IndexOf(
    '$connectorActual.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()',
    [Math]::Max(0, $connectorActualIndex), [StringComparison]::Ordinal)
  $connectorReacquireIndex = $uiaLiveGateSource.IndexOf(
    '$connectorProbe = Wait-ForGraphChildren $root $rawWalker',
    [Math]::Max(0, $connectorActualInvokeIndex), [StringComparison]::Ordinal)
  $connectorSourceIndex = $uiaLiveGateSource.IndexOf(
    '$connectorSourceCard = @($connectorProjectCards',
    [Math]::Max(0, $connectorReacquireIndex), [StringComparison]::Ordinal)
  if ($compositeEvidenceIndex -lt 0 -or
      $connectorActualIndex -le $compositeEvidenceIndex -or
      $connectorActualInvokeIndex -le $connectorActualIndex -or
      $connectorReacquireIndex -le $connectorActualInvokeIndex -or
      $connectorSourceIndex -le $connectorReacquireIndex -or
      $uiaLiveGateSource -notmatch '(?s)\$connectorProbe = Wait-ForGraphChildren \$root \$rawWalker.*?UIA loop A.*?UIA loop B.*?\$items\.Count -eq 2' -or
      $uiaLiveGateSource -notmatch '\$connectorTargetCard = @\(\$connectorProjectCards') {
    throw "RED: connector evidence does not reset Actual Size and reacquire the exact parent cards after composite navigation"
  }
  if ($uiaLiveGateSource -notmatch '\$readNormalizedLaneGeometry\s*=\s*\{' -or
      $uiaLiveGateSource -notmatch 'lane cards do not normalize to the shared 250x96 geometry' -or
      $uiaLiveGateSource -notmatch '\$sameNormalizedLaneGeometry\s*=\s*\{' -or
      $uiaLiveGateSource -notmatch 'Scale = \$scale' -or
      $uiaLiveGateSource -notmatch 'PixelWidth = \[double\]\$cardBounds\[0\]\.Width' -or
      $uiaLiveGateSource -notmatch '\$sizeTolerance = 1 / \$scale \+ 0\.01' -or
      $uiaLiveGateSource -notmatch 'SizeTolerance = \$sizeTolerance' -or
      $uiaLiveGateSource -notmatch 'Widths = @\(\$normalized \| ForEach-Object' -or
      $uiaLiveGateSource -notmatch 'Heights = @\(\$normalized \| ForEach-Object' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Abs\(\$normalized\[0\]\.Width - 250\) -le 0\.01' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Abs\(\$normalized\[1\]\.Width - 250\) -le \$sizeTolerance' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Abs\(\$normalized\[0\]\.Height - 96\) -le \$sizeTolerance' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Abs\(\$normalized\[1\]\.Height - 96\) -le \$sizeTolerance' -or
      $uiaLiveGateSource -notmatch '\$actualDeltaXBudget = 250 \*' -or
      $uiaLiveGateSource -notmatch '\$expectedDeltaXBudget = 250 \*' -or
      $uiaLiveGateSource -notmatch '\$actualDeltaYBudget = 250 \*' -or
      $uiaLiveGateSource -notmatch '\$expectedDeltaYBudget = 250 \*' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Max\(1, \$actual\.PixelWidth - 1\)' -or
      $uiaLiveGateSource -notmatch '\[Math\]::Max\(1, \$expected\.PixelWidth - 1\)' -or
      $uiaLiveGateSource -notmatch '\$deltaXTolerance = \$actualDeltaXBudget \+ \$expectedDeltaXBudget \+ 0\.01' -or
      $uiaLiveGateSource -notmatch '\$deltaYTolerance = \$actualDeltaYBudget \+ \$expectedDeltaYBudget \+ 0\.01' -or
      $uiaLiveGateSource -notmatch 'normalized lane comparison requires positive pixel widths' -or
      $uiaLiveGateSource -notmatch 'normalized lane comparison requires positive scales' -or
      $uiaLiveGateSource -notmatch '\$cards = @\(\$laneOverviewIds \| ForEach-Object' -or
      $uiaLiveGateSource -notmatch '\$laneOpenedProbe = Wait-ForGraphChildren \$root \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$_.Current\.AutomationId -cin \$laneProjectIds' -or
      $uiaLiveGateSource -notmatch '\$laneOpenedCards = @\(\$laneProjectIds \| ForEach-Object' -or
      $uiaLiveGateSource -notmatch 'opened project requires one exact card for \$id' -or
      $uiaLiveGateSource -notmatch '\$restoredLaneProbe = Wait-ForGraphChildren \$root \$rawWalker' -or
      $uiaLiveGateSource -notmatch '\$_.Current\.AutomationId -cin \$laneOverviewIds' -or
      $uiaLiveGateSource -notmatch 'UIA_LANE_OPEN_NORMALIZED_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch 'normalizedActual = \$laneOpenedGeometry' -or
      $uiaLiveGateSource -notmatch 'normalizedExpected = \$laneSnapshotGeometry' -or
      $uiaLiveGateSource -notmatch 'normalizedEqual = \$laneNormalizedEqual' -or
      $uiaLiveGateSource -notmatch 'normalizedDeltaXTolerance = \$laneNormalizedComparison\.DeltaXTolerance' -or
      $uiaLiveGateSource -notmatch 'normalizedDeltaYTolerance = \$laneNormalizedComparison\.DeltaYTolerance' -or
      $uiaLiveGateSource -notmatch 'normalizedActualDeltaXBudget = \$laneNormalizedComparison\.ActualDeltaXBudget' -or
      $uiaLiveGateSource -notmatch 'normalizedExpectedDeltaXBudget = \$laneNormalizedComparison\.ExpectedDeltaXBudget' -or
      $uiaLiveGateSource -notmatch 'normalizedActualDeltaYBudget = \$laneNormalizedComparison\.ActualDeltaYBudget' -or
      $uiaLiveGateSource -notmatch 'normalizedExpectedDeltaYBudget = \$laneNormalizedComparison\.ExpectedDeltaYBudget' -or
      $uiaLiveGateSource -notmatch 'ActualDeltaXBudget = \$actualDeltaXBudget' -or
      $uiaLiveGateSource -notmatch 'ExpectedDeltaXBudget = \$expectedDeltaXBudget' -or
      $uiaLiveGateSource -notmatch 'ActualDeltaYBudget = \$actualDeltaYBudget' -or
      $uiaLiveGateSource -notmatch 'ExpectedDeltaYBudget = \$expectedDeltaYBudget' -or
      $uiaLiveGateSource -notmatch 'normalizedDeltaXError = \$laneNormalizedComparison\.DeltaXError' -or
      $uiaLiveGateSource -notmatch 'normalizedDeltaYError = \$laneNormalizedComparison\.DeltaYError' -or
      $uiaLiveGateSource -notmatch 'nonOverlap = \$laneNonOverlap' -or
      $uiaLiveGateSource -notmatch 'before-restored-lane-sheet-pan' -or
      $uiaLiveGateSource -notmatch 'restored lane sheet pan down was rejected' -or
      $uiaLiveGateSource -notmatch 'restored lane sheet pan move was rejected' -or
      $uiaLiveGateSource -notmatch 'restored lane sheet pan up was rejected' -or
      $uiaLiveGateSource -notmatch '\$restoredLaneComparison = & \$sameNormalizedLaneGeometry \$restoredLaneGeometry \$laneSnapshotGeometry' -or
      $uiaLiveGateSource -notmatch 'UIA_RESTORED_LANE_NORMALIZED_EVIDENCE=' -or
      $uiaLiveGateSource -notmatch 'normalizedActual = \$restoredLaneGeometry' -or
      $uiaLiveGateSource -notmatch 'normalizedExpected = \$laneSnapshotGeometry' -or
      $uiaLiveGateSource -notmatch 'Require \$restoredLaneComparison\.Equal' -or
      $uiaLiveGateSource -match '\.Equals\(\$laneSnapshot\.CardBounds\[') {
    throw "RED: overview/project navigation evidence depends on absolute fitted card coordinates instead of normalized shared geometry"
  }
  $connectorCardSelectorAst = $edgeTextGateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Select-EdgeConnectorCardPair"
    }, $true)
  if (-not $connectorCardSelectorAst) {
    throw "RED: connector-card selector is not extractable for named functional cases"
  }
  . ([scriptblock]::Create($connectorCardSelectorAst.Extent.Text))
  function New-EdgeConnectorTestCard([string] $automationId, [string] $name) {
    return [pscustomobject]@{
      Current = [pscustomobject]@{ AutomationId = $automationId; Name = $name }
    }
  }
  $edgeConnectorCardCases = @(
    @{
      Name = "positive selects one named source and target"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source" "source"),
        (New-EdgeConnectorTestCard "canvas-card-target" "target")
      )
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $true
      ExpectedSource = "canvas-card-source"
      ExpectedTarget = "canvas-card-target"
    },
    @{
      Name = "negative rejects duplicate source cards"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source-a" "source"),
        (New-EdgeConnectorTestCard "canvas-card-source-b" "source"),
        (New-EdgeConnectorTestCard "canvas-card-target" "target")
      )
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects a missing source card"
      Cards = @((New-EdgeConnectorTestCard "canvas-card-target" "target"))
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects a missing target card"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source" "source"),
        (New-EdgeConnectorTestCard "button-target" "target")
      )
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects a different named target card"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source" "source"),
        (New-EdgeConnectorTestCard "canvas-card-target" "other target")
      )
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects duplicate target cards"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source" "source"),
        (New-EdgeConnectorTestCard "canvas-card-target-a" "target"),
        (New-EdgeConnectorTestCard "canvas-card-target-b" "target")
      )
      SourceTitle = "source"
      TargetTitle = "target"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects the same card as both endpoints"
      Cards = @((New-EdgeConnectorTestCard "canvas-card-same" "same"))
      SourceTitle = "same"
      TargetTitle = "same"
      ShouldSelect = $false
    },
    @{
      Name = "negative rejects a blank endpoint title"
      Cards = @(
        (New-EdgeConnectorTestCard "canvas-card-source" "source"),
        (New-EdgeConnectorTestCard "canvas-card-target" "target")
      )
      SourceTitle = " "
      TargetTitle = "target"
      ShouldSelect = $false
    }
  )
  foreach ($case in $edgeConnectorCardCases) {
    $selection = $null
    $selectionError = $null
    try {
      $selection = Select-EdgeConnectorCardPair `
        $case.Cards $case.SourceTitle $case.TargetTitle
    } catch {
      $selectionError = $_
    }
    if ($case.ShouldSelect) {
      if ($null -ne $selectionError -or
          $selection.Source.Current.AutomationId -cne $case.ExpectedSource -or
          $selection.Target.Current.AutomationId -cne $case.ExpectedTarget) {
        throw "RED: edge connector functional case '$($case.Name)' failed: $($selectionError.Exception.Message)"
      }
    } elseif ($null -eq $selectionError) {
      throw "RED: edge connector functional case '$($case.Name)' unexpectedly selected ambiguous/missing cards"
    }
    Write-Host "UIA_EDGE_CONNECTOR_CASE name='$($case.Name)' result=PASS"
  }
  function Test-SketchPromotionSubmenuCases([string] $gateSource) {
    if ($gateSource -notmatch 'Test-SketchPromotionSubmenuItems \$subItems') {
      throw "RED: live Promote submenu gate does not use its testable exact-shape oracle"
    }
    $gateTokens = $null
    $gateParseErrors = $null
    $gateAst = [System.Management.Automation.Language.Parser]::ParseInput(
      $gateSource, [ref]$gateTokens, [ref]$gateParseErrors)
    if ($gateParseErrors.Count -ne 0) {
      throw "RED: live Promote submenu source does not parse for functional oracle tests"
    }
    $helperAst = $gateAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq "Test-SketchPromotionSubmenuItems"
      }, $true)
    if (-not $helperAst) {
      throw "RED: live Promote submenu exact-shape oracle is not extractable"
    }
    . ([scriptblock]::Create($helperAst.Extent.Text))
    function New-SketchPromotionTestItems {
      return @(
        [pscustomobject]@{
          Id = 0; Text = "Keep the session, add a shape"; Enabled = $false; Separator = $false
        },
        [pscustomobject]@{
          Id = 5116; Text = "Goal — asks for a done check"; Enabled = $true; Separator = $false
        },
        [pscustomobject]@{
          Id = 5117; Text = "Turn — asks where to pause"; Enabled = $true; Separator = $false
        },
        [pscustomobject]@{
          Id = 5118; Text = "Timed — asks for a cadence"; Enabled = $true; Separator = $false
        }
      )
    }
    $exact = @(New-SketchPromotionTestItems)
    $extra = @(New-SketchPromotionTestItems) + @(
      [pscustomobject]@{ Id = 5120; Text = "Unexpected"; Enabled = $true; Separator = $false }
    )
    $reorderedBase = @(New-SketchPromotionTestItems)
    $reordered = @(
      $reorderedBase[0], $reorderedBase[2], $reorderedBase[1], $reorderedBase[3]
    )
    $enabledHeading = @(New-SketchPromotionTestItems)
    $enabledHeading[0].Enabled = $true
    $disabledAction = @(New-SketchPromotionTestItems)
    $disabledAction[1].Enabled = $false
    $wrongCaption = @(New-SketchPromotionTestItems)
    $wrongCaption[2].Text = "Turn — unexpected caption"
    $separatorHeading = @(New-SketchPromotionTestItems)
    $separatorHeading[0].Separator = $true
    $cases = @(
      @{
        Name = "positive accepts exact disabled nonseparator heading and three enabled actions"
        Items = $exact
        Expected = $true
      },
      @{ Name = "negative rejects an extra item"; Items = $extra; Expected = $false },
      @{ Name = "negative rejects reordered actions"; Items = $reordered; Expected = $false },
      @{ Name = "negative rejects an enabled heading"; Items = $enabledHeading; Expected = $false },
      @{ Name = "negative rejects a disabled action"; Items = $disabledAction; Expected = $false },
      @{ Name = "negative rejects a wrong action caption"; Items = $wrongCaption; Expected = $false },
      @{ Name = "negative rejects a separator heading"; Items = $separatorHeading; Expected = $false }
    )
    $passed = 0
    foreach ($case in $cases) {
      $actual = [bool](Test-SketchPromotionSubmenuItems $case.Items)
      if ($actual -ne [bool]$case.Expected) {
        throw "RED: Promote submenu functional case '$($case.Name)' returned $actual"
      }
      Write-Host "UIA_SKETCH_SUBMENU_CASE name='$($case.Name)' result=PASS"
      $passed++
    }
    if ($passed -ne $cases.Count -or $passed -le 0) {
      throw "RED: Promote submenu functional case count was $passed, expected $($cases.Count)"
    }
    Write-Host "UIA_SKETCH_SUBMENU_CASES executed=$passed"
  }
  Test-SketchPromotionSubmenuCases $uiaLiveGateSource
  $nativeFormsSource = Get-Content (Join-Path $repoRoot "graphcode-windows\src\NativeForms.zig") -Raw
  if ($nativeFormsSource -notmatch '(?s)const node_labels = \[_\]\[\]const u8\{(.*?)\};') {
    throw "RED: NativeForms.zig node_labels table not found for node creation sheet label contract"
  }
  $nativeNodeLabels = @([regex]::Matches($Matches[1], '"((?:[^"\\]|\\.)*)"') | ForEach-Object { $_.Groups[1].Value })
  $gateAst = [System.Management.Automation.Language.Parser]::ParseInput($uiaLiveGateSource, [ref]$null, [ref]$null)
  $labelMapAst = $gateAst.Find({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$nodeSheetFieldLabels'
    }, $true)
  $labelHashAst = if ($labelMapAst) { $labelMapAst.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true) }
  if (-not $labelHashAst) {
    throw "RED: UIA live gate node creation sheet label map is missing"
  }
  $gateLabelMap = [System.Management.Automation.ScriptBlock]::Create($labelMapAst.Right.Extent.Text).InvokeReturnAsIs()
  foreach ($labelId in @(9100, 9102, 9103, 9104, 9106, 9107, 9108, 9109, 9110, 9111, 9112, 9113, 9114)) {
    $expectedLabel = $nativeNodeLabels[$labelId - 9100]
    $actualLabel = [string]$gateLabelMap[$labelId]
    if ([string]::IsNullOrWhiteSpace($expectedLabel) -or $actualLabel -ne $expectedLabel) {
      throw "RED: UIA live gate node creation sheet label lookup for $labelId returned '$actualLabel', expected '$expectedLabel' from NativeForms.zig"
    }
  }
  if ($uiaLiveGateSource -notmatch 'expected label list is empty or blank') {
    throw "RED: UIA live gate node creation sheet label comparison can pass vacuously on an empty expected list"
  }
  if ($uiaLiveGateSource -notmatch '(?s)for \(\$index = 0; \$index -lt 20 -and\s*\[GraphCodeUiaGateState\]::FocusSourceAutomationId -ne \$safeRowId; \$index\+\+\)' -or
      $uiaLiveGateSource -notmatch 'Require \(\[GraphCodeUiaGateState\]::FocusSourceAutomationId -eq \$safeRowId\) "FocusChanged source identity changed"') {
    throw "RED: UIA focus retention waits for any FocusChanged event instead of the focused row identity"
  }
  if ($uiaLiveGateSource -notmatch 'SystemParametersInfoRect\(0x0030' -or
      $uiaLiveGateSource -notmatch 'HitTarget = !visibleEmpty && sameTopLevel && realChild == target' -or
      $uiaLiveGateSource -notmatch 'RealChildWindowFromPoint\(dialog, clientPoint\)' -or
      $uiaLiveGateSource -notmatch 'Require \(-not \$hit\.VisibleEmpty\)' -or
      $uiaLiveGateSource -notmatch 'has no visible portion inside' -or
      $uiaLiveGateSource -notmatch 'footerOccludedByTaskbar = ' -or
      $uiaLiveGateSource -notmatch 'overlapPixels = ' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_OCCLUSION') {
    throw "RED: UIA live gate node creation sheet cannot measure and record controls occluded outside the monitor work area"
  }
  if ($uiaLiveGateSource -notmatch 'if \(!hit\.HitTarget && !visibleEmpty && dialog != IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'for \(int row = 1; row <= 3; row\+\+\)' -or
      $uiaLiveGateSource -notmatch 'for \(int column = 1; column <= 5; column\+\+\)' -or
      $uiaLiveGateSource -notmatch 'return RealChildWindowFromPoint\(dialog, clientPoint\) == target;' -or
      $uiaLiveGateSource -notmatch '\} else if \(!hit\.HitTarget\) \{' -or
      $uiaLiveGateSource -notmatch 'footerOccludedByContent = ' -or
      $uiaLiveGateSource -notmatch 'coveredFraction = ' -or
      $uiaLiveGateSource -notmatch 'createCentreClicks = ' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_CONTENT_OCCLUSION' -or
      $uiaLiveGateSource -notmatch 'has no verified uncovered point in' -or
      $uiaLiveGateSource -notmatch 'SubtractCoveredRectangles' -or
      $uiaLiveGateSource -notmatch 'GetWindow\(target, 3\)' -or
      $uiaLiveGateSource -notmatch 'ChosenUncoveredRectangle = piece' -or
      $uiaLiveGateSource -notmatch 'uncoveredRectangles = ') {
    throw "RED: UIA live gate node creation sheet cannot click and record a footer control partly covered by scrolled content"
  }
  if ($uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_INVALID_WINDOW' -or
      $uiaLiveGateSource -notmatch '\$nativeVisible = \[GraphCodeUiaGateState\]::WindowIsVisible\(\$nodeSheetWindow\)' -or
      $uiaLiveGateSource -notmatch '\$stillOpen = \$nativeVisible -and \$nativeTitle -eq \$nodeSheetTitle' -or
      $uiaLiveGateSource -notmatch 'Require \$stillOpen') {
    throw "RED: UIA live gate does not check the native modal remains visible after rejected Create"
  }
  if ($uiaLiveGateSource -notmatch '(?s)for \(\$attempt = 1; \$attempt -le 10; \$attempt\+\+\).*?uiaRecoveredAtAttempt = \$attempt' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_INVALID_WINDOW' -or
      $uiaLiveGateSource -notmatch 'Require \$nodeSheetClosed' -or
      $uiaLiveGateSource -notmatch 'if \(-not \[GraphCodeUiaGateState\]::WindowIsVisible\(\$nodeSheetWindow\) -or' -or
      $uiaLiveGateSource -notmatch 'UIA_NODE_CREATION_FOOTER_CLICK' -or
      $uiaLiveGateSource -notmatch '(?s)function Invoke-NodeSheetClick.*?Start-Sleep -Milliseconds 200.*?\$buttonFallback = \[GraphCodeUiaGateState\]::ClickButton\(\$control\).*?buttonFallback = \$buttonFallback' -or
      $uiaLiveGateSource -notmatch 'sub-3px verified uncovered strip') {
    throw "RED: UIA live gate omits modal liveness retry, native closure, or footer-click geometry"
  }
  if ($uiaLiveGateSource -notmatch 'mouseSubmitUnavailable = ' -or
      $uiaLiveGateSource -notmatch '\$allowOccludedEnter -and -not \$hit\.HitTarget -and \$hit\.ScannedPoints -gt 0' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$nodeSheetWindow\)' -or
      $uiaLiveGateSource -notmatch 'FocusControl\(\$nodeSheetWindow, \$goalEdit\)' -or
      $uiaLiveGateSource -notmatch 'SendKeyInput\(0x0D, 1\)' -or
      $uiaLiveGateSource -notmatch 'Invoke-NodeSheetClick 1 "Create \(\$loopType, invalid\)" -allowOccludedEnter:\(\$loopType -eq "goalBased"\)') {
    throw "RED: occluded Goal Create cannot submit with a measured, focused native Enter fallback"
  }
  if ($uiaLiveGateSource -notmatch '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@ -ReferencedAssemblies @\(') {
    throw "RED: UIA live gate native input helper is missing"
  }
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -TypeDefinition $Matches[1] -ReferencedAssemblies @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.AutomationEventArgs].Assembly.Location
  )
  function Test-PromptControlLookup {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PromptLookupFixture {
  private delegate IntPtr WindowProc(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  private static readonly WindowProc procedure = DefWindowProc;
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct WindowClass {
    public uint Style;
    public IntPtr Procedure;
    public int ClassExtra, WindowExtra;
    public IntPtr Instance, Icon, Cursor, Background;
    public string Menu, Name;
  }
  [DllImport("user32.dll", EntryPoint = "DefWindowProcW")]
  private static extern IntPtr DefWindowProc(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "RegisterClassW")]
  private static extern ushort RegisterClass(ref WindowClass value);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  private static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateWindowExW")]
  private static extern IntPtr CreateWindow(uint ex, string cls, string title, uint style,
    int x, int y, int width, int height, IntPtr parent, IntPtr id, IntPtr instance, IntPtr parameter);
  [DllImport("user32.dll")]
  public static extern bool DestroyWindow(IntPtr window);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")]
  private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
  public static void Place(IntPtr window, int x, int y, int width, int height) {
    if (!SetWindowPos(window, IntPtr.Zero, x, y, width, height, 0x14))
      throw new InvalidOperationException("Hidden lookup fixture placement failed.");
  }
  public static void Register(string name) {
    var value = new WindowClass { Name = name, Instance = GetModuleHandle(null),
      Procedure = Marshal.GetFunctionPointerForDelegate(procedure) };
    if (RegisterClass(ref value) == 0)
      throw new InvalidOperationException("Hidden lookup fixture class registration failed: " + Marshal.GetLastWin32Error());
  }
  public static IntPtr Create(string cls, IntPtr parent, int id) {
    IntPtr result = CreateWindow(0, cls, "lookup fixture", parent == IntPtr.Zero ? 0u : 0x50000000u,
      0, 0, 400, 300, parent, new IntPtr(id), GetModuleHandle(null), IntPtr.Zero);
    if (result == IntPtr.Zero)
      throw new InvalidOperationException("Hidden lookup fixture creation failed: " + Marshal.GetLastWin32Error());
    return result;
  }
}
'@
  [PromptLookupFixture]::Register("GraphCodeSheetHost")
  [PromptLookupFixture]::Register("GraphCodeSheetViewport")
  [PromptLookupFixture]::Register("GraphCodeWindowsDialogContent")
  [PromptLookupFixture]::Register("GraphCodeNativeForm")
  [PromptLookupFixture]::Register("GraphCodeWorkspaceManager")
  [PromptLookupFixture]::Register("GraphCodeUnknownSheetContent")
  $lookupRoots = [Collections.Generic.List[IntPtr]]::new()
  function New-PromptLookupRoot([string] $class) {
    $window = [PromptLookupFixture]::Create($class, [IntPtr]::Zero, 0)
    $lookupRoots.Add($window)
    return $window
  }
  function Assert-PromptLookup([IntPtr] $parent, [int] $id, [IntPtr] $expected, [string] $name) {
    $actual = [GraphCodeUiaGateState]::ControlById($parent, $id)
    if ($actual -ne $expected) {
      throw "RED: prompt lookup $name expected=$expected actual=$actual"
    }
    $script:promptLookupExecuted++
  }
  $script:promptLookupExecuted = 0
  try {
    $promptRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $viewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $promptRoot, 0)
    $content = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $viewport, 0)
    $edit = [PromptLookupFixture]::Create("EDIT", $content, 9904)
    Assert-PromptLookup $promptRoot 9904 $edit "exact named direct viewport"
    if ([PromptLookupFixture]::IsWindowVisible($promptRoot) -or
        -not [GraphCodeUiaGateState]::SetEditTextById($promptRoot, 9904, "owned fixture") -or
        [GraphCodeUiaGateState]::EditTextById($promptRoot, 9904) -cne "owned fixture") {
      throw "RED: prompt lookup hidden nested write/read did not use the same control"
    }
    $script:promptLookupExecuted++
    Assert-PromptLookup $promptRoot 9905 ([IntPtr]::Zero) "missing id"
    if ([GraphCodeUiaGateState]::SetEditTextById($promptRoot, 9905, "wrong") -or
        $null -ne [GraphCodeUiaGateState]::EditTextById($promptRoot, 9905)) {
      throw "RED: prompt lookup missing id returned successful text"
    }
    $script:promptLookupExecuted++
    $direct = [PromptLookupFixture]::Create("EDIT", $promptRoot, 9904)
    Assert-PromptLookup $promptRoot 9904 $direct "direct-child precedence"
    $wrongRoot = New-PromptLookupRoot "STATIC"
    $wrongRootViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $wrongRoot, 0)
    $wrongRootContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $wrongRootViewport, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $wrongRootContent, 9904)
    Assert-PromptLookup $wrongRoot 9904 ([IntPtr]::Zero) "wrong root cannot opt in"
    $wrongContainerRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $wrongContainer = [PromptLookupFixture]::Create("STATIC", $wrongContainerRoot, 0)
    $wrongContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $wrongContainer, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $wrongContent, 9904)
    Assert-PromptLookup $wrongContainerRoot 9904 ([IntPtr]::Zero) "wrong viewport ignored"
    $namedViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $wrongContainerRoot, 0)
    $namedContainer = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $namedViewport, 0)
    Assert-PromptLookup $wrongContainerRoot 9904 ([IntPtr]::Zero) "same id in other sibling ignored"
    $deeper = [PromptLookupFixture]::Create("STATIC", $namedContainer, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $deeper, 9904)
    Assert-PromptLookup $wrongContainerRoot 9904 ([IntPtr]::Zero) "no deeper fallback"
    $deepRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $wrapper = [PromptLookupFixture]::Create("STATIC", $deepRoot, 0)
    $deepViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $wrapper, 0)
    $deepContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $deepViewport, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $deepContent, 9904)
    Assert-PromptLookup $deepRoot 9904 ([IntPtr]::Zero) "named viewport must be direct"
    $nativeRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $nativeViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $nativeRoot, 0)
    $nativeContent = [PromptLookupFixture]::Create("GraphCodeNativeForm", $nativeViewport, 0)
    $nativeEdit = [PromptLookupFixture]::Create("EDIT", $nativeContent, 9100)
    Assert-PromptLookup $nativeRoot 9100 $nativeEdit "exact named native-form content"
    $workspaceRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $workspaceViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $workspaceRoot, 0)
    $workspaceContent = [PromptLookupFixture]::Create("GraphCodeWorkspaceManager", $workspaceViewport, 0)
    $workspaceList = [PromptLookupFixture]::Create("LISTBOX", $workspaceContent, 9721)
    Assert-PromptLookup $workspaceRoot 9721 $workspaceList "exact named workspace-manager content"
    $unknownRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $unknownViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $unknownRoot, 0)
    $unknownContent = [PromptLookupFixture]::Create("GraphCodeUnknownSheetContent", $unknownViewport, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $unknownContent, 9100)
    Assert-PromptLookup $unknownRoot 9100 ([IntPtr]::Zero) "unknown content class cannot opt in"
    Assert-PromptLookup ([IntPtr]::Zero) 9904 ([IntPtr]::Zero) "null parent"
    if ($script:promptLookupExecuted -ne 14) { throw "RED: prompt lookup case count was not 14" }
    Write-Host "Prompt lookup hidden native cases: $script:promptLookupExecuted passed"
    $hitRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $hitViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $hitRoot, 0)
    [PromptLookupFixture]::Place($hitViewport, 0, 0, 400, 300)
    $hitContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $hitViewport, 0)
    [PromptLookupFixture]::Place($hitContent, 15, 20, 350, 250)
    $hitEdit = [PromptLookupFixture]::Create("EDIT", $hitContent, 9904)
    [PromptLookupFixture]::Place($hitEdit, 20, 25, 100, 24)
    $editBounds = [GraphCodeUiaGateState]::WindowBounds($hitEdit)
    $hitX = [int](($editBounds[0] + $editBounds[2])/2)
    $hitY = [int](($editBounds[1] + $editBounds[3])/2)
    if ([PromptLookupFixture]::IsWindowVisible($hitRoot) -or
        [GraphCodeMultiProjectRenameNative]::ChildAt($hitRoot,$hitX,$hitY) -ne $hitEdit) {
      throw "RED: prompt hit did not resolve nested edit in hidden named viewport"
    }
    $hitCases = 1
    $contentBounds = [GraphCodeUiaGateState]::WindowBounds($hitContent)
    if ([GraphCodeMultiProjectRenameNative]::ChildAt($hitRoot,$contentBounds[2]-10,$contentBounds[3]-10) -ne $hitContent) {
      throw "RED: prompt viewport background became an edit hit"
    }
    $hitCases++
    $plainRoot = New-PromptLookupRoot "STATIC"
    $plainViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $plainRoot, 0)
    $plainContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $plainViewport, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $plainContent, 9904)
    $plainBounds = [GraphCodeUiaGateState]::WindowBounds($plainContent)
    if ([GraphCodeMultiProjectRenameNative]::ChildAt($plainRoot,$plainBounds[0]+50,$plainBounds[1]+50) -ne $plainViewport) {
      throw "RED: prompt hit descended through wrong root class"
    }
    $hitCases++
    $otherRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $otherContent = [PromptLookupFixture]::Create("BUTTON", $otherRoot, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $otherContent, 9904)
    $otherBounds = [GraphCodeUiaGateState]::WindowBounds($otherContent)
    if ([GraphCodeMultiProjectRenameNative]::ChildAt($otherRoot,$otherBounds[0]+50,$otherBounds[1]+50) -ne $otherContent) {
      throw "RED: prompt hit descended through wrong container class"
    }
    $hitCases++
    $deepHitRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $deepHitViewport = [PromptLookupFixture]::Create("GraphCodeSheetViewport", $deepHitRoot, 0)
    [PromptLookupFixture]::Place($deepHitViewport, 0, 0, 400, 300)
    $deepHitContent = [PromptLookupFixture]::Create("GraphCodeWindowsDialogContent", $deepHitViewport, 0)
    $hitWrapper = [PromptLookupFixture]::Create("BUTTON", $deepHitContent, 0)
    $null = [PromptLookupFixture]::Create("EDIT", $hitWrapper, 9904)
    $deepBounds = [GraphCodeUiaGateState]::WindowBounds($hitWrapper)
    if ([GraphCodeMultiProjectRenameNative]::ChildAt($deepHitRoot,$deepBounds[0]+50,$deepBounds[1]+50) -ne $hitWrapper) {
      throw "RED: prompt hit recursively searched deeper descendants"
    }
    $hitCases++
    $directRoot = New-PromptLookupRoot "GraphCodeSheetHost"
    $directEdit = [PromptLookupFixture]::Create("EDIT", $directRoot, 9904)
    $directBounds = [GraphCodeUiaGateState]::WindowBounds($directEdit)
    if ([GraphCodeMultiProjectRenameNative]::ChildAt($directRoot,$directBounds[0]+50,$directBounds[1]+50) -ne $directEdit) {
      throw "RED: prompt hit changed existing direct-child behavior"
    }
    $hitCases++
    if ($hitCases -ne 6) { throw "RED: prompt hit case count was not 6" }
    Write-Host "Prompt hit hidden native cases: $hitCases passed"
  } finally {
    foreach ($window in $lookupRoots) {
      if (-not [PromptLookupFixture]::DestroyWindow($window)) {
        throw "Prompt lookup fixture cleanup failed for $window"
      }
    }
  }
  }
  Test-PromptControlLookup
  $goalCover = [int[][]]::new(1)
  $goalCover[0] = [int[]]@(84, 699, 763, 721)
  $goalRemainder = [GraphCodeUiaGateState]::SubtractCoveredRectangles(
    [int[]]@(667, 698, 763, 728), $goalCover)
  if ($goalRemainder.Count -ne 2 -or
      ($goalRemainder[0] -join ',') -ne '667,721,763,728') {
    throw "RED: node sheet rectangle subtraction misses the real seven-pixel uncovered Create band"
  }
  $twoCovers = [int[][]]::new(2)
  $twoCovers[0] = [int[]]@(84, 699, 763, 721)
  $twoCovers[1] = [int[]]@(667, 721, 715, 728)
  $twoRemainders = [GraphCodeUiaGateState]::SubtractCoveredRectangles(
    [int[]]@(667, 698, 763, 728), $twoCovers)
  if ($twoRemainders.Count -ne 2 -or
      ($twoRemainders[0] -join ',') -ne '715,721,763,728') {
    throw "RED: node sheet rectangle subtraction does not handle more than one covering control"
  }
  if ($shellTests -notmatch '(?s)Windows update feed executable tests.*?zig test src\\WindowsUpdates\.zig.*?-lwinhttp') {
    throw "RED: Windows shell validation does not run the native updater tests"
  }
  if ($runnerSource -notmatch '\$SkipWslRemoteE2E' -or
      $runnerSource -notmatch '"--skip-local-wsl"') {
    throw "RED: hosted validation cannot explicitly isolate unavailable local WSL fixtures"
  }
  $privacyRaceSource = Get-Content `
    (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1") -Raw
  if ($privacyRaceSource -notmatch '\$AvailableProcessorCount = \[Environment\]::ProcessorCount' -or
      $privacyRaceSource -notmatch '\$remoteProcessCount = 1' -or
      $privacyRaceSource -notmatch '\[Math\]::Min\(24, \[Math\]::Max\(4, \$processorCount \* 2\)\)' -or
      $privacyRaceSource -notmatch 'GRAPHCODE_REMOTE_BRIDGE_TEST_TIMEOUT_MULTIPLIER = "3"') {
    throw "RED: remote bridge privacy race does not scale bounded concurrency to runner capacity"
  }
  if ($windowsWorkflow -notmatch "(?s)environment:.*Hardening\.Tests\.ps1 -Environment -SchemaOnly") {
    throw "RED: environment CI does not invoke the exact schema-only hardening contract"
  }
  $macWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\macos-shared-regression.yml") -Raw
  if ($macWorkflow -notmatch "brew install mise" -or
      $macWorkflow -notmatch "mise install" -or
      $macWorkflow -notmatch "mise exec -- make test") {
    throw "RED: macOS CI does not install and execute pinned mise.toml tools"
  }
  $requiredWorkflows = [ordered]@{
    "macos-shared-regression.yml" = $macWorkflow
    "windows-shell.yml" = $windowsShellWorkflow
    "windows-port-validation.yml" = $windowsPortWorkflow
    "windows-hardening.yml" = $windowsWorkflow
  }
  foreach ($entry in $requiredWorkflows.GetEnumerator()) {
    $trigger = [regex]::Match(
      $entry.Value,
      '(?ms)^  pull_request:(?<settings>.*?)(?=^[^\s#]|^  [A-Za-z_][A-Za-z0-9_-]*:|\z)')
    $settings = [regex]::Replace($trigger.Groups["settings"].Value, '(?m)#.*$', '').Trim()
    if (-not $trigger.Success -or $settings -notin @("", "{}")) {
      throw "RED: $($entry.Key) must report required checks for every PR, including documentation-only changes"
    }
  }
} finally {
  Remove-Item -LiteralPath $foreignJunction -Recurse -Force -ErrorAction SilentlyContinue
}

$oldWinghosttyRoot = [Environment]::GetEnvironmentVariable(
  "GRAPHCODE_WINGHOSTTY_ROOT"
)
$oldZmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
try {
  $env:GRAPHCODE_WINGHOSTTY_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-winghostty-provider"
  $env:GRAPHCODE_ZMX_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-zmx-provider"
  & $pwsh -NoProfile -File $runner -Task terminal-gate *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "terminal-gate passed without its pinned providers"
  }
} finally {
  if ($null -eq $oldWinghosttyRoot) {
    Remove-Item Env:GRAPHCODE_WINGHOSTTY_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_WINGHOSTTY_ROOT = $oldWinghosttyRoot
  }
  if ($null -eq $oldZmxRoot) {
    Remove-Item Env:GRAPHCODE_ZMX_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_ZMX_ROOT = $oldZmxRoot
  }
}

$uiScenarioOutput = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot "UiScenario.Tests.ps1"))
if ($LASTEXITCODE -ne 0) { throw "RED: offline UI scenario contract child failed" }
$uiScenarioSummaries = @($uiScenarioOutput | Where-Object { $_ -is [string] -and $_.StartsWith('{"suite":"UiScenario",') })
if ($uiScenarioSummaries.Count -ne 1) { throw "RED: offline UI scenario structured count missing or duplicated" }
$uiScenarioSummary = ConvertFrom-Json $uiScenarioSummaries[0]
if ($uiScenarioSummary.executed -isnot [long] -or $uiScenarioSummary.executed -le 0 -or
    $uiScenarioSummary.passed -isnot [long] -or $uiScenarioSummary.passed -ne $uiScenarioSummary.executed -or
    $uiScenarioSummary.failed -isnot [long] -or $uiScenarioSummary.failed -ne 0) {
  throw "RED: offline UI scenario child has no positive executed/passed contract count"
}
$uiScenarioOutput | ForEach-Object { Write-Host $_ }

$uiCaptureRoot = Join-Path ([IO.Path]::GetTempPath()) ("g" + [guid]::NewGuid().ToString("N").Substring(0,8))
$null = New-Item -ItemType Directory -Path $uiCaptureRoot
$uiCapturePrebuilt = Join-Path $uiCaptureRoot "prebuilt"
$uiCapturePrepareOutput = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot "UiCaptureDriver.Tests.ps1") `
    -PrepareFixturesOnly -ScratchRoot $uiCapturePrebuilt)
if ($LASTEXITCODE -ne 0) { throw "RED: offline capture fixture preparation failed" }
$uiCaptureManifestPath = Join-Path $uiCapturePrebuilt "fixtures.json"
$uiCaptureManifestHash = (Get-FileHash -LiteralPath $uiCaptureManifestPath -Algorithm SHA256).Hash
$uiCaptureOutput = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot "UiCaptureDriver.Tests.ps1") `
    -ScratchRoot (Join-Path $uiCaptureRoot "suite") `
    -PrebuiltFixtureManifest $uiCaptureManifestPath -PrebuiltFixtureManifestSha256 $uiCaptureManifestHash)
$uiCaptureOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "RED: offline real-launch capture child failed" }
$uiCaptureSummaries = @($uiCaptureOutput | Where-Object { $_ -is [string] -and $_.StartsWith('{"suite":"UiCaptureDriver",') })
if ($uiCaptureSummaries.Count -ne 1) { throw "RED: offline real-launch capture structured count missing or duplicated" }
$uiCaptureSummary = ConvertFrom-Json $uiCaptureSummaries[0]
if ($uiCaptureSummary.executed -isnot [long] -or $uiCaptureSummary.executed -ne 182 -or
    $uiCaptureSummary.passed -isnot [long] -or $uiCaptureSummary.passed -ne $uiCaptureSummary.executed -or
    $uiCaptureSummary.failed -isnot [long] -or $uiCaptureSummary.failed -ne 0) {
  throw "RED: offline real-launch capture child has no positive executed/passed contract count"
}
if ($uiCaptureSummary.skipped -isnot [long] -or $uiCaptureSummary.skipped -ne 0) {throw 'RED: capture contract skips are not permitted'}
$uiCaptureReport=Get-Content -LiteralPath (Join-Path $uiCaptureRoot 'suite\report.json') -Raw | ConvertFrom-Json
$matchedGroups=@(
  'matched v12 fixture binds exact node type wiring reason and outcome fields',
  'matched v12 fixture refuses identity type wiring selection reason and outcome mutations',
  'matched v12 complete scene inventory is admitted and missing scenes refuse',
  'matched S tab actual worker seed write preserves scene path and not-created cleanup',
  'matched all eighteen scenes across both phases create write and clean isolated seed paths',
  'matched tab observations preserve exact owned IDs parents selection and close bounds',
  'real restart transcript requires daemon confirmation resume and new owned attach',
  'real restart scene invokes existing UIA route and refuses offline peer authority',
  'matched transparent proxy relays unchanged real pipe frames with connection identity',
  'matched manifest seals scene inventory and refuses premature restart success',
  'DPI matched geometry derives exact 96 and 192 physical frames',
  'DPI matched geometry refuses insufficient work area and invalid scaling',
  'DPI matched logical zoom normalizes physical UIA width',
  'DPI matched manifest preserves raw logical physical metadata without resampling'
)
foreach ($name in $matchedGroups) {
  $group=@($uiCaptureReport.cases | Where-Object name -CEQ $name)
  if ($group.Count -ne 1 -or $group[0].passed -cne $true) {
    throw "RED: matched capture group must pass exactly once: $name"
  }
}
$agentCommandOutput = @(& $pwsh -NoProfile -File (
    Join-Path $PSScriptRoot "Invoke-AgentCommand.Tests.ps1"))
$agentCommandSummary = "Invoke-AgentCommand.Tests.ps1: PASS; executed=6; cases=argument-stream-marker,zero-arguments,existing-console,existing-marker,parse-failure,child-nonzero"
if ($LASTEXITCODE -ne 0 -or $agentCommandOutput.Count -ne 1 -or
    ([string]$agentCommandOutput[0]) -cne $agentCommandSummary) {
  throw "RED: agent command contract failed or did not report exactly six cases: $($agentCommandOutput -join ' | ')"
}


Write-Host "ValidationRunner.Tests.ps1: PASS"
exit 0
