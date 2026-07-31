# relay-bench — is the zmx relay why scroll feels worse than Ghostty?

An A/B harness that drives the identical TUI-shaped workload two ways and diffs
the numbers:

```sh
cc -O2 -o workload workload.c && cc -O2 -o ptybench ptybench.c

./ptybench ./workload                       # A: bare PTY — the Ghostty-app shape
zmx run bench -d "$PWD/workload"            # B: through the relay — the graphcode shape
./ptybench zmx attach bench                 #    (kill the session afterwards)
```

`ptybench` plays the terminal (forkpty), `workload` plays the agent TUI (raw
mode, answers pings, emits 64KB redraw bursts at 60Hz). Scenarios: idle
round-trip, 20MB drain, round-trip under redraw load, burst pacing, and SGR
mouse-report fragmentation. Output is one JSON object.

## Result (2026-07-30, macOS, M-series)

| Metric | bare PTY | zmx (Debug build) | zmx (ReleaseFast) |
|---|---|---|---|
| idle RTT p50 | 0.049 ms | 1.74 ms | 0.159 ms |
| RTT under load p50 | 7.8 ms | 131 ms | 7.0 ms |
| 60Hz burst gap p50 | 20.1 ms | 231 ms (≈4Hz!) | 21.3 ms |
| late gaps (>25ms) | 9/299 | 299/299 | 0/299 |
| drain throughput | 219 MB/s | 0.3 MB/s | 9.4 MB/s |
| split mouse reports | 0 | 0 | 0 |

The relay architecture was never the cost. The cost was the build mode:
`zig build` defaults to Debug, and Debug ghostty-vt runs
`page.Page.verifyIntegrity` (via `slow_runtime_safety`) on **every scrolled
line** — confirmed by `sample` showing the session daemon pinned at 100% CPU
inside `PageList.grow → verifyIntegrity` during the drain test. A ReleaseFast
zmx is at parity with a bare PTY for TUI redraw cadence; the remaining
throughput gap only shows on `cat huge-file`-class dumps, not on redraws.

The fix is `-Doptimize=ReleaseFast` in the Makefile's `build-zmx` — and
`build-ghostty`, which had the same omission, meaning the app's own GhosttyKit
(terminal emulation *and* renderer) also shipped as a Debug build while
Ghostty.app ships ReleaseFast.
