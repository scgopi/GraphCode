BeforeDiscovery {
  Import-Module (Join-Path $PSScriptRoot "..\ShellProcessOwnership.psm1") -Force
}

BeforeAll {
  $hadValidationRoot = [Environment]::GetEnvironmentVariables("Process").Contains("GRAPHCODE_VALIDATION_ROOT")
  $savedValidationRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT", "Process")
  Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
}

AfterAll {
  if ($hadValidationRoot) {
    [Environment]::SetEnvironmentVariable("GRAPHCODE_VALIDATION_ROOT", $savedValidationRoot, "Process")
  } else {
    Remove-Item Env:\GRAPHCODE_VALIDATION_ROOT -ErrorAction SilentlyContinue
  }
}

Describe "Owned live callers and shell adapter with mocked native operations" {
  InModuleScope ShellProcessOwnership {
    BeforeAll {
      $moduleRoot = Split-Path -Parent (Get-Module ShellProcessOwnership).Path
      . (Join-Path $moduleRoot "OwnedLiveProcess.ps1")
      foreach ($item in @(
          @{ File = "ScrubbedShellStartup.Live.Tests.ps1"; Name = "Invoke-ScrubbedCli" },
          @{ File = "DaemonHandoff.Live.Tests.ps1"; Name = "Assert-EndpointReachable" },
          @{ File = "DaemonRoundTrip.Live.Tests.ps1"; Name = "Start-OwnedDaemon" },
          @{ File = "DaemonRoundTrip.Live.Tests.ps1"; Name = "Stop-OwnedDaemon" })) {
        $errors = $null
        $source = Join-Path $moduleRoot "Tests\$($item.File)"
        $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
        if ($errors.Count -ne 0) { throw "$source does not parse" }
        $matches = @($ast.FindAll({
              param($node)
              $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $item.Name
            }, $true))
        if ($matches.Count -ne 1) { throw "Expected one function named $($item.Name)." }
        . ([scriptblock]::Create($matches[0].Extent.Text))
      }

      function New-StartInfo([string] $file, [string] $root) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $file
        $info.UseShellExecute = $false
        return $info
      }

      function New-ControlledLaunch([string] $name, [bool] $exited = $false) {
        $process = [Diagnostics.Process]::new()
        $process | Add-Member NoteProperty MockName $name
        $process | Add-Member NoteProperty HasExited $exited -Force
        $process | Add-Member NoteProperty ExitCode 7 -Force
        $process | Add-Member NoteProperty Id 61001 -Force
        $process | Add-Member NoteProperty Handle ([IntPtr]91) -Force
        $process | Add-Member ScriptMethod WaitForExit {
          param($milliseconds = $null)
          $script:events.Add("wait-root:$($this.MockName)")
          $this.HasExited = $true
          if ($null -ne $milliseconds) { return $true }
        } -Force
        $process | Add-Member ScriptMethod Refresh { } -Force
        $process | Add-Member ScriptMethod Dispose {
          $script:events.Add("dispose:$($this.MockName)")
        } -Force
        $run = [pscustomobject]@{
          Process = $process
          Handle = [IntPtr]91
          Output = [Threading.Tasks.Task]::FromResult[string]("stdout-$name")
          Error = [Threading.Tasks.Task]::FromResult[string]("stderr-$name")
          PipeError = $false
          OutputChunks = [Collections.Generic.Queue[string]]::new()
          ErrorChunks = [Collections.Generic.Queue[string]]::new()
        }
        $run | Add-Member ScriptMethod Resume { $script:events.Add("resume:$($this.Process.MockName)") }
        $run | Add-Member ScriptMethod Stop {
          $script:events.Add("stop:$($this.Process.MockName)")
          $this.Process.HasExited = $true
        }
        $run | Add-Member ScriptMethod RequireExited {
          $script:events.Add("require-exited:$($this.Process.MockName)")
          if (-not $this.Process.HasExited) { throw "mock root is still live" }
        }
        $run | Add-Member ScriptMethod Drain {
          $script:events.Add("drain:$($this.Process.MockName)")
          if ($this.PipeError) { throw "mock inherited pipe EOF unproved" }
        }
        $run | Add-Member ScriptMethod TakeOutput {
          param([int] $maximumCharacters)
          $script:events.Add("take-output:$($this.Process.MockName)")
          if ($maximumCharacters -ne 65536) { throw "unexpected output bound" }
          if ($this.OutputChunks.Count -gt 0) { return $this.OutputChunks.Dequeue() }
          return ""
        }
        $run | Add-Member ScriptMethod TakeError {
          param([int] $maximumCharacters)
          $script:events.Add("take-error:$($this.Process.MockName)")
          if ($maximumCharacters -ne 65536) { throw "unexpected error bound" }
          if ($this.ErrorChunks.Count -gt 0) { return $this.ErrorChunks.Dequeue() }
          return ""
        }
        $run | Add-Member ScriptMethod Close { $script:events.Add("close-run:$($this.Process.MockName)") }
        $script:queue.Enqueue($run)
        return $run
      }
    }

    BeforeEach {
      $script:events = [Collections.Generic.List[string]]::new()
      $script:queue = [Collections.Generic.Queue[object]]::new()
      $script:starts = [Collections.Generic.List[Diagnostics.ProcessStartInfo]]::new()
      $script:nextJob = 100
      $script:scope = $null
      Mock Initialize-ShellProcessOwnership {}
      Mock New-ShellSuspendedLaunch {
        param($StartInfo)
        $script:events.Add("suspended")
        $script:starts.Add($StartInfo)
        return $script:queue.Dequeue()
      }
      Mock Invoke-ShellJob {
        param($Operation, $Job, $Handle)
        $script:events.Add("${Operation}:$Job")
        switch ($Operation) {
          "Create" { $script:nextJob += 100; return [IntPtr]$script:nextJob }
          "Active" { return 0 }
          "Contains" { return $true }
          "Terminate" {
            if ($null -ne $script:scope -and $Job -eq $script:scope.Job) {
              foreach ($run in $script:scope.Runs) { $run.Process.HasExited = $true }
            }
          }
        }
      }
      Mock Write-Host {}
      $script:scope = New-ShellProcessScope
      $script:events.Clear()
      $script:Cli = "C:\mock\graphcode.exe"
      $script:runLog = [Collections.Generic.List[string]]::new()
      $script:processScope = $script:scope
    }

    It "runs the command helper through assignment, completion and both output reads" {
      $run = New-ControlledLaunch "command"
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.FileName = "C:\mock\zig.exe"
      $info.UseShellExecute = $false
      [void]$info.ArgumentList.Add("test")

      $result = Invoke-OwnedLiveCommand -Scope $script:scope -StartInfo $info

      $result.ExitCode | Should -Be 7
      $result.Output | Should -BeExactly "stdout-command"
      $result.Error | Should -BeExactly "stderr-command"
      $info.RedirectStandardOutput | Should -BeTrue
      $info.RedirectStandardError | Should -BeTrue
      $script:starts.Count | Should -Be 1
      [object]::ReferenceEquals($script:starts[0], $info) | Should -BeTrue
      $run.Finalized | Should -BeTrue
      ($script:events -join ",") | Should -BeExactly (
        "suspended,Assign:200,Create:,Assign:300,resume:command,wait-root:command," +
        "require-exited:command,Terminate:300,Wait:300,Active:300,drain:command,Close:300")
      Close-ShellProcessScope $script:scope
      $script:scope.Closed | Should -BeTrue
    }

    It "finalizes the handoff endpoint probe before reading or disposing it" {
      $run = New-ControlledLaunch "endpoint"
      $run.Process.ExitCode = 0
      $script:cliExecutable = "C:\mock\graphcode.exe"
      $script:Executable = "C:\mock\graphcode-windows.exe"
      $script:supportDirectory = "C:\mock\support"
      $script:daemonPipe = "\\.\pipe\controlled-endpoint"
      Assert-EndpointReachable
      $run.Finalized | Should -BeTrue
      ($script:events -join ",") | Should -BeExactly (
        "suspended,Assign:200,Create:,Assign:300,resume:endpoint,wait-root:endpoint," +
        "require-exited:endpoint,Terminate:300,Wait:300,Active:300,drain:endpoint,Close:300,dispose:endpoint")
      $handoffPath = Join-Path $moduleRoot 'Tests\DaemonHandoff.Live.Tests.ps1'
      $handoff = [Management.Automation.Language.Parser]::ParseFile($handoffPath, [ref]$null, [ref]$null)
      $normalStop = $handoff.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-ShellNormally'
      }, $true)
      @($normalStop.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
          $node.GetCommandName() -eq 'Complete-ShellOwnedProcess'
      }, $true)).Count | Should -Be 0
      $source = [IO.File]::ReadAllText($handoffPath)
      $ownerObservation = $source.IndexOf('$daemonProcess.WaitForExit(7000)', [StringComparison]::Ordinal)
      $ownerFinalization = $source.IndexOf('Complete-ShellOwnedProcess $processScope $owner', [StringComparison]::Ordinal)
      $ownerObservation | Should -BeGreaterThan 0
      $ownerFinalization | Should -BeGreaterThan $ownerObservation
      Close-ShellProcessScope $script:scope
      $script:scope.Closed | Should -BeTrue
    }

    It "does not finalize a live sibling when the command completes" {
      $daemon = New-ControlledLaunch "daemon"
      $command = New-ControlledLaunch "command"
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.FileName = "C:\mock\fixture.exe"
      $info.UseShellExecute = $false
      [void](Start-ShellOwnedProcess $script:scope $info)
      $script:events.Clear()

      $result = Invoke-OwnedLiveCommand -Scope $script:scope -StartInfo $info

      $result.Output | Should -BeExactly "stdout-command"
      $command.Finalized | Should -BeTrue
      $daemon.Finalized | Should -BeFalse
      $daemon.Process.HasExited | Should -BeFalse
      $script:events | Should -Contain "Terminate:400"
      $script:events | Should -Not -Contain "Terminate:200"
      $script:events | Should -Not -Contain "Terminate:300"
      $script:events | Should -Not -Contain "drain:daemon"
      Close-ShellProcessScope $script:scope
      $script:scope.Closed | Should -BeTrue
    }

    It "propagates adapter EOF uncertainty before either command output read" {
      $run = New-ControlledLaunch "command"
      $run.PipeError = $true
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.UseShellExecute = $false
      Mock Read-ShellOwnedOutput { throw "unexpected output read" }
      $failure = $null
      try { Invoke-OwnedLiveCommand -Scope $script:scope -StartInfo $info } catch { $failure = $_.Exception }

      $failure | Should -Not -BeNullOrEmpty
      Test-OwnedLiveProcessRetentionRequired $failure | Should -BeTrue
      $run.Finalized | Should -BeFalse
      $script:scope.Closed | Should -BeFalse
      Should -Invoke Read-ShellOwnedOutput -Times 0 -Exactly
    }

    It "forwards adapter chunks before exit and drains after completion without duplication" {
      $run = New-ControlledLaunch "command"
      foreach ($chunk in @("early out", "", "late out", "")) { $run.OutputChunks.Enqueue($chunk) }
      foreach ($chunk in @("early err", "", "late err", "")) { $run.ErrorChunks.Enqueue($chunk) }
      $run.Output = [Threading.Tasks.Task]::FromResult[string]("early outlate out")
      $run.Error = [Threading.Tasks.Task]::FromResult[string]("early errlate err")
      $run.Process | Add-Member ScriptMethod WaitForExit {
        param([int] $milliseconds)
        $script:events.Add("wait-root:$($this.MockName):$milliseconds")
        if ($milliseconds -eq 100) {
          $this.HasExited = $true
          return $true
        }
        return $false
      } -Force
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.UseShellExecute = $false
      $previousOutput = [Console]::Out
      $previousError = [Console]::Error
      $output = [IO.StringWriter]::new()
      $error = [IO.StringWriter]::new()
      try {
        [Console]::SetOut($output)
        [Console]::SetError($error)
        $result = Invoke-OwnedLiveCommand -Scope $script:scope -StartInfo $info -StreamOutput
        $stdout = $output.ToString()
        $stderr = $error.ToString()
      } finally {
        [Console]::SetOut($previousOutput)
        [Console]::SetError($previousError)
        $output.Dispose()
        $error.Dispose()
      }

      $stdout | Should -BeExactly "early outlate out"
      $stderr | Should -BeExactly "early errlate err"
      $result.Output | Should -BeExactly $stdout
      $result.Error | Should -BeExactly $stderr
      $script:starts[0].RedirectStandardOutput | Should -BeTrue
      $script:starts[0].RedirectStandardError | Should -BeTrue
      $run.Finalized | Should -BeTrue
      $script:events.IndexOf("take-output:command") | Should -BeLessThan `
        $script:events.IndexOf("wait-root:command:100")
      $script:events.IndexOf("wait-root:command:100") | Should -BeLessThan `
        $script:events.IndexOf("Terminate:300")
      $run.OutputChunks.Count | Should -Be 0
      $run.ErrorChunks.Count | Should -Be 0
      Close-ShellProcessScope $script:scope
    }

    It "propagates a tagged adapter pump fault without completing the launch" {
      $run = New-ControlledLaunch "command"
      $run | Add-Member ScriptMethod TakeOutput { throw "mock source pump failed" } -Force
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.UseShellExecute = $false
      $failure = $null
      try { Invoke-OwnedLiveCommand -Scope $script:scope -StartInfo $info -StreamOutput } catch {
        $failure = $_.Exception
      }

      $failure | Should -Not -BeNullOrEmpty
      Test-OwnedLiveProcessRetentionRequired $failure | Should -BeTrue
      $run.Finalized | Should -BeFalse
      $script:events | Should -Not -Contain "Terminate:300"
      $script:scope.Closed | Should -BeFalse
    }

    It "runs the source-derived scrubbed CLI through the adapter before disposal" {
      $daemon = New-ControlledLaunch "daemon"
      $cli = New-ControlledLaunch "cli"
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.UseShellExecute = $false
      [void](Start-ShellOwnedProcess $script:scope $info)
      $script:events.Clear()

      $result = Invoke-ScrubbedCli $script:scope "case" "C:\mock\root" `
        "C:\mock\support" @("projects", "--json")

      $result.ExitCode | Should -Be 7
      $result.Output | Should -BeExactly "stdout-cli"
      $result.Error | Should -BeExactly "stderr-cli"
      $cli.Finalized | Should -BeTrue
      $daemon.Finalized | Should -BeFalse
      $daemon.Process.HasExited | Should -BeFalse
      $script:starts[1].Environment["GRAPHCODE_SUPPORT_DIR"] | Should -BeExactly "C:\mock\support"
      $script:starts[1].RedirectStandardOutput | Should -BeTrue
      $script:starts[1].RedirectStandardError | Should -BeTrue
      @($script:starts[1].ArgumentList) | Should -Be @("projects", "--json")
      $script:events.IndexOf("drain:cli") | Should -BeLessThan $script:events.IndexOf("dispose:cli")
      $script:events | Should -Not -Contain "Terminate:300"
      Close-ShellProcessScope $script:scope
    }

    It "preserves the unredirected <name> startup stream policy through the owned launcher" -TestCases @(
      @{ name = "daemon"; variable = "daemonInfo" },
      @{ name = "shell"; variable = "shellInfo" }
    ) {
      param($name, $variable)
      $path = Join-Path $moduleRoot "Tests\ScrubbedShellStartup.Live.Tests.ps1"
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
      $errors.Count | Should -Be 0
      $builders = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
              $node.Name -ceq "New-StartInfo"
          }, $true))
      $builders.Count | Should -Be 1
      . ([scriptblock]::Create($builders[0].Extent.Text))
      $commands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
              $node.GetCommandName() -ceq "Start-ShellOwnedProcess" -and
              $node.Extent.Text -match ('\$processScope\s+\$' + $variable + '\b')
          }, $true))
      $commands.Count | Should -Be 1
      $info = New-StartInfo "C:\mock\$name.exe" "C:\mock\root"
      Set-Variable -Name $variable -Value $info
      $processScope = $script:scope
      $null = New-ControlledLaunch $name
      [void](& ([scriptblock]::Create($commands[0].Extent.Text)))

      $script:starts.Count | Should -Be 1
      [object]::ReferenceEquals($script:starts[0], $info) | Should -BeTrue
      $info.RedirectStandardOutput | Should -BeFalse
      $info.RedirectStandardError | Should -BeFalse
      Close-ShellProcessScope $script:scope
    }

    It "preserves the unredirected GDI runner stream policy through the owned launcher" {
      $path = Join-Path $moduleRoot "Tests\GdiplusStartup.Live.Tests.ps1"
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
      $errors.Count | Should -Be 0
      $builders = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
              $node.Left.Extent.Text -ceq '$start' -and
              $node.Right.Extent.Text -ceq '[Diagnostics.ProcessStartInfo]::new()'
          }, $true))
      $builders.Count | Should -Be 1
      $redirects = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
              $node.Left -is [Management.Automation.Language.MemberExpressionAst] -and
              $node.Left.Expression.Extent.Text -ceq '$start' -and
              $node.Left.Member.Extent.Text -in @("RedirectStandardOutput", "RedirectStandardError")
          }, $true))
      $redirects.Count | Should -Be 0
      $commands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
              $node.GetCommandName() -ceq "Start-ShellOwnedProcess" -and
              $node.Extent.Text -match '\$processScope\s+\$start\b'
          }, $true))
      $commands.Count | Should -Be 1
      . ([scriptblock]::Create($builders[0].Extent.Text))
      $processScope = $script:scope
      $null = New-ControlledLaunch "gdiplus"
      [void](& ([scriptblock]::Create($commands[0].Extent.Text)))

      $script:starts.Count | Should -Be 1
      [object]::ReferenceEquals($script:starts[0], $start) | Should -BeTrue
      $start.RedirectStandardOutput | Should -BeFalse
      $start.RedirectStandardError | Should -BeFalse
      Close-ShellProcessScope $script:scope
    }

    It "retains adapter completion failures across the scrubbed CLI cleanup" {
      $cli = New-ControlledLaunch "cli"
      $cli.PipeError = $true
      $failure = $null
      try {
        Invoke-ScrubbedCli $script:scope "case" "C:\mock\root" "C:\mock\support" @("projects")
      } catch { $failure = $_.Exception }

      $failure | Should -Not -BeNullOrEmpty
      Test-OwnedLiveProcessRetentionRequired $failure | Should -BeTrue
      $cli.Finalized | Should -BeFalse
      $script:events | Should -Contain "dispose:cli"
      $script:scope.Closed | Should -BeFalse
    }

    It "uses the adapter after source-derived graceful daemon shutdown" {
      $daemon = New-ControlledLaunch "daemon"
      $info = [Diagnostics.ProcessStartInfo]::new()
      $info.UseShellExecute = $false
      $process = Start-ShellOwnedProcess $script:scope $info
      $script:shutdownEvent = [pscustomobject]@{}
      $script:shutdownEvent | Add-Member ScriptMethod Set {
        $script:events.Add("shutdown-event")
        return $true
      }
      $script:events.Clear()

      Stop-OwnedDaemon $process

      $daemon.Finalized | Should -BeTrue
      $script:events.IndexOf("shutdown-event") | Should -BeLessThan $script:events.IndexOf("wait-root:daemon")
      $script:events.IndexOf("wait-root:daemon") | Should -BeLessThan $script:events.IndexOf("Terminate:300")
      $script:runLog.Count | Should -Be 3
      $script:runLog[1] | Should -BeExactly "daemon-stdout=stdout-daemon"
      $script:runLog[2] | Should -BeExactly "daemon-stderr=stderr-daemon"
      Close-ShellProcessScope $script:scope
    }

    It "preserves the source-derived startup-exit error after adapter completion" {
      $daemon = New-ControlledLaunch "daemon" $true
      $script:shutdownEvent = [pscustomobject]@{}
      $script:shutdownEvent | Add-Member ScriptMethod Reset { return $true }
      $script:expectedDaemonPath = "C:\mock\graphcoded.exe"
      $script:supportDirectory = "C:\mock\support"
      $script:daemonPipe = "\\.\pipe\mock"
      $script:shutdownEventName = "Local\mock"
      $script:runRoot = "C:\mock\root"
      $failure = $null
      try { Start-OwnedDaemon } catch { $failure = $_.Exception }

      $failure | Should -Not -BeNullOrEmpty
      $failure.Message | Should -Match "graphcoded.exe exited during startup: stderr-daemon"
      $script:starts[0].RedirectStandardOutput | Should -BeTrue
      $script:starts[0].RedirectStandardError | Should -BeTrue
      $daemon.Finalized | Should -BeTrue
      $script:events.IndexOf("drain:daemon") | Should -BeLessThan $script:events.IndexOf("dispose:daemon")
      Close-ShellProcessScope $script:scope
    }
  }
}
