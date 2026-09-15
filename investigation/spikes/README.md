# Windows feasibility spikes

All Swift spikes were run with Swift 6.3.3 on Windows 11.

The official toolkit used in this investigation installed under:

```text
%LOCALAPPDATA%\Programs\Swift\
```

Before running SwiftPM, put the selected toolchain and runtime `usr\bin` directories on
`PATH` and set `SDKROOT` to the matching Windows SDK inside the Swift installation.

| Directory | Purpose | Last result |
|---|---|---|
| `swift-full` | Compile all GraphcodeKit sources through SwiftPM | Dependencies build; fails at `PTYProcessSession.swift: import Darwin` |
| `swift-portable` | Compile/test 31 portable domain files | Pass, 2 tests |
| `swift-paths` | Execute current path algorithms on Windows paths | Pass; reproduces 3 blockers |
| `swift-named-pipe` | Swift/WinSDK daemon transport behaviors | Pass, 7 behaviors; connected-I/O deadlines remain untested |
| `swift-process` | Foundation `Process`, argv, cwd, environment, scripts | Pass |
| `zmx-conpty` | ConPTY + Named Pipe + Job Object primitive survival/snapshot | Pass; not actual zmx protocol parity |
| `ghostty-custom-window` | GraphCode-owned HWND with two libghostty-vt-backed views | Pass for VT/state rendering; not a full Ghostty renderer proof |

The `swift-full` and `swift-portable` setup scripts create directory junctions into the
repository so source is not duplicated.

Generated `.build` directories, executables, libraries, and runtime logs are not required
source artifacts and should not be committed.
