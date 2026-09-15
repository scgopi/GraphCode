# zmx ConPTY persistence spike

Standalone Windows feasibility spike; it does not use or modify GraphCode production code.
It combines:

- ConPTY for a hosted `cmd.exe /Q /K` terminal.
- A reader thread for ConPTY output.
- Named Pipe IPC: `\\.\pipe\zmx-conpty-spike`.
- A Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
- Detach/reconnect snapshot behavior while the daemon remains alive.

The daemon uses the current directory for its log and ready marker.

## Build (PowerShell)

```powershell
Set-Location <GraphCode checkout>\investigation\spikes\zmx-conpty
# Run from a Developer PowerShell or Developer Command Prompt.
cl /nologo /W4 /O2 conpty_spike.c /link /SUBSYSTEM:CONSOLE /OUT:conpty_spike.exe
```

The observed build exited `0`.

## Run (PowerShell)

```powershell
Set-Location <GraphCode checkout>\investigation\spikes\zmx-conpty
Remove-Item -Force -ErrorAction SilentlyContinue daemon.log,ready.txt
.\conpty_spike.exe start
Start-Sleep -Milliseconds 800
.\conpty_spike.exe status
.\conpty_spike.exe send 'echo BEFORE'
Start-Sleep -Milliseconds 800
.\conpty_spike.exe detach
.\conpty_spike.exe send 'echo DETACHED'
Start-Sleep -Milliseconds 800
.\conpty_spike.exe attach
.\conpty_spike.exe status
Get-Content ready.txt
Get-Content daemon.log -Tail 30
.\conpty_spike.exe stop
Start-Sleep -Milliseconds 800
.\conpty_spike.exe status  # expected: connect failed gle=2
```

## Observed rerun

```text
start: daemon_process_pid=40672
ready=ready.txt
STATUS pid=42544 running=1 output=160 conpty=1 named_pipe=1 job=1
OK write
OK detached
OK write
SNAPSHOT 388
...echo BEFORE
BEFORE...
...echo DETACHED
DETACHED...
STATUS pid=42544 running=1 output=388 conpty=1 named_pipe=1 job=1
pid=42544
pipe=\\.\pipe\zmx-conpty-spike
conpty=ok
job=kill-on-close
OK stopping
connect failed gle=2
```

`daemon.log` also recorded `CreatePseudoConsole(80x25)`, the Named Pipe,
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, reader startup, both commands, and their
output. After stopping, the hosted child and daemon were absent and the Named
Pipe endpoint was closed.
