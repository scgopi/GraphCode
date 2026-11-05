function ConvertTo-CardsPilotCanonicalJson($value) {
  if ($null -eq $value) { return 'null' }
  if ($value -is [Collections.IDictionary]) {
    $keys = [string[]]@($value.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $parts = foreach ($key in $keys) {
      (ConvertTo-Json -InputObject $key -Compress) + ':' + (ConvertTo-CardsPilotCanonicalJson $value[$key])
    }
    return '{' + ($parts -join ',') + '}'
  }
  if ($value -is [array]) {
    return '[' + ((@($value | ForEach-Object { ConvertTo-CardsPilotCanonicalJson $_ })) -join ',') + ']'
  }
  return ConvertTo-Json -InputObject $value -Depth 50 -Compress
}

function Assert-CardsPilotTarget($graph, [string] $projectPath, [string] $nodeId, [string] $type) {
  if ($graph -isnot [Collections.IDictionary] -or $null -eq $graph.project -or
      [string]$graph.project.path -ine $projectPath -or $graph.nodes -isnot [array] -or $graph.nodes.Count -lt 1) {
    throw [InvalidOperationException]::new('CARDS_PILOT_TARGET: positive owned project snapshot required')
  }
  $nodes = @($graph.nodes | Where-Object { [string]$_.id -ieq $nodeId })
  if ($nodes.Count -ne 1 -or [string]$nodes[0].loopType -cne $type) {
    throw [InvalidOperationException]::new('CARDS_PILOT_TARGET: exact node identity/type required')
  }
  return $nodes[0]
}

function Assert-CardsPilotNoMutation($before, $after) {
  if ($before.nodes -isnot [array] -or $after.nodes -isnot [array] -or
      $before.nodes.Count -lt 1 -or $after.nodes.Count -lt 1 -or
      (ConvertTo-CardsPilotCanonicalJson $before) -cne (ConvertTo-CardsPilotCanonicalJson $after)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_MUTATION: invalid/cancel changed the positive saved graph')
  }
}

function Assert-CardsPilotRetype($before, $after, [string] $nodeId, [string] $targetType,
    [string] $decision) {
  $sourceType = if ($targetType -ceq 'timeBased') { 'goalBased' } else { 'timeBased' }
  $old = Assert-CardsPilotTarget $before ([string]$before.project.path) $nodeId $sourceType
  $new = Assert-CardsPilotTarget $after ([string]$before.project.path) $nodeId $targetType
  if (@($before.nodes).Count -ne @($after.nodes).Count -or
      [string]$before.id -cne [string]$after.id -or
      (ConvertTo-CardsPilotCanonicalJson $before.edges) -cne (ConvertTo-CardsPilotCanonicalJson $after.edges)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_TOPOLOGY: retype changed graph identity/count/edges')
  }
  foreach ($field in @('id','title','backend','modelTier','worktreeBinding','subGraph',
      'createdBy','createdAt','attachments','sessionRestarts','firstInstruction')) {
    if ($old.Contains($field) -ne $new.Contains($field) -or
        (ConvertTo-CardsPilotCanonicalJson $old[$field]) -cne (ConvertTo-CardsPilotCanonicalJson $new[$field])) {
      throw [InvalidOperationException]::new("CARDS_PILOT_CUSTODY: retype changed $field")
    }
  }
  foreach ($peer in @($before.nodes | Where-Object { [string]$_.id -ine $nodeId })) {
    $current = @($after.nodes | Where-Object { [string]$_.id -ieq [string]$peer.id })
    if ($current.Count -ne 1 -or
        (ConvertTo-CardsPilotCanonicalJson $peer) -cne (ConvertTo-CardsPilotCanonicalJson $current[0])) {
      throw [InvalidOperationException]::new('CARDS_PILOT_CUSTODY: non-target node changed')
    }
  }
  if ($targetType -ceq 'timeBased') {
    if ([string]$new.triggerPrompt -cne $decision -or $null -ne $new.goal) {
      throw [InvalidOperationException]::new('CARDS_PILOT_FIELDS: timed decision or preserved instruction differs')
    }
  } elseif ($targetType -ceq 'goalBased') {
    if ([string]$new.goal.summary -cne $decision -or $null -ne $new.triggerPrompt -or
        $new.goal.pollIntervalSeconds -ne 60 -or $new.goal.metricDirection -cne 'maximize' -or
        $new.goal.skipsUnchangedWorkspace -ne $false) {
      throw [InvalidOperationException]::new('CARDS_PILOT_FIELDS: goal decision/default fields or old timed prompt differs')
    }
  } else { throw [InvalidOperationException]::new('CARDS_PILOT_FIELDS: unsupported pilot target type') }
  $expectedState = if ($targetType -ceq 'goalBased') { 'running' } else { 'idle' }
  if ($new.state -isnot [Collections.IDictionary] -or $new.state.Count -ne 1 -or
      -not $new.state.Contains($expectedState)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_FIELDS: source-defined retype state differs')
  }
  return [ordered]@{ nodeId = $nodeId; sourceType = $sourceType; targetType = $targetType
    state = $expectedState; firstInstructionPreserved = $true
    nodes = @($after.nodes).Count; edges = @($after.edges).Count; decision = $decision; custodyPreserved = $true }
}

function Assert-CardsPilotPointer($hit, [int] $processId, [int] $controlId) {
  if ($null -eq $hit -or -not $hit.HitTarget -or -not $hit.SameTopLevel -or $hit.VisibleEmpty -or
      $hit.WindowAtPointProcessId -ne $processId -or $hit.ControlId -ne $controlId) {
    $failure=[InvalidOperationException]::new('CARDS_PILOT_POINTER: exact owned native control hit required; no fallback')
    try {
    $receipt=[ordered]@{
      expectedProcessId=$processId; expectedControlId=$controlId; hitAvailable=($null -ne $hit)
      controlId=$hit.ControlId; hitTarget=$hit.HitTarget; sameTopLevel=$hit.SameTopLevel
      visibleEmpty=$hit.VisibleEmpty; windowAtPointProcessId=$hit.WindowAtPointProcessId
      windowAtPointId=$hit.WindowAtPointId; realChildId=$hit.RealChildId
      rect=@($hit.Left,$hit.Top,$hit.Right,$hit.Bottom); point=@($hit.ScreenX,$hit.ScreenY)
      work=@($hit.WorkLeft,$hit.WorkTop,$hit.WorkRight,$hit.WorkBottom)
      outsideWorkArea=$hit.OutsideWorkArea; centerHitTarget=$hit.CenterHitTarget
      scanUsed=$hit.ScanUsed; scannedPoints=$hit.ScannedPoints; coveredPoints=$hit.CoveredPoints
      narrowUncovered=$hit.NarrowUncovered; coveringId=$hit.CoveringId
      coveringRect=@($hit.CoveringLeft,$hit.CoveringTop,$hit.CoveringRight,$hit.CoveringBottom)
      cursorBefore=@($hit.CursorBeforeX,$hit.CursorBeforeY); cursorAt=@($hit.CursorAtX,$hit.CursorAtY)
      coordinateSource='ClickScreenPoint native GetWindowRect/work-area intersection; not UIA bounds'
      inputCountsAvailable=$false
    }
    $failure.Data['CardsPilotPointerReceipt']=$receipt
    if ($null -ne $hit -and $hit.GetType().FullName -ceq 'GraphCodeUiaGateState+ControlClick') {
      $foreground=[GraphCodeUiaGateState]::CurrentForegroundWindow()
      $receipt['postRefusalForegroundOwned']=([GraphCodeUiaGateState]::WindowProcessId($foreground) -eq $processId)
      if ($receipt.postRefusalForegroundOwned) {
        $candidate=[GraphCodeUiaGateState]::ControlById($foreground,$controlId)
        if ($candidate -ne [IntPtr]::Zero -and
            [GraphCodeUiaGateState]::WindowProcessId($candidate) -eq $processId -and
            [GraphCodeUiaGateState]::IsControlOwnedBy($foreground,$candidate,$controlId)) {
          $receipt['postRefusalOwnedRoot']=$foreground.ToInt64()
          $receipt['postRefusalOwnedControl']=$candidate.ToInt64()
          $receipt['postRefusalOwnedNativeBounds']=[GraphCodeUiaGateState]::WindowBounds($candidate)
          $receipt['observationScope']='post-refusal current owned foreground/control; not original target-handle retention'
        }
      }
    }
    Write-Host ('CARDS_PILOT_POINTER_REFUSAL='+($receipt | ConvertTo-Json -Depth 4 -Compress))
    } catch {
      $failure.Data['CardsPilotPointerMetadataFailure']=$_.Exception.GetType().FullName
      Write-Warning 'Owned pointer-refusal metadata failed; preserving the original pointer error' -WarningAction Continue
    }
    throw $failure
  }
}

function Assert-CardsPilotMembers([int[]] $members, [int[]] $expected, [bool] $requirePositive = $true) {
  $known = [Collections.Generic.HashSet[int]]::new()
  foreach ($id in $expected) {
    if ($id -le 0 -or -not $known.Add($id)) { throw 'CARDS_PILOT_ISOLATION: invalid expected held identities' }
  }
  $actual = [Collections.Generic.HashSet[int]]::new()
  foreach ($id in $members) {
    if ($id -le 0) { throw 'CARDS_PILOT_ISOLATION: invalid native member identity' }
    [void]$actual.Add($id)
  }
  if (($requirePositive -and $known.Count -eq 0) -or -not $actual.SetEquals($known)) {
    throw 'CARDS_PILOT_ISOLATION: unique native members differ from exact held roots'
  }
  return [ordered]@{ rawCount=$members.Count; uniqueCount=$actual.Count; expectedCount=$known.Count }
}

function Assert-CardsPilotLeafAccounting($snapshot) {
  if ($snapshot.completionKind -ceq 'original-native-exit-empty-private-job-drained') {
    if ($snapshot.total -lt 1 -or $snapshot.active -ne 0 -or $snapshot.expectedActive -ne 0 -or
        @($snapshot.rawMembers).Count -ne 0 -or $snapshot.rootIdentityVerified -ne $true -or
        $snapshot.heldExitVerified -ne $true -or $snapshot.privateJobEmptyBeforeFinalize -ne $true -or
        $snapshot.readersDrained -ne $true -or
        $snapshot.retiredUnobserved -ne ($snapshot.total - 1 - $snapshot.observedCompanions) -or
        $snapshot.retiredUnobserved -lt 0 -or
        ($snapshot.retiredUnobserved -gt 0 -and $snapshot.retiredIdentityCoverage -cne 'UNOBSERVED')) {
      throw 'CARDS_PILOT_ISOLATION: original native root/private-job/readers completion unproved'
    }
    return
  }
  $companions = if ($null -ne $snapshot.observedCompanions) { [int]$snapshot.observedCompanions } else { 0 }
  $rootActive = if ($null -ne $snapshot.rootActiveCount) { [int]$snapshot.rootActiveCount } else { $snapshot.expectedActive }
  if ($null -eq $snapshot -or $companions -notin @(0,1) -or $snapshot.total -ne (1 + $companions) -or
      $rootActive -notin @(0,1) -or $snapshot.expectedActive -notin @(0,1,2) -or $snapshot.active -ne $snapshot.expectedActive -or
      $snapshot.rootIdentityVerified -ne $true -or
      ($rootActive -eq 0 -and $snapshot.heldExitVerified -ne $true)) {
    throw 'CARDS_PILOT_ISOLATION: private launch accounting contains unexpected descendants or lost authority'
  }
}

function Assert-CardsConsoleIdentity($candidate, $trusted, [int] $rootPid, [long] $rootCreation, [long] $job) {
  if ($null -eq $trusted -or $trusted.signatureStatus -cne 'Valid' -or
      $trusted.signerSubject -cne 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -or
      -not [string]::Equals([string]$trusted.path,(Join-Path ([Environment]::SystemDirectory) 'conhost.exe'),
        [StringComparison]::OrdinalIgnoreCase) -or
      $candidate.pid -le 0 -or $candidate.pid -eq $rootPid -or $candidate.creationUtcTicks -le $rootCreation -or
      $candidate.job -ne $job -or $candidate.name -cne 'conhost' -or
      -not [IO.Path]::IsPathFullyQualified([string]$candidate.imagePath) -or
      -not [string]::Equals([IO.Path]::GetFullPath([string]$candidate.imagePath),
        [IO.Path]::GetFullPath([string]$trusted.path),[StringComparison]::OrdinalIgnoreCase) -or
      $candidate.sha256 -cne $trusted.sha256 -or $candidate.signatureStatus -cne 'Valid' -or
      $candidate.signerThumbprint -cne $trusted.signerThumbprint) {
    throw 'CARDS_PILOT_ISOLATION: console companion native/protected Windows identity differs'
  }
}

function Wait-CardsPilotCliOriginalExit($run, [long] $elapsedMilliseconds) {
  if ($elapsedMilliseconds -lt 0 -or $elapsedMilliseconds -ge 15000) {
    throw 'CARDS_PILOT_CLI: original 15-second native exit deadline expired or invalid'
  }
  $run.RequireExited([int](15000 - $elapsedMilliseconds))
}

function Read-CardsPilotLaunchAccounting($run, [Diagnostics.Stopwatch] $cliClock = $null) {
  if ($run.LaunchJobClosed -or $run.LaunchJob -eq [IntPtr]::Zero) {
    throw 'CARDS_PILOT_ISOLATION: private job authority already closed'
  }
  $exited = $run.Process.HasExited
  $heldExit = $false
  if ($exited) {
    if ($null -ne $cliClock) {
      Wait-CardsPilotCliOriginalExit $run $cliClock.ElapsedMilliseconds
      $remaining = 15000 - [int]$cliClock.ElapsedMilliseconds
      if ($remaining -le 0) { throw 'CARDS_PILOT_CLI: original private-job exit deadline expired' }
      [GraphCode.Validation.Ownership.StandaloneProcessJob]::WaitForEmpty($run.LaunchJob,$remaining)
    }
    else { $run.RequireExited(0) }
    $heldExit = $true
  }
  $summary = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Summary($run.LaunchJob)
  if ($summary -notmatch '^total=(\d+); active=(\d+);') { throw 'CARDS_PILOT_ISOLATION: invalid private accounting' }
  $total = [int]$Matches[1]; $active = [int]$Matches[2]
  $expected = [Collections.Generic.List[int]]::new()
  if (-not $exited) { $expected.Add($run.Process.Id) }
  $members = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Members($run.LaunchJob)
  $identity = if ($exited) { $heldExit } else {
    [GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($run.LaunchJob,$run.Handle)
  }
  $rootCreation = $run.Process.StartTime.ToUniversalTime().Ticks
  $nativeIdentities = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Processes($run.LaunchJob)
  $snapshot = [ordered]@{ pid=$run.Process.Id; job=$run.LaunchJob.ToInt64(); rawSummary=$summary
    rootHandle=$run.Handle.ToInt64(); creationFileTime=$run.Process.StartTime.ToUniversalTime().ToFileTimeUtc()
    total=$total; active=$active; expectedActive=$expected.Count; rawMembers=$members
    rootIdentityVerified=$identity; heldExitVerified=$heldExit
    nativeOwnedIdentities=$nativeIdentities }
  Write-Host ('CARDS_PILOT_PRIVATE_JOB_RAW=' + ($snapshot | ConvertTo-Json -Depth 8 -Compress))
  foreach ($record in @($nativeIdentities -split ' \| ' | Where-Object { $_ })) {
    if ($record -notmatch '^pid=(\d+); creationUtcTicks=(\d+); name=([^;]+); imagePath=(.+)$') {
      throw 'CARDS_PILOT_ISOLATION: native identity receipt incomplete'
    }
    $pidValue=[int]$Matches[1]; $creation=[long]$Matches[2]; $name=$Matches[3]; $path=$Matches[4]
    if ($pidValue -eq $run.Process.Id) {
      if ($creation -ne $rootCreation) { throw 'CARDS_PILOT_ISOLATION: original root creation changed' }
      continue
    }
    if ($null -eq $run.PSObject.Properties['CardsConsoleExpected'] -or $run.CardsConsoleExpected -ne $true -or
        $null -eq $script:CardsConsoleIdentity -or
        -not [string]::Equals($path,[string]$script:CardsConsoleIdentity.path,[StringComparison]::OrdinalIgnoreCase)) {
      throw 'CARDS_PILOT_ISOLATION: undeclared native child image'
    }
    $candidate = [ordered]@{ pid=$pidValue; creationUtcTicks=$creation; name=$name; imagePath=$path
      job=$run.LaunchJob.ToInt64(); sha256=(Get-FileHash -LiteralPath $script:CardsConsoleIdentity.path -Algorithm SHA256).Hash
      signatureStatus=$script:CardsConsoleIdentity.signatureStatus; signerThumbprint=$script:CardsConsoleIdentity.signerThumbprint }
    Assert-CardsConsoleIdentity $candidate $script:CardsConsoleIdentity $run.Process.Id $rootCreation $run.LaunchJob.ToInt64()
    if ($null -ne $run.PSObject.Properties['CardsConsoleCompanion'] -and
        ($run.CardsConsoleCompanion.pid -ne $pidValue -or $run.CardsConsoleCompanion.creationUtcTicks -ne $creation)) {
      throw 'CARDS_PILOT_ISOLATION: third or replaced companion process'
    }
    $run | Add-Member -NotePropertyName CardsConsoleCompanion -NotePropertyValue $candidate -Force
    $expected.Add($pidValue)
  }
  $snapshot.observedCompanions = if ($null -ne $run.PSObject.Properties['CardsConsoleCompanion']) { 1 } else { 0 }
  $snapshot.rootActiveCount = if ($exited) { 0 } else { 1 }
  $snapshot.expectedActive = $expected.Count
  $snapshot.liveExpectedMembers = $expected.ToArray()
  $snapshot.companion = if ($snapshot.observedCompanions) { $run.CardsConsoleCompanion } else { $null }
  $snapshot.uniqueMembers = Assert-CardsPilotMembers $members $expected.ToArray() $false
  if ($exited -and $null -ne $cliClock) {
    if ($total -lt 1 -or $active -ne 0 -or $members.Count -ne 0 -or -not $heldExit) {
      throw 'CARDS_PILOT_ISOLATION: original CLI exit/private-job emptiness unproved'
    }
    $snapshot.completionKind = 'native-exit-empty-job-readers-pending'
    $snapshot.privateJobEmptyBeforeFinalize = $true
    $snapshot.readersDrained = $false
    $snapshot.retiredUnobserved = $total - 1 - $snapshot.observedCompanions
    $snapshot.retiredIdentityCoverage = if ($snapshot.retiredUnobserved -gt 0) { 'UNOBSERVED' } else { 'observed-live' }
  } else { Assert-CardsPilotLeafAccounting $snapshot }
  if ($null -eq $run.PSObject.Properties['CardsPrivateAccountingInitial']) {
    $run | Add-Member -NotePropertyName CardsPrivateAccountingInitial -NotePropertyValue $snapshot
  }
  $run | Add-Member -NotePropertyName CardsPrivateAccounting -NotePropertyValue $snapshot -Force
  Write-Host ('CARDS_PILOT_PRIVATE_JOB=' + ($snapshot | ConvertTo-Json -Depth 8 -Compress))
  return $snapshot
}

function Assert-CardsPilotBackendFixture($parent) {
  if ([string]$parent.pilotState -cne 'notPiloted' -or
      $null -eq $parent.subGraph -or @($parent.subGraph.nodes).Count -ne 2) {
    throw 'CARDS_PILOT_ISOLATION: unpiloted two-child backend fixture required'
  }
  foreach ($child in $parent.subGraph.nodes) {
    if ($child.state -isnot [Collections.IDictionary] -or $child.state.Count -ne 1 -or
        -not $child.state.Contains('idle')) {
      throw 'CARDS_PILOT_ISOLATION: child backend fixture is not idle'
    }
  }
}

function Assert-CardsPilotIsolation($scope, $plan, [string] $phase) {
  $summary = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Summary($scope.Job)
  if ($summary -notmatch '^total=(\d+); active=(\d+);') { throw 'CARDS_PILOT_ISOLATION: invalid held job accounting' }
  $liveRuns = @($scope.Runs | Where-Object { -not $_.Process.HasExited })
  if ($scope.Closed -or $scope.Runs.Count -lt 5) { throw 'CARDS_PILOT_ISOLATION: positive open held scope required' }
  $expected = [Collections.Generic.List[int]]::new()
  foreach ($run in $scope.Runs) {
    if (-not $run.Finalized -and -not $run.Process.HasExited -and
        -not [GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($scope.Job,$run.Handle)) {
      throw 'CARDS_PILOT_ISOLATION: original held root lost scope membership'
    }
    if (-not $run.Finalized) { $null = Read-CardsPilotLaunchAccounting $run }
    if ($null -eq $run.PSObject.Properties['CardsPrivateAccounting']) {
      throw 'CARDS_PILOT_ISOLATION: finalized root has no private cumulative accounting receipt'
    }
    Assert-CardsPilotLeafAccounting $run.CardsPrivateAccounting
    if (-not $run.Finalized) {
      foreach ($id in $run.CardsPrivateAccounting.liveExpectedMembers) { $expected.Add($id) }
    }
  }
  $members = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Members($scope.Job)
  $unique = Assert-CardsPilotMembers $members $expected.ToArray()
  $graph = Read-CardsPilotGraph $plan.support $plan.project
  $parents = @($graph.nodes | Where-Object { [string]$_.id -ieq $plan.containingComposite })
  if ($parents.Count -ne 1 -or [string]$parents[0].pilotState -cne 'notPiloted') {
    throw 'CARDS_PILOT_ISOLATION: containing composite was piloted/armed or changed identity'
  }
  if ($phase -ceq 'before-gui') { Assert-CardsPilotBackendFixture $parents[0] }
  if (-not [string]::IsNullOrEmpty([string]$plan.childGraphId) -and
      [string]$parents[0].subGraph.id -ine [string]$plan.childGraphId) {
    throw 'CARDS_PILOT_ISOLATION: owned child graph identity changed'
  }
  foreach ($directory in @((Join-Path $plan.support 'sessions'), (Join-Path $plan.root 'profile\zmx\ipc'))) {
    if ((Test-Path -LiteralPath $directory) -and
        @(Get-ChildItem -LiteralPath $directory -Force -Recurse -File).Count -gt 0) {
      throw "CARDS_PILOT_ISOLATION: unexpected provider/session state in $directory"
    }
  }
  Write-Host ('CARDS_PILOT_ISOLATION=' + ([ordered]@{ phase=$phase; rawScopeSummary=$summary
    scopeJob=$scope.Job.ToInt64(); rawMembers=$members; uniqueMembers=$unique
    expectedRoots=$scope.Runs.Count; privateAccountingReceipts=$scope.Runs.Count
    unexpectedUniqueMembers=0; sessionFiles=0; localProject=$plan.project } | ConvertTo-Json -Depth 8 -Compress))
}

function Complete-CardsPilotOutcome([AllowNull()][Exception] $primary, [Exception[]] $cleanupErrors,
    [int] $expectedCases, [int] $actualCases) {
  if ($cleanupErrors.Count -gt 0) {
    $errors = [Collections.Generic.List[Exception]]::new()
    if ($primary) { $errors.Add($primary) }
    foreach ($error in $cleanupErrors) { $errors.Add($error) }
    throw [AggregateException]::new('CARDS_PILOT_CLEANUP: retained owned roots require inspection',
      [Exception[]]$errors.ToArray())
  }
  if ($primary) { throw $primary }
  if ($expectedCases -lt 1 -or $actualCases -ne $expectedCases) {
    throw [InvalidOperationException]::new('CARDS_PILOT_COUNT: exact positive executed effects required')
  }
}

function Read-CardsPilotGraph([string] $support, [string] $projectPath, [string] $containingComposite = '',
    [string] $expectedChildGraphId = '') {
  $directory = Join-Path $support 'projects'
  if (-not (Test-Path -LiteralPath $directory)) { return $null }
  $matches = @(foreach ($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.json') {
    $graph = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json -AsHashtable
    if ([IO.Path]::IsPathFullyQualified([string]$graph.project.path) -and
        [string]::Equals([IO.Path]::GetFullPath([string]$graph.project.path),
          [IO.Path]::GetFullPath($projectPath),[StringComparison]::OrdinalIgnoreCase)) { ,$graph }
  })
  if ($matches.Count -gt 1) { throw 'CARDS_PILOT_READBACK: duplicate saved project identity' }
  if ($matches.Count -eq 1) {
    if ([string]::IsNullOrEmpty($containingComposite)) { return $matches[0] }
    $parents = @($matches[0].nodes | Where-Object { [string]$_.id -ieq $containingComposite })
    $childId = [Guid]::Empty
    if ($parents.Count -ne 1 -or [string]$parents[0].loopType -cne 'proactive' -or
        [string]$parents[0].pilotState -cne 'notPiloted' -or $null -eq $parents[0].subGraph -or
        -not [Guid]::TryParse([string]$parents[0].subGraph.id,[ref]$childId) -or
        (-not [string]::IsNullOrEmpty($expectedChildGraphId) -and
          [string]$parents[0].subGraph.id -ine $expectedChildGraphId)) {
      throw 'CARDS_PILOT_READBACK: containing composite/child identity or unpiloted state changed'
    }
    return $parents[0].subGraph
  }
  return $null
}

function Wait-CardsPilotState([scriptblock] $read, [string] $label, [int] $timeout = 15000) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt $timeout) {
    $value = & $read
    if ($null -ne $value -and $value -isnot [bool]) { return $value }
    if ($value -is [bool] -and $value) { return $true }
    Start-Sleep -Milliseconds 50
  }
  throw "CARDS_PILOT_TIMEOUT: $label"
}

function New-CardsPilotStartInfo([string] $file, [string[]] $arguments, [hashtable] $environment,
    [string] $workingDirectory) {
  $info = [Diagnostics.ProcessStartInfo]::new($file)
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.WorkingDirectory = $workingDirectory
  foreach ($name in $environment.Keys) { $info.Environment[$name] = [string]$environment[$name] }
  foreach ($name in @($info.Environment.Keys)) {
    if ($name.StartsWith('GRAPHCODE_UIA_', [StringComparison]::Ordinal) -or
        $name -in @('GRAPHCODE_DAEMON_STARTUP_EVENT','GRAPHCODE_DAEMON_HANDOFF_READY_EVENT',
          'GRAPHCODE_DAEMON_HANDOFF_TEST_STATE','GRAPHCODE_DAEMON_SUPERVISOR_TEST_HOOK',
          'GRAPHCODE_GATE_CWD','GRAPHCODE_SHELL_SESSION_PREFIX','ZMX_SESSION_PREFIX','ZMX_DIR','ZMX_SESSION')) {
      [void]$info.Environment.Remove($name)
    }
  }
  foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
  return $info
}

function Invoke-CardsPilotCli($scope, $plan, [hashtable] $environment, [string[]] $arguments,
    [string] $label) {
  $info = New-CardsPilotStartInfo $plan.cli $arguments $environment $plan.root
  $exitClock = [Diagnostics.Stopwatch]::StartNew()
  $process = Start-ShellOwnedProcess $scope $info
  $runs = @($scope.Runs | Where-Object { [object]::ReferenceEquals($_.Process,$process) })
  if ($runs.Count -ne 1) { throw 'CARDS_PILOT_CLI: exact retained launch record absent' }
  $runs[0] | Add-Member -NotePropertyName CardsConsoleExpected -NotePropertyValue $true
  $null = Wait-CardsPilotState {
    $sample = Read-CardsPilotLaunchAccounting $runs[0] $exitClock
    return $sample.heldExitVerified
  } "CLI $label original native exit/private job" (15000 - [int]$exitClock.ElapsedMilliseconds)
  $null = Read-CardsPilotLaunchAccounting $runs[0] $exitClock
  Complete-ShellOwnedProcess $scope $process
  $completed = $runs[0].CardsPrivateAccounting
  $completed.readersDrained = $runs[0].Finalized -and $runs[0].LaunchJobClosed
  $completed.completionKind = 'original-native-exit-empty-private-job-drained'
  Assert-CardsPilotLeafAccounting $completed
  Write-Host ('CARDS_PILOT_CLI_COMPLETION=' + ($completed | ConvertTo-Json -Depth 8 -Compress))
  $stdout = Read-ShellOwnedOutput $scope $process
  $stderr = Read-ShellOwnedOutput $scope $process -StandardError
  [IO.File]::WriteAllText((Join-Path $plan.root "$label-stdout.log"), $stdout, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $plan.root "$label-stderr.log"), $stderr, [Text.UTF8Encoding]::new($false))
  if ($process.ExitCode -ne 0) { throw "CARDS_PILOT_CLI: $label exit=$($process.ExitCode): $stderr" }
  Write-Host "CARDS_PILOT_CLI=$label exit=0"
}

