param(
  [Parameter(Mandatory)][string] $RepositoryRoot,
  [Parameter(Mandatory)][string] $ArtifactRoot,
  [Parameter(Mandatory)] $Graph,
  [Parameter(Mandatory)][string] $CompositeId
)
$ErrorActionPreference='Stop'
function Require([bool] $condition,[string] $message) {
  if(-not $condition) { throw [InvalidOperationException]::new($message) }
}
. (Join-Path $RepositoryRoot 'Tools\windows\CardsAcceptance.Live.ps1')
$directory=Join-Path $ArtifactRoot ('zip-entry-controls-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$cases=@(
  @{id='flat'; valid=$true; entries=@('manifest.json','graph-snapshot.json','README.md')},
  @{id='tar-root'; valid=$true; entries=@('./','./manifest.json','./graph-snapshot.json','./README.md')},
  @{id='duplicate-alias'; valid=$false; entries=@('manifest.json','./manifest.json','graph-snapshot.json')},
  @{id='duplicate-case'; valid=$false; entries=@('manifest.json','Manifest.json','graph-snapshot.json')},
  @{id='traversal'; valid=$false; entries=@('manifest.json','graph-snapshot.json','./../outside')},
  @{id='nested-dot'; valid=$false; entries=@('manifest.json','graph-snapshot.json','././README.md')},
  @{id='sessions'; valid=$false; entries=@('./manifest.json','./graph-snapshot.json','./sessions/private')},
  @{id='missing-manifest'; valid=$false; entries=@('./graph-snapshot.json')}
)
$results=@(foreach($case in $cases) {
  $path=Join-Path $directory ($case.id+'.zip')
  $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach($name in $case.entries) {
      $entry=$zip.CreateEntry($name)
      if($name -cne './') {
        $writer=[IO.StreamWriter]::new($entry.Open())
        try {
          $writer.Write($(if($name.EndsWith('graph-snapshot.json',[StringComparison]::Ordinal)) {
            ConvertTo-Json -InputObject $Graph -Depth 50 -Compress
          } else {'{}'}))
        } finally { $writer.Dispose() }
      }
    }
  } finally { $zip.Dispose() }
  $caught=$null
  try { $null=Read-CardsZipBundle @{zipPath=$path;containingComposite=$CompositeId} $Graph }
  catch { $caught=$_.Exception }
  $passed=if($case.valid) {$null -eq $caught} else {
    $caught -is [InvalidOperationException] -and $caught.Message -like 'CARDS_PILOT_ZIP:*'
  }
  [ordered]@{id=$case.id;passed=$passed;error=$(if($caught){$caught.Message}else{$null})}
})
$results+=@(foreach($case in @(
  @{id='win32-status';status='Export commit did not report success (Win32 87).';field='NativeErrorCode';code=87},
  @{id='native-status';status='Export commit did not report synchronous success (NTSTATUS 0xc0000035, completion 0x103).';field='NativeStatusCode';code=[uint32]3221225525},
  @{id='unobserved-completion';status='Export commit did not report synchronous success (NTSTATUS 0x0, completion 0x103).';field='NativeCompletionCode';code=259}
)) {
  $caught=$null
  try { $null=Test-CardsZipTransferStatus ($case.status+' Export staging retained at private-test-path') 'completed' }
  catch { $caught=$_.Exception }
  $passed=$caught -is [InvalidOperationException] -and
    $caught.Message -like 'CARDS_PILOT_ZIP:*' -and -not $caught.Message.Contains('private-test-path') -and
    $caught.Data[$case.field] -eq $case.code
  [ordered]@{id=$case.id;passed=$passed;error=$(if($caught){$caught.Message}else{$null})}
})
$receipt=[ordered]@{executed=$results.Count;passed=@($results|Where-Object passed).Count;results=$results;desktopInputCalls=0}
[IO.File]::WriteAllText((Join-Path $directory 'result.json'),($receipt|ConvertTo-Json -Depth 5))
Write-Output ($receipt|ConvertTo-Json -Depth 5 -Compress)
if($receipt.executed -ne 11 -or $receipt.passed -ne 11) { throw 'CARDS_PILOT_ZIP: ZIP entry/status controls failed' }