function Assert-CardsZipFixture($graph, [string] $containerId) {
  if ($graph -isnot [Collections.IDictionary] -or @($graph.nodes).Count -ne 1 -or
      @($graph.edges).Count -ne 0) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: one owned containing Composite required')
  }
  $parent = $graph.nodes[0]
  if ([string]$parent.id -ine $containerId -or $parent.loopType -cne 'proactive' -or
      $parent.pilotState -cne 'notPiloted' -or $parent.createdBy -or $null -eq $parent.subGraph -or
      @($parent.subGraph.nodes).Count -ne 2 -or @($parent.subGraph.edges).Count -ne 1 -or
      @($parent.subGraph.nodes | Where-Object loopType -CEQ 'goalBased').Count -ne 1 -or
      @($parent.subGraph.nodes | Where-Object loopType -CEQ 'sketch').Count -ne 1) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: export must carry the unpiloted Composite, not a bare Goal')
  }
  foreach ($node in @($parent) + @($parent.subGraph.nodes)) {
    if ($node.state -isnot [Collections.IDictionary] -or $node.state.Count -ne 1 -or
        -not $node.state.Contains('idle') -or -not $node.Contains('sessionRestarts') -or
        $node.sessionRestarts -ne 0) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: all fixture nodes must be idle with zero session restarts')
    }
  }
  return $parent
}

function Assert-CardsZipImport($before, $after, [string] $goalId, [string] $containerId, $sourceParent) {
  if ($before -isnot [Collections.IDictionary] -or $after -isnot [Collections.IDictionary] -or
      @($before.nodes).Count -ne 2 -or @($before.edges).Count -ne 1 -or
      @($after.nodes).Count -ne 3 -or @($after.edges).Count -ne 2 -or
      [string]$before.id -ine [string]$after.id -or
      (ConvertTo-CardsPilotCanonicalJson $before.project) -cne (ConvertTo-CardsPilotCanonicalJson $after.project)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: containing child graph identity or direct 3-node/2-edge result differs')
  }
  foreach ($node in $before.nodes) {
    $current = @($after.nodes | Where-Object { [string]$_.id -ieq [string]$node.id })
    if ($current.Count -ne 1 -or
        (ConvertTo-CardsPilotCanonicalJson $node) -cne (ConvertTo-CardsPilotCanonicalJson $current[0])) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: existing child custody or payload changed')
    }
  }
  $oldEdge = $before.edges[0]
  $keptEdge = @($after.edges | Where-Object { [string]$_.id -ieq [string]$oldEdge.id })
  if ($keptEdge.Count -ne 1 -or
      (ConvertTo-CardsPilotCanonicalJson $oldEdge) -cne (ConvertTo-CardsPilotCanonicalJson $keptEdge[0])) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original internal edge changed')
  }
  $oldIds = @($before.nodes | ForEach-Object { [string]$_.id })
  $arriving = @($after.nodes | Where-Object { [string]$_.id -notin $oldIds })
  if ($arriving.Count -ne 1 -or $arriving[0].loopType -cne 'proactive' -or
      $arriving[0].pilotState -cne 'notPiloted' -or $arriving[0].createdBy -or $null -eq $arriving[0].subGraph -or
      @($arriving[0].subGraph.nodes).Count -ne 2 -or @($arriving[0].subGraph.edges).Count -ne 1) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: imported Composite must retain its nested two-node/one-edge graph')
  }
  $imported = $arriving[0]
  if ($null -eq $sourceParent) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original exported Composite payload is missing')
  }
  $null=Assert-CardsZipFixture @{nodes=@($sourceParent);edges=@()} ([string]$sourceParent.id)
  $sourceGraph=$sourceParent.subGraph
  $sourceEdge=$sourceGraph.edges[0]
  foreach ($field in @('title','loopType','backend','modelTier','firstInstruction','goal',
      'triggerPrompt','summary','usage','metricHistory')) {
    if ((ConvertTo-CardsPilotCanonicalJson $sourceParent[$field]) -cne
        (ConvertTo-CardsPilotCanonicalJson $imported[$field])) {
      throw [InvalidOperationException]::new("CARDS_PILOT_ZIP: imported Composite payload changed: $field")
    }
  }
  $freshIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $oldIdentities = @($containerId,[string]$before.id,[string]$oldEdge.id,
    [string]$sourceParent.id,[string]$sourceGraph.id,[string]$sourceEdge.id) + $oldIds +
    @($sourceGraph.nodes|ForEach-Object {[string]$_.id})
  $spawn = @($after.edges | Where-Object { [string]$_.id -ine [string]$oldEdge.id })
  if ($spawn.Count -ne 1) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: exactly one fresh selected-child spawn edge required')
  }
  foreach ($identity in @([string]$imported.id,[string]$imported.subGraph.id,
      [string]$imported.subGraph.edges[0].id,[string]$spawn[0].id) +
      @($imported.subGraph.nodes | ForEach-Object { [string]$_.id })) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($identity,[ref]$parsed) -or $identity -in $oldIdentities -or
        -not $freshIds.Add($identity)) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: imported identities were not remapped uniquely at every depth')
    }
  }
  $mapping = @{ ([string]$sourceParent.id) = [string]$imported.id }
  foreach ($node in $sourceGraph.nodes) {
    $match = @($imported.subGraph.nodes | Where-Object { $_.loopType -ceq $node.loopType })
    if ($match.Count -ne 1) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: nested node types differ')
    }
    $mapping[[string]$node.id] = [string]$match[0].id
    foreach ($field in @('title','loopType','backend','modelTier','firstInstruction','goal',
        'triggerPrompt','summary','usage','metricHistory')) {
      if ((ConvertTo-CardsPilotCanonicalJson $node[$field]) -cne
          (ConvertTo-CardsPilotCanonicalJson $match[0][$field])) {
        throw [InvalidOperationException]::new("CARDS_PILOT_ZIP: nested node payload changed: $field")
      }
    }
  }
  foreach ($node in @($imported) + @($imported.subGraph.nodes)) {
    if ($node.state -isnot [Collections.IDictionary] -or $node.state.Count -ne 1 -or
        -not $node.state.Contains('idle') -or $node.sessionRestarts -ne 0) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: imported child template is not idle')
    }
  }
  foreach ($node in $sourceGraph.nodes) {
    $match = @($imported.subGraph.nodes | Where-Object { [string]$_.id -ieq $mapping[[string]$node.id] })[0]
    $expectedCreator = if ($node.createdBy -and $mapping.ContainsKey([string]$node.createdBy)) {
      $mapping[[string]$node.createdBy]
    } else { $null }
    if ([string]$match.createdBy -ine [string]$expectedCreator) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: nested custody identity was not remapped')
    }
  }
  $nestedEdge = $imported.subGraph.edges[0]
  if ([string]$nestedEdge.from -ine $mapping[[string]$sourceEdge.from] -or
      [string]$nestedEdge.to -ine $mapping[[string]$sourceEdge.to] -or
      $spawn.Count -ne 1 -or [string]$spawn[0].from -ine $goalId -or
      [string]$spawn[0].to -ine [string]$imported.id -or $spawn[0].kind -cne 'spawn') {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: nested internal edge or selected-child spawn edge differs')
  }
  foreach ($field in @('kind','condition')) {
    if ((ConvertTo-CardsPilotCanonicalJson $nestedEdge[$field]) -cne
        (ConvertTo-CardsPilotCanonicalJson $sourceEdge[$field])) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: nested internal edge semantics changed')
    }
  }
  return [ordered]@{
    directNodes=3; directEdges=2; recursiveNodes=5; recursiveEdges=3
    importedCompositeId=[string]$imported.id; identityMapping=$mapping
    existingCustodyPreserved=$true; nestedCustodyRemapped=$true
  }
}

function Assert-CardsZipQuiescence($snapshot) {
  if ($null -eq $snapshot -or $snapshot.heldRootMember -ne $true -or
      $snapshot.rootActive -ne $true -or $snapshot.expectedBirth -le 0 -or
      $snapshot.observedBirth -ne $snapshot.expectedBirth -or
      $snapshot.statusComplete -ne $true -or $snapshot.effectVerified -ne $true -or
      $snapshot.drainError -ne $false -or $snapshot.active -lt 1 -or
      $snapshot.total -lt $snapshot.active) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: held live GUI identity or completed transfer/effect proof is missing')
  }
  $expected = [Collections.Generic.HashSet[int]]::new()
  $actual = [Collections.Generic.HashSet[int]]::new()
  foreach ($id in $snapshot.expectedMembers) {
    if ($id -le 0 -or -not $expected.Add($id)) {
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: invalid known live GUI/companion identities')
    }
  }
  foreach ($id in $snapshot.activeMembers) {
    if ($id -le 0) { throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: invalid active member') }
    [void]$actual.Add($id)
  }
  if ($expected.Count -notin @(1,2) -or $actual.Count -ne $snapshot.active -or
      -not $actual.SetEquals($expected)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: current active set contains an unclassified member or lost GUI')
  }
  return [ordered]@{
    proofKind='LIVEQUIESCENCE'; rawTotal=$snapshot.total; active=$snapshot.active
    activeMembers=@($actual); historicalRetiredCount=($snapshot.total-$snapshot.active)
    retiredIdentityCoverage='UNOBSERVED'; originalRootCompletion=$false
  }
}

function Read-CardsZipQuiescence($scope, $plan, $process, $completedTransfer) {
  Require ($plan.kind -ceq 'cards-zip-pilot' -and $scope -and -not $scope.Closed -and
    $completedTransfer.statusMatched -eq $true -and $completedTransfer.effectVerified -eq $true) `
    'CARDS_PILOT_ZIP: ZIP-only completed-transfer proof required'
  $gui = @($scope.Runs | Where-Object { $_.Process.Id -eq $process.Id })
  Require ($gui.Count -eq 1 -and -not $gui[0].Finalized -and -not $gui[0].LaunchJobClosed) `
    'CARDS_PILOT_ZIP: original held GUI authority unavailable'
  $gui = $gui[0]
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new([long]$completedTransfer.ownerWindow))
  $status = Find-FragmentById $root 'status' ([System.Windows.Automation.TreeWalker]::RawViewWalker)
  Require ($status -and $status.Current.ProcessId -eq $process.Id -and
    ($status.Current.Name -ceq $completedTransfer.status -or
      $status.Current.Name.StartsWith('Composite group opened',[StringComparison]::Ordinal))) `
    'CARDS_PILOT_ZIP: normal transfer status was replaced by an unproved or failed operation'
  $initial = $gui.CardsPrivateAccountingInitial
  $summary = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Summary($gui.LaunchJob)
  Require ($summary -match '^total=(\d+); active=(\d+);') 'CARDS_PILOT_ZIP: invalid raw GUI job summary'
  $total = [int]$Matches[1]; $active = [int]$Matches[2]
  $members = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Members($gui.LaunchJob)
  $identities = [GraphCode.Validation.Ownership.StandaloneProcessJob]::Processes($gui.LaunchJob)
  $classified = [Collections.Generic.List[int]]::new()
  $birth = 0L
  foreach ($record in @($identities -split ' \| ' | Where-Object { $_ })) {
    Require ($record -match '^pid=(\d+); creationUtcTicks=(\d+); name=([^;]+); imagePath=(.+)$') `
      'CARDS_PILOT_ZIP: current original-job member identity unavailable'
    $id=[int]$Matches[1]; $created=[long]$Matches[2]; $name=$Matches[3]; $path=$Matches[4]
    if ($id -eq $process.Id) {
      Require ([string]::Equals($path,$plan.shell,[StringComparison]::OrdinalIgnoreCase)) `
        'CARDS_PILOT_ZIP: original GUI image differs'
      $birth=$created
    } else {
      $known=$gui.CardsConsoleCompanion
      Require ($known -and $known.pid -eq $id -and $known.creationUtcTicks -eq $created) `
        'CARDS_PILOT_ZIP: unclassified active descendant; no adoption'
      $candidate=[ordered]@{ pid=$id; creationUtcTicks=$created; name=$name; imagePath=$path
        job=$gui.LaunchJob.ToInt64(); sha256=(Get-FileHash -LiteralPath $script:CardsConsoleIdentity.path -Algorithm SHA256).Hash
        signatureStatus=$script:CardsConsoleIdentity.signatureStatus; signerThumbprint=$script:CardsConsoleIdentity.signerThumbprint }
      Assert-CardsConsoleIdentity $candidate $script:CardsConsoleIdentity $process.Id `
        ([DateTime]::FromFileTimeUtc($initial.creationFileTime).Ticks) $gui.LaunchJob.ToInt64()
    }
    $classified.Add($id)
  }
  $snapshot=[ordered]@{
    total=$total; active=$active; activeMembers=$members; expectedMembers=$classified.ToArray()
    rootActive=($process.Id -in $members)
    heldRootMember=([GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($gui.LaunchJob,$gui.Handle) -and
      [GraphCode.Validation.Ownership.StandaloneProcessJob]::Contains($scope.Job,$gui.Handle))
    expectedBirth=[DateTime]::FromFileTimeUtc($initial.creationFileTime).Ticks; observedBirth=$birth
    statusComplete=$completedTransfer.statusMatched; effectVerified=$completedTransfer.effectVerified
    drainError=$completedTransfer.drainError
  }
  $verdict=Assert-CardsZipQuiescence $snapshot
  $expected=[Collections.Generic.List[int]]::new()
  foreach ($id in $classified) { $expected.Add($id) }
  foreach ($run in $scope.Runs | Where-Object { $_ -ne $gui }) {
    if (-not $run.Finalized) { $null=Read-CardsPilotLaunchAccounting $run }
    Assert-CardsPilotLeafAccounting $run.CardsPrivateAccounting
    foreach ($id in $run.CardsPrivateAccounting.liveExpectedMembers) { $expected.Add($id) }
  }
  $null=Assert-CardsPilotMembers `
    ([GraphCode.Validation.Ownership.StandaloneProcessJob]::Members($scope.Job)) $expected.ToArray()
  $graph=Read-CardsPilotGraph $plan.support $plan.project
  $parent=@($graph.nodes | Where-Object { [string]$_.id -ieq $plan.containingComposite })
  Require ($parent.Count -eq 1 -and $parent[0].pilotState -ceq 'notPiloted' -and
    [string]$parent[0].subGraph.id -ieq [string]$plan.childGraphId) `
    'CARDS_PILOT_ZIP: original unpiloted containing graph changed'
  foreach ($directory in @((Join-Path $plan.support 'sessions'),(Join-Path $plan.root 'profile\zmx\ipc'))) {
    Require (-not (Test-Path -LiteralPath $directory) -or
      @(Get-ChildItem -LiteralPath $directory -Force -Recurse -File).Count -eq 0) `
      'CARDS_PILOT_ZIP: unexpected provider/session files'
  }
  Write-Host ('CARDS_PILOT_ZIP_QUIESCENCE=' + ([ordered]@{
    verdict=$verdict; rawSummary=$summary; rawMembers=$members; nativeIdentities=$identities
    originalHandle=$gui.Handle.ToInt64(); originalJob=$gui.LaunchJob.ToInt64()
    transferStatus=$completedTransfer.status; proofLimit='LIVEQUIESCENCE, not root exit or lifetime child/backend identity coverage'
  } | ConvertTo-Json -Depth 8 -Compress))
  return $verdict
}

function Open-CardsZipPicker($process, $root, [IntPtr] $window, [string] $cardId,
    [string] $cardTitle, [int] $command) {
  Require ($command -in @(5123,5124)) 'CARDS_PILOT_ZIP: unsupported picker command'
  $title = if ($command -eq 5123) { 'Export Loop' } else { 'Import Loops Here' }
  $popup = Open-CardsPilotCardMenu $process $root $window $cardId $cardTitle $title
  $entry = @(Get-PopupMenuItems $popup | Where-Object { $_.Id -eq $command -and $_.Enabled })
  Require ($entry.Count -eq 1) 'CARDS_PILOT_ZIP: exact enabled ZIP menu entry absent'
  $hit = [GraphCodeUiaGateState]::ClickPopupMenuItemStrict($popup,$window,
    [int]$entry[0].Position,$command,[uint32]$process.Id)
  Require ($hit.ItemId -eq $command -and -not $hit.UsedKeyboardFallback -and
    -not $hit.UsedSelectItemFallback) 'CARDS_PILOT_ZIP: strict native ZIP menu route required'
  $picker = Get-CardsPilotModal $process $title
  Require ([GraphCodeUiaGateState]::WindowClass($picker) -ceq '#32770' -and
    [GraphCodeUiaGateState]::WindowOwner($picker) -eq $window -and
    -not [GraphCodeUiaGateState]::WindowIsEnabled($window)) `
    'CARDS_PILOT_ZIP: exact owned native modal picker required'
  Write-Host ('CARDS_PILOT_ZIP_PICKER=' + ([ordered]@{
    processId=$process.Id; owner=$window.ToInt64(); picker=$picker.ToInt64()
    title=$title; command=$command; nativeMenuHit=$hit
  } | ConvertTo-Json -Depth 6 -Compress))
  return $picker
}

function Assert-CardsZipFilenameIdentity($snapshot, [int] $expectedId=1001) {
  if ($expectedId -notin @(1001,1148) -or
      $snapshot.expectedProcessId -le 0 -or $snapshot.hostProcessId -ne $snapshot.expectedProcessId -or
      $snapshot.processId -ne $snapshot.expectedProcessId -or $snapshot.count -ne 1 -or
      $snapshot.handle -le 0 -or $snapshot.controlId -ne $expectedId -or $snapshot.class -cne 'Edit' -or
      $snapshot.nativeOwned -ne $true -or [string]::IsNullOrWhiteSpace($snapshot.runtime) -or
      [string]::IsNullOrWhiteSpace($snapshot.hostRuntime) -or
      $snapshot.runtime -cne $snapshot.expectedRuntime -or
      $snapshot.hostRuntime -cne $snapshot.expectedHostRuntime) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: filename scope, native identity or RuntimeID changed')
  }
}

function Get-CardsPickerNavigationBudget([long] $caseElapsed, [long] $controlElapsed) {
  if ($caseElapsed -lt 0 -or $controlElapsed -lt 0 -or $caseElapsed -ge 10000 -or $controlElapsed -ge 5000) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: original case/control deadline expired before input')
  }
  return [int][Math]::Min(5000-$controlElapsed,10000-$caseElapsed)
}

function Get-CardsPickerInputDisposition([int] $attempted, [int] $completed, [bool] $failed) {
  if ($attempted -lt 0 -or $completed -lt 0 -or $completed -gt $attempted) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: invalid chord phase accounting; input disposition is unproved')
  }
  $emission=if($attempted -eq 0){'NOT_ATTEMPTED'}
    elseif($completed -eq $attempted){'COMPLETE_BATCHES_ONLY'}else{'ATTEMPTED_UNRESOLVED'}
  return [ordered]@{
    chordCallsAttempted=$attempted;chordCallsCompleted=$completed
    policyInputBarrier=($failed -or $attempted -gt $completed)
    modifierEmissionDisposition=$emission;possiblyHeldModifierUnresolved=($attempted -gt $completed)
    proofLimit='Call phases and complete guarded batches only; no universal physical keyboard-state assertion'
  }
}

function Select-CardsPickerAddressBand($shape, [uint32] $processId, [IntPtr] $picker) {
  if ($processId -eq 0 -or $picker -eq [IntPtr]::Zero -or
      $shape.processId -ne $processId -or $shape.picker -ne $picker.ToInt64() -or
      $shape.queuedNodesOmitted -ne $false -or [string]::IsNullOrWhiteSpace($shape.rootRuntimeBefore) -or
      $shape.rootRuntimeBefore -cne $shape.rootRuntimeAfter) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: bounded raw address scope was truncated or its original root changed')
  }
  $candidates=@($shape.controls|Where-Object {$_.automationId -ceq '41477' -and
    $_.class -ceq 'Address Band Root' -and $_.role -ceq 'ControlType.Pane' -and $_.controlId -eq 41477})
  if ($candidates.Count -ne 1 -or $candidates[0].nativeWindow -le 0 -or
      $candidates[0].processId -ne $processId -or $candidates[0].nativeProcessId -ne $processId -or
      $candidates[0].nativeRootOwned -ne $true -or [string]::IsNullOrWhiteSpace($candidates[0].runtime) -or
      [string]::IsNullOrWhiteSpace($candidates[0].nativeClass)) {
    $failure=[InvalidOperationException]::new('CARDS_PILOT_NAV: exact owned raw address band absent, ambiguous or changed')
    $failure.Data['CandidateCount']=$candidates.Count
    throw $failure
  }
  return $candidates[0]
}

function Assert-CardsPickerAddressIdentity($s) {
  if ($s.expectedProcessId -le 0 -or $s.expectedPicker -le 0 -or $s.picker -ne $s.expectedPicker -or
      $s.rootProcessId -ne $s.expectedProcessId -or $s.rootClass -cne '#32770' -or
      $s.rootVisible -ne $true -or $s.rootEnabled -ne $true -or
      [string]::IsNullOrWhiteSpace($s.expectedRootRuntime) -or $s.rootRuntime -cne $s.expectedRootRuntime -or
      $s.expectedBandHandle -le 0 -or $s.bandHandle -ne $s.expectedBandHandle -or
      $s.bandId -ne 41477 -or $s.bandClass -cne 'Address Band Root' -or
      [string]::IsNullOrWhiteSpace($s.expectedBandNativeClass) -or $s.bandNativeClass -cne $s.expectedBandNativeClass -or
      $s.bandProcessId -ne $s.expectedProcessId -or $s.bandNativeOwned -ne $true -or
      [string]::IsNullOrWhiteSpace($s.expectedBandRuntime) -or $s.bandRuntime -cne $s.expectedBandRuntime -or
      $s.expectedEditHandle -le 0 -or $s.editHandle -ne $s.expectedEditHandle -or
      $null -eq $s.editId -or $s.editId -ne $s.expectedEditId -or $s.editClass -cne 'Edit' -or
      $s.editProcessId -ne $s.expectedProcessId -or $s.editNativeOwned -ne $true -or
      [string]::IsNullOrWhiteSpace($s.expectedEditRuntime) -or $s.editRuntime -cne $s.expectedEditRuntime -or
      $s.focusedHandle -ne $s.editHandle -or $s.exactBandAncestor -ne $true) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: exact owned root/address band/focused Edit identity changed')
  }
}

function Assert-CardsPickerAddressEnter($s, [string] $ownPath) {
  Assert-CardsPickerAddressIdentity $s
  $null=Get-CardsPickerNavigationBudget $s.caseElapsed $s.controlElapsed
  if (-not [IO.Path]::IsPathFullyQualified($ownPath) -or
      [string]::IsNullOrWhiteSpace($s.buffer) -or $s.buffer -cne $ownPath) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: Enter requires exact full owned-path native readback')
  }
}

function Assert-CardsPickerFolderView($s, [string] $ownPath) {
  if (-not [IO.Path]::IsPathFullyQualified($ownPath) -or
      $s.expectedProcessId -le 0 -or $s.processId -ne $s.expectedProcessId -or
      $s.nativeOwned -ne $true -or $s.viewClass -cne 'UIItemsView' -or
      [string]::IsNullOrWhiteSpace($s.runtime) -or $s.hostClass -cne 'DUIListView' -or
      $s.hostId -ne 1121 -or $s.hostNativeOwned -ne $true -or
      $s.markerCount -ne 1 -or $s.markerProcessId -ne $s.expectedProcessId -or
      $s.markerVisible -ne $true -or $s.markerRole -cne 'ControlType.ListItem' -or
      [string]::IsNullOrWhiteSpace($s.markerRuntime) -or $s.exactKnownMarker -ne $true -or
      $s.navigationEntered -ne $true -or $s.addressBuffer -cne $ownPath) {
    throw [InvalidOperationException]::new('CARDS_PILOT_NAV: actual owned view marker and current-folder address are unproved')
  }
}

function Get-CardsPickerAddressState($process, [IntPtr] $picker, $binding) {
  [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,[IntPtr]::Zero)
  $dialog=[System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $band=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$binding.expectedBandHandle)
  $focus=[GraphCodeUiaGateState]::FocusedControlInDialog($picker)
  $edit=[System.Windows.Automation.AutomationElement]::FromHandle($focus)
  Require ($dialog.Current.ProcessId -eq $process.Id -and $band.Current.ProcessId -eq $process.Id -and
    $edit.Current.ProcessId -eq $process.Id) 'CARDS_PILOT_NAV: UIA root/band/Edit process changed'
  $runtime=$edit.GetRuntimeId() -join ','
  $bandRuntime=$band.GetRuntimeId() -join ','
  $ancestor=$edit;$reachesBand=$false
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  for($depth=0;$ancestor -and $depth -lt 12;$depth++) {
    Require ($ancestor.Current.ProcessId -eq $process.Id) 'CARDS_PILOT_NAV: foreign address ancestor'
    if ($ancestor.Current.NativeWindowHandle -eq $binding.expectedBandHandle -and
        ($ancestor.GetRuntimeId() -join ',') -ceq $binding.expectedBandRuntime) { $reachesBand=$true;break }
    if ($ancestor.Current.NativeWindowHandle -eq $picker.ToInt64()) { break }
    $ancestor=$walker.GetParent($ancestor)
  }
  if ($binding.expectedEditHandle -eq 0 -and
      ([GraphCodeUiaGateState]::WindowClass($focus) -cne 'Edit' -or -not $reachesBand)) { return $null }
  $id=[GraphCodeUiaGateState]::ControlIdOf($focus)
  $s=@{
    expectedProcessId=$process.Id;picker=$picker.ToInt64();expectedPicker=$binding.expectedPicker
    rootProcessId=[GraphCodeUiaGateState]::WindowProcessId($picker);rootClass=[GraphCodeUiaGateState]::WindowClass($picker)
    rootRuntime=($dialog.GetRuntimeId() -join ',');expectedRootRuntime=$binding.expectedRootRuntime
    rootVisible=[GraphCodeUiaGateState]::WindowIsVisible($picker)
    rootEnabled=[GraphCodeUiaGateState]::WindowIsEnabled($picker)
    bandHandle=[long]$band.Current.NativeWindowHandle;expectedBandHandle=$binding.expectedBandHandle
    bandId=[GraphCodeUiaGateState]::ControlIdOf([IntPtr]$binding.expectedBandHandle)
    bandClass=$band.Current.ClassName
    bandNativeClass=[GraphCodeUiaGateState]::WindowClass([IntPtr]$binding.expectedBandHandle)
    expectedBandNativeClass=$binding.expectedBandNativeClass
    bandProcessId=[GraphCodeUiaGateState]::WindowProcessId([IntPtr]$binding.expectedBandHandle)
    bandNativeOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,[IntPtr]$binding.expectedBandHandle,41477)
    bandRuntime=$bandRuntime;expectedBandRuntime=$binding.expectedBandRuntime
    editHandle=$focus.ToInt64();editId=$id;editClass=[GraphCodeUiaGateState]::WindowClass($focus)
    editProcessId=[GraphCodeUiaGateState]::WindowProcessId($focus);editNativeOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,$focus,$id)
    editRuntime=$runtime;focusedHandle=[GraphCodeUiaGateState]::FocusedControlInDialog($picker).ToInt64()
    exactBandAncestor=$reachesBand
    expectedEditHandle=$(if($binding.expectedEditHandle -eq 0){$focus.ToInt64()}else{$binding.expectedEditHandle})
    expectedEditId=$(if($binding.expectedEditHandle -eq 0){$id}else{$binding.expectedEditId})
    expectedEditRuntime=$(if($binding.expectedEditHandle -eq 0){$runtime}else{$binding.expectedEditRuntime})
  }
  Assert-CardsPickerAddressIdentity $s
  return $s
}

function Assert-CardsPickerBareZipBasename([string] $name) {
  if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('..') -or
      $name -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]*\.zip\z' -or
      $name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: native filename must be an unambiguous bare ZIP basename')
  }
}

function Select-CardsPickerNativeFilename($shape, [uint32] $processId, [IntPtr] $picker, [switch] $Importing) {
  $null=Select-CardsPickerAddressBand $shape $processId $picker
  $outer=$null
  if($Importing){
    $outers=@($shape.controls|Where-Object {$_.automationId -ceq '1148' -and $_.class -ceq 'ComboBoxEx32'})
    if($outers.Count -ne 1){throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: exact Open filename outer absent or ambiguous')}
    $outer=$outers[0]
    if($outer.parent -ne 0 -or $outer.role -cne 'ControlType.Pane' -or
        $outer.nativeClass -cne 'ComboBoxEx32' -or $outer.controlId -ne 1148){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: exact Open filename outer fields or root relation changed')
    }
    $hosts=@($shape.controls|Where-Object {$_.parent -eq $outer.index -and $_.automationId -ceq '1148'})
  }else{
    $hosts=@($shape.controls|Where-Object {$_.automationId -ceq 'FileNameControlHost'})
  }
  if($hosts.Count -ne 1){throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: exact raw filename host absent or ambiguous')}
  $hostRow=$hosts[0]
  $editId=if($Importing){1148}else{1001}
  $hostId=if($Importing){1148}else{0}
  $hostClass=if($Importing){'ComboBox'}else{'AppControlHost'}
  $edits=@($shape.controls|Where-Object {$_.parent -eq $hostRow.index -and $_.automationId -ceq [string]$editId})
  if($edits.Count -ne 1){throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: exact raw filename child absent or ambiguous')}
  $editRow=$edits[0]
  foreach($row in @($hostRow,$editRow)+$(if($Importing){@($outer)}else{@()})){
    if($row.nativeWindow -le 0 -or $row.processId -ne $processId -or $row.nativeProcessId -ne $processId -or
        $row.nativeRootOwned -ne $true -or [string]::IsNullOrWhiteSpace($row.runtime)){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: raw filename host/child ownership changed')
    }
  }
  if($hostRow.class -cne $hostClass -or $hostRow.nativeClass -cne 'ComboBox' -or
      $hostRow.role -cne 'ControlType.ComboBox' -or $hostRow.controlId -ne $hostId -or
      $editRow.class -cne 'Edit' -or $editRow.nativeClass -cne 'Edit' -or
      $editRow.role -cne 'ControlType.Edit' -or $editRow.controlId -ne $editId){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: raw native filename fields or roles changed')
  }
  return @{host=$hostRow;edit=$editRow;outer=$outer;importing=[bool]$Importing
    picker=$picker.ToInt64();rootRuntime=$shape.rootRuntimeAfter}
}

function Assert-CardsPickerNativeFilenameState($s, [bool] $requireFocus) {
  $importing=($s.importing -is [bool] -and $s.importing)
  $editId=if($importing){1148}else{1001}
  $hostClass=if($importing){'ComboBox'}else{'AppControlHost'}
  Assert-CardsZipFilenameIdentity $s $editId
  if($s.handle -ne $s.expectedHandle -or $s.nativeClass -cne 'Edit' -or
      $s.nativeProcessId -ne $s.expectedProcessId -or $s.role -cne 'ControlType.Edit' -or
      $s.hostClass -cne $hostClass -or $s.hostNativeClass -cne 'ComboBox' -or
      $s.hostRole -cne 'ControlType.ComboBox' -or
      $s.hostNativeOwned -ne $true -or $s.picker -le 0 -or $s.picker -ne $s.expectedPicker -or
      $s.rootProcessId -ne $s.expectedProcessId -or $s.rootClass -cne '#32770' -or
      [string]::IsNullOrWhiteSpace($s.expectedRootRuntime) -or $s.rootRuntime -cne $s.expectedRootRuntime -or
      $s.rootVisible -ne $true -or $s.rootEnabled -ne $true -or
      ($requireFocus -and $s.focusedHandle -ne $s.handle)){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original native filename root/host/Edit/focus changed')
  }
  if($importing){
    $outer=$s.outer
    if($null -eq $outer -or $outer.nativeWindow -le 0 -or $outer.nativeWindow -ne $outer.expectedHandle -or
        $outer.class -cne 'ComboBoxEx32' -or $outer.nativeClass -cne 'ComboBoxEx32' -or
        $outer.role -cne 'ControlType.Pane' -or $outer.controlId -ne 1148 -or
        $outer.processId -ne $s.expectedProcessId -or $outer.nativeProcessId -ne $s.expectedProcessId -or
        $outer.nativeOwned -ne $true -or $outer.nativeRootChild -ne $true -or $outer.hostParentVerified -ne $true -or
        [string]::IsNullOrWhiteSpace($outer.expectedRuntime) -or $outer.runtime -cne $outer.expectedRuntime){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original Open filename outer/root/host identity changed')
    }
  }
}

function Assert-CardsPickerNativeFilenameValue($s, [string] $basename, $channels=$null) {
  Assert-CardsPickerBareZipBasename $basename
  Assert-CardsPickerNativeFilenameState $s $true
  $hostExact=($s.hostBuffer -ceq $basename)
  if($s.importing -eq $true){
    $hostExact=($hostExact -or $s.hostBuffer -ceq '')
    if($channels.uiaHostValueAvailable -ne $true -or $channels.uiaHostMatchesSuggested -ne $true -or
        $channels.uiaHostMatchesChild -ne $true){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: Open native child requires independent advertised semantic host full-name agreement')
    }
  }
  if($s.buffer -cne $basename -or -not $hostExact){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: native filename child and host readbacks differ from the owned basename')
  }
}

function Test-CardsPickerNativeFilenameReady($s, [string] $basename, $channels) {
  Assert-CardsPickerBareZipBasename $basename
  Assert-CardsPickerNativeFilenameState $s $true
  if($s.buffer -isnot [string] -or $s.hostBuffer -isnot [string] -or
      -not $basename.StartsWith($s.buffer,[StringComparison]::Ordinal) -or
      -not $basename.StartsWith($s.hostBuffer,[StringComparison]::Ordinal) -or
      ($s.importing -eq $true -and $s.hostBuffer -cne '' -and $s.hostBuffer -cne $basename) -or
      $channels.uiaHostValueAvailable -ne $true -or $channels.uiaHostIsExpectedPrefix -ne $true){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: unexpected non-prefix native or semantic filename readback')
  }
  $ready=($s.buffer -ceq $basename -and
    ($s.hostBuffer -ceq $basename -or ($s.importing -eq $true -and $s.hostBuffer -ceq '')) -and
    $channels.uiaHostMatchesSuggested -eq $true)
  if($ready){Assert-CardsPickerNativeFilenameValue $s $basename $channels}
  return $ready
}

function Get-CardsPickerNativeFilenameState($process, [IntPtr] $picker, $binding, [bool] $requireFocus) {
  [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,[IntPtr]::Zero)
  $dialog=[System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $hostHandle=[IntPtr]$binding.host.nativeWindow;$editHandle=[IntPtr]$binding.edit.nativeWindow
  $hostElement=[System.Windows.Automation.AutomationElement]::FromHandle($hostHandle)
  $editElement=[System.Windows.Automation.AutomationElement]::FromHandle($editHandle)
  $importing=($binding.importing -is [bool] -and $binding.importing)
  $editId=if($importing){1148}else{1001}
  $hostId=if($importing){1148}else{0}
  $hostAutomationId=if($importing){'1148'}else{'FileNameControlHost'}
  $outerState=$null
  if($importing){
    $outerHandle=[IntPtr]$binding.outer.nativeWindow
    $outerElement=[System.Windows.Automation.AutomationElement]::FromHandle($outerHandle)
    $outerParent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($outerElement)
    $hostParent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hostElement)
    Require ($null -ne $outerParent -and $null -ne $hostParent -and
      $outerParent.Current.ProcessId -eq $process.Id -and $outerParent.Current.NativeWindowHandle -eq $picker.ToInt64() -and
      ($outerParent.GetRuntimeId() -join ',') -ceq $binding.rootRuntime -and
      $outerElement.Current.AutomationId -ceq '1148' -and $hostParent.Current.ProcessId -eq $process.Id -and
      $hostParent.Current.NativeWindowHandle -eq $outerHandle.ToInt64() -and
      ($hostParent.GetRuntimeId() -join ',') -ceq $binding.outer.runtime) `
      'CARDS_PILOT_ZIP: original Open filename root/outer/host relation changed'
    $outerState=@{nativeWindow=$outerHandle.ToInt64();expectedHandle=$binding.outer.nativeWindow;class=$outerElement.Current.ClassName
      nativeClass=[GraphCodeUiaGateState]::WindowClass($outerHandle);role=$outerElement.Current.ControlType.ProgrammaticName
      controlId=[GraphCodeUiaGateState]::ControlIdOf($outerHandle);processId=$outerElement.Current.ProcessId
      nativeProcessId=[GraphCodeUiaGateState]::WindowProcessId($outerHandle)
      nativeOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,$outerHandle,1148)
      nativeRootChild=([GraphCodeUiaGateState]::ControlById($picker,1148) -eq $outerHandle)
      hostParentVerified=$true;runtime=($outerElement.GetRuntimeId() -join ',');expectedRuntime=$binding.outer.runtime}
  }
  $parent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($editElement)
  Require ($null -ne $parent -and $parent.Current.ProcessId -eq $process.Id -and
    $parent.Current.NativeWindowHandle -eq $hostHandle.ToInt64() -and
    ($parent.GetRuntimeId() -join ',') -ceq $binding.host.runtime -and
    $hostElement.Current.AutomationId -ceq $hostAutomationId -and
    $editElement.Current.AutomationId -ceq [string]$editId -and
    [GraphCodeUiaGateState]::WindowProcessId($hostHandle) -eq $process.Id -and
    [GraphCodeUiaGateState]::ControlById($hostHandle,$editId) -eq $editHandle) `
    'CARDS_PILOT_ZIP: original native filename parent/child relation changed'
  $s=@{importing=$importing;outer=$outerState;expectedProcessId=$process.Id;hostProcessId=$hostElement.Current.ProcessId
    processId=$editElement.Current.ProcessId;count=1;handle=$editHandle.ToInt64()
    expectedHandle=$binding.edit.nativeWindow;controlId=[GraphCodeUiaGateState]::ControlIdOf($editHandle)
    class=$editElement.Current.ClassName;nativeClass=[GraphCodeUiaGateState]::WindowClass($editHandle)
    role=$editElement.Current.ControlType.ProgrammaticName
    nativeProcessId=[GraphCodeUiaGateState]::WindowProcessId($editHandle)
    nativeOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,$editHandle,$editId)
    runtime=($editElement.GetRuntimeId() -join ',');expectedRuntime=$binding.edit.runtime
    hostRuntime=($hostElement.GetRuntimeId() -join ',');expectedHostRuntime=$binding.host.runtime
    hostClass=$hostElement.Current.ClassName;hostNativeClass=[GraphCodeUiaGateState]::WindowClass($hostHandle)
    hostRole=$hostElement.Current.ControlType.ProgrammaticName
    hostNativeOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,$hostHandle,$hostId)
    picker=$picker.ToInt64();expectedPicker=$binding.picker
    rootProcessId=[GraphCodeUiaGateState]::WindowProcessId($picker);rootClass=[GraphCodeUiaGateState]::WindowClass($picker)
    rootRuntime=($dialog.GetRuntimeId() -join ',');expectedRootRuntime=$binding.rootRuntime
    rootVisible=[GraphCodeUiaGateState]::WindowIsVisible($picker);rootEnabled=[GraphCodeUiaGateState]::WindowIsEnabled($picker)
    focusedHandle=[GraphCodeUiaGateState]::FocusedControlInDialog($picker).ToInt64()}
  Assert-CardsPickerNativeFilenameState $s $requireFocus
  return $s
}

function Get-CardsPickerFilenameReadbackMetadata([string] $child, [string] $nativeHost,
    [string] $uiaHost, [bool] $uiaAvailable, [string] $expected) {
  $stem=[IO.Path]::GetFileNameWithoutExtension($expected)
  return [ordered]@{
    childLength=$child.Length;childEmpty=[string]::IsNullOrEmpty($child)
    childMatchesSuggested=($child -ceq $expected);childMatchesSuggestedStem=($child -ceq $stem)
    nativeHostLength=$nativeHost.Length;nativeHostEmpty=[string]::IsNullOrEmpty($nativeHost)
    nativeHostMatchesSuggested=($nativeHost -ceq $expected);nativeHostMatchesChild=($nativeHost -ceq $child)
    nativeHostMatchesSuggestedStem=($nativeHost -ceq $stem)
    uiaHostValueAvailable=$uiaAvailable;uiaHostLength=$uiaHost.Length
    uiaHostIsExpectedPrefix=($uiaAvailable -and $expected.StartsWith($uiaHost,[StringComparison]::Ordinal))
    uiaHostMatchesSuggested=($uiaAvailable -and $uiaHost -ceq $expected)
    uiaHostMatchesChild=($uiaAvailable -and $uiaHost -ceq $child)
  }
}

function Read-CardsPickerFilenameMetadata($process, [IntPtr] $picker, $binding,
    [string] $child, [string] $nativeHost, [string] $expected) {
  $state=Get-CardsPickerNativeFilenameState $process $picker $binding $true
  $hostElement=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$binding.host.nativeWindow)
  $advertised=@($hostElement.GetSupportedPatterns()|Where-Object {
    $_.Id -eq [System.Windows.Automation.ValuePattern]::Pattern.Id})
  Require ($advertised.Count -le 1) 'CARDS_PILOT_ZIP: filename host advertises duplicate value patterns'
  $value=$null;$available=$false;$text=''
  if($advertised.Count -eq 1){
    $available=$hostElement.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)
    Require $available 'CARDS_PILOT_ZIP: advertised host read-only value getter unavailable'
    $text=$value.Current.Value
  }
  $null=Get-CardsPickerNativeFilenameState $process $picker $binding $true
  return [ordered]@{processId=$process.Id;picker=$picker.ToInt64();rootRuntime=$state.rootRuntime
    host=$binding.host.nativeWindow;hostRuntime=$state.hostRuntime;hostClass=$state.hostClass
    nativeHostClass=$state.hostNativeClass;control=$state.handle;controlId=$state.controlId
    editRuntime=$state.runtime;nativeEditClass=$state.nativeClass;exactOwnedFocus=$true
    channels=(Get-CardsPickerFilenameReadbackMetadata $child $nativeHost $text $available $expected)
    actualTextRetained=$false
    proofLimit='Native WM_GETTEXT results and advertised read-only UIA host value are distinct; not filename input qualification'}
}

function Assert-CardsPickerInitialFilename([string] $child, [string] $nativeHost, [string] $suggested, $channels) {
  Assert-CardsPickerBareZipBasename $suggested
  $stem=[IO.Path]::GetFileNameWithoutExtension($suggested)
  if(($child -cne $suggested -and $child -cne $stem) -or $nativeHost -cne $child -or
      $channels.uiaHostValueAvailable -ne $true -or $channels.uiaHostMatchesChild -ne $true){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: source-derived initial bare suggested name differs')
  }
  return $(if($child -ceq $suggested){'fullSuggested'}else{'sourceStem'})
}

function Assert-CardsPickerAbsentOutputs([string] $root, [string] $wanted, [string] $suggested) {
  Assert-CardsPickerBareZipBasename $wanted
  Assert-CardsPickerBareZipBasename $suggested
  if(-not [IO.Path]::IsPathFullyQualified($root) -or [IO.Path]::GetFullPath($root) -cne $root -or
      -not [IO.Directory]::Exists($root) -or
      ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: output candidates require the exact non-reparse owned folder')
  }
  $names=@($wanted,[IO.Path]::GetFileNameWithoutExtension($wanted),
    $suggested,[IO.Path]::GetFileNameWithoutExtension($suggested))
  $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($name in $names){
    if(-not $unique.Add($name) -or $name -match '[. ]\z' -or
        (Test-Path -LiteralPath (Join-Path $root $name))){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: wanted/default full-name or stem output is ambiguous or already exists')
    }
  }
  return $unique.Count
}

function Test-CardsZipNativeExportOnly($plan) {
  return ($plan.kind -ceq 'cards-zip-pilot' -and $plan.caseCount -eq 1 -and
    -not $plan.PSObject.Properties['nativeImportOnly'] -and
    $plan.PSObject.Properties['nativeExportOnly'] -and $plan.nativeExportOnly -is [bool] -and
    $plan.nativeExportOnly -eq $true)
}

function Test-CardsZipNativeImportOnly($plan) {
  return ($plan.kind -ceq 'cards-zip-pilot' -and $plan.caseCount -eq 1 -and
    -not $plan.PSObject.Properties['nativeExportOnly'] -and
    $plan.PSObject.Properties['nativeImportOnly'] -and $plan.nativeImportOnly -is [bool] -and
    $plan.nativeImportOnly -eq $true)
}

function Assert-CardsPickerOwnedInput([string] $root, [string] $wanted, [string] $suggested, [string] $sha256) {
  Assert-CardsPickerBareZipBasename $wanted
  Assert-CardsPickerBareZipBasename $suggested
  if(-not [IO.Path]::IsPathFullyQualified($root) -or [IO.Path]::GetFullPath($root) -cne $root -or
      -not [IO.Directory]::Exists($root) -or
      ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      $sha256 -cnotmatch '^[0-9A-F]{64}$'){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: input archive requires the exact owned non-reparse folder and sealed hash')
  }
  $path=Join-Path $root $wanted
  if(-not [IO.File]::Exists($path) -or
      ([IO.File]::GetAttributes($path) -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -ne 0 -or
      ([IO.FileInfo]::new($path)).Length -le 0 -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $sha256){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original owned input archive is missing, replaced or changed')
  }
  $names=@($wanted,[IO.Path]::GetFileNameWithoutExtension($wanted),
    $suggested,[IO.Path]::GetFileNameWithoutExtension($suggested))
  $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($name in $names){
    if(-not $unique.Add($name) -or $name -match '[. ]\z' -or
        ($name -cne $wanted -and (Test-Path -LiteralPath (Join-Path $root $name)))){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: owned input full/default/stem candidates are ambiguous')
    }
  }
  return 3
}

function Assert-CardsPickerNativeFileScope($plan) {
  $basename=[IO.Path]::GetFileName([string]$plan.zipPath)
  Require ((Join-Path $plan.root $basename) -ceq [string]$plan.zipPath) 'CARDS_PILOT_ZIP: native file escaped the owned folder'
  if(Test-CardsZipNativeImportOnly $plan){
    return Assert-CardsPickerOwnedInput $plan.root $basename $plan.initialSuggestedBasename $plan.nativeImportArchive.sha256
  }
  return Assert-CardsPickerAbsentOutputs $plan.root $basename $plan.initialSuggestedBasename
}

function Assert-CardsPickerInitialImportFilename([string] $child, [string] $hostBuffer, [string] $wanted, $channels) {
  Assert-CardsPickerBareZipBasename $wanted
  if(($child -cne '' -and $child -cne $wanted -and $child -cne [IO.Path]::GetFileNameWithoutExtension($wanted)) -or
      $hostBuffer -cne $child -or $channels.uiaHostValueAvailable -ne $true -or $channels.uiaHostMatchesChild -ne $true){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: Open initial name is neither empty nor the exact owned existing archive')
  }
  return $(if($child -ceq ''){'emptyOpenDialog'}else{'ownExistingArchive'})
}

function Assert-CardsNativeExportQualification($plan, $qualification) {
  $evidence=$plan.nativeFilenameQualification
  $native=$qualification.nativeFilename
  if(-not (Test-CardsZipNativeExportOnly $plan) -or
      $plan.pickerNavigationOnly -ne $true -or $plan.pickerNativeFilenameOnly -ne $true -or
      ($plan.PSObject.Properties['pickerStructureOnly'] -and $plan.pickerStructureOnly -ne $false) -or
      ($plan.PSObject.Properties['pickerNativeFilenameReadbackOnly'] -and $plan.pickerNativeFilenameReadbackOnly -ne $false) -or
      -not $evidence -or $evidence.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
      @($plan.bindings|Where-Object {$_.path -ceq $evidence.path -and $_.sha256 -ceq $evidence.sha256}).Count -ne 1 -or
      $qualification.case -cne 'zip-picker-native-filename-cancel-qualification' -or
      $qualification.actualQualifications -ne 1 -or $qualification.transferEffects -ne 0 -or
      $qualification.ownedFolderView -ne $true -or $qualification.graphUnchanged -ne $true -or
      $qualification.markerCustodyVerified -ne $true -or $qualification.absentFullAndStemOutputs -ne 4 -or
      $qualification.strictExportMenuAndCancel -ne $true -or
      $qualification.ownedJobCleanupVerified -ne $true -or $qualification.exactDpiRestoreVerified -ne $true -or
      $qualification.sourceBindingsVerifiedAtEnd -le 0 -or
      $qualification.inputDisposition.chordCallsAttempted -ne 2 -or
      $qualification.inputDisposition.chordCallsCompleted -ne 2 -or
      $qualification.inputDisposition.possiblyHeldModifierUnresolved -ne $false -or
      $qualification.inputDisposition.policyInputBarrier -ne $false -or
      $qualification.driver.gateExit -ne 0 -or $qualification.driver.sourceUnchanged -ne $true -or
      $qualification.driver.defaultProfilesUnchanged -ne $true -or $qualification.driver.driverOwnedCleanup -ne $true -or
      $qualification.driver.failure -or @($qualification.driver.cleanupFailures).Count -ne 0 -or
      $native.basename -cnotmatch '^cards-native-[0-9a-f]{32}\.zip$' -or
      $native.initialSuggestedBasename -cne 'loop.zip' -or
      $native.strictPointer -ne $true -or $native.exactFocus -ne $true -or
      $native.childReadbackExact -ne $true -or $native.hostReadbackExact -ne $true -or
      $native.filenameEdits -ne 1 -or $native.readbackSamples -le 0 -or $native.fullAndStemCandidatesAbsent -ne 4 -or
      $native.typedChannels.uiaHostValueAvailable -ne $true -or
      $native.typedChannels.uiaHostMatchesSuggested -ne $true -or
      $native.clearEvents -ne 2 -or $native.typedEvents -ne 2*$native.basename.Length -or
      $native.enterEvents -ne 0 -or $native.inputReplays -ne 0 -or $native.transferEffects -ne 0){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: one native export requires a sealed positive native filename Cancel qualification')
  }
}

function Assert-CardsNativeImportQualification($plan, $receipt) {
  $archive=$plan.nativeImportArchive
  $evidence=$archive.exportReceipt
  if(-not (Test-CardsZipNativeImportOnly $plan) -or
      $plan.pickerNavigationOnly -ne $true -or $plan.pickerNativeFilenameOnly -ne $true -or
      ($plan.PSObject.Properties['pickerStructureOnly'] -and $plan.pickerStructureOnly -ne $false) -or
      ($plan.PSObject.Properties['pickerNativeFilenameReadbackOnly'] -and $plan.pickerNativeFilenameReadbackOnly -ne $false) -or
      -not $evidence -or $evidence.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
      $archive.sha256 -cnotmatch '^[0-9A-F]{64}$' -or
      @($plan.bindings|Where-Object {$_.path -ceq $evidence.path -and $_.sha256 -ceq $evidence.sha256}).Count -ne 1 -or
      @($plan.bindings|Where-Object {$_.path -ceq $archive.sourcePath -and $_.sha256 -ceq $archive.sha256}).Count -ne 1 -or
      $receipt.actualTransfers -ne 1 -or $receipt.OpenImportActions -ne 0 -or
      $receipt.archivePath -cne $archive.sourcePath -or $receipt.archiveSha256 -cne $archive.sha256 -or
      $receipt.case.case -cne 'zip-save-export' -or $receipt.case.transferEffects -ne 1 -or
      $receipt.case.bundle.sha256 -cne $archive.sha256 -or $receipt.case.bundle.rootNodes -ne 1 -or
      $receipt.case.bundle.recursiveNodes -ne 3 -or $receipt.case.bundle.recursiveEdges -ne 1 -or
      $receipt.case.bundle.sessionTransplantEntries -ne 0 -or $receipt.case.graphUnchanged -ne $true -or
      $receipt.case.alternateArchives -ne 0 -or $receipt.case.retainedStagingDirectories -ne 0 -or
      $receipt.case.markerCustodyVerified -ne $true -or $receipt.ownedJobCleanupVerified -ne $true -or
      $receipt.exactDpiRestoreVerified -ne $true -or $receipt.sourceBindingsVerifiedAtEnd -le 0 -or
      $receipt.inputDisposition.possiblyHeldModifierUnresolved -ne $false -or
      $receipt.inputDisposition.policyInputBarrier -ne $false -or $receipt.driver.gateExit -ne 0 -or
      $receipt.driver.sourceUnchanged -ne $true -or $receipt.driver.defaultProfilesUnchanged -ne $true -or
      $receipt.driver.driverOwnedCleanup -ne $true -or $receipt.driver.failure -or
      @($receipt.driver.cleanupFailures).Count -ne 0){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: one native import requires the sealed positive native export and exact owned archive')
  }
}

function Assert-CardsNativeExportReady($observation, $state, $channels, $view,
    [string] $root, [string] $basename, [bool] $existingInput=$false) {
  Assert-CardsPickerNativeFilenameValue $state $basename $channels
  $native=$observation.nativeFilename
  if($observation.folderContainmentEstablished -ne $true -or
      $observation.processId -ne $state.expectedProcessId -or $observation.picker -ne $state.picker -or
      $native.rootRuntime -cne $state.rootRuntime -or $native.control -ne $state.handle -or
      $native.runtime -cne $state.runtime -or $native.hostRuntime -cne $state.hostRuntime -or
      ($existingInput -and ($state.importing -ne $true -or $native.importing -ne $true -or
        $native.outer.nativeWindow -ne $state.outer.nativeWindow -or $native.outer.runtime -cne $state.outer.runtime)) -or
      (-not $existingInput -and ($state.importing -eq $true -or $native.importing -eq $true)) -or
      $native.basename -cne $basename -or $native.inputReplays -ne 0 -or $native.enterEvents -ne 0 -or
      $native.fullAndStemCandidatesAbsent -ne $(if($existingInput){3}else{4}) -or
      ($existingInput -and $native.ownedExistingArchiveVerified -ne $true) -or
      $channels.uiaHostValueAvailable -ne $true -or $channels.uiaHostMatchesSuggested -ne $true -or
      $channels.uiaHostMatchesChild -ne $true -or
      $null -eq $view -or $view.runtime -cne $observation.markerView.runtime -or
      $view.markerRuntime -cne $observation.markerView.markerRuntime){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original folder/view or exact native filename changed before primary action')
  }
  $view.navigationEntered=$true
  $view.addressBuffer=$observation.markerView.addressBuffer
  Assert-CardsPickerFolderView $view $root
}

function Invoke-CardsPickerNativeFilename($process, [IntPtr] $picker, $plan, $shape, $view, $caseClock, $controlClock) {
  $ownPath=[IO.Path]::GetFullPath([string]$plan.root)
  $basename=[IO.Path]::GetFileName([string]$plan.zipPath)
  Assert-CardsPickerBareZipBasename $basename
  Assert-CardsPickerBareZipBasename ([string]$plan.initialSuggestedBasename)
  $existingInput=Test-CardsZipNativeImportOnly $plan
  $absentCandidateCount=Assert-CardsPickerNativeFileScope $plan
  Require ((($plan.kind -ceq 'cards-zip-filename-observation' -and $plan.caseCount -eq 1) -or
      (Test-CardsZipNativeExportOnly $plan) -or $existingInput) -and
    $basename -cmatch '^cards-native-[0-9a-f]{32}\.zip$' -and $plan.initialSuggestedBasename -ceq 'loop.zip' -and
    (Join-Path $ownPath $basename) -ceq [string]$plan.zipPath) `
    'CARDS_PILOT_ZIP: explicit native filename scope or absent owned basenames changed'
  Assert-CardsPickerFolderView $view $ownPath
  $binding=Select-CardsPickerNativeFilename $shape ([uint32]$process.Id) $picker -Importing:$existingInput
  $editId=if($existingInput){1148}else{1001}
  $owner=[GraphCodeUiaGateState]::WindowOwner($picker)
  $samples=@{previous=$null}
  $null=Wait-CardsPilotState {
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    $null=Assert-CardsPickerNativeFileScope $plan
    $null=Get-CardsPickerNativeFilenameState $process $picker $binding $false
    $current=Get-CardsPickerCancelSnapshot $process $owner $picker ([IntPtr]$binding.edit.nativeWindow) $editId 'Edit'
    $stable=Test-CardsPickerCancelReady $samples.previous $current $process.Id $owner.ToInt64() $picker.ToInt64() $editId 'Edit'
    $samples.previous=$current
    if($stable){return $current};return $null
  } 'exact native filename Edit stable geometry and strict-hit readiness' `
    (Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds)
  $null=Get-CardsPickerNativeFilenameState $process $picker $binding $false
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  $edit=[IntPtr]$binding.edit.nativeWindow;$hostHandle=[IntPtr]$binding.host.nativeWindow
  $hit=[GraphCodeUiaGateState]::ClickScreenPoint($edit)
  Assert-CardsPilotPointer $hit $process.Id $editId
  $null=Get-CardsPickerNativeFilenameState $process $picker $binding $true
  $before=[GraphCodeMultiProjectEditNative]::Buffer($edit,100)
  $hostBefore=[GraphCodeMultiProjectEditNative]::Buffer($hostHandle,100)
  if($plan.PSObject.Properties['pickerNativeFilenameReadbackOnly'] -and $plan.pickerNativeFilenameReadbackOnly -eq $true){
    $metadata=Read-CardsPickerFilenameMetadata $process $picker $binding $before $hostBefore ([string]$plan.initialSuggestedBasename)
    $currentView=Get-CardsPickerKnownMarker $process $picker ([string]$plan.pickerSentinel)
    Require ($null -ne $currentView -and $currentView.runtime -ceq $view.runtime -and
      $currentView.markerRuntime -ceq $view.markerRuntime) 'CARDS_PILOT_ZIP: original owned view changed during readback diagnosis'
    $currentView.navigationEntered=$true;$currentView.addressBuffer=$view.addressBuffer
    Assert-CardsPickerFolderView $currentView $ownPath
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    Require (-not (Test-Path -LiteralPath $plan.zipPath) -and
      -not (Test-Path -LiteralPath (Join-Path $ownPath $plan.initialSuggestedBasename))) `
      'CARDS_PILOT_ZIP: readback-only diagnosis found an unexpected archive'
    return [ordered]@{entryMethod='bounded readback-only diagnosis; not filename input qualification'
      diagnosticOnly=$true;metadata=$metadata;filenameEdits=0;selectionClearUnicodeCalls=0
      enterEvents=0;transferEffects=0;selectedResultProven=$false}
  }
  $initialExpected=if($existingInput){$basename}else{[string]$plan.initialSuggestedBasename}
  $initialMetadata=Read-CardsPickerFilenameMetadata $process $picker $binding $before $hostBefore $initialExpected
  Write-Host ('CARDS_PILOT_FILENAME_INITIAL_CHANNELS='+($initialMetadata|ConvertTo-Json -Depth 4 -Compress))
  $initialDisplayMode=if($existingInput){
    Assert-CardsPickerInitialImportFilename $before $hostBefore $basename $initialMetadata.channels
  }else{
    Assert-CardsPickerInitialFilename $before $hostBefore ([string]$plan.initialSuggestedBasename) $initialMetadata.channels
  }
  $remaining=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,$edit)
  [GraphCodeMultiProjectEditNative]::SelectAll($edit,$remaining)
  $selection=[GraphCodeMultiProjectEditNative]::Selection($edit,100)
  Require ($selection[0] -eq 0 -and $selection[1] -eq $before.Length) 'CARDS_PILOT_ZIP: native filename selection refused'
  $null=Get-CardsPickerNativeFilenameState $process $picker $binding $true
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  Require ([GraphCodeUiaGateState]::SendKeyInput($picker,[uint32]$process.Id,$edit,0x2E,1) -eq 1) `
    'CARDS_PILOT_ZIP: native filename Delete count differs'
  Require ([string]::IsNullOrEmpty([GraphCodeMultiProjectEditNative]::Buffer($edit,100)) -and
    [string]::IsNullOrEmpty([GraphCodeMultiProjectEditNative]::Buffer($hostHandle,100))) `
    'CARDS_PILOT_ZIP: native filename child/host were not cleared'
  $null=Get-CardsPickerNativeFilenameState $process $picker $binding $true
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  $typed=[GraphCodeUiaGateState]::SendUnicodeInput($picker,[uint32]$process.Id,$edit,$basename)
  Require ($typed[0] -eq 2*$basename.Length -and $typed[1] -eq $typed[0]) 'CARDS_PILOT_ZIP: native filename typed event count differs'
  $readiness=@{samples=0;last=$null}
  try{
    $typedReady=Wait-CardsPilotState {
      $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
      $sample=Get-CardsPickerNativeFilenameState $process $picker $binding $true
      $sample.buffer=[GraphCodeMultiProjectEditNative]::Buffer($edit,100)
      $sample.hostBuffer=[GraphCodeMultiProjectEditNative]::Buffer($hostHandle,100)
      $metadata=Read-CardsPickerFilenameMetadata $process $picker $binding $sample.buffer $sample.hostBuffer $basename
      $readiness.samples++;$readiness.last=$metadata
      $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
      if(Test-CardsPickerNativeFilenameReady $sample $basename $metadata.channels){
        return @{state=$sample;metadata=$metadata}
      }
      return $null
    } 'native filename exact child/host/semantic full-basename readiness' `
      (Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds)
  }finally{
    Write-Host ('CARDS_PILOT_FILENAME_TYPED_CHANNELS='+([ordered]@{
      samples=$readiness.samples;last=$readiness.last;inputReplays=0
    }|ConvertTo-Json -Depth 5 -Compress))
  }
  $state=$typedReady.state
  $typedMetadata=$typedReady.metadata
  Assert-CardsPickerNativeFilenameValue $state $basename $typedMetadata.channels
  Require ($typedMetadata.channels.childMatchesSuggested -and
    ($existingInput -or $typedMetadata.channels.nativeHostMatchesSuggested) -and
    $typedMetadata.channels.uiaHostValueAvailable -and $typedMetadata.channels.uiaHostMatchesChild) `
    'CARDS_PILOT_ZIP: exact typed native basename and semantic host value differ'
  $currentView=Get-CardsPickerKnownMarker $process $picker ([string]$plan.pickerSentinel)
  Require ($null -ne $currentView -and $currentView.runtime -ceq $view.runtime -and
    $currentView.markerRuntime -ceq $view.markerRuntime) 'CARDS_PILOT_ZIP: original owned folder/view changed during filename input'
  $currentView.navigationEntered=$true;$currentView.addressBuffer=$view.addressBuffer
  Assert-CardsPickerFolderView $currentView $ownPath
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  $null=Assert-CardsPickerNativeFileScope $plan
  Require (
    ([IO.File]::GetAttributes($ownPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
    ([IO.File]::GetAttributes((Join-Path $ownPath $plan.pickerSentinel)) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
    (Get-FileHash -LiteralPath (Join-Path (Join-Path $ownPath $plan.pickerSentinel) 'owner.json') -Algorithm SHA256).Hash -ceq
      $plan.pickerSentinelSha256) `
    'CARDS_PILOT_ZIP: native filename input created an unexpected archive'
  return [ordered]@{entryMethod='explicit guarded native-primary basename; no Enter or setter'
    host=$hostHandle.ToInt64();control=$edit.ToInt64();controlId=$editId;importing=$existingInput;outer=$state.outer
    hostRuntime=$state.hostRuntime;runtime=$state.runtime;rootRuntime=$state.rootRuntime;basename=$basename
    initialSuggestedBasename=[string]$plan.initialSuggestedBasename;initialDisplayMode=$initialDisplayMode
    bothBasenamesAbsent=(-not $existingInput);fullAndStemCandidatesAbsent=$absentCandidateCount
    ownedExistingArchiveVerified=$existingInput
    readbackAuthority=$(if($existingInput){'Native Edit WM_GETTEXT plus advertised host semantic full equality; host WM_GETTEXT empty or exact only'}
      else{'Native Edit and host WM_GETTEXT plus advertised host semantic full equality'})
    strictPointer=$true;exactFocus=$true;childReadbackExact=$typedMetadata.channels.childMatchesSuggested
    hostReadbackExact=$typedMetadata.channels.nativeHostMatchesSuggested
    semanticHostReadbackExact=$typedMetadata.channels.uiaHostMatchesSuggested
    typedChannels=$typedMetadata.channels;readbackSamples=$readiness.samples;inputReplays=0
    filenameEdits=1;clearEvents=2;typedEvents=$typed[0]
    enterEvents=0;transferEffects=0;selectedResultProven=$false}
}

function Open-CardsPickerAddress($process, [IntPtr] $picker, $binding, $caseClock, $controlClock) {
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  $focus=[GraphCodeUiaGateState]::FocusedControlInDialog($picker)
  [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,$focus)
  $script:CardsPickerChordAttempts++
  Require ([GraphCodeUiaGateState]::SendKeyInput($picker,[uint32]$process.Id,$focus,0x4C,1,$true) -eq 1) `
    'CARDS_PILOT_NAV: Ctrl+L single-batch result differs'
  $script:CardsPickerChordCompletions++
  Write-Host ('CARDS_PILOT_NAV_CTRL_BATCH='+([ordered]@{
    observedAt=[DateTimeOffset]::Now.ToString('o');processId=$process.Id;picker=$picker.ToInt64()
    focusedBefore=$focus.ToInt64();guardedCoreVerifiedEvents=4;keyDownReplay=$false
  }|ConvertTo-Json -Compress))
  $ready=Wait-CardsPilotState {
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    Get-CardsPickerAddressState $process $picker $binding
  } 'exact focused Edit inside observed address band' `
    (Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds)
  $binding.expectedEditHandle=$ready.editHandle
  $binding.expectedEditId=$ready.editId
  $binding.expectedEditRuntime=$ready.editRuntime
  return $ready
}

function Get-CardsPickerKnownMarker($process, [IntPtr] $picker, [string] $marker) {
  [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,[IntPtr]::Zero)
  $dialog=[System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $hosts=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.AndCondition]::new(
      [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'listview'),
      [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'DUIListView')))
  Require ($hosts.Count -le 1) 'CARDS_PILOT_NAV: exact native view host ambiguous'
  if($hosts.Count -eq 0){return $null}
  $hostHandle=[IntPtr]::new([long]$hosts[0].Current.NativeWindowHandle)
  $views=$hosts[0].FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty,'UIItemsView'))
  Require ($views.Count -le 1) 'CARDS_PILOT_NAV: exact native items view ambiguous'
  if($views.Count -eq 0){return $null}
  $view=$views[0];$viewHandle=[IntPtr]::new([long]$view.Current.NativeWindowHandle)
  $matches=$view.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty,$marker))
  Require ($matches.Count -le 1) 'CARDS_PILOT_NAV: known unique marker is ambiguous'
  if($matches.Count -eq 0){return $null}
  $item=$matches[0]
  return @{
    expectedProcessId=$process.Id;processId=$view.Current.ProcessId
    nativeOwned=([GraphCodeUiaGateState]::WindowProcessId($viewHandle) -eq $process.Id -and
      [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$viewHandle,[GraphCodeUiaGateState]::ControlIdOf($viewHandle)))
    viewClass=$view.Current.ClassName;runtime=($view.GetRuntimeId() -join ',')
    hostClass=$hosts[0].Current.ClassName;hostId=[GraphCodeUiaGateState]::ControlIdOf($hostHandle)
    hostNativeOwned=($hosts[0].Current.ProcessId -eq $process.Id -and
      [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$hostHandle,1121))
    markerCount=$matches.Count;markerProcessId=$item.Current.ProcessId;markerVisible=(-not $item.Current.IsOffscreen)
    markerRole=$item.Current.ControlType.ProgrammaticName;markerRuntime=($item.GetRuntimeId() -join ',')
    exactKnownMarker=($item.Current.Name -ceq $marker)
  }
}

function Invoke-CardsPickerNavigation($process, [IntPtr] $picker, $plan, $caseClock) {
  $controlClock=[Diagnostics.Stopwatch]::StartNew()
  $ownPath=[IO.Path]::GetFullPath([string]$plan.root)
  $marker=[string]$plan.pickerSentinel
  Require ($marker -cmatch '^cards-view-[0-9a-f]{32}$' -and
    $ownPath -ceq [string]$plan.root -and
    ([IO.File]::GetAttributes($ownPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
    'CARDS_PILOT_NAV: exact owned folder or fresh marker binding is invalid'
  $markerPath=Join-Path $ownPath $marker
  Require ([IO.Directory]::Exists($markerPath) -and
    ([IO.File]::GetAttributes($markerPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
    (Get-FileHash -LiteralPath (Join-Path $markerPath 'owner.json') -Algorithm SHA256).Hash -ceq $plan.pickerSentinelSha256) `
    'CARDS_PILOT_NAV: original owned marker changed'
  $dialog=[System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $shape=Get-CardsPickerControlShape $process $picker
  $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  $bandRow=Select-CardsPickerAddressBand $shape ([uint32]$process.Id) $picker
  $bandHandle=[IntPtr]::new([long]$bandRow.nativeWindow)
  Require (($dialog.GetRuntimeId() -join ',') -ceq $shape.rootRuntimeAfter -and
    [GraphCodeUiaGateState]::WindowProcessId($bandHandle) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowClass($bandHandle) -ceq $bandRow.nativeClass -and
    [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$bandHandle,41477)) `
    'CARDS_PILOT_NAV: observed address band native identity changed'
  $binding=@{expectedProcessId=$process.Id;expectedPicker=$picker.ToInt64()
    expectedRootRuntime=($dialog.GetRuntimeId() -join ',');expectedBandHandle=$bandHandle.ToInt64()
    expectedBandRuntime=$bandRow.runtime;expectedBandNativeClass=$bandRow.nativeClass
    expectedEditHandle=0;expectedEditRuntime='';expectedEditId=$null}
  try {
    $initial=Open-CardsPickerAddress $process $picker $binding $caseClock $controlClock
    $edit=[IntPtr]$initial.editHandle
    $null=Get-CardsPickerAddressState $process $picker $binding
    $remaining=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    [GraphCodeUiaGateState]::RequireOwnedKeyboardInput($picker,[uint32]$process.Id,$edit)
    [GraphCodeMultiProjectEditNative]::SelectAll($edit,$remaining)
    $before=[GraphCodeMultiProjectEditNative]::Buffer($edit,100)
    $selection=[GraphCodeMultiProjectEditNative]::Selection($edit,100)
    Require ($selection[0] -eq 0 -and $selection[1] -eq $before.Length) 'CARDS_PILOT_NAV: exact address selection refused'
    $null=Get-CardsPickerAddressState $process $picker $binding
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    Require ([GraphCodeUiaGateState]::SendKeyInput($picker,[uint32]$process.Id,$edit,0x2E,1) -eq 1) `
      'CARDS_PILOT_NAV: native address Delete count differs'
    Require ([string]::IsNullOrEmpty([GraphCodeMultiProjectEditNative]::Buffer($edit,100))) `
      'CARDS_PILOT_NAV: native address was not cleared'
    $null=Get-CardsPickerAddressState $process $picker $binding
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    $typed=[GraphCodeUiaGateState]::SendUnicodeInput($picker,[uint32]$process.Id,$edit,$ownPath)
    Require ($typed[0] -eq 2*$ownPath.Length -and $typed[1] -eq $typed[0]) 'CARDS_PILOT_NAV: native address text count differs'
    $submitted=Get-CardsPickerAddressState $process $picker $binding
    $submitted.buffer=[GraphCodeMultiProjectEditNative]::Buffer($edit,100)
    $submitted.caseElapsed=$caseClock.ElapsedMilliseconds;$submitted.controlElapsed=$controlClock.ElapsedMilliseconds
    Assert-CardsPickerAddressEnter $submitted $ownPath
    Require ([GraphCodeUiaGateState]::SendKeyInput($picker,[uint32]$process.Id,$edit,0x0D,1) -eq 1) `
      'CARDS_PILOT_NAV: guarded address Enter count differs'
    $view=Wait-CardsPilotState {
      $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
      Get-CardsPickerKnownMarker $process $picker $marker
    } 'fresh unique owned-folder marker in actual native view' `
      (Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds)
    $binding.expectedEditHandle=0;$binding.expectedEditRuntime='';$binding.expectedEditId=$null
    $current=Open-CardsPickerAddress $process $picker $binding $caseClock $controlClock
    $current.buffer=[GraphCodeMultiProjectEditNative]::Buffer([IntPtr]$current.editHandle,100)
    $current.caseElapsed=$caseClock.ElapsedMilliseconds;$current.controlElapsed=$controlClock.ElapsedMilliseconds
    Assert-CardsPickerAddressEnter $current $ownPath
    $view=Get-CardsPickerKnownMarker $process $picker $marker
    Require ($null -ne $view) 'CARDS_PILOT_NAV: original own marker disappeared during address confirmation'
    $view.navigationEntered=$true;$view.addressBuffer=$current.buffer
    Assert-CardsPickerFolderView $view $ownPath
    Require (([IO.File]::GetAttributes($ownPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
      [IO.Directory]::Exists($markerPath) -and
      ([IO.File]::GetAttributes($markerPath) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
      (Get-FileHash -LiteralPath (Join-Path $markerPath 'owner.json') -Algorithm SHA256).Hash -ceq $plan.pickerSentinelSha256) `
      'CARDS_PILOT_NAV: original owned folder/marker changed during qualification'
    $null=Get-CardsPickerNavigationBudget $caseClock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
    $nativeFilename=$null
    if($plan.PSObject.Properties['pickerNativeFilenameOnly'] -and $plan.pickerNativeFilenameOnly -eq $true){
      $nativeFilename=Invoke-CardsPickerNativeFilename $process $picker $plan $shape $view $caseClock $controlClock
    }
    return [ordered]@{
      processId=$process.Id;picker=$picker.ToInt64();addressBand=$bandHandle.ToInt64()
      addressBandUiaClass=$bandRow.class;addressBandNativeClass=$bandRow.nativeClass
      addressBandRuntime=$bandRow.runtime;addressLookup='bounded original RawView structural reader'
      initialAddressEdit=$initial.editHandle;initialAddressId=$initial.editId
      currentAddressEdit=$current.editHandle;currentAddressId=$current.editId
      initialRuntime=$initial.editRuntime;currentRuntime=$current.editRuntime
      exactBandAncestor=$true;nativeAddressReadbackExact=$true;knownMarker=$marker;markerView=$view
      controlBatches=2;addressEnterEvents=2;addressTextEvents=$typed[0]
      folderContainmentEstablished=$true;filenameEdits=$(if($null -ne $nativeFilename){$nativeFilename.filenameEdits}else{0})
      nativeFilename=$nativeFilename;transferEffects=0;selectedResultProven=$false
      elapsedMilliseconds=$controlClock.ElapsedMilliseconds
      proofLimit='Owned folder/view, and explicit native filename when requested; no Save/GetResult/publication proof'
    }
  } catch {
    $script:CardsPickerNativeInputBarrier=$true
    $inputDisposition=Get-CardsPickerInputDisposition $script:CardsPickerChordAttempts $script:CardsPickerChordCompletions $true
    $_.Exception.Data['CardsNativeInputBarrier']=$true
    Write-Host 'CARDS_PILOT_NATIVE_INPUT_BARRIER=STOP; no further native input or clean-desktop release; modifier emission disposition is recorded separately'
    Write-Host ('CARDS_PILOT_NAV_FAILURE='+([ordered]@{
      observedAt=[DateTimeOffset]::Now.ToString('o');error=$_.Exception.ToString()
      subsequentNativeInputForbidden=$true;inputDisposition=$inputDisposition
      possiblyHeldModifierBarrier=$inputDisposition.possiblyHeldModifierUnresolved;desktopCleanReleasePermitted=$false
    }|ConvertTo-Json -Depth 4 -Compress))
    throw
  }
}

function Get-CardsPickerControlShape($process, [IntPtr] $picker) {
  Require ([GraphCodeUiaGateState]::WindowProcessId($picker) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowClass($picker) -ceq '#32770' -and
    [GraphCodeUiaGateState]::WindowIsVisible($picker)) 'CARDS_PILOT_ZIP: structure reader lost its owned native picker'
  $readClock=[Diagnostics.Stopwatch]::StartNew()
  $dialog=[System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $rootRuntime=$dialog.GetRuntimeId() -join ','
  $findAddress={
    Require ($readClock.ElapsedMilliseconds -lt 5000) 'CARDS_PILOT_ZIP: original structure budget expired'
    $matches=$dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'41477'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'Address Band Root')))
    $candidates=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt [Math]::Min(8,$matches.Count);$i++) {
      $element=$matches[$i];$handle=[IntPtr]::new([long]$element.Current.NativeWindowHandle)
      $candidates.Add([ordered]@{
        automationId=$element.Current.AutomationId;uiaClass=$element.Current.ClassName
        nativeWindow=$handle.ToInt64();nativeClass=[GraphCodeUiaGateState]::WindowClass($handle)
        nativeControlId=[GraphCodeUiaGateState]::ControlIdOf($handle);processId=$element.Current.ProcessId
        nativeProcessId=[GraphCodeUiaGateState]::WindowProcessId($handle)
        nativeRootOwned=[GraphCodeUiaGateState]::IsControlOwnedBy($picker,$handle,[GraphCodeUiaGateState]::ControlIdOf($handle))
        runtime=($element.GetRuntimeId() -join ',');isControlElement=$element.Current.IsControlElement
      })
    }
    return [ordered]@{count=$matches.Count;candidates=$candidates.ToArray();truncated=($matches.Count -gt 8)
      elapsedMilliseconds=$readClock.ElapsedMilliseconds;observedAt=[DateTimeOffset]::Now.ToString('o')}
  }
  $beforeLookup=& $findAddress
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $pending=[Collections.Generic.Queue[object]]::new()
  $pending.Enqueue(@{element=[System.Windows.Automation.AutomationElement]::FromHandle($picker);parent=-1;depth=0})
  $rows=[Collections.Generic.List[object]]::new()
  while ($pending.Count -gt 0 -and $rows.Count -lt 96) {
    Require ($readClock.ElapsedMilliseconds -lt 5000) 'CARDS_PILOT_ZIP: bounded picker structure read expired'
    $item=$pending.Dequeue(); $current=$item.element.Current
    Require ($current.ProcessId -eq $process.Id) 'CARDS_PILOT_ZIP: structure reader encountered a foreign UIA descendant'
    $native=[IntPtr]::new([long]$current.NativeWindowHandle)
    $id=if ($native -ne [IntPtr]::Zero) { [GraphCodeUiaGateState]::ControlIdOf($native) } else { $null }
    $omit=$current.ControlType -in @([System.Windows.Automation.ControlType]::List,
      [System.Windows.Automation.ControlType]::DataGrid,[System.Windows.Automation.ControlType]::Tree)
    $index=$rows.Count
    $rows.Add([ordered]@{
      index=$index;parent=$item.parent;depth=$item.depth;processId=$current.ProcessId
      automationId=$current.AutomationId;class=$current.ClassName;role=$current.ControlType.ProgrammaticName
      runtime=($item.element.GetRuntimeId() -join ',');nativeWindow=$native.ToInt64();controlId=$id
      nativeProcessId=$(if($native -ne [IntPtr]::Zero){[GraphCodeUiaGateState]::WindowProcessId($native)}else{$null})
      nativeClass=$(if($native -ne [IntPtr]::Zero){[GraphCodeUiaGateState]::WindowClass($native)}else{$null})
      isControlElement=$current.IsControlElement;isContentElement=$current.IsContentElement
      nativeRootOwned=($native -ne [IntPtr]::Zero -and
        [GraphCodeUiaGateState]::WindowProcessId($native) -eq $process.Id -and
        [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$native,$id))
      nativeBounds=[GraphCodeUiaGateState]::WindowBounds($native)
      patterns=@($item.element.GetSupportedPatterns()|ForEach-Object ProgrammaticName)
      listContentsOmitted=$omit
    })
    if (-not $omit -and $item.depth -lt 6) {
      $child=$walker.GetFirstChild($item.element)
      while ($child) {
        Require ($readClock.ElapsedMilliseconds -lt 5000 -and $pending.Count -lt 96) `
          'CARDS_PILOT_ZIP: bounded picker structure enumeration exceeded its limit'
        $pending.Enqueue(@{element=$child;parent=$index;depth=$item.depth+1})
        $child=$walker.GetNextSibling($child)
      }
    }
  }
  $afterLookup=& $findAddress
  $finalRootRuntime=$dialog.GetRuntimeId() -join ','
  Require ($readClock.ElapsedMilliseconds -lt 5000 -and
    $rootRuntime -ceq $finalRootRuntime -and $dialog.Current.ProcessId -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowProcessId($picker) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowClass($picker) -ceq '#32770' -and
    [GraphCodeUiaGateState]::WindowIsVisible($picker)) 'CARDS_PILOT_ZIP: original structure root identity changed'
  $addressRows=@($rows|Where-Object {$_.controlId -eq 41477 -or $_.automationId -ceq '41477' -or
    $_.class -ceq 'Address Band Root'})
  return [ordered]@{
    processId=$process.Id;picker=$picker.ToInt64();observedAt=[DateTimeOffset]::Now.ToString('o')
    rootRuntimeBefore=$rootRuntime;rootRuntimeAfter=$finalRootRuntime
    controls=$rows.ToArray();queuedNodesOmitted=($pending.Count -gt 0)
    depthLimitReached=(@($rows|Where-Object depth -EQ 6).Count -gt 0)
    addressLookup=[ordered]@{beforeRawWalk=$beforeLookup;afterRawWalk=$afterLookup;rawCandidates=$addressRows
      fieldMeanings='class=UIA.ClassName; nativeClass=GetClassName; controlId=GetDlgCtrlID; automationId=UIA.AutomationId'}
    inputDisposition=(Get-CardsPickerInputDisposition $script:CardsPickerChordAttempts $script:CardsPickerChordCompletions $false)
    folderContainmentEstablished=$false;filenameEdits=0;transferEffects=0;selectedResultProven=$false
    entryMethod='read-only structural inspection; no Name/Value or list-content read'
    proofLimit='Roles, IDs, native ownership, bounds and available patterns only; no current-folder/selected-result proof'
  }
}

function Assert-CardsPickerImportStructurePlan($plan) {
  if($plan.kind -cne 'cards-zip-filename-observation' -or $plan.caseCount -ne 1 -or
      $plan.pickerImportStructureOnly -isnot [bool] -or $plan.pickerImportStructureOnly -ne $true -or
      $plan.pickerStructureOnly -isnot [bool] -or $plan.pickerStructureOnly -ne $true -or
      $plan.PSObject.Properties['nativeImportOnly'] -or $plan.PSObject.Properties['nativeExportOnly']){
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: Import structure requires a distinct strict-Cancel-only plan')
  }
  foreach($field in @('pickerNavigationOnly','pickerNativeFilenameOnly','pickerNativeFilenameReadbackOnly')){
    if($plan.PSObject.Properties[$field] -and ($plan.$field -isnot [bool] -or $plan.$field -ne $false)){
      throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: Import structure forbids navigation, filename input and dispatch')
    }
  }
}

function Select-CardsPickerFilenameStructure($shape, [uint32] $processId, [IntPtr] $picker) {
  $null=Select-CardsPickerAddressBand $shape $processId $picker
  $rows=@($shape.controls|Where-Object {$_.automationId -cin @('FileNameControlHost','1001','1148') -or
    $_.controlId -in @(1001,1148) -or $_.nativeClass -cin @('ComboBox','ComboBoxEx32') -or
    $_.role -ceq 'ControlType.ComboBox'}|ForEach-Object {
      if($_.processId -ne $processId -or ($_.nativeWindow -gt 0 -and
          ($_.nativeProcessId -ne $processId -or $_.nativeRootOwned -ne $true))){
        throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: filename diagnostic encountered changed native/UIA ownership')
      }
      [ordered]@{index=$_.index;parent=$_.parent;depth=$_.depth;processId=$_.processId
        automationId=$_.automationId;class=$_.class;role=$_.role;runtime=$_.runtime
        nativeWindow=$_.nativeWindow;controlId=$_.controlId;nativeProcessId=$_.nativeProcessId
        nativeClass=$_.nativeClass;nativeRootOwned=$_.nativeRootOwned;nativeBounds=$_.nativeBounds
        isControlElement=$_.isControlElement;isContentElement=$_.isContentElement;patterns=$_.patterns}
    })
  return [ordered]@{processId=$processId;picker=$picker.ToInt64();observedAt=$shape.observedAt
    rootRuntimeBefore=$shape.rootRuntimeBefore;rootRuntimeAfter=$shape.rootRuntimeAfter
    visitedControls=@($shape.controls).Count;queuedNodesOmitted=$shape.queuedNodesOmitted
    depthLimitReached=$shape.depthLimitReached;exactFilenameHostRawCount=@($shape.controls|Where-Object automationId -CEQ 'FileNameControlHost').Count
    knownFilenameCandidates=$rows;candidateCount=$rows.Count;filenameEdits=0;transferEffects=0;chordCalls=0
    actualTextRetained=$false;proofLimit='Bounded exact-owned structural candidates only; not filename identity/input or current-folder proof'}
}

function Set-CardsZipPath($process, [IntPtr] $picker, $plan, $caseClock = $null) {
  $fieldClock = [Diagnostics.Stopwatch]::StartNew()
  $path = [string]$plan.zipPath
  Require ([IO.Path]::IsPathFullyQualified($path) -and
    [string]::Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)),
      [IO.Path]::GetFullPath($plan.root),[StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetExtension($path) -ieq '.zip' -and
    ([IO.File]::GetAttributes($plan.root) -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
    'CARDS_PILOT_ZIP: unique ZIP must be directly inside the original owned root'
  if($plan.PSObject.Properties['pickerNativeFilenameOnly'] -and $plan.pickerNativeFilenameOnly -eq $true){
    Require ($plan.PSObject.Properties['pickerNavigationOnly'] -and $plan.pickerNavigationOnly -eq $true) `
      'CARDS_PILOT_ZIP: native-primary filename requires the explicit proved-navigation route, never a setter fallback'
  }
  if($plan.PSObject.Properties['pickerNativeFilenameReadbackOnly'] -and $plan.pickerNativeFilenameReadbackOnly -eq $true){
    Require ($plan.PSObject.Properties['pickerNativeFilenameOnly'] -and $plan.pickerNativeFilenameOnly -eq $true) `
      'CARDS_PILOT_ZIP: readback-only diagnosis requires the explicit native filename branch'
  }
  if ($plan.PSObject.Properties['pickerNavigationOnly'] -and $plan.pickerNavigationOnly -eq $true) {
    Require ((($plan.kind -ceq 'cards-zip-filename-observation' -and $plan.caseCount -eq 1) -or
        (Test-CardsZipNativeExportOnly $plan) -or (Test-CardsZipNativeImportOnly $plan)) -and $null -ne $caseClock -and
      -not ($plan.PSObject.Properties['pickerStructureOnly'] -and $plan.pickerStructureOnly -eq $true)) `
      'CARDS_PILOT_NAV: navigation requires the explicit native entry and original case clock'
    return Invoke-CardsPickerNavigation $process $picker $plan $caseClock
  }
  if ($plan.PSObject.Properties['pickerStructureOnly'] -and $plan.pickerStructureOnly -eq $true) {
    Require ($plan.kind -ceq 'cards-zip-filename-observation' -and $plan.caseCount -eq 1) `
      'CARDS_PILOT_ZIP: structure inspection requires the explicit Cancel-only observation'
    if($plan.PSObject.Properties['pickerImportStructureOnly']){
      Assert-CardsPickerImportStructurePlan $plan
      return Select-CardsPickerFilenameStructure (Get-CardsPickerControlShape $process $picker) ([uint32]$process.Id) $picker
    }
    return Get-CardsPickerControlShape $process $picker
  }
  Require (Ensure-ShellForeground $picker 'owned ZIP filename') 'CARDS_PILOT_ZIP: filename foreground refused'
  $dialog = [System.Windows.Automation.AutomationElement]::FromHandle($picker)
  $hosts = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::AutomationIdProperty,'FileNameControlHost'))
  Require ($hosts.Count -eq 1 -and $hosts[0].Current.ProcessId -eq $process.Id) `
    'CARDS_PILOT_ZIP: exact owned filename host absent or ambiguous'
  $expectedHostRuntime=$hosts[0].GetRuntimeId() -join ','
  $observation=@{ runtime=$null; shape=$null }
  $readiness = {
    $currentHosts = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,'FileNameControlHost'))
    Require ($currentHosts.Count -eq 1 -and $currentHosts[0].Current.ProcessId -eq $process.Id -and
      ($currentHosts[0].GetRuntimeId() -join ',') -ceq $expectedHostRuntime) `
      'CARDS_PILOT_ZIP: original filename host scope or RuntimeID changed'
    $hostElement=$currentHosts[0]
    $hostNative=[IntPtr]::new([long]$hostElement.Current.NativeWindowHandle)
    $hostControlId=[GraphCodeUiaGateState]::ControlIdOf($hostNative)
    Require ([GraphCodeUiaGateState]::WindowProcessId($hostNative) -eq $process.Id -and
      [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$hostNative,$hostControlId)) `
      'CARDS_PILOT_ZIP: filename host native root or process changed'
    $shape=[ordered]@{
      processId=$process.Id; picker=$picker.ToInt64(); parentRootProcessId=[GraphCodeUiaGateState]::WindowProcessId($picker)
      hostAutomationId=$hostElement.Current.AutomationId; hostRuntime=$expectedHostRuntime
      hostNativeWindow=$hostNative.ToInt64(); hostControlId=$hostControlId
      hostClass=$hostElement.Current.ClassName; hostType=$hostElement.Current.ControlType.ProgrammaticName
      hostBounds=$hostElement.Current.BoundingRectangle.ToString()
      hostPatterns=@($hostElement.GetSupportedPatterns() | ForEach-Object ProgrammaticName)
    }
    $raw=[System.Windows.Automation.TreeWalker]::RawViewWalker
    $children=[Collections.Generic.List[object]]::new()
    $candidates=[Collections.Generic.List[object]]::new()
    $child=$raw.GetFirstChild($hostElement)
    while ($child -and $children.Count -lt 8) {
      $handle=[IntPtr]::new([long]$child.Current.NativeWindowHandle)
      $row=[ordered]@{
        processId=$child.Current.ProcessId; automationId=$child.Current.AutomationId
        class=$child.Current.ClassName; type=$child.Current.ControlType.ProgrammaticName
        nativeWindow=$handle.ToInt64(); controlId=[GraphCodeUiaGateState]::ControlIdOf($handle)
        runtime=($child.GetRuntimeId() -join ','); bounds=$child.Current.BoundingRectangle.ToString()
        patterns=@($child.GetSupportedPatterns() | ForEach-Object ProgrammaticName)
      }
      $children.Add($row)
      if ($row.processId -eq $process.Id -and $row.controlId -eq 1001 -and $row.class -ceq 'Edit' -and
          [GraphCodeUiaGateState]::WindowProcessId($handle) -eq $process.Id -and
          [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$handle,1001)) {
        $candidates.Add(@{ element=$child; handle=$handle; row=$row })
      }
      $child=$raw.GetNextSibling($child)
    }
    $shape.rawFilenameChildren=$children.ToArray()
    $shape.rawChildrenTruncated=($null -ne $child)
    $shape.nativeCandidates=$candidates.Count
    $shape.elapsedMilliseconds=$fieldClock.ElapsedMilliseconds
    $observation.shape=$shape
    Require (-not $shape.rawChildrenTruncated -and $candidates.Count -le 1) `
      'CARDS_PILOT_ZIP: filename child scope is truncated or ambiguous'
    if ($candidates.Count -ne 1) { return $null }
    $candidate=$candidates[0]
    if ($null -eq $observation.runtime) { $observation.runtime=$candidate.row.runtime }
    $identity=@{ expectedProcessId=$process.Id; hostProcessId=$hostElement.Current.ProcessId
      processId=$candidate.row.processId; count=$candidates.Count; handle=$candidate.handle.ToInt64()
      controlId=$candidate.row.controlId; class=$candidate.row.class; nativeOwned=$true
      hostRuntime=$shape.hostRuntime; expectedHostRuntime=$expectedHostRuntime
      runtime=$candidate.row.runtime; expectedRuntime=$observation.runtime }
    Assert-CardsZipFilenameIdentity $identity
    $value=$null
    if (-not $candidate.element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value)) {
      return $null
    }
    return @{ element=$candidate.element; handle=$candidate.handle; value=$value; identity=$identity }
  }
  $remaining=5000 - [int]$fieldClock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original filename field budget expired before readiness'
  try { $ready=Wait-CardsPilotState $readiness 'owned filename ValuePattern readiness' $remaining }
  finally {
    Write-Host ('CARDS_PILOT_ZIP_FILENAME_SHAPE=' + ($observation.shape | ConvertTo-Json -Depth 6 -Compress))
  }
  $handle=$ready.handle
  $value=$ready.value
  Require (-not $value.Current.IsReadOnly) 'CARDS_PILOT_ZIP: filename provider is read-only'
  $value.SetValue($path)
  Require ($value.Current.Value -ceq $path -and
    [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$handle,1001) -and
    [GraphCodeUiaGateState]::WindowProcessId($handle) -eq $process.Id -and
    ($ready.element.GetRuntimeId() -join ',') -ceq $observation.runtime -and
    $fieldClock.ElapsedMilliseconds -lt 5000) `
    'CARDS_PILOT_ZIP: exact filename provider readback or identity differs'
  Write-Host ('CARDS_PILOT_ZIP_PATH=' + ([ordered]@{
    processId=$process.Id; picker=$picker.ToInt64(); control=$handle.ToInt64(); controlId=1001
    path=$path; exactReadback=$true; entryMethod='UIA.ValuePattern.SetValue; not keyboard-input evidence'
    proofLimit='Windows MRU/recent state is outside the GraphCode profile fingerprint'
  } | ConvertTo-Json -Compress))
  if ($plan.kind -ceq 'cards-zip-filename-observation') {
    $hostElement=$hosts[0]
    $hostNative=[IntPtr]::new([long]$hostElement.Current.NativeWindowHandle)
    Require ($hostElement.Current.ProcessId -eq $process.Id -and
      ($hostElement.GetRuntimeId() -join ',') -ceq $expectedHostRuntime -and
      [GraphCodeUiaGateState]::WindowProcessId($hostNative) -eq $process.Id -and
      [GraphCodeUiaGateState]::IsControlOwnedBy($picker,$hostNative,
        [GraphCodeUiaGateState]::ControlIdOf($hostNative))) 'CARDS_PILOT_ZIP: observed host identity changed'
    $hostValue=$null
    $hostAvailable=$hostElement.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$hostValue)
    $childText=$value.Current.Value
    $hostText=if ($hostAvailable) { $hostValue.Current.Value } else { $null }
    return [ordered]@{
      childMatchesOwnedPath=($childText -ceq $path); hostValuePattern=$hostAvailable
      hostMatchesOwnedPath=($hostAvailable -and $hostText -ceq $path)
      hostEqualsChild=($hostAvailable -and $hostText -ceq $childText)
      childLength=$childText.Length; hostLength=$(if ($hostAvailable) { $hostText.Length } else { $null })
      requestedLength=$path.Length; childRuntime=$observation.runtime; hostRuntime=$expectedHostRuntime
      entryMethod='original child Edit ValuePattern.SetValue only; no host setter'
      selectedResultProven=$false; transferDispatched=$false
    }
  }
}

function Test-CardsZipTransferStatus([string] $actual, [string] $expected) {
  if ($actual -match '^Export commit did not report synchronous success \(NTSTATUS 0x([0-9a-f]{1,8}), completion 0x([0-9a-f]{1,8})\)\.') {
    $code=$Matches[1]
    $completion=$Matches[2]
    $failure=[InvalidOperationException]::new(
      "CARDS_PILOT_ZIP: App export commit failed (NTSTATUS 0x$code, completion 0x$completion); raw status retained in owned app log")
    $failure.Data['NativeStatusCode']=[Convert]::ToUInt32($code,16)
    $failure.Data['NativeCompletionCode']=[Convert]::ToUInt32($completion,16)
    throw $failure
  }
  if ($actual -match '^Export commit did not report success \(Win32 ([0-9]+)\)\.') {
    $code=[int]$Matches[1]
    $failure=[InvalidOperationException]::new(
      "CARDS_PILOT_ZIP: App export commit failed (Win32 $code); raw status retained in owned app log")
    $failure.Data['NativeErrorCode']=$code
    throw $failure
  }
  return $actual -ceq $expected
}

function Read-CardsZipBundle($plan, $expectedGraph) {
  Require ([IO.File]::Exists($plan.zipPath) -and
    ([IO.File]::GetAttributes($plan.zipPath) -band
      ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory)) -eq 0 -and
    ([IO.FileInfo]::new($plan.zipPath)).Length -gt 0) 'CARDS_PILOT_ZIP: owned regular nonempty archive absent'
  $zip = [IO.Compression.ZipFile]::OpenRead($plan.zipPath)
  try {
    $entries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootSeen=$false
    foreach($entry in $zip.Entries) {
      $name=[string]$entry.FullName
      if($name -ceq './') {
        Require (-not $rootSeen -and $entry.Length -eq 0) 'CARDS_PILOT_ZIP: duplicate or nonempty tar root entry'
        $rootSeen=$true
        continue
      }
      if($name.StartsWith('./',[StringComparison]::Ordinal)) { $name=$name.Substring(2) }
      $parts=$name.TrimEnd('/').Split('/')
      Require ($name.Length -gt 0 -and -not $name.Contains('\') -and -not $name.Contains(':') -and
        @($parts | Where-Object { $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..' }).Count -eq 0 -and
        $names.Add($name)) 'CARDS_PILOT_ZIP: unsafe or duplicate logical bundle entry'
      $entries.Add($name,$entry)
    }
    Require ($entries.ContainsKey('manifest.json') -and $entries.ContainsKey('graph-snapshot.json') -and
      @($entries.Keys | Where-Object { $_.StartsWith('sessions/',[StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) `
      'CARDS_PILOT_ZIP: exact bundle entries without session transplants required'
    $reader = [IO.StreamReader]::new($entries['graph-snapshot.json'].Open())
    try { $snapshot = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
    finally { $reader.Dispose() }
    $null = Assert-CardsZipFixture $snapshot ([string]$expectedGraph.nodes[0].id)
    Assert-CardsPilotNoMutation $expectedGraph $snapshot
  } finally { $zip.Dispose() }
  return [ordered]@{
    path=[string]$plan.zipPath; sha256=(Get-FileHash -LiteralPath $plan.zipPath -Algorithm SHA256).Hash
    rootNodes=1; recursiveNodes=3; recursiveEdges=1; sessionTransplantEntries=0
    originalCompositeId=[string]$snapshot.nodes[0].id
  }
}

function Read-CardsNativePrimaryReady($process, [IntPtr] $window, [IntPtr] $picker,
    $plan, $filenameObservation, $clock) {
    $existingInput=Test-CardsZipNativeImportOnly $plan
    $ready=Wait-CardsPickerCancelReady $process $window $picker $clock 1
    $native=$filenameObservation.nativeFilename
    Require ($native.importing -is [bool] -and $native.importing -eq $existingInput) `
      'CARDS_PILOT_ZIP: explicit native filename operation changed before primary action'
    $binding=@{picker=$filenameObservation.picker;rootRuntime=$native.rootRuntime;importing=$existingInput;outer=$native.outer
      host=@{nativeWindow=$native.host;runtime=$native.hostRuntime}
      edit=@{nativeWindow=$native.control;runtime=$native.runtime}}
    $state=Get-CardsPickerNativeFilenameState $process $picker $binding $true
    $state.buffer=[GraphCodeMultiProjectEditNative]::Buffer([IntPtr]$native.control,100)
    $state.hostBuffer=[GraphCodeMultiProjectEditNative]::Buffer([IntPtr]$native.host,100)
    $metadata=Read-CardsPickerFilenameMetadata $process $picker $binding $state.buffer $state.hostBuffer $native.basename
    $view=Get-CardsPickerKnownMarker $process $picker ([string]$plan.pickerSentinel)
    Assert-CardsNativeExportReady $filenameObservation $state $metadata.channels $view $plan.root $native.basename $existingInput
    $absent=Assert-CardsPickerNativeFileScope $plan
    $marker=Join-Path $plan.root $plan.pickerSentinel
    Require (([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
      (Get-FileHash -LiteralPath (Join-Path $marker 'owner.json') -Algorithm SHA256).Hash -ceq $plan.pickerSentinelSha256) `
      'CARDS_PILOT_ZIP: original marker custody changed before primary action'
    $null=Get-CardsPickerCancelReadinessBudget $clock.ElapsedMilliseconds
    Write-Host ('CARDS_PILOT_NATIVE_PRIMARY_PRECONDITIONS='+([ordered]@{
      filename=$native;folderView=$view;currentChannels=$metadata.channels
      absentCandidates=$absent;ownedExistingArchiveVerified=$existingInput
      navigationAfterFilename=0;selectedResultDirectlyMeasured=$false
    }|ConvertTo-Json -Depth 6 -Compress))
    return $ready
}

function Read-CardsNativeImportSource($plan) {
  $null=Assert-CardsPickerNativeFileScope $plan
  $zip=[IO.Compression.ZipFile]::OpenRead($plan.zipPath)
  try{
    $snapshots=@($zip.Entries|Where-Object FullName -CIN @('graph-snapshot.json','./graph-snapshot.json'))
    Require ($snapshots.Count -eq 1) 'CARDS_PILOT_ZIP: exact owned source snapshot is missing or duplicated'
    $reader=[IO.StreamReader]::new($snapshots[0].Open())
    try{$snapshot=$reader.ReadToEnd()|ConvertFrom-Json -AsHashtable}finally{$reader.Dispose()}
  }finally{$zip.Dispose()}
  $bundle=Read-CardsZipBundle $plan $snapshot
  Require ($bundle.sha256 -ceq $plan.nativeImportArchive.sha256) 'CARDS_PILOT_ZIP: owned source archive changed while reading'
  return ,$snapshot
}

function Invoke-CardsZipExportCase($process, $root, [IntPtr] $window, $plan, $scope,
    [string] $containerCardId, $parentGraph) {
  $nativeExportOnly=Test-CardsZipNativeExportOnly $plan
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $picker=Open-CardsZipPicker $process $root $window $containerCardId 'PilotContainer' 5123
  $filenameObservation=Set-CardsZipPath $process $picker $plan $clock
  Require (-not (Test-Path -LiteralPath $plan.zipPath)) 'CARDS_PILOT_ZIP: destination appeared before Save'
  if($nativeExportOnly){
    $ready=Read-CardsNativePrimaryReady $process $window $picker $plan $filenameObservation $clock
    Click-CardsPilotControl $process $picker 1 ([IntPtr]$ready.control)
  }else{
    Click-CardsPilotControl $process $picker 1
  }
  $exportStatus='Exported the selected loop. Embedded descendants may not carry all memory or session history.'
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original export case budget expired'
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $null=Wait-CardsPilotState {
    $status=Find-FragmentById $root 'status' $walker
    $status -and $status.Current.ProcessId -eq $process.Id -and
      (Test-CardsZipTransferStatus $status.Current.Name $exportStatus)
  } 'normal App export completion status' $remaining
  $bundle=Read-CardsZipBundle $plan $parentGraph
  Assert-CardsPilotNoMutation $parentGraph (Read-CardsPilotGraph $plan.support $plan.project)
  $proof=[ordered]@{status=$exportStatus;statusMatched=$true;effectVerified=$true;drainError=$false
    ownerWindow=$window.ToInt64()}
  $null=Read-CardsZipQuiescence $scope $plan $process $proof
  if($nativeExportOnly){
    $marker=Join-Path $plan.root $plan.pickerSentinel
    foreach($name in @([IO.Path]::GetFileNameWithoutExtension($plan.zipPath),
        $plan.initialSuggestedBasename,[IO.Path]::GetFileNameWithoutExtension($plan.initialSuggestedBasename))){
      Require (-not (Test-Path -LiteralPath (Join-Path $plan.root $name))) 'CARDS_PILOT_ZIP: alternate full/stem output appeared'
    }
    $archives=@(Get-ChildItem -LiteralPath $plan.root -Force -File|Where-Object Extension -IEQ '.zip')
    $staging=@(Get-ChildItem -LiteralPath @($plan.root,(Join-Path $plan.root 'temp')) -Force -Directory|
      Where-Object {$_.Name.StartsWith('.graphcode-card-export-',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('graphcode-export-',[StringComparison]::OrdinalIgnoreCase)})
    Require ($archives.Count -eq 1 -and $archives[0].FullName -ceq $plan.zipPath -and $staging.Count -eq 0 -and
      ([IO.File]::GetAttributes($plan.root) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
      ([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
      (Get-FileHash -LiteralPath (Join-Path $marker 'owner.json') -Algorithm SHA256).Hash -ceq $plan.pickerSentinelSha256) `
      'CARDS_PILOT_ZIP: alternate archive, staging or marker custody mismatch after export'
  }
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_ZIP: export proof exceeded original case budget'
  $save=[ordered]@{case='zip-save-export';nativePointer=$true;bundle=$bundle;graphUnchanged=$true
    filenameEntry=$(if($nativeExportOnly){'explicit native-primary bare basename'}else{'UIA.ValuePattern'})
    normalTransferStatus=$exportStatus}
  if($nativeExportOnly){
    $save['filenameObservation']=$filenameObservation
    $save['transferEffects']=1
    $save['absentBeforeSaveCandidates']=4
    $save['alternateArchives']=0
    $save['retainedStagingDirectories']=0
    $save['markerCustodyVerified']=$true
    $save['selectedResultProof']='Normal completion and exact own archive effect; no direct pre-dispatch GetResult measurement'
  }
  return @{save=$save;proof=$proof;bundle=$bundle}
}

function Open-CardsZipImportTarget($process, $root, [IntPtr] $window,
    [string] $containerCardId, [string] $goalCardId, $clock) {
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $popup=Open-CardsPilotCardMenu $process $root $window $containerCardId 'PilotContainer' 'ZIP containing graph'
  $openGroup=@(Get-PopupMenuItems $popup|Where-Object {$_.Id -eq 5113 -and $_.Enabled})
  Require ($openGroup.Count -eq 1) 'CARDS_PILOT_ZIP: exact Open Group entry absent'
  $hit=[GraphCodeUiaGateState]::ClickPopupMenuItemStrict($popup,$window,[int]$openGroup[0].Position,5113,[uint32]$process.Id)
  Require ($hit.ItemId -eq 5113 -and -not $hit.UsedKeyboardFallback -and -not $hit.UsedSelectItemFallback) `
    'CARDS_PILOT_ZIP: strict Open Group route required'
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original import case budget expired'
  $null=Wait-CardsPilotState {Find-FragmentById $root $goalCardId $walker} 'owned import child canvas' $remaining
}

function Invoke-CardsZipNativeImportCase($process, $root, [IntPtr] $window, $plan, $scope,
    [string] $containerCardId, [string] $goalCardId, [string] $goalId, $parentGraph) {
  $source=$plan.nativeImportSourceGraph
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  Open-CardsZipImportTarget $process $root $window $containerCardId $goalCardId $clock
  $before=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  Assert-CardsPilotIsolation $scope $plan 'native-import-before-picker'
  $picker=Open-CardsZipPicker $process $root $window $goalCardId 'PilotGoal' 5124
  $filenameObservation=Set-CardsZipPath $process $picker $plan $clock
  $ready=Read-CardsNativePrimaryReady $process $window $picker $plan $filenameObservation $clock
  Click-CardsPilotControl $process $picker 1 ([IntPtr]$ready.control)
  $importStatus='Imported 1 loop(s); 0 session(s) restored. Embedded descendants may not carry all memory or session history.'
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original import case budget expired after Open'
  $null=Wait-CardsPilotState {
    $status=Find-FragmentById $root 'status' $walker
    $status -and $status.Current.ProcessId -eq $process.Id -and $status.Current.Name -ceq $importStatus
  } 'normal App import completion status' $remaining
  $after=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $effect=Assert-CardsZipImport $before $after $goalId $plan.containingComposite $source.nodes[0]
  $expectedRoot=$parentGraph|ConvertTo-Json -Depth 50|ConvertFrom-Json -AsHashtable
  $expectedRoot.nodes[0].subGraph=$after
  Assert-CardsPilotNoMutation $expectedRoot (Read-CardsPilotGraph $plan.support $plan.project)
  $null=Assert-CardsPickerNativeFileScope $plan
  $marker=Join-Path $plan.root $plan.pickerSentinel
  $archives=@(Get-ChildItem -LiteralPath $plan.root -Force -File|Where-Object Extension -IEQ '.zip')
  $staging=@(Get-ChildItem -LiteralPath (Join-Path $plan.root 'temp') -Force -Directory|
    Where-Object {$_.Name.StartsWith('graphcode-import-',[StringComparison]::OrdinalIgnoreCase)})
  Require (([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
    $archives.Count -eq 1 -and $archives[0].FullName -ceq $plan.zipPath -and $staging.Count -eq 0 -and
    (Get-FileHash -LiteralPath (Join-Path $marker 'owner.json') -Algorithm SHA256).Hash -ceq $plan.pickerSentinelSha256) `
    'CARDS_PILOT_ZIP: alternate archive, retained staging or marker custody mismatch after import'
  $proof=[ordered]@{status=$importStatus;statusMatched=$true;effectVerified=$true;drainError=$false
    ownerWindow=$window.ToInt64()}
  $null=Read-CardsZipQuiescence $scope $plan $process $proof
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_ZIP: import proof exceeded original case budget'
  return [ordered]@{case='zip-open-import';nativePointer=$true;filenameEntry='explicit native-primary bare basename'
    normalTransferStatus=$importStatus;effect=$effect;archiveSha256=$plan.nativeImportArchive.sha256
    archiveUnchanged=$true;markerCustodyVerified=$true;retainedStagingDirectories=0;alternateArchives=0
    filenameObservation=$filenameObservation;transferEffects=1}
}

function Invoke-CardsZipCases($process, $root, [IntPtr] $window, $plan, $scope,
    [string] $goalId, $results) {
  $parentGraph = Read-CardsPilotGraph $plan.support $plan.project
  $null = Assert-CardsZipFixture $parentGraph $plan.containingComposite
  Assert-CardsPilotIsolation $scope $plan 'zip-before-first-input'
  $nativeImportOnly=Test-CardsZipNativeImportOnly $plan
  if($nativeImportOnly){$null=Assert-CardsPickerNativeFileScope $plan}else{
    Require (-not (Test-Path -LiteralPath $plan.zipPath)) 'CARDS_PILOT_ZIP: unique destination already exists; no overwrite'
  }
  $containerCardId = Get-MultiProjectAutomationId 'project-card' ([string]$parentGraph.project.path) $plan.containingComposite
  $goalCardId = Get-MultiProjectAutomationId 'project-card' ([string]$parentGraph.project.path) $goalId
  $nativeExportOnly=Test-CardsZipNativeExportOnly $plan
  if($nativeExportOnly){
    $export=Invoke-CardsZipExportCase $process $root $window $plan $scope $containerCardId $parentGraph
    $results.Add($export.save)
    Write-Host ('CARDS_PILOT_CASE_RESULT='+($export.save|ConvertTo-Json -Depth 12 -Compress))
    return
  }
  if($nativeImportOnly){
    $import=Invoke-CardsZipNativeImportCase $process $root $window $plan $scope $containerCardId $goalCardId $goalId $parentGraph
    $results.Add($import)
    Write-Host ('CARDS_PILOT_CASE_RESULT='+($import|ConvertTo-Json -Depth 12 -Compress))
    return
  }
  $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $importStructure=($plan.PSObject.Properties['pickerImportStructureOnly'] -and $plan.pickerImportStructureOnly -eq $true)
  if($importStructure){
    Assert-CardsPickerImportStructurePlan $plan
    Open-CardsZipImportTarget $process $root $window $containerCardId $goalCardId $clock
    $picker=Open-CardsZipPicker $process $root $window $goalCardId 'PilotGoal' 5124
  }else{
    $picker = Open-CardsZipPicker $process $root $window $containerCardId 'PilotContainer' 5123
  }
  $ready=Wait-CardsPickerCancelReady $process $window $picker $clock
  $filenameObservation=$null
  if ($plan.kind -ceq 'cards-zip-filename-observation') {
    $filenameObservation=Set-CardsZipPath $process $picker $plan $clock
    if (($plan.PSObject.Properties['pickerNavigationOnly'] -and $plan.pickerNavigationOnly -eq $true) -or $importStructure) {
      $currentReady=Wait-CardsPickerCancelReady $process $window $picker $clock
      Require ($currentReady.control -eq $ready.control) 'CARDS_PILOT_NAV: original Cancel control was recreated'
      $ready=$currentReady
    }
  }
  $null=Get-CardsPickerCancelReadinessBudget $clock.ElapsedMilliseconds
  Click-CardsPilotControl $process $picker 2 ([IntPtr]$ready.control)
  $remaining = 15000 - [int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original Cancel case budget expired'
  $null = Wait-CardsPilotState {
    -not [GraphCodeUiaGateState]::WindowIsVisible($picker)
  } 'owned native picker Cancel' $remaining
  Assert-CardsPilotNoMutation $parentGraph (Read-CardsPilotGraph $plan.support $plan.project)
  Require (-not (Test-Path -LiteralPath $plan.zipPath)) 'CARDS_PILOT_ZIP: Cancel created an archive'
  Assert-CardsPilotIsolation $scope $plan 'zip-cancel-before-dispatch'
  $cancel = [ordered]@{ case='zip-picker-cancel'; nativePointer=$true; graphUnchanged=$true; archiveAbsent=$true }
  if ($plan.kind -ceq 'cards-zip-filename-observation') {
    $cancel.case='zip-filename-cancel-observation'
    $cancel['filenameObservation']=$filenameObservation
    if ($plan.PSObject.Properties['pickerStructureOnly'] -and $plan.pickerStructureOnly -eq $true) {
      $cancel.case='zip-picker-structure-cancel-observation'
      $cancel['transferEffects']=0
      $cancel['filenameEdits']=0
      $cancel['menuAndCancelActionsNonzero']=$true
    }
    if ($plan.PSObject.Properties['pickerNavigationOnly'] -and $plan.pickerNavigationOnly -eq $true) {
      $cancel.case='zip-picker-navigation-cancel-qualification'
      $cancel['transferEffects']=0
      $cancel['filenameEdits']=0
      $cancel['menuAndCancelActionsNonzero']=$true
    }
    if($plan.PSObject.Properties['pickerNativeFilenameOnly'] -and $plan.pickerNativeFilenameOnly -eq $true){
      $cancel.case='zip-picker-native-filename-cancel-qualification'
      $cancel['filenameEdits']=$filenameObservation.filenameEdits
    }
    if($plan.PSObject.Properties['pickerNativeFilenameReadbackOnly'] -and $plan.pickerNativeFilenameReadbackOnly -eq $true){
      $cancel.case='zip-picker-native-filename-readback-cancel-observation'
    }
    if($importStructure){$cancel.case='zip-import-picker-structure-cancel-observation'}
  }
  $results.Add($cancel)
  Write-Host ('CARDS_PILOT_CASE_RESULT=' + ($cancel | ConvertTo-Json -Compress))
  if ($plan.kind -ceq 'cards-zip-filename-observation') { return }

  $export=Invoke-CardsZipExportCase $process $root $window $plan $scope $containerCardId $parentGraph
  $bundle=$export.bundle
  $proof=$export.proof
  $results.Add($export.save)
  Write-Host ('CARDS_PILOT_CASE_RESULT=' + ($export.save | ConvertTo-Json -Depth 6 -Compress))

  $clock = [Diagnostics.Stopwatch]::StartNew()
  $null = Read-CardsZipQuiescence $scope $plan $process $proof
  $popup = Open-CardsPilotCardMenu $process $root $window $containerCardId 'PilotContainer' 'ZIP containing graph'
  $openGroup = @(Get-PopupMenuItems $popup | Where-Object { $_.Id -eq 5113 -and $_.Enabled })
  Require ($openGroup.Count -eq 1) 'CARDS_PILOT_ZIP: exact Open Group entry absent'
  $hit = [GraphCodeUiaGateState]::ClickPopupMenuItemStrict($popup,$window,
    [int]$openGroup[0].Position,5113,[uint32]$process.Id)
  Require ($hit.ItemId -eq 5113 -and -not $hit.UsedKeyboardFallback -and
    -not $hit.UsedSelectItemFallback) 'CARDS_PILOT_ZIP: strict Open Group route required'
  $remaining = 15000 - [int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original import case budget expired'
  $null = Wait-CardsPilotState { Find-FragmentById $root $goalCardId $walker } 'owned import child canvas' $remaining
  $before = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $null = Read-CardsZipQuiescence $scope $plan $process $proof
  $picker = Open-CardsZipPicker $process $root $window $goalCardId 'PilotGoal' 5124
  Set-CardsZipPath $process $picker $plan
  Require ((Get-FileHash -LiteralPath $plan.zipPath -Algorithm SHA256).Hash -ceq $bundle.sha256) `
    'CARDS_PILOT_ZIP: owned archive changed before Open'
  Click-CardsPilotControl $process $picker 1
  $importStatus = 'Imported 1 loop(s); 0 session(s) restored. Embedded descendants may not carry all memory or session history.'
  $remaining = 15000 - [int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original import case budget expired after Open'
  $null = Wait-CardsPilotState {
    $status = Find-FragmentById $root 'status' $walker
    $status -and $status.Current.ProcessId -eq $process.Id -and $status.Current.Name -ceq $importStatus
  } 'normal App import completion status' $remaining
  $after = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $effect = Assert-CardsZipImport $before $after $goalId $plan.containingComposite $parentGraph.nodes[0]
  $expectedRoot = $parentGraph | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
  $expectedRoot.nodes[0].subGraph = $after
  Assert-CardsPilotNoMutation $expectedRoot (Read-CardsPilotGraph $plan.support $plan.project)
  $proof = [ordered]@{ status=$importStatus; statusMatched=$true; effectVerified=$true; drainError=$false
    ownerWindow=$window.ToInt64() }
  $null = Read-CardsZipQuiescence $scope $plan $process $proof
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_ZIP: import proof exceeded original case budget'
  $import = [ordered]@{ case='zip-open-import'; nativePointer=$true; filenameEntry='UIA.ValuePattern'
    normalTransferStatus=$importStatus; effect=$effect; archiveSha256=$bundle.sha256 }
  $results.Add($import)
  Write-Host ('CARDS_PILOT_CASE_RESULT=' + ($import | ConvertTo-Json -Depth 6 -Compress))
}

function Assert-CardsConnectedEdgePlan($plan) {
  if($plan.kind -cne 'cards-connected-edge-strict' -or $plan.caseCount -ne 1 -or
      $plan.desktopReservation.scope -cne 'one strict connected edge Edit/Cancel' -or
      @('pickerNavigationOnly','pickerNativeFilenameOnly','nativeImportOnly','nativeExportOnly'|
        Where-Object {$plan.PSObject.Properties[$_]}).Count){
    throw [InvalidOperationException]::new('CARDS_EDGE_PLAN: exact pointer-only connected edge Edit/Cancel scope required')
  }
}

function Get-CardsConnectedEdgePoint([double[]] $source, [double[]] $target, [double[]] $canvas) {
  foreach($rect in @($source,$target,$canvas)){
    if($rect.Count -ne 4 -or @($rect|Where-Object {[double]::IsNaN($_) -or [double]::IsInfinity($_)}).Count -or
        $rect[0] -ge $rect[2] -or $rect[1] -ge $rect[3]){
      throw [InvalidOperationException]::new('CARDS_EDGE_POINT: finite positive endpoint/canvas rectangles required')
    }
  }
  $x=[int](($source[2]+$target[0])/2);$y=[int](($source[1]+$source[3]+$target[1]+$target[3])/4)
  if($source[2] -ge $target[0] -or [Math]::Abs(($source[1]+$source[3])-($target[1]+$target[3])) -gt 2 -or
      $source[0] -lt $canvas[0] -or $target[2] -gt $canvas[2] -or
      [Math]::Min($source[1],$target[1]) -lt $canvas[1] -or [Math]::Max($source[3],$target[3]) -gt $canvas[3] -or
      $x -le $source[2] -or $x -ge $target[0] -or $y -le $canvas[1] -or $y -ge $canvas[3]){
    throw [InvalidOperationException]::new('CARDS_EDGE_POINT: single horizontal midpoint is not a clear contained edge target')
  }
  return @{x=$x;y=$y}
}

function Assert-CardsConnectedEdgeRoot($s, [int] $processId, [long] $owner) {
  if($processId -le 0 -or $owner -le 0 -or $s.processId -ne $processId -or
      $s.owner -ne $owner -or $s.window -le 0 -or $s.class -cne 'GraphCodeSheetHost' -or
      $s.contentClass -cne 'GraphCodeNativeForm' -or $s.captionless -ne $true -or $s.title -cne 'Edit edge'){
    throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: exact owned existing-edge form required')
  }
  if($null -eq $s.elapsedMilliseconds -or $null -eq $s.controlElapsedMilliseconds){
    throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: original case/control clocks required')
  }
  $null=Get-CardsPickerNavigationBudget $s.elapsedMilliseconds $s.controlElapsedMilliseconds
  foreach($child in @(@{row=$s.viewport;class='GraphCodeSheetViewport';parent=$s.window},
      @{row=$s.content;class='GraphCodeNativeForm';parent=$s.viewport.handle})){
    $r=$child.row
    if($null -eq $r -or $r.handle -le 0 -or $r.processId -ne $processId -or $r.controlId -ne 0 -or
        $r.class -cne $child.class -or $r.parent -ne $child.parent -or $r.matches -ne 1 -or
        $r.sameReading -ne $true -or $r.owned -ne $true -or [string]::IsNullOrWhiteSpace($r.runtime)){
      throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: unique current exact owned sheet child required')
    }
  }
}

function Assert-CardsConnectedEdgePrefill($s, [int] $processId, [long] $owner,
    [string] $from, [string] $to) {
  Assert-CardsConnectedEdgeRoot $s $processId $owner
  if([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to) -or $from -ieq $to){
    throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: distinct original endpoints required')
  }
  foreach($field in @(@{row=$s.source;id=9100;expected=$from},@{row=$s.target;id=9101;expected=$to})){
    $r=$field.row
    if($null -eq $r -or $r.handle -le 0 -or $r.processId -ne $processId -or $r.controlId -ne $field.id -or
        $r.parent -ne $s.content.handle -or $r.class -cne 'Edit' -or $r.owned -ne $true -or
        $r.readonly -ne $true -or $r.sameReading -ne $true -or
        [string]::IsNullOrWhiteSpace($r.runtime) -or $r.value -ine $field.expected){
      throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: original native endpoint identity/value changed')
    }
  }
  if($s.source.handle -eq $s.target.handle){
    throw [InvalidOperationException]::new('CARDS_EDGE_PREFILL: distinct native endpoint fields required')
  }
}

function Invoke-CardsConnectedEdgeCase($process, $root, [IntPtr] $window, $plan, $scope,
    [string] $goalId, [string] $peerId) {
  Assert-CardsConnectedEdgePlan $plan
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $before=Read-CardsPilotGraph $plan.support $plan.project
  $child=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite
  $edges=@($child.edges)
  Require (@($child.nodes).Count -eq 2 -and $edges.Count -eq 1 -and
    $edges[0].from -ieq $goalId -and $edges[0].to -ieq $peerId) 'CARDS_EDGE_SEED: exact connected source/target required'
  $containerCardId=Get-MultiProjectAutomationId 'project-card' ([string]$before.project.path) $plan.containingComposite
  $sourceId=Get-MultiProjectAutomationId 'project-card' ([string]$before.project.path) $goalId
  $targetId=Get-MultiProjectAutomationId 'project-card' ([string]$before.project.path) $peerId
  Open-CardsZipImportTarget $process $root $window $containerCardId $sourceId $clock
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $canvas=Find-FragmentByIdWithRetry $root 'graph' $walker
  $source=Find-FragmentByIdWithRetry $root $sourceId $walker
  $target=Find-FragmentByIdWithRetry $root $targetId $walker
  foreach($element in @($canvas,$source,$target)){
    Require ($null -ne $element -and $element.Current.ProcessId -eq $process.Id -and
      -not $element.Current.IsOffscreen) 'CARDS_EDGE_POINT: exact owned visible canvas/endpoints required'
  }
  Require ($source.Current.AutomationId -ceq $sourceId -and $source.Current.Name -ceq 'PilotGoal' -and
    $target.Current.AutomationId -ceq $targetId -and $target.Current.Name -ceq 'PilotPeer') `
    'CARDS_EDGE_POINT: stable endpoint identities differ'
  $a=$source.Current.BoundingRectangle;$b=$target.Current.BoundingRectangle;$c=$canvas.Current.BoundingRectangle
  $point=Get-CardsConnectedEdgePoint @($a.Left,$a.Top,$a.Right,$a.Bottom) @($b.Left,$b.Top,$b.Right,$b.Bottom) `
    @($c.Left,$c.Top,$c.Right,$c.Bottom)
  $null=Get-CardsPickerNavigationBudget $clock.ElapsedMilliseconds 0
  Require (Ensure-ShellForeground $window 'strict connected edge context') 'CARDS_EDGE_POINT: owned foreground refused'
  $input=@([GraphCodeUiaGateState]::ClickOwnedScreenRectangle($window,$point.x,$point.y,($point.x+1),($point.y+1),$true))
  Require ($input.Count -eq 8 -and $input[6] -eq 2 -and $input[7] -eq 2) 'CARDS_EDGE_POINT: native right-click count differs'
  $popup=Wait-ForPopupMenu $process $window 'strict connected edge'
  $items=@(Get-PopupMenuItems $popup)
  $edit=@($items|Where-Object {$_.Id -eq 5110 -and $_.Enabled})
  Require (($items.Id -join ',') -ceq '5110,5111' -and $edit.Count -eq 1) 'CARDS_EDGE_MENU: exact single-edge Edit/Delete menu required'
  $null=Get-CardsPickerNavigationBudget $clock.ElapsedMilliseconds 0
  $hit=[GraphCodeUiaGateState]::ClickPopupMenuItemStrict($popup,$window,[int]$edit[0].Position,5110,[uint32]$process.Id)
  Require ($null -ne $hit -and $hit.ItemId -eq 5110 -and
    $hit.CursorAtX -ge $hit.Left -and $hit.CursorAtX -lt $hit.Right -and
    $hit.CursorAtY -ge $hit.Top -and $hit.CursorAtY -lt $hit.Bottom -and -not $hit.UsedKeyboardFallback -and
    -not $hit.UsedSelectItemFallback) 'CARDS_EDGE_MENU: strict native Edit pointer required'
  $controlClock=[Diagnostics.Stopwatch]::StartNew()
  $modal=Get-CardsPilotModal $process 'Edit edge'
  $prefill=@{processId=[GraphCodeUiaGateState]::WindowProcessId($modal)
    window=$modal.ToInt64();owner=[GraphCodeUiaGateState]::WindowOwner($modal).ToInt64()
    class=[GraphCodeUiaGateState]::WindowClass($modal);title=[GraphCodeUiaGateState]::WindowTitle($modal)
    contentClass=[GraphCodeUiaGateState]::SheetContentClass($modal)
    captionless=[GraphCodeUiaGateState]::IsCaptionlessSheet($modal)}
  try {
    Require ($prefill.processId -eq $process.Id -and $prefill.owner -eq $window.ToInt64() -and
      $prefill.class -ceq 'GraphCodeSheetHost' -and $prefill.contentClass -ceq 'GraphCodeNativeForm' -and
      $prefill.captionless -and $prefill.title -ceq 'Edit edge') `
      'CARDS_EDGE_PREFILL: exact current native form owner/class required before reads'
    $parent=$modal
    foreach($child in @(@{name='viewport';class='GraphCodeSheetViewport'},@{name='content';class='GraphCodeNativeForm'})){
      $null=Get-CardsPickerNavigationBudget $clock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
      $handle=[GraphCodeUiaGateState]::FindChild($parent,$child.class)
      Require ($handle -ne [IntPtr]::Zero -and
        [GraphCodeUiaGateState]::WindowProcessId($handle) -eq $process.Id) `
        'CARDS_EDGE_PREFILL: exact native sheet child required before UIA lookup'
      $element=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
      $runtime=$element.GetRuntimeId() -join ','
      $sibling=$walker.GetFirstChild([System.Windows.Automation.AutomationElement]::FromHandle($parent))
      $visited=0;$matches=0
      while($null -ne $sibling){
        $null=Get-CardsPickerNavigationBudget $clock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
        Require ($visited -lt 32 -and $sibling.Current.ProcessId -eq $process.Id) `
          'CARDS_EDGE_PREFILL: bounded exact owned direct sheet children required'
        $siblingHandle=[IntPtr]::new([long]$sibling.Current.NativeWindowHandle)
        if($siblingHandle -ne [IntPtr]::Zero -and
            [GraphCodeUiaGateState]::WindowClass($siblingHandle) -ceq $child.class){$matches++}
        $visited++;$sibling=$walker.GetNextSibling($sibling)
      }
      $prefill[$child.name]=@{handle=$handle.ToInt64();processId=[GraphCodeUiaGateState]::WindowProcessId($handle)
        parent=([long]$walker.GetParent($element).Current.NativeWindowHandle)
        class=[GraphCodeUiaGateState]::WindowClass($handle);controlId=[GraphCodeUiaGateState]::ControlIdOf($handle)
        matches=$matches;runtime=$runtime;owned=[GraphCodeUiaGateState]::IsControlOwnedBy($modal,$handle,0)
        sameReading=([GraphCodeUiaGateState]::FindChild($parent,$child.class) -eq $handle -and
          ($element.GetRuntimeId() -join ',') -ceq $runtime)}
      $parent=$handle
    }
    $prefill.elapsedMilliseconds=$clock.ElapsedMilliseconds
    $prefill.controlElapsedMilliseconds=$controlClock.ElapsedMilliseconds
    Assert-CardsConnectedEdgeRoot $prefill $process.Id $window.ToInt64()
  } catch {
    Write-Host ('CARDS_EDGE_FORM_STRUCTURE_REFUSAL=' + ([ordered]@{
      observed=[DateTimeOffset]::Now.ToString('o');window=$prefill.window;processId=$prefill.processId
      expectedProcessId=$process.Id;owner=$prefill.owner;expectedOwner=$window.ToInt64()
      class=$prefill.class;contentClass=$prefill.contentClass;captionless=$prefill.captionless
      expectedTitleMatches=($prefill.title -ceq 'Edit edge');viewport=$prefill.viewport;content=$prefill.content
      elapsedMilliseconds=$clock.ElapsedMilliseconds;controlElapsedMilliseconds=$controlClock.ElapsedMilliseconds
    }|ConvertTo-Json -Depth 4 -Compress))
    throw
  }
  foreach($field in @(@{name='source';id=9100},@{name='target';id=9101})){
    $handle=[GraphCodeUiaGateState]::ControlById($modal,$field.id)
    Require ($handle -ne [IntPtr]::Zero -and
      [GraphCodeUiaGateState]::WindowProcessId($handle) -eq $process.Id -and
      [GraphCodeUiaGateState]::WindowClass($handle) -ceq 'Edit' -and
      [GraphCodeUiaGateState]::ControlById([IntPtr]::new($prefill.content.handle),$field.id) -eq $handle -and
      [GraphCodeUiaGateState]::IsControlOwnedBy($modal,$handle,$field.id)) `
      'CARDS_EDGE_PREFILL: exact native endpoint ownership required before reads'
    $element=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
    Require ($element.Current.ProcessId -eq $process.Id) 'CARDS_EDGE_PREFILL: endpoint UIA process changed'
    $runtime=($element.GetRuntimeId() -join ',')
    $valuePattern=$element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value=[GraphCodeMultiProjectEditNative]::Buffer($handle,100)
    $prefill[$field.name]=@{handle=$handle.ToInt64();parent=$prefill.content.handle
      processId=[GraphCodeUiaGateState]::WindowProcessId($handle)
      controlId=[GraphCodeUiaGateState]::ControlIdOf($handle);class=[GraphCodeUiaGateState]::WindowClass($handle)
      owned=[GraphCodeUiaGateState]::IsControlOwnedBy($modal,$handle,$field.id);runtime=$runtime;value=$value
      readonly=$valuePattern.Current.IsReadOnly
      sameReading=([GraphCodeUiaGateState]::ControlById($modal,$field.id) -eq $handle -and
        ($element.GetRuntimeId() -join ',') -ceq $runtime)}
  }
  $prefill.elapsedMilliseconds=$clock.ElapsedMilliseconds
  $prefill.controlElapsedMilliseconds=$controlClock.ElapsedMilliseconds
  Assert-CardsConnectedEdgePrefill $prefill $process.Id $window.ToInt64() $goalId $peerId
  $null=Get-CardsPickerNavigationBudget $clock.ElapsedMilliseconds $controlClock.ElapsedMilliseconds
  Click-CardsPilotControl $process $modal 2
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_EDGE_CANCEL: original case deadline expired'
  $null=Wait-CardsPilotState { -not [GraphCodeUiaGateState]::WindowIsVisible($modal) } 'strict edge Cancel closed exact form' $remaining
  Assert-CardsPilotNoMutation $before (Read-CardsPilotGraph $plan.support $plan.project)
  Assert-CardsPilotIsolation $scope $plan 'after-strict-connected-edge-cancel'
  return [ordered]@{case='strict-connected-edge-edit-cancel';nativePointer=$true;edgeId=$edges[0].id
    sourceId=$goalId;targetId=$peerId;point=$point;rightClickEvents=2;menuHit=$hit;prefill=$prefill
    strictCancel=$true;graphUnchanged=$true;commandFallback=$false;keyboardFallback=$false
    alternatePointAttempts=0;transferEffects=0;elapsedMilliseconds=$clock.ElapsedMilliseconds}
}

function Get-CardsPilotModal($process, [string] $title) {
  try {
    $window = Wait-CardsPilotState {
      $candidate = [GraphCodeUiaGateState]::FindVisibleProcessWindow([uint32]$process.Id, $title)
      if ($candidate -ne [IntPtr]::Zero) { return $candidate }
      return $null
    } "native modal $title" 5000
  } catch {
    $modalFailure = $_
    try {
      Write-Host ('CARDS_PILOT_MODAL_REFUSAL=' + ([ordered]@{
        processId=$process.Id; expectedTitle=$title
        ownedTopLevels=@([GraphCodeUiaGateState]::DescribeTopLevelWindows([uint32]$process.Id))
      } | ConvertTo-Json -Depth 5 -Compress))
    } catch { Write-Warning "Owned modal refusal diagnostics failed: $_" }
    throw $modalFailure
  }
  Require ([GraphCodeUiaGateState]::WindowProcessId($window) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowIsVisible($window) -and
    [GraphCodeUiaGateState]::WindowTitle($window) -ceq $title) 'CARDS_PILOT_MODAL: wrong native identity'
  return $window
}

function Test-CardsPickerCancelReady($previous, $current, [int] $processId, [long] $owner, [long] $window,
    [int] $expectedId=2, [string] $expectedClass='Button') {
  if ($null -eq $previous -or $null -eq $current -or $processId -le 0) { return $false }
  foreach ($sample in @($previous,$current)) {
    if ($sample.processId -ne $processId -or $sample.rootProcessId -ne $processId -or
        $sample.controlProcessId -ne $processId -or $sample.owner -ne $owner -or
        $sample.root -ne $window -or $sample.rootClass -cne '#32770' -or
        $sample.control -eq 0 -or $sample.controlId -ne $expectedId -or $sample.controlClass -cne $expectedClass -or
        $sample.owned -ne $true -or $sample.visible -ne $true -or $sample.enabled -ne $true -or
        $sample.hitViable -ne $true -or $sample.sameReading -ne $true -or
        @($sample.rootBounds).Count -ne 4 -or @($sample.controlBounds).Count -ne 4) { return $false }
    $r=$sample.rootBounds; $c=$sample.controlBounds
    if ($r[2] -le $r[0] -or $r[3] -le $r[1] -or $c[2]-$c[0] -lt 3 -or $c[3]-$c[1] -lt 3 -or
        $c[0] -lt $r[0] -or $c[1] -lt $r[1] -or $c[2] -gt $r[2] -or $c[3] -gt $r[3]) { return $false }
  }
  return $previous.control -eq $current.control -and
    ($previous.rootBounds -join ',') -ceq ($current.rootBounds -join ',') -and
    ($previous.controlBounds -join ',') -ceq ($current.controlBounds -join ',')
}

function Get-CardsPickerCancelReadinessBudget([long] $elapsedMilliseconds) {
  $remaining=15000-$elapsedMilliseconds-5000
  if ($elapsedMilliseconds -lt 0 -or $remaining -le 0) {
    throw [InvalidOperationException]::new('CARDS_PILOT_ZIP: original picker Cancel budget cannot admit control readiness')
  }
  return [int][Math]::Min(5000,$remaining)
}

function Get-CardsPickerCancelSnapshot($process, [IntPtr] $owner, [IntPtr] $window,
    [IntPtr] $expectedControl=[IntPtr]::Zero, [int] $expectedId=2, [string] $expectedClass='Button') {
  Require ([GraphCodeUiaGateState]::WindowProcessId($owner) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowProcessId($window) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowOwner($window) -eq $owner -and
    [GraphCodeUiaGateState]::WindowClass($window) -ceq '#32770' -and
    [GraphCodeUiaGateState]::WindowIsVisible($window) -and
    -not [GraphCodeUiaGateState]::WindowIsEnabled($owner)) 'CARDS_PILOT_ZIP: picker readiness lost its exact modal owner'
  $control=if($expectedControl -eq [IntPtr]::Zero){[GraphCodeUiaGateState]::ControlById($window,$expectedId)}else{$expectedControl}
  if ($control -eq [IntPtr]::Zero) { return $null }
  Require ([GraphCodeUiaGateState]::IsControlOwnedBy($window,$control,$expectedId) -and
    [GraphCodeUiaGateState]::WindowProcessId($control) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowClass($control) -ceq $expectedClass) `
    'CARDS_PILOT_ZIP: picker readiness found a different native Cancel identity'
  $beforeRoot=[GraphCodeUiaGateState]::WindowBounds($window)
  $beforeControl=[GraphCodeUiaGateState]::WindowBounds($control)
  $visible=[GraphCodeUiaGateState]::WindowIsVisible($control)
  $enabled=[GraphCodeUiaGateState]::WindowIsEnabled($control)
  $viable=$false
  if ($visible -and $enabled -and @($beforeControl).Count -eq 4 -and
      $beforeControl[2] -gt $beforeControl[0] -and $beforeControl[3] -gt $beforeControl[1]) {
    $point=[GraphCode.Windows.UiaInputSafety+ScreenPoint]::new()
    $point.X=[int][Math]::Floor(($beforeControl[0]+$beforeControl[2])/2)
    $point.Y=[int][Math]::Floor(($beforeControl[1]+$beforeControl[3])/2)
    $bridge=[GraphCodeUiaGateState].GetMethod('ResolvesToControl',
      [Reflection.BindingFlags]'NonPublic,Static')
    Require ($null -ne $bridge) 'CARDS_PILOT_ZIP: existing native exact-hit bridge unavailable'
    $viable=[bool]$bridge.Invoke($null,[object[]]@($control,$window,$point))
  }
  $afterRoot=[GraphCodeUiaGateState]::WindowBounds($window)
  $afterControl=[GraphCodeUiaGateState]::WindowBounds($control)
  return [ordered]@{
    observedAt=[DateTimeOffset]::Now.ToString('o'); processId=$process.Id
    owner=[GraphCodeUiaGateState]::WindowOwner($window).ToInt64(); root=$window.ToInt64()
    rootProcessId=[GraphCodeUiaGateState]::WindowProcessId($window)
    rootClass=[GraphCodeUiaGateState]::WindowClass($window); rootBounds=$afterRoot
    control=$control.ToInt64(); controlProcessId=[GraphCodeUiaGateState]::WindowProcessId($control)
    controlId=[GraphCodeUiaGateState]::ControlIdOf($control)
    controlClass=[GraphCodeUiaGateState]::WindowClass($control); controlBounds=$afterControl
    owned=[GraphCodeUiaGateState]::IsControlOwnedBy($window,$control,$expectedId)
    visible=$visible; enabled=$enabled; hitViable=$viable
    sameReading=(($expectedControl -ne [IntPtr]::Zero -or
        [GraphCodeUiaGateState]::ControlById($window,$expectedId) -eq $control) -and
      ($beforeRoot -join ',') -ceq ($afterRoot -join ',') -and
      ($beforeControl -join ',') -ceq ($afterControl -join ','))
  }
}

function Wait-CardsPickerCancelReady($process, [IntPtr] $owner, [IntPtr] $window, $clock, [int] $expectedId=2) {
  Require ($expectedId -in @(1,2)) 'CARDS_PILOT_ZIP: picker readiness supports only exact Save or Cancel buttons'
  $budget=Get-CardsPickerCancelReadinessBudget $clock.ElapsedMilliseconds
  $state=@{previous=$null;samples=0}
  $ready=Wait-CardsPilotState {
    $sample=Get-CardsPickerCancelSnapshot $process $owner $window ([IntPtr]::Zero) $expectedId
    $state.samples++
    Write-Host ('CARDS_PILOT_PICKER_CONTROL_OBSERVATION='+($sample|ConvertTo-Json -Depth 4 -Compress))
    $matches=Test-CardsPickerCancelReady $state.previous $sample $process.Id $owner.ToInt64() $window.ToInt64() $expectedId
    $state.previous=$sample
    if ($matches) { return $sample }
    return $null
  } 'exact owned native button identity, stable geometry and read-only hit viability' $budget
  $null=Get-CardsPickerCancelReadinessBudget $clock.ElapsedMilliseconds
  Write-Host ('CARDS_PILOT_PICKER_CONTROL_READY='+([ordered]@{
    samples=$state.samples;elapsedMilliseconds=$clock.ElapsedMilliseconds;target=$ready
    inputCalls=0;originalTransactionMilliseconds=15000;reservedInputMarginMilliseconds=5000
  }|ConvertTo-Json -Depth 5 -Compress))
  return $ready
}

function Click-CardsPilotControl($process, [IntPtr] $window, [int] $id,
    [IntPtr] $expectedControl = [IntPtr]::Zero) {
  Require (Ensure-ShellForeground $window "cards pilot control $id") 'CARDS_PILOT_CONTROL: foreground refused'
  $control = [GraphCodeUiaGateState]::ControlById($window, $id)
  Require ($control -ne [IntPtr]::Zero -and
    [GraphCodeUiaGateState]::IsControlOwnedBy($window, $control, $id) -and
    [GraphCodeUiaGateState]::WindowProcessId($window) -eq $process.Id -and
    [GraphCodeUiaGateState]::WindowIsEnabled($control)) 'CARDS_PILOT_CONTROL: exact enabled owner/control required'
  Require ($expectedControl -eq [IntPtr]::Zero -or $control -eq $expectedControl) `
    'CARDS_PILOT_CONTROL: ready control was replaced before strict input'
  if ($expectedControl -ne [IntPtr]::Zero) {
    Write-Host ('CARDS_PILOT_CONTROL_RETAINED_TARGET='+([ordered]@{
      observedAt=[DateTimeOffset]::Now.ToString('o'); processId=$process.Id
      root=$window.ToInt64();rootProcessId=[GraphCodeUiaGateState]::WindowProcessId($window)
      rootClass=[GraphCodeUiaGateState]::WindowClass($window);rootBounds=[GraphCodeUiaGateState]::WindowBounds($window)
      control=$control.ToInt64();controlProcessId=[GraphCodeUiaGateState]::WindowProcessId($control)
      controlClass=[GraphCodeUiaGateState]::WindowClass($control);controlId=[GraphCodeUiaGateState]::ControlIdOf($control)
      controlBounds=[GraphCodeUiaGateState]::WindowBounds($control)
    }|ConvertTo-Json -Depth 4 -Compress))
  }
  $hit = [GraphCodeUiaGateState]::ClickScreenPoint($control)
  if ($expectedControl -ne [IntPtr]::Zero) {
    Write-Host ('CARDS_PILOT_CONTROL_RETAINED_AFTER_PROBE='+([ordered]@{
      observedAt=[DateTimeOffset]::Now.ToString('o');processId=$process.Id
      root=$window.ToInt64();rootBounds=[GraphCodeUiaGateState]::WindowBounds($window)
      control=$control.ToInt64();controlBounds=[GraphCodeUiaGateState]::WindowBounds($control)
      currentControl=[GraphCodeUiaGateState]::ControlById($window,$id).ToInt64()
      hitAvailable=($null -ne $hit);hitTarget=($null -ne $hit -and $hit.HitTarget)
    }|ConvertTo-Json -Depth 4 -Compress))
  }
  Assert-CardsPilotPointer $hit $process.Id $id
  Write-Host ("CARDS_PILOT_NATIVE_CONTROL=" + ([ordered]@{
    processId = $process.Id; window = Format-WindowHandle $window; controlId = $id
    point = @($hit.ScreenX,$hit.ScreenY); hitTarget = $hit.HitTarget
    keyboardFallback = $false; commandFallback = $false
  } | ConvertTo-Json -Compress))
}

function Set-CardsPilotField($process, [IntPtr] $window, [int] $id, [string] $text) {
  Require (Ensure-ShellForeground $window "cards pilot field $id") 'CARDS_PILOT_FIELD: foreground refused'
  $control = [GraphCodeUiaGateState]::ControlById($window, $id)
  Require ($control -ne [IntPtr]::Zero -and
    [GraphCodeUiaGateState]::IsControlOwnedBy($window, $control, $id) -and
    [GraphCodeUiaGateState]::WindowProcessId($window) -eq $process.Id) 'CARDS_PILOT_FIELD: wrong owner/control'
  $watch = [Diagnostics.Stopwatch]::StartNew()
  Click-CardsPilotControl $process $window $id
  $null = Wait-CardsPilotState {
    [GraphCodeUiaGateState]::FocusedControlInDialog($window) -eq $control
  } 'native field pointer focus' 5000
  $remaining = 5000 - [int]$watch.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_FIELD: native focus exceeded transaction deadline'
  [GraphCodeMultiProjectEditNative]::SelectAll($control, $remaining)
  $before = [GraphCodeMultiProjectEditNative]::Buffer($control, 100)
  $selection = [GraphCodeMultiProjectEditNative]::Selection($control, 100)
  Require ($selection[0] -eq 0 -and $selection[1] -eq $before.Length) `
    'CARDS_PILOT_FIELD: native edit selection differs'
  Require ([GraphCodeUiaGateState]::SendKeyInput($window, [uint32]$process.Id, $control, 0x2E, 1) -eq 1) `
    'CARDS_PILOT_FIELD: native Delete input count differs'
  $remaining = 5000 - [int]$watch.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_FIELD: native clear exceeded transaction deadline'
  $null = Wait-CardsPilotState {
    [string]::IsNullOrEmpty([GraphCodeMultiProjectEditNative]::Buffer($control, 100))
  } 'native field empty buffer' $remaining
  $typed = [GraphCodeUiaGateState]::SendUnicodeInput($window, [uint32]$process.Id, $control, $text)
  Require ($typed[0] -eq $typed[1] -and $typed[1] -eq 2 * $text.Length -and $typed[1] -gt 0) `
    'CARDS_PILOT_FIELD: native Unicode input count differs'
  $remaining = 5000 - [int]$watch.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_FIELD: native typing exceeded transaction deadline'
  $null = Wait-CardsPilotState {
    [GraphCodeMultiProjectEditNative]::Buffer($control, 100) -ceq $text
  } 'native field exact buffer readback' $remaining
  Require ($watch.ElapsedMilliseconds -lt 5000 -and
    [GraphCodeUiaGateState]::FocusedControlInDialog($window) -eq $control -and
    [GraphCodeUiaGateState]::IsControlOwnedBy($window, $control, $id)) `
    'CARDS_PILOT_FIELD: native transaction deadline or final identity/focus changed'
  Write-Host ('CARDS_PILOT_NATIVE_FIELD=' + ([ordered]@{
    processId = $process.Id; window = Format-WindowHandle $window; controlId = $id
    clearEvents = 2; textEvents = $typed[0]; expectedTextEvents = $typed[1]
    exactReadback = $true; messageFallback = $false; focusFallback = $false
    elapsedMilliseconds = $watch.ElapsedMilliseconds
  } | ConvertTo-Json -Compress))
}

function Open-CardsPilotCardMenu($process, $root, [IntPtr] $window, [string] $cardId,
    [string] $expectedTitle, [string] $label) {
  Require (Ensure-ShellForeground $window "$label native context") 'CARDS_PILOT_MENU: owned foreground refused'
  $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $card = Find-FragmentByIdWithRetry $root $cardId $walker
  $canvas = Find-FragmentByIdWithRetry $root 'graph' $walker
  Require ($null -ne $card -and $null -ne $canvas -and
    $card.Current.AutomationId -ceq $cardId -and $card.Current.Name -ceq $expectedTitle -and
    $card.Current.ProcessId -eq $process.Id -and $canvas.Current.ProcessId -eq $process.Id -and
    -not $card.Current.IsOffscreen) 'CARDS_PILOT_MENU: stable owned card/canvas identity differs'
  $bounds = $card.Current.BoundingRectangle
  $canvasBounds = $canvas.Current.BoundingRectangle
  $rect = Get-MultiProjectClippedRectangle @($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom) `
    @($canvasBounds.Left,$canvasBounds.Top,$canvasBounds.Right,$canvasBounds.Bottom)
  $input = @([GraphCodeUiaGateState]::ClickOwnedScreenRectangle($window,
    [int]$rect[0],[int]$rect[1],[int]$rect[2],[int]$rect[3],$true))
  Require ($input.Count -eq 8 -and $input[6] -eq 2 -and $input[7] -eq 2) `
    'CARDS_PILOT_MENU: real right-click event count differs'
  Write-Host ('CARDS_PILOT_NATIVE_CONTEXT=' + ([ordered]@{
    processId=$process.Id; cardId=$cardId; title=$expectedTitle; point=@($input[4],$input[5])
    events=$input[6]; expectedEvents=$input[7]; postedMouseFallback=$false
  } | ConvertTo-Json -Compress))
  return Wait-ForPopupMenu $process $window $label
}

function Open-CardsPilotRetype($process, $root, [IntPtr] $window, [string] $nodeId,
    [int] $command, [string] $label, [string] $projectPath) {
  $cardId = Get-MultiProjectAutomationId 'project-card' $projectPath $nodeId
  $popup = Open-CardsPilotCardMenu $process $root $window $cardId 'PilotGoal' $label
  $items = @(Get-PopupMenuItems $popup)
  $target = @($items | Where-Object { $_.Id -eq $command -and $_.Enabled })
  Require ($target.Count -eq 1) "CARDS_PILOT_MENU: missing exact enabled command $command"
  $menu = [GraphCodeUiaGateState]::PopupMenuHandle($popup)
  Write-Host ('CARDS_PILOT_MENU_ENTRY=' + ([ordered]@{
    processId=$process.Id; owner=Format-WindowHandle $window; popup=Format-WindowHandle $popup
    menu=$menu.ToInt64(); ownerEnabled=[GraphCodeUiaGateState]::WindowIsEnabled($window)
    popupClass=[GraphCodeUiaGateState]::WindowClass($popup); command=$command
    items=ConvertTo-PopupMenuEvidence $items
  } | ConvertTo-Json -Depth 6 -Compress))
  try {
    $hit = [GraphCodeUiaGateState]::ClickPopupMenuItemStrict($popup, $window,
      [int]$target[0].Position, $command, [uint32]$process.Id)
  } catch {
    $menuFailure = $_
    try {
      Write-Host ('CARDS_PILOT_MENU_REFUSAL=' + ([ordered]@{
        processId=$process.Id; owner=Format-WindowHandle $window; popup=Format-WindowHandle $popup
        ownerEnabled=[GraphCodeUiaGateState]::WindowIsEnabled($window)
        popupVisible=[GraphCodeUiaGateState]::WindowIsVisible($popup)
        items=ConvertTo-PopupMenuEvidence @(Get-PopupMenuItems $popup)
        ownedTopLevels=@([GraphCodeUiaGateState]::DescribeTopLevelWindows([uint32]$process.Id))
      } | ConvertTo-Json -Depth 6 -Compress))
    } catch { Write-Warning "Owned popup refusal diagnostics failed: $_" }
    throw $menuFailure
  }
  Require ($hit.ItemId -eq $command -and -not $hit.UsedKeyboardFallback -and
    -not $hit.UsedSelectItemFallback) 'CARDS_PILOT_MENU: strict native route receipt differs'
  Write-Host ("CARDS_PILOT_NATIVE_MENU=" + ([ordered]@{
    nodeId = $nodeId; cardId = $cardId; commandId = $command; label = $target[0].Text
    position = $hit.Position; keyboardFallback = $false; selectItemFallback = $false
    nativeHit=$hit
  } | ConvertTo-Json -Compress))
  return Get-CardsPilotModal $process $label
}

function Invoke-CardsPilotRetypeCase($process, $root, [IntPtr] $window, $plan,
    [string] $nodeId, [string] $title, [string] $targetType, $scope) {
  $command = if ($targetType -ceq 'timeBased') { 5122 } else { 5121 }
  $label = 'Change ' + $title + $(if ($targetType -ceq 'timeBased') { ' to Timed' } else { ' to Goal' })
  $before = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $rootGraph = Read-CardsPilotGraph $plan.support $plan.project
  Assert-CardsPilotIsolation $scope $plan "before-$targetType"
  $null = Assert-CardsPilotTarget $before ([string]$before.project.path) $nodeId `
    $(if ($targetType -ceq 'timeBased') { 'goalBased' } else { 'timeBased' })
  $modal = Open-CardsPilotRetype $process $root $window $nodeId $command $label ([string]$rootGraph.project.path)
  Set-CardsPilotField $process $modal 9100 ' '
  $submit = [GraphCodeUiaGateState]::ControlById($modal, 1)
  Require ($submit -ne [IntPtr]::Zero -and [GraphCodeUiaGateState]::IsControlOwnedBy($modal,$submit,1)) `
    'CARDS_PILOT_INVALID: submit identity absent'
  $invalidInput = 'disabled-native-submit'
  if ([GraphCodeUiaGateState]::WindowIsEnabled($submit)) {
    Click-CardsPilotControl $process $modal 1
    $invalidInput = 'strict-native-pointer'
  }
  Start-Sleep -Milliseconds 250
  Require ([GraphCodeUiaGateState]::WindowIsVisible($modal)) 'CARDS_PILOT_INVALID: invalid input closed the modal'
  Assert-CardsPilotNoMutation $before (Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId)
  Assert-CardsPilotIsolation $scope $plan "invalid-$targetType"
  Write-Host "CARDS_PILOT_INVALID=command=$command input=$invalidInput positiveSavedGraphUnchanged=true"
  Click-CardsPilotControl $process $modal 2
  $null = Wait-CardsPilotState { -not [GraphCodeUiaGateState]::WindowIsVisible($modal) } 'native pointer cancel' 5000
  Assert-CardsPilotNoMutation $before (Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId)
  Assert-CardsPilotIsolation $scope $plan "cancel-$targetType"
  Write-Host "CARDS_PILOT_CANCEL=command=$command nativePointer=true positiveSavedGraphUnchanged=true"
  $modal = Open-CardsPilotRetype $process $root $window $nodeId $command $label ([string]$rootGraph.project.path)
  $decision = if ($targetType -ceq 'timeBased') { 'Run the owned pilot check' } else { 'Owned pilot goal is met' }
  Set-CardsPilotField $process $modal 9100 $decision
  if ($targetType -ceq 'timeBased') {
    Require ([GraphCodeUiaGateState]::ComboSelection($modal, 9101) -ceq '1|1h') `
      'CARDS_PILOT_FIELDS: retained default hourly choice differs'
    $decision = '/loop 1h ' + $decision
  }
  Click-CardsPilotControl $process $modal 1
  $null = Wait-CardsPilotState { -not [GraphCodeUiaGateState]::WindowIsVisible($modal) } 'native pointer submit' 5000
  $after = Wait-CardsPilotState {
    $graph = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
    if ($null -ne $graph -and @($graph.nodes | Where-Object {
        [string]$_.id -ieq $nodeId -and [string]$_.loopType -ceq $targetType }).Count -eq 1) { return $graph }
    return $null
  } "production daemon saved $targetType effect"
  $effect = Assert-CardsPilotRetype $before $after $nodeId $targetType $decision
  Assert-CardsPilotIsolation $scope $plan "effect-$targetType"
  $effect.nativePointer = $true
  $effect.productionDaemon = $true
  $effect.containingComposite = $plan.containingComposite
  Write-Host ('CARDS_PILOT_CASE_RESULT=' + ($effect | ConvertTo-Json -Depth 10 -Compress))
  return $effect
}

function Initialize-CardsPilotOnboarding([string] $root, [string] $support) {
  $ownedRoot = [IO.Path]::GetFullPath($root)
  $ownedSupport = [IO.Path]::GetFullPath((Join-Path $ownedRoot 'support'))
  if (-not [string]::Equals([IO.Path]::GetFullPath($support), $ownedSupport,
      [StringComparison]::OrdinalIgnoreCase)) {
    throw [InvalidOperationException]::new('CARDS_PILOT_READINESS: foreign onboarding support directory')
  }
  foreach ($directory in @($ownedRoot, $ownedSupport)) {
    if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw [InvalidOperationException]::new('CARDS_PILOT_READINESS: redirected onboarding fixture directory')
    }
  }
  $markerPath = Join-Path $ownedSupport 'onboarding-seen'
  $marker = [IO.FileStream]::new($markerPath, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::Read)
  $marker.Dispose()
  return [ordered]@{ context = 'precompleted-onboarding'; marker = $markerPath }
}

function Assert-CardsPilotRemovedTarget($before,$after,[string] $nodeId) {
  $null=Assert-CardsPilotTarget $before ([string]$before.project.path) $nodeId 'goalBased'
  if(@($before.nodes).Count -ne 2 -or @($before.edges).Count -ne 1) {
    throw [InvalidOperationException]::new('CARDS_PILOT_DRIFT: exact original two-node one-edge fixture required')
  }
  $expected=ConvertTo-Json -InputObject $before -Depth 50 | ConvertFrom-Json -AsHashtable
  $expected.nodes=@($expected.nodes | Where-Object { [string]$_.id -ine $nodeId })
  $expected.edges=@($expected.edges | Where-Object { [string]$_.from -ine $nodeId -and [string]$_.to -ine $nodeId })
  Assert-CardsPilotNoMutation $expected $after
}

function Test-CardsModeDriftOnly($plan) {
  return ($plan.kind -ceq 'cards-cancel-drift' -and $plan.caseCount -eq 1 -and
    $plan.PSObject.Properties['modeDriftOnly'] -and $plan.modeDriftOnly -is [bool] -and
    $plan.modeDriftOnly -eq $true)
}

function Assert-CardsModeRenderCheck([string]$phase,[Collections.IDictionary]$terms,
    [Collections.IDictionary]$metadata) {
  $failed=@($terms.Keys|Where-Object {$terms[$_] -isnot [bool] -or $terms[$_] -cne $true})
  if($terms.Count -eq 0 -or $failed.Count) {
    Write-Host ('CARDS_MODE_RENDER_REFUSAL='+([ordered]@{
      phase=$phase;terms=$terms;metadata=$metadata}|ConvertTo-Json -Depth 7 -Compress))
    throw [InvalidOperationException]::new(
      "CARDS_PILOT_DRIFT: mode render $phase failed terms: $($failed -join ',')")
  }
}

function Read-CardsModeRender($process,$root,[IntPtr]$window,[IntPtr]$foreground,[string]$cardId,
    [int]$red,[int]$green,[int]$blue,$caseClock=$null) {
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $check={
    Assert-CardsModeRenderCheck 'ownership' ([ordered]@{
      processRunning=(-not $process.HasExited);mainWindow=($process.MainWindowHandle -eq $window)
      rootPid=([GraphCodeUiaGateState]::WindowProcessId($window) -eq $process.Id)
      rootClass=([GraphCodeUiaGateState]::WindowClass($window) -ceq 'GraphCodeWindowsShell')
      rootOwner=([GraphCodeUiaGateState]::WindowOwner($window) -eq [IntPtr]::Zero)
      foregroundPid=([GraphCodeUiaGateState]::WindowProcessId($foreground) -eq $process.Id)
      foreground=([GraphCodeUiaGateState]::IsForegroundWindow($foreground))
    }) ([ordered]@{window=$window.ToInt64();foreground=$foreground.ToInt64();processId=$process.Id
      rootPid=[GraphCodeUiaGateState]::WindowProcessId($window)
      foregroundPid=[GraphCodeUiaGateState]::WindowProcessId($foreground)})
    if($foreground -ne $window) {
      Assert-CardsModeRenderCheck 'retained-sheet' ([ordered]@{
        foregroundOwner=([GraphCodeUiaGateState]::WindowOwner($foreground) -eq $window)
        sheetClass=([GraphCodeUiaGateState]::IsCaptionlessSheet($foreground))
      }) ([ordered]@{window=$window.ToInt64();foreground=$foreground.ToInt64()
        owner=[GraphCodeUiaGateState]::WindowOwner($foreground).ToInt64()})
    }
  }
  & $check
  $card=Find-FragmentById $root $cardId ([System.Windows.Automation.TreeWalker]::RawViewWalker)
  Assert-CardsModeRenderCheck 'card-identity' ([ordered]@{
    found=($null -ne $card)
    cardPid=($null -ne $card -and $card.Current.ProcessId -eq $process.Id)
    cardId=($null -ne $card -and $card.Current.AutomationId -ceq $cardId)
    cardRole=($null -ne $card -and $card.Current.Name -ceq 'PilotGoal')
  }) ([ordered]@{window=$window.ToInt64();processId=$process.Id})
  $rect=$card.Current.BoundingRectangle
  $bounds=[GraphCodeUiaAttribution]::Bounds($window)
  $width=$bounds.Right-$bounds.Left;$height=$bounds.Bottom-$bounds.Top
  $unit=$rect.Width/250.0
  Assert-CardsModeRenderCheck 'geometry' ([ordered]@{
    rootDimensions=($width -gt 0 -and $height -gt 0 -and $width -le 8192 -and $height -le 8192)
    cardGeometry=($unit -ge 1 -and $unit -le 4 -and [Math]::Abs($rect.Height-96*$unit) -le 1)
    cardContained=($rect.Left -ge $bounds.Left -and $rect.Top -ge $bounds.Top -and
      $rect.Right -le $bounds.Right -and $rect.Bottom -le $bounds.Bottom)
  }) ([ordered]@{rootBounds=@($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom)
    cardBounds=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom);unit=$unit
    expectedLogicalWidth=250;expectedLogicalHeight=96})
  # GraphCanvas.cardTextLayout/drawCardMetaRow place the solid type square here.
  $x=[int][Math]::Floor($rect.Left-$bounds.Left+14*$unit)
  $y=[int][Math]::Floor($rect.Bottom-$bounds.Top-14.5*$unit)
  $bitmap=[Drawing.Bitmap]::new($width,$height)
  try {
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
      $hdc=$graphics.GetHdc()
      try { $printed=[GraphCodeUiaAttribution]::PrintWindow($window,$hdc,2) }
      finally { $graphics.ReleaseHdc($hdc) }
    } finally { $graphics.Dispose() }
    Require $printed 'CARDS_PILOT_DRIFT: exact owned window render unavailable'
    $pixels=@(foreach($offset in @(-1,0,1)) {
      $pixel=$bitmap.GetPixel($x+$offset,$y)
      [ordered]@{r=[int]$pixel.R;g=[int]$pixel.G;b=[int]$pixel.B}
    })
  } finally { $bitmap.Dispose() }
  & $check
  $proof=[ordered]@{window=$window.ToInt64();processId=$process.Id;cardId=$cardId
    runtime=($card.GetRuntimeId()-join ',');cardBounds=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
    sample=@($x,$y);pixels=$pixels;elapsedMilliseconds=$clock.ElapsedMilliseconds
    expected=@($red,$green,$blue);deadlineMilliseconds=5000;caseDeadlineMilliseconds=15000
    caseClockStarted=($null -ne $caseClock)
    caseElapsedMilliseconds=$(if($caseClock){$caseClock.ElapsedMilliseconds}else{0})
    rootBounds=@($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom)
    foreground=$foreground.ToInt64()
    foregroundBounds=$(if($foreground -ne $window){
      $sheetBounds=[GraphCodeUiaAttribution]::Bounds($foreground)
      @($sheetBounds.Left,$sheetBounds.Top,$sheetBounds.Right,$sheetBounds.Bottom)
    }else{@($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom)})
    capturedFiles=0;scope='Existing PrintWindow getter, exact owned root only; three source-derived solid type-square pixels'}
  Assert-CardsModeRenderCheck 'sample' ([ordered]@{
    controlDeadline=($clock.ElapsedMilliseconds -lt 5000)
    pixelsMatch=(@($pixels|Where-Object {$_.r -ne $red -or $_.g -ne $green -or $_.b -ne $blue}).Count -eq 0)
  }) $proof
  Write-Host ('CARDS_MODE_RENDER='+($proof|ConvertTo-Json -Depth 6 -Compress))
  return $proof
}

function Invoke-CardsModeDriftCase($process,$root,[IntPtr] $window,$plan,$scope,
    [hashtable] $environment,[string] $goalId) {
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $before=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $parent=Read-CardsPilotGraph $plan.support $plan.project
  $null=Assert-CardsPilotTarget $before ([string]$before.project.path) $goalId 'goalBased'
  Assert-CardsPilotIsolation $scope $plan 'before-captured-cli-mode-drift'
  $cardId=Get-MultiProjectAutomationId 'project-card' ([string]$parent.project.path) $goalId
  $goalRender=Read-CardsModeRender $process $root $window $window $cardId 25 158 112
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $modal=Open-CardsPilotRetype $process $root $window $goalId 5122 `
    'Change PilotGoal to Timed' ([string]$parent.project.path)
  Set-CardsPilotField $process $modal 9100 'Stale owned task must never be submitted'
  $prompt='/loop 1h Deliberate owned fixture mode drift'
  Invoke-CardsPilotCli $scope $plan $environment @('node','promote',$plan.project,$goalId,
    '--type','time','--prompt',$prompt) 'deliberate-cli-mode-drift'
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 5000) 'CARDS_PILOT_DRIFT: original mode-drift budget cannot admit submission'
  $changed=Wait-CardsPilotState {
    $current=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
    if($current -and @($current.nodes|Where-Object {
        [string]$_.id -ieq $goalId -and $_.loopType -ceq 'timeBased'}).Count -eq 1) { return $current }
  } 'exact saved same-child Timed mode before stale submit' ($remaining-5000)
  $effect=Assert-CardsPilotRetype $before $changed $goalId 'timeBased' $prompt
  $changedParent=Read-CardsPilotGraph $plan.support $plan.project
  Assert-CardsPilotIsolation $scope $plan 'after-deliberate-cli-mode-drift'
  $timedRender=Read-CardsModeRender $process $root $window $modal $cardId 201 133 0 $clock
  Assert-CardsModeRenderCheck 'retained-card' ([ordered]@{
    cardRuntime=($timedRender.runtime -ceq $goalRender.runtime)
    cardGeometry=((ConvertTo-CardsPilotCanonicalJson $timedRender.cardBounds) -ceq
      (ConvertTo-CardsPilotCanonicalJson $goalRender.cardBounds))
  }) ([ordered]@{beforeRuntime=$goalRender.runtime;afterRuntime=$timedRender.runtime
    beforeBounds=$goalRender.cardBounds;afterBounds=$timedRender.cardBounds})
  Require ([GraphCodeUiaGateState]::WindowIsVisible($modal)) `
    'CARDS_PILOT_DRIFT: captured form disappeared before stale submission'
  Require ((15000-[int]$clock.ElapsedMilliseconds) -gt 5000) `
    'CARDS_PILOT_DRIFT: original mode-drift budget cannot admit another input'
  Click-CardsPilotControl $process $modal 1
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_DRIFT: original stale-mode submit budget expired'
  $null=Wait-CardsPilotState {
    $status=Find-FragmentById $root 'status' $walker
    -not [GraphCodeUiaGateState]::WindowIsVisible($modal) -and $status -and
      $status.Current.ProcessId -eq $process.Id -and
      $status.Current.Name -ceq 'Loop type change context changed. Nothing was submitted; reopen the loop menu.'
  } 'exact App stale-mode refusal without retry' $remaining
  Assert-CardsPilotNoMutation $changedParent (Read-CardsPilotGraph $plan.support $plan.project)
  Assert-CardsPilotNoMutation $changed (Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId)
  Assert-CardsPilotIsolation $scope $plan 'stale-mode-refused-after-status'
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_DRIFT: original mode-drift budget exceeded'
  $result=[ordered]@{case='retype-mode-context-drift';nativePointer=$true;targetId=$goalId
    deliberateCliRetype=$effect;savedModeObservedBeforeSubmit=$true
    appModeObservedBeforeSubmit=$true;goalRender=$goalRender;timedRender=$timedRender
    appModeMismatchProvedByExactRefusal=$true;explicitNothingSubmitted=$true
    comparisonBaseline='after-deliberate-cli-mode-drift';postDeliberateGraphUnchanged=$true
    elapsedMilliseconds=$clock.ElapsedMilliseconds
    proofLimit='Pre-submit App observation is exact source-derived rendered type-square color, not a UIA type property or whole-card raster/parity claim'}
  Write-Host ('CARDS_PILOT_CASE_RESULT='+($result|ConvertTo-Json -Depth 8 -Compress))
  return $result
}

function Invoke-CardsCancelDriftCases($process,$root,[IntPtr] $window,$plan,$scope,
    [hashtable] $environment,[string] $goalId,$results) {
  $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker
  $parentBefore=Read-CardsPilotGraph $plan.support $plan.project
  $before=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
  $cardId=Get-MultiProjectAutomationId 'project-card' ([string]$parentBefore.project.path) $goalId
  $clock=[Diagnostics.Stopwatch]::StartNew()
  Assert-CardsPilotIsolation $scope $plan 'import-cancel-before-input'
  $picker=Open-CardsZipPicker $process $root $window $cardId 'PilotGoal' 5124
  $ready=Wait-CardsPickerCancelReady $process $window $picker $clock
  Click-CardsPilotControl $process $picker 2 ([IntPtr]$ready.control)
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_ZIP: original Import Cancel budget expired'
  $null=Wait-CardsPilotState {
    $status=Find-FragmentById $root 'status' $walker
    -not [GraphCodeUiaGateState]::WindowIsVisible($picker) -and $status -and
      $status.Current.ProcessId -eq $process.Id -and
      $status.Current.Name -ceq 'Loop transfer cancelled before dispatch.'
  } 'owned Import Cancel and explicit before-dispatch status' $remaining
  Assert-CardsPilotNoMutation $parentBefore (Read-CardsPilotGraph $plan.support $plan.project)
  Require (-not (Test-Path -LiteralPath $plan.zipPath)) 'CARDS_PILOT_ZIP: Cancel created an archive'
  Assert-CardsPilotIsolation $scope $plan 'import-cancel-after-status'
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_ZIP: Import Cancel proof exceeded original budget'
  $result=[ordered]@{case='zip-import-cancel';nativePointer=$true;graphUnchanged=$true;archiveAbsent=$true
    explicitBeforeDispatchStatus=$true;elapsedMilliseconds=$clock.ElapsedMilliseconds}
  $results.Add($result)
  Write-Host ('CARDS_PILOT_CASE_RESULT='+($result|ConvertTo-Json -Compress))

  $clock=[Diagnostics.Stopwatch]::StartNew()
  $modal=Open-CardsPilotRetype $process $root $window $goalId 5122 `
    'Change PilotGoal to Timed' ([string]$parentBefore.project.path)
  Set-CardsPilotField $process $modal 9100 'Stale owned task must never be submitted'
  Invoke-CardsPilotCli $scope $plan $environment @('node','delete',$plan.project,$goalId) 'remove-captured-target'
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_DRIFT: original target-drift budget expired'
  $removed=Wait-CardsPilotState {
    $current=Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite $plan.childGraphId
    if($current -and @($current.nodes).Count -eq 1 -and
        @($current.nodes|Where-Object { [string]$_.id -ieq $goalId }).Count -eq 0) { return $current }
  } 'positive production target removal' $remaining
  Assert-CardsPilotRemovedTarget $before $removed $goalId
  $removedParent=Read-CardsPilotGraph $plan.support $plan.project
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 5000) 'CARDS_PILOT_DRIFT: original budget cannot admit another native input'
  $null=Wait-CardsPilotState {
    -not (Find-FragmentById $root $cardId $walker)
  } 'App observed exact captured card removal while form remains open' ($remaining-5000)
  Require ([GraphCodeUiaGateState]::WindowIsVisible($modal)) 'CARDS_PILOT_DRIFT: retained form disappeared before submission'
  Click-CardsPilotControl $process $modal 1
  $remaining=15000-[int]$clock.ElapsedMilliseconds
  Require ($remaining -gt 0) 'CARDS_PILOT_DRIFT: original stale-submit budget expired'
  $null=Wait-CardsPilotState {
    $status=Find-FragmentById $root 'status' $walker
    -not [GraphCodeUiaGateState]::WindowIsVisible($modal) -and $status -and
      $status.Current.ProcessId -eq $process.Id -and
      $status.Current.Name -ceq 'The loop was removed. Nothing was submitted.'
  } 'explicit stale-target refusal without retry' $remaining
  Assert-CardsPilotNoMutation $removedParent (Read-CardsPilotGraph $plan.support $plan.project)
  Assert-CardsPilotIsolation $scope $plan 'drift-refused-after-status'
  Require ($clock.ElapsedMilliseconds -lt 15000) 'CARDS_PILOT_DRIFT: proof exceeded original budget'
  $result=[ordered]@{case='retype-context-drift';nativePointer=$true;targetId=$goalId
    productionTargetRemoved=$true;appObservedRemoval=$true;explicitRefusal=$true;postRemovalGraphUnchanged=$true
    peerNodes=1;edges=0;elapsedMilliseconds=$clock.ElapsedMilliseconds}
  $results.Add($result)
  Write-Host ('CARDS_PILOT_CASE_RESULT='+($result|ConvertTo-Json -Compress))
}

function Invoke-CardsRootObservation($process, [IntPtr] $window, $plan, $scope) {
  $heldHandle=$process.Handle
  $processId=$process.Id
  $measure={
    $process.Refresh()
    Require ($process.Handle -eq $heldHandle -and -not $process.HasExited -and
      $process.MainWindowHandle -eq $window -and
      [GraphCodeUiaGateState]::WindowProcessId($window) -eq $processId -and
      [GraphCodeUiaGateState]::WindowClass($window) -ceq 'GraphCodeWindowsShell' -and
      [GraphCodeUiaGateState]::WindowOwner($window) -eq [IntPtr]::Zero) `
      'CARDS_ROOT_OBSERVATION: retained root identity changed'
    $native=[GraphCodeUiaGateState]::WindowBounds($window)
    $element=[System.Windows.Automation.AutomationElement]::FromHandle($window)
    $current=$element.Current
    $rect=$current.BoundingRectangle
    $bounds=@($rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
    Require ($current.ProcessId -eq $processId -and $current.AutomationId -ceq 'graphcode-root' -and
      $native.Count -eq 4 -and $native[2] -gt $native[0] -and $native[3] -gt $native[1]) `
      'CARDS_ROOT_OBSERVATION: exact production root and positive native rectangle required'
    for($i=0;$i -lt 4;$i++) {
      Require ($bounds[$i] -eq $native[$i]) 'CARDS_ROOT_OBSERVATION: UIA/native root rectangle mismatch'
    }
    return [ordered]@{ observed=[DateTimeOffset]::Now.ToString('o');processId=$processId
      heldHandle=$heldHandle.ToInt64();window=$window.ToInt64();nativeBounds=$native;uiaBounds=$bounds
      automationId=$current.AutomationId;foreground=[GraphCodeUiaGateState]::IsForegroundWindow($window) }
  }
  Assert-CardsPilotIsolation $scope $plan 'root-observation-before'
  $first=& $measure
  [IO.File]::WriteAllText((Join-Path $plan.root 'root-observation-ready.json'),
    ($first|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
  Write-Host ('CARDS_ROOT_OBSERVATION_READY='+($first|ConvertTo-Json -Compress))
  $changes=[Collections.Generic.List[object]]::new()
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $last=''
  $complete=Join-Path $plan.root 'root-observation.complete'
  while($true) {
    $process.Refresh()
    Require (-not $process.HasExited -and $process.Handle -eq $heldHandle -and
      $process.MainWindowHandle -eq $window -and
      [GraphCodeUiaGateState]::WindowProcessId($window) -eq $processId -and
      [GraphCodeUiaGateState]::WindowIsVisible($window) -and
      [GraphCodeUiaGateState]::WindowIsEnabled($window) -and $process.Responding) `
      'CARDS_ROOT_OBSERVATION: owned visible healthy root changed'
    $native=[GraphCodeUiaGateState]::WindowBounds($window)
    $foreground=[GraphCodeUiaGateState]::IsForegroundWindow($window)
    $key=($native -join ',')+':'+$foreground
    if($key -cne $last) {
      $changes.Add([ordered]@{observed=[DateTimeOffset]::Now.ToString('o')
        nativeBounds=$native;foreground=$foreground})
      $last=$key
    }
    if(Test-Path -LiteralPath $complete) {
      Require ([IO.File]::ReadAllText($complete) -ceq 'complete') 'CARDS_ROOT_OBSERVATION: controller aborted'
      break
    }
    Require ($watch.ElapsedMilliseconds -lt 60000) 'CARDS_ROOT_OBSERVATION: observation controller timeout'
    Start-Sleep -Milliseconds 50
  }
  $final=& $measure
  Assert-CardsPilotIsolation $scope $plan 'root-observation-after'
  return [ordered]@{rootGeometrySamples=@($first,$final);nativeChanges=$changes.ToArray()
    exactOwnedForegroundObserved=(@($changes|Where-Object foreground -EQ $true).Count -gt 0)
    originalInputAdmissionNotEntered=$true;acceptanceEffects=0}
}

function Invoke-CardsNativePilot([string] $planPath) {
  $plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json
  $script:CardsPickerNativeInputBarrier=$false
  $script:CardsPickerChordAttempts=0
  $script:CardsPickerChordCompletions=0
  $navigationOnly=($plan.PSObject.Properties['pickerNavigationOnly'] -and $plan.pickerNavigationOnly -eq $true)
  $script:CardsConsoleIdentity = $plan.consoleCompanion
  $zipSlice = $plan.kind -ceq 'cards-zip-pilot'
  $nativeExportOnly=Test-CardsZipNativeExportOnly $plan
  $nativeImportOnly=Test-CardsZipNativeImportOnly $plan
  $zipObservation = $plan.kind -ceq 'cards-zip-filename-observation'
  $cancelDrift = $plan.kind -ceq 'cards-cancel-drift'
  $modeDriftOnly=Test-CardsModeDriftOnly $plan
  if($plan.PSObject.Properties['modeDriftOnly']){
    Require $modeDriftOnly 'CARDS_PILOT_PLAN: exact single typed mode-drift extension required'
  }
  $rootObservation = $plan.kind -ceq 'cards-root-geometry-observation'
  $strictEdge = $plan.kind -ceq 'cards-connected-edge-strict'
  if($strictEdge){Assert-CardsConnectedEdgePlan $plan}
  if($plan.PSObject.Properties['pickerImportStructureOnly']){Assert-CardsPickerImportStructurePlan $plan}
  Require ((($plan.kind -ceq 'cards-retype-pilot' -and $plan.caseCount -eq 2) -or
      ($zipSlice -and $plan.caseCount -eq 3 -and -not $plan.PSObject.Properties['nativeExportOnly'] -and
        -not $plan.PSObject.Properties['nativeImportOnly']) -or
      $nativeExportOnly -or $nativeImportOnly -or $strictEdge -or ($zipObservation -and $plan.caseCount -eq 1) -or
      ($cancelDrift -and $plan.caseCount -eq 2) -or $modeDriftOnly -or ($rootObservation -and $plan.caseCount -eq 0)) -and
    [IO.Path]::GetFullPath($plan.root).StartsWith('D:\b71\', [StringComparison]::OrdinalIgnoreCase)) `
    'CARDS_PILOT_PLAN: exact owned bounded case plan required'
  if ($zipSlice -or $zipObservation -or $cancelDrift -or $strictEdge) {
    $reservationScope=if($modeDriftOnly){'one captured same-child mode-drift submit'}
      elseif($strictEdge){'one strict connected edge Edit/Cancel'}
      elseif ($cancelDrift) { 'one ImportCancel and captured-target drift batch' }
      elseif ($zipObservation) { 'one Cancel-only ZIP filename observation' }
      elseif ($nativeExportOnly) { 'one native ZIP Save/export' }
      elseif ($nativeImportOnly) { 'one native ZIP Open/import' } else { 'one three-case ZIP batch' }
    Require ($plan.desktopReservation -and $plan.desktopReservation.announced -eq $true -and
      $plan.desktopReservation.scope -ceq $reservationScope -and
      -not [string]::IsNullOrWhiteSpace($plan.desktopReservation.directUserStatement)) `
      'CARDS_PILOT_ZIP: fresh announced desktop reservation required before any native process'
  }
  foreach ($file in $plan.bindings) {
    Require ((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash -ceq $file.sha256) `
      "CARDS_PILOT_BINDING: changed input $($file.path)"
  }
  if($nativeExportOnly){
    $qualification=Get-Content -Raw -LiteralPath $plan.nativeFilenameQualification.path|ConvertFrom-Json
    Assert-CardsNativeExportQualification $plan $qualification
  }
  if($nativeImportOnly){
    $qualification=Get-Content -Raw -LiteralPath $plan.nativeImportArchive.exportReceipt.path|ConvertFrom-Json
    Assert-CardsNativeImportQualification $plan $qualification
    $plan|Add-Member -NotePropertyName nativeImportSourceGraph -NotePropertyValue (Read-CardsNativeImportSource $plan)
  }
  Require ($env:GRAPHCODE_UIA_SUPERVISED_FOREGROUND -ceq '1') 'CARDS_PILOT_PLAN: supervised admission required'
  $runMarker = Join-Path $plan.root 'started-once'
  $marker = [IO.FileStream]::new($runMarker,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  $marker.Dispose()
  $environment = @{}
  foreach ($pair in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
    $environment[$pair.Key] = [string]$pair.Value
  }
  $environment.TEMP = Join-Path $plan.root 'temp'; $environment.TMP = $environment.TEMP
  $environment.RUNNER_TEMP = $environment.TEMP
  $environment.LOCALAPPDATA = Join-Path $plan.root 'profile'
  $environment.APPDATA = Join-Path $plan.root 'roaming'
  $environment.USERPROFILE = Join-Path $plan.root 'home'; $environment.HOME = $environment.USERPROFILE
  $environment.GRAPHCODE_SUPPORT_DIR = $plan.support
  $environment.GRAPHCODE_DAEMON_PIPE = $plan.pipe
  $environment.GRAPHCODE_SOCKET = $plan.pipe
  $environment.GRAPHCODE_DAEMON_SHUTDOWN_EVENT = $plan.shutdownEvent
  $environment.GRAPHCODE_ZMX = $plan.zmx
  $environment.GIT_CONFIG_PARAMETERS = "'protocol.allow=never'"
  $scope = $null; $daemon = $null; $shellProcess = $null; $event = $null; $dpi = $null
  $failure = $null; $cleanupErrors = [Collections.Generic.List[Exception]]::new(); $dpiRestored = $false
  $nativePopupFailure = $null
  $observation = $null
  $results = [Collections.Generic.List[object]]::new()
  try {
    foreach ($directory in @($environment.TEMP,$environment.LOCALAPPDATA,$environment.APPDATA,
        $environment.USERPROFILE,$plan.support,$plan.project)) {
      [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $onboarding = Initialize-CardsPilotOnboarding $plan.root $plan.support
    Write-Host ('CARDS_PILOT_ONBOARDING_CONTEXT=' + ($onboarding | ConvertTo-Json -Compress))
    $event = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$plan.shutdownEvent)
    $scope = New-ShellProcessScope
    $daemonInfo = New-CardsPilotStartInfo $plan.daemon @() $environment $plan.root
    $daemon = Start-ShellOwnedProcess $scope $daemonInfo
    $scope.Runs[0] | Add-Member -NotePropertyName CardsConsoleExpected -NotePropertyValue $true
    $null = Read-CardsPilotLaunchAccounting $scope.Runs[0]
    Write-Host "CARDS_PILOT_DAEMON=pid=$($daemon.Id) heldHandle=$($daemon.Handle) pipe=$($plan.pipe)"
    $connection = [IO.Pipes.NamedPipeClientStream]::new('.', $plan.pipe.Substring(9), [IO.Pipes.PipeDirection]::InOut)
    try { $connection.Connect(15000) } finally { $connection.Dispose() }
    Invoke-CardsPilotCli $scope $plan $environment @('node','create',$plan.project,
      '--title','Pilot Container','--type','composite','--backend','copilotCLI') 'seed-container'
    $parentGraph = Wait-CardsPilotState {
      $graph = Read-CardsPilotGraph $plan.support $plan.project
      if ($null -ne $graph -and @($graph.nodes).Count -eq 1) { return $graph }
      return $null
    } 'positive unpiloted container seed'
    $container = $parentGraph.nodes[0]
    Require ($container.title -ceq 'PilotContainer' -and $container.loopType -ceq 'proactive') `
      'CARDS_PILOT_SEED: exact containing composite required'
    $plan.containingComposite = [string]$container.id
    Invoke-CardsPilotCli $scope $plan $environment @('node','create',$plan.project,
      '--title','Pilot Goal','--type','goal','--goal','Original owned goal',
      '--backend','copilotCLI','--model','capable','--into',$plan.containingComposite) 'seed-goal'
    Invoke-CardsPilotCli $scope $plan $environment @('node','create',$plan.project,
      '--title','Pilot Peer','--type','main','--backend','copilotCLI','--into',$plan.containingComposite) 'seed-peer'
    $seed = Wait-CardsPilotState {
      $graph = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite
      if ($null -ne $graph -and @($graph.nodes).Count -eq 2) { return $graph }
      return $null
    } 'positive two-node seed'
    $plan.childGraphId = [string]$seed.id
    $goal = @($seed.nodes | Where-Object title -CEQ 'PilotGoal')
    $peer = @($seed.nodes | Where-Object title -CEQ 'PilotPeer')
    Require ($goal.Count -eq 1 -and $peer.Count -eq 1) 'CARDS_PILOT_SEED: unique seed identities required'
    Invoke-CardsPilotCli $scope $plan $environment @('edge','create',$plan.project,
      [string]$goal[0].id,[string]$peer[0].id,'--kind','message','--condition','onSuccess') 'seed-edge'
    $null = Wait-CardsPilotState {
      $graph = Read-CardsPilotGraph $plan.support $plan.project $plan.containingComposite
      $null -ne $graph -and @($graph.nodes).Count -eq 2 -and @($graph.edges).Count -eq 1
    } 'positive saved edge seed'
    $persistedParent = Read-CardsPilotGraph $plan.support $plan.project
    $parent = @($persistedParent.nodes | Where-Object { [string]$_.id -ieq $plan.containingComposite })
    Require ($parent.Count -eq 1 -and $parent[0].pilotState -ceq 'notPiloted') `
      'CARDS_PILOT_SEED: containing composite must not have a pilot/arm receipt'
    Assert-CardsPilotIsolation $scope $plan 'before-gui'
    $dpi = [GraphCodeUiaGateState]::EnterPhysicalDpiCoordinates()
    $shellInfo = New-CardsPilotStartInfo $plan.shell @() $environment $plan.root
    $shellInfo.CreateNoWindow = $false
    $shellProcess = Start-ShellOwnedProcess $scope $shellInfo
    [GraphCodeUiaGateState]::RetainProcess($shellProcess)
    $window = Wait-CardsPilotState {
      $shellProcess.Refresh()
      Require (-not $shellProcess.HasExited) 'CARDS_PILOT_BOOT: shell exited'
      if ($shellProcess.MainWindowHandle -ne [IntPtr]::Zero) { return $shellProcess.MainWindowHandle }
      return $null
    } 'owned main window'
    if ($rootObservation) {
      $observation=Invoke-CardsRootObservation $shellProcess $window $plan $scope
    } else {
    try { Wait-UiaSupervisedForeground $shellProcess $window }
    catch {
      $foregroundFailure = $_
      try {
        $refusal = [ordered]@{
          processId = $shellProcess.Id; heldHandle = $shellProcess.Handle.ToInt64()
          window = Format-WindowHandle $window; mainWindow = Format-WindowHandle $shellProcess.MainWindowHandle
          windowProcessId = [GraphCodeUiaGateState]::WindowProcessId($window)
          class = [GraphCodeUiaGateState]::WindowClass($window)
          owner = Format-WindowHandle ([GraphCodeUiaGateState]::WindowOwner($window))
          visible = [GraphCodeUiaGateState]::WindowIsVisible($window)
          enabled = [GraphCodeUiaGateState]::WindowIsEnabled($window)
          responding = $shellProcess.Responding; hasExited = $shellProcess.HasExited
          ownedTopLevels = @([GraphCodeUiaGateState]::DescribeTopLevelWindows([uint32]$shellProcess.Id))
          onboardingContext = $onboarding.context
          failure = $foregroundFailure.ToString()
        }
        [IO.File]::WriteAllText((Join-Path $plan.root 'foreground-refusal.json'),
          ($refusal | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host ('CARDS_PILOT_FOREGROUND_REFUSAL=' + ($refusal | ConvertTo-Json -Depth 8 -Compress))
      } catch {
        throw [AggregateException]::new('Pilot foreground guard and owned refusal diagnostic failed',
          [Exception[]]@($foregroundFailure.Exception, $_.Exception))
      }
      throw $foregroundFailure
    }
    Require (Ensure-ShellForeground $window 'cards pilot first input') 'CARDS_PILOT_BOOT: original foreground guard refused'
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $null = Wait-CardsPilotState { Find-FragmentById $root 'graph' $walker } 'real connected canvas'
    $actualSize = Find-FragmentByIdWithRetry $root 'actual-size' $walker
    Require ($null -ne $actualSize -and $actualSize.Current.ProcessId -eq $shellProcess.Id) `
      'CARDS_PILOT_BOOT: owned actual-size control absent'
    $actualSize.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if($strictEdge){
      $results.Add((Invoke-CardsConnectedEdgeCase $shellProcess $root $window $plan $scope ([string]$goal[0].id) ([string]$peer[0].id)))
    } elseif ($zipSlice -or $zipObservation) {
      Invoke-CardsZipCases $shellProcess $root $window $plan $scope ([string]$goal[0].id) $results
    } else {
    $containerCardId = Get-MultiProjectAutomationId 'project-card' ([string]$persistedParent.project.path) $plan.containingComposite
    $goalCardId = Get-MultiProjectAutomationId 'project-card' ([string]$persistedParent.project.path) ([string]$goal[0].id)
    $graphElement = Find-FragmentByIdWithRetry $root 'graph' $walker
    Require ($null -ne $graphElement) 'CARDS_PILOT_BOOT: owned graph absent before exact card wait'
    $targetReceipt = [ordered]@{
      processId = $shellProcess.Id; projectPath = [string]$persistedParent.project.path
      containingComposite = $plan.containingComposite; childGraphId = $plan.childGraphId
      expectedContainerCard = $containerCardId; expectedGoalCard = $goalCardId
      children = @(Get-DirectChildren $graphElement $walker | ForEach-Object {
        $bounds = $_.Current.BoundingRectangle
        [ordered]@{ automationId = $_.Current.AutomationId; name = $_.Current.Name
          processId = $_.Current.ProcessId; offscreen = $_.Current.IsOffscreen
          bounds = @($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom) }
      })
    }
    [IO.File]::WriteAllText((Join-Path $plan.root 'canvas-target.json'),
      ($targetReceipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Host ('CARDS_PILOT_CANVAS_TARGET=' + ($targetReceipt | ConvertTo-Json -Depth 8 -Compress))
    $containerCard = Wait-CardsPilotState {
      Find-FragmentById $root $containerCardId $walker
    } 'exact production container card identity'
    Require ($containerCard.Current.ProcessId -eq $shellProcess.Id -and
      $containerCard.Current.AutomationId -ceq $containerCardId -and
      $containerCard.Current.Name -ceq 'PilotContainer') 'CARDS_PILOT_BOOT: exact container identity/title differs'
    $containerPopup = Open-CardsPilotCardMenu $shellProcess $root $window `
      $containerCardId 'PilotContainer' 'PilotContainer'
    $openGroup = @(Get-PopupMenuItems $containerPopup | Where-Object { $_.Id -eq 5113 -and $_.Enabled })
    Require ($openGroup.Count -eq 1) 'CARDS_PILOT_BOOT: exact enabled Open Group entry required'
    $groupHit = [GraphCodeUiaGateState]::ClickPopupMenuItemStrict($containerPopup,$window,
      [int]$openGroup[0].Position,5113,[uint32]$shellProcess.Id)
    Require ($groupHit.ItemId -eq 5113 -and -not $groupHit.UsedKeyboardFallback -and
      -not $groupHit.UsedSelectItemFallback) 'CARDS_PILOT_BOOT: strict Open Group pointer route required'
    $groupReturn = [ordered]@{
      processId=$shellProcess.Id; window=$window.ToInt64(); popup=$containerPopup.ToInt64()
      projectPath=[string]$persistedParent.project.path; containerCardId=$containerCardId
      expectedGoalCardId=$goalCardId; nativeHit=$groupHit
      proofLimit='Pointer receipt is not the selected TrackPopupMenu command or an App callback.'
    }
    [IO.File]::WriteAllText((Join-Path $plan.root 'open-group-return.json'),
      ($groupReturn | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Write-Host ('CARDS_PILOT_OPEN_GROUP_RETURN=' + ($groupReturn | ConvertTo-Json -Depth 6 -Compress))
    try {
      $null = Wait-CardsPilotState {
        Find-FragmentById $root $goalCardId $walker
      } 'owned child canvas after Open Group'
    } catch {
      $groupFailure = $_
      try {
        $fragments = foreach ($id in @('graph','status',$containerCardId,$goalCardId)) {
          $fragment = Find-FragmentById $root $id $walker
          if ($null -eq $fragment) {
            [ordered]@{ expectedAutomationId=$id; state='absent' }
            continue
          }
          $current = $fragment.Current
          if ($current.ProcessId -ne $shellProcess.Id) {
            [ordered]@{ expectedAutomationId=$id; state='foreign-refused'; processId=$current.ProcessId }
            continue
          }
          $bounds = $current.BoundingRectangle
          [ordered]@{
            expectedAutomationId=$id; state='owned'; processId=$current.ProcessId
            automationId=$current.AutomationId; name=$current.Name; offscreen=$current.IsOffscreen
            bounds=@($bounds.Left,$bounds.Top,$bounds.Right,$bounds.Bottom)
          }
        }
        $groupRefusal = [ordered]@{
          failure=$groupFailure.ToString(); returnedPointer=$groupReturn; fragments=@($fragments)
          ownedTopLevels=@([GraphCodeUiaGateState]::DescribeTopLevelWindows([uint32]$shellProcess.Id))
        }
        [IO.File]::WriteAllText((Join-Path $plan.root 'open-group-refusal.json'),
          ($groupRefusal | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host ('CARDS_PILOT_OPEN_GROUP_REFUSAL=' + ($groupRefusal | ConvertTo-Json -Depth 8 -Compress))
      } catch { Write-Warning "Owned Open Group refusal evidence could not be copied: $_" }
      throw $groupFailure
    }
    Write-Host "CARDS_PILOT_SCOPE=containingComposite=$($plan.containingComposite) childNodes=2 childEdges=1 openGroupNativePointer=true"
    if($cancelDrift) {
      if($modeDriftOnly) {
        $results.Add((Invoke-CardsModeDriftCase $shellProcess $root $window $plan $scope $environment ([string]$goal[0].id)))
      } else {
        Invoke-CardsCancelDriftCases $shellProcess $root $window $plan $scope $environment ([string]$goal[0].id) $results
      }
    } else {
    $results.Add((Invoke-CardsPilotRetypeCase $shellProcess $root $window $plan `
      ([string]$goal[0].id) 'PilotGoal' 'timeBased' $scope))
    $results.Add((Invoke-CardsPilotRetypeCase $shellProcess $root $window $plan `
      ([string]$goal[0].id) 'PilotGoal' 'goalBased' $scope))
    Require ($results.Count -eq 2) 'CARDS_PILOT_COUNT: exactly two executed effects required'
    }
    }
    }
  } catch {
    $failure = $_
    if ($navigationOnly) { $script:CardsPickerNativeInputBarrier=$true }
    try {
      $nativeData = $failure.Exception.GetBaseException().Data
      if ($nativeData.Contains('rawMenuState')) {
        $nativePopupFailure = [ordered]@{}
        foreach ($key in @('rawMenuState','rawMenuStateObserved','nativeErrorAvailable','owner','popup','menu',
            'expectedProcessId','position','commandId','itemRect','screenPoint','clientPoint',
            'cursorBefore','cursorAtMove','cursorAtRefusal','pointWindow','pointWindowProcessId',
            'pointWindowRoot','foreground','foregroundProcessId','foregroundRoot',
            'ownerProcessId','popupProcessId','metadataError')) {
          if ($nativeData.Contains($key)) { $nativePopupFailure[$key] = $nativeData[$key] }
        }
        Write-Host ('CARDS_PILOT_NATIVE_POPUP_REFUSAL=' + ($nativePopupFailure | ConvertTo-Json -Depth 6 -Compress))
      }
    } catch { Write-Warning "Owned native popup exception metadata could not be copied: $_" }
  }
  finally {
    if ($shellProcess) {
      try {
        if (-not $shellProcess.HasExited) { Stop-ShellOwnedProcess $scope $shellProcess }
        Complete-ShellOwnedProcess $scope $shellProcess
        [IO.File]::WriteAllText((Join-Path $plan.root 'shell-stdout.log'),
          (Read-ShellOwnedOutput $scope $shellProcess), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $plan.root 'shell-stderr.log'),
          (Read-ShellOwnedOutput $scope $shellProcess -StandardError), [Text.UTF8Encoding]::new($false))
      } catch { $cleanupErrors.Add($_.Exception) }
    }
    if ($daemon) {
      try {
        if (-not $daemon.HasExited) {
          [void]$event.Set()
          if (-not $daemon.WaitForExit(15000)) { throw 'CARDS_PILOT_CLEANUP: normal daemon shutdown timed out' }
        }
        Complete-ShellOwnedProcess $scope $daemon
        [IO.File]::WriteAllText((Join-Path $plan.root 'daemon-stdout.log'),
          (Read-ShellOwnedOutput $scope $daemon), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $plan.root 'daemon-stderr.log'),
          (Read-ShellOwnedOutput $scope $daemon -StandardError), [Text.UTF8Encoding]::new($false))
      } catch { $cleanupErrors.Add($_.Exception) }
    }
    if ($scope) { try { Close-ShellProcessScope $scope } catch { $cleanupErrors.Add($_.Exception) } }
    if ($dpi) {
      try { [GraphCodeUiaGateState]::RestorePhysicalDpiCoordinates($dpi); $dpiRestored = $true }
      catch { $cleanupErrors.Add($_.Exception) }
    }
    if ($event) { $event.Dispose() }
    $receipt = [ordered]@{ mode = 'supervised-or-tool-assisted'; requestedCases = $plan.caseCount
      slice=$plan.kind
      actualEffects = $results.Count; cases = $results.ToArray()
      rootObservation = $observation
      failure = $(if ($failure) { $failure.ToString() } else { $null })
      nativePopupFailure = $nativePopupFailure
      ownedJobCleanupVerified = ($scope -and $scope.Closed)
      cleanupFailures = @($cleanupErrors | ForEach-Object { $_.Message })
      dpiRestoreAttempted = ($null -ne $dpi); exactDpiRestoreVerified = $dpiRestored
      fullParity = $false; remainingAcceptedCases = 7 }
    if ($navigationOnly) {
      $inputDisposition=Get-CardsPickerInputDisposition $script:CardsPickerChordAttempts $script:CardsPickerChordCompletions `
        ($null -ne $failure -or $script:CardsPickerNativeInputBarrier)
      $receipt['nativeInputBarrier']=$inputDisposition.policyInputBarrier
      $receipt['inputDisposition']=$inputDisposition
      $receipt['possiblyHeldModifierUnresolved']=$inputDisposition.possiblyHeldModifierUnresolved
      $receipt['desktopCleanReleasePermitted']=(-not $script:CardsPickerNativeInputBarrier -and
        $null -eq $failure -and $cleanupErrors.Count -eq 0)
      $receipt['cleanupProofLimit']='Job/DPI/profile cleanup does not resolve any modifier input barrier'
    }
    [IO.File]::WriteAllText((Join-Path $plan.root 'pilot-result.json'),
      ($receipt | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Write-Host ('CARDS_PILOT_TERMINAL=' + ($receipt | ConvertTo-Json -Depth 20 -Compress))
  }
  if ($rootObservation -and -not $failure -and $cleanupErrors.Count -eq 0) {
    Require ($results.Count -eq 0 -and @($observation.rootGeometrySamples).Count -eq 2) `
      'CARDS_ROOT_OBSERVATION: two actual root samples and zero acceptance effects required'
    return
  }
  Complete-CardsPilotOutcome $(if ($failure) { $failure.Exception } else { $null }) `
    $cleanupErrors.ToArray() $plan.caseCount $results.Count
}
