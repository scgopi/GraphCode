# Winghostty fork, extraction, and GraphCode extension plan

## Decision and assumptions

This plan assumes GraphCode will:

1. fork `amanthanvi/winghostty`;
2. maintain the fork against Winghostty and Ghostty upstream;
3. extract an embeddable Win32 terminal-host layer from Winghostty's internal runtime;
4. build the GraphCode Windows shell in Zig + Win32 around that layer; and
5. keep GraphCode orchestration in Swift `graphcoded`, connected through Named Pipes.

The fork is not treated as the GraphCode application. It is the source and maintenance
home for a reusable Windows Ghostty host.

## Target architecture

```text
graphcode-windows.exe                         graphcoded.exe
Zig + Win32                                  Swift
        |                                      |
        | Named Pipe protocol                  |
        +--------------------------------------+
        |
        +-- GraphCode-owned top-level HWND
        |     sidebar, graph canvas, dialogs, navigation
        |
        +-- winghostty-host package
              |
              +-- terminal child HWND A
              |     WGL/OpenGL Ghostty renderer
              |     child process: zmx attach <session>
              |
              +-- terminal child HWND B
                    WGL/OpenGL Ghostty renderer
                    child process: zmx attach <session>

zmx session daemon
  owns the coding agent's persistent ConPTY
```

GraphCode owns product UI and layout. The extracted Winghostty layer owns complete
terminal surfaces: rendering, font metrics, input encoding, IME, selection, clipboard,
DPI, accessibility, repaint scheduling, and the short-lived `zmx attach` client process.

## Repository strategy

Create or use:

```text
coneilen/winghostty
```

Configure remotes:

```text
origin      coneilen/winghostty
winghostty  amanthanvi/winghostty
ghostty     ghostty-org/ghostty
```

The production baseline is an atomic compatibility tuple:

```text
{ Winghostty SHA, Winghostty Ghostty dependency SHA, Zig, MSVC, Windows SDK }
```

Do not merge Ghostty upstream directly into the fork. Upgrade Ghostty only through a
reviewed Winghostty update or an isolated vendor-bump branch that reruns the original-app,
external one-surface, and two-surface gates.

Long-lived branches:

| Branch | Purpose |
|---|---|
| `upstream` | Unmodified Winghostty synchronization point |
| `graphcode-host` | Extraction and reusable host API |
| `graphcode-integration` | Temporary integration branch only when a change spans both repositories |

Rules:

- Never mix GraphCode canvas/product code into the Winghostty fork.
- Keep extraction commits separate from behavior changes.
- Rebase unpublished extraction work; merge/version branches already pinned by GraphCode.
- Regularly synchronize the atomic Winghostty baseline; do not independently advance its
  Ghostty dependency.
- Pin GraphCode to an exact fork commit.
- Record Winghostty and Ghostty upstream bases in dependency metadata.
- Send generally useful extraction fixes upstream even if the complete host API is not accepted.

## Extracted package

Create a package/module such as:

```text
src/win32_host/
  Host.zig
  Surface.zig
  SurfaceConfig.zig
  Callbacks.zig
  Command.zig
  Clipboard.zig
  Input.zig
  Ime.zig
  Accessibility.zig
  Renderer.zig
  Dpi.zig
  Errors.zig
```

Initial consumption should be a pinned Zig package because both Winghostty and the
GraphCode Windows shell are Zig. Do not add a stable C ABI until another language actually
needs to embed the host.

The extracted package must not depend on:

- Winghostty tabs or split-tree product UI
- Winghostty settings window
- Winghostty update/recovery flows
- Winghostty top-level window chrome
- Winghostty application IPC
- Winghostty session persistence
- GraphCode types or daemon protocol

## Minimum host API

Illustrative Zig boundary:

```zig
pub const Host = struct {
    pub fn init(allocator: Allocator, options: HostOptions) !Host;
    pub fn deinit(self: *Host) void;
    pub fn createSurface(self: *Host, options: SurfaceOptions) !*Surface;
    pub fn drainUiThreadWork(self: *Host) !void;
};

pub const SurfaceOptions = struct {
    parent_hwnd: HWND,
    bounds: Rect,
    command: []const []const u8,
    cwd: ?[]const u8,
    environment: []const EnvironmentEntry,
    callbacks: SurfaceCallbacks,
};

pub const Surface = struct {
    pub fn setBounds(self: *Surface, bounds: Rect) !void;
    pub fn setVisible(self: *Surface, visible: bool) void;
    pub fn focus(self: *Surface) !void;
    pub fn setTheme(self: *Surface, theme: Theme) !void;
    pub fn setFontScale(self: *Surface, scale: f32) !void;
    pub fn destroy(self: *Surface) !void;
};
```

Embedding contract:

- GraphCode owns the sole UI thread and `GetMessage`/`TranslateMessage`/`DispatchMessage`
  loop.
- The host owns registered child-window procedures; it does not run a competing loop.
- `drainUiThreadWork` is optional non-blocking work called by GraphCode on the UI thread.
- Every host/surface call and callback documents UI-thread affinity.
- `createSurface` copies command, cwd, environment, and callback configuration.
- `destroy` is synchronous or explicitly awaitable and guarantees no callbacks, renderer
  access, process access, or posted child-window work after completion.

Callbacks should report:

- process exit
- title and working-directory changes
- bell/notification
- redraw requested
- focus change
- fatal surface error

The caller supplies `parent_hwnd`; the host must not create or own the GraphCode top-level
window.

## Ownership boundary

| Concern | Owner |
|---|---|
| Top-level HWND, app lifetime | GraphCode Windows |
| Sidebar, graph canvas, cards, dialogs | GraphCode Windows |
| Tabs/splits and terminal workspace model | GraphCode Windows |
| Terminal child HWND | Winghostty host |
| WGL/OpenGL renderer and glyph resources | Winghostty host |
| Keyboard, mouse, IME, selection | Winghostty host |
| Terminal clipboard and UIA text provider | Winghostty host |
| `zmx attach` child process/ConPTY | Winghostty host |
| Persistent agent process and scrollback state | zmx |
| Graph/session/backend orchestration | Swift GraphcodeKit/graphcoded |
| Project/graph persistence | Swift GraphcodeKit |

GraphCode should implement its own tab/split layout using `TerminalLayout`; do not import
Winghostty's product-level tab/split UI.

## Phased work

### Phase 0: Fork governance and reproducible baseline

Tasks:

- fork Winghostty and configure remotes;
- document exact upstream revisions and license provenance;
- pin the supported Zig, MSVC, Windows SDK, and dependency versions;
- reproduce the full Winghostty build in clean Windows CI;
- fix the observed absolute-child-cwd build-runner failure;
- add a smoke workflow that launches Winghostty and opens one terminal.

Exit criteria:

- clean clone builds without local path assumptions;
- CI produces a runnable artifact;
- upstream synchronization procedure is documented.

Estimate: 1-2 engineer-weeks.

### Phase 1: Separate runtime from Winghostty application policy

Move or refactor code in small commits:

1. isolate Win32 types/errors/helpers;
2. isolate renderer/context creation;
3. isolate terminal child `Surface`;
4. isolate input/IME/clipboard/DPI/accessibility;
5. replace direct `App`/`Host` product calls with callbacks/interfaces;
6. make top-level ownership injectable.

Keep Winghostty behavior unchanged after every commit.

Exit criteria:

- normal Winghostty still builds and behaves the same;
- terminal surface code no longer imports tabs, settings UI, updater, recovery, or app IPC;
- one internal Winghostty test host creates a surface under a supplied parent HWND.

Estimate: 3-5 weeks.

### Phase 2: Publish the embeddable `win32_host` package

Tasks:

- define `Host`, `Surface`, options, callbacks, and errors;
- accept a caller-owned parent HWND;
- accept direct command argv, cwd, and environment;
- make surface lifetime deterministic;
- support independent WGL contexts and renderer resources;
- provide a minimal external example with custom GraphCode-like chrome.

Acceptance tests:

- create/destroy one surface 100 times;
- resize continuously across per-monitor DPI changes;
- run `cmd.exe`, PowerShell, and an arbitrary executable;
- verify Unicode, dead keys, IME, selection, clipboard, mouse wheel, and links;
- close the top-level host without leaked threads/processes/HWNDs/HDCs/HGLRCs.

Exit criteria:

- a standalone executable outside Winghostty creates a complete rendered terminal surface;
- no Winghostty product window, tabs, or settings code is linked.

Estimate: 3-5 weeks.

### Phase 3: Two-surface architecture gate

Build the exact GraphCode-shaped proof:

```text
GraphCode-owned top-level HWND
  custom header/panel
  terminal child A
  terminal child B
```

Test:

- independent commands and terminal state;
- independent focus and keyboard input;
- repeated focus switching;
- simultaneous output;
- resize and DPI;
- IME in each surface;
- copy in one and paste in the other;
- accessibility tree exposes both;
- a UI Automation client verifies focus, role/name, terminal text exposure and updates,
  and selection/copy behavior for each surface;
- destroy/recreate one while the other remains active.

Exit criteria:

- all tests pass without using Winghostty's top-level application UI;
- renderer/context/thread ownership is documented;
- this becomes the full Windows UI go/no-go checkpoint.

Estimate: 2-4 weeks.

### Phase 4: zmx attach integration

Dependency: the source-integrated Windows zmx protocol prototype must pass first.

Tasks:

- launch `zmx.exe attach <session>` as the surface command;
- close a surface without killing the zmx session;
- recreate and reattach with VT state restored by zmx;
- test input injection while attached and detached;
- define exit/reconnect UI when zmx or the attach client fails.

Acceptance:

- session survives terminal surface destruction;
- session survives GraphCode Windows process exit;
- two GraphCode surfaces can attach to two sessions concurrently;
- one policy is chosen for two surfaces attaching to one session: reject, shared attach,
  or explicit leadership transfer;
- that policy is tested concurrently for input routing, resize ownership, transfer or
  rejection, detach/reconnect, and continued session health.

Estimate: 2-4 weeks.

### Parallel prerequisite: Windows daemon, CLI, and protocol

This can run alongside Winghostty extraction but must complete before Phase 5.

Implement and prove:

- cross-platform Swift package boundaries;
- `PlatformPaths`, `ProcessRunner`, and `ShellStrategy`;
- Windows `graphcoded.exe` and `graphcode.exe`;
- current-user Named Pipe ACL and collision-resistant endpoint naming;
- bounded framing, partial-frame handling, backpressure, and non-reading peers;
- connected read/write deadlines and cancellation;
- request correlation and protocol version negotiation;
- event subscription, ordering, reconnect, and replay semantics;
- interleaved multi-client CLI/UI tests.

Exit criteria:

- Windows CLI creates, reads, and updates a local graph through `graphcoded`;
- two clients issue interleaved commands without misattributing responses;
- reconnect and daemon restart behavior are deterministic;
- security tests show another user cannot open the pipe.

Estimate: 6-10 engineer-weeks, including shared Swift extraction.

### Phase 5: GraphCode Windows shell scaffold

Dependencies:

- Phase 3 two-surface host gate;
- Phase 4 zmx attach integration;
- Windows daemon/CLI/protocol prerequisite.

Create `graphcode-windows/`:

```text
build.zig
src/
  main.zig
  App.zig
  MainWindow.zig
  DaemonClient.zig
  GraphCanvas.zig
  Sidebar.zig
  TerminalWorkspace.zig
  TerminalSurface.zig
  InputRouter.zig
  Accessibility.zig
```

Implement:

- top-level window and message loop;
- Named Pipe daemon client;
- project/sidebar list;
- basic graph cards and edges;
- node selection/open;
- one terminal workspace;
- two-surface support;
- create/stop/send actions;
- live graph/presence events.

Exit criteria:

- local project can be opened through Windows `graphcoded`;
- a node can be created and opened;
- its persistent zmx terminal can be closed and reopened;
- two nodes can be viewed simultaneously.

Estimate: 6-10 weeks.

### Phase 6: Workspace and graph parity

Implement in GraphCode, not the Winghostty fork:

- tabs/splits and `TerminalLayout` persistence;
- keyboard focus/navigation;
- jump palette and needs-you navigation;
- full node/edge forms;
- graph pan/zoom/drag/connect;
- context menus and native dialogs;
- theme and font settings.

Estimate: 6-10 weeks.

### Phase 7: Production hardening

- UIA/accessibility audit;
- IME and international keyboard matrix;
- GPU/device/context failure recovery;
- renderer crash and teardown tests;
- code signing and installer;
- Swift and Zig runtime packaging;
- telemetry/logging consistent with project policy;
- updater;
- performance and memory tests with 10-20 live surfaces;
- upstream/fork sync rehearsal.

Estimate: 6-10 weeks.

## Proposed PR sequence in the Winghostty fork

Keep changes reviewable:

1. CI/toolchain baseline and cwd fix.
2. Win32 error/type helpers extraction.
3. Renderer context lifecycle extraction.
4. Surface options and caller-owned parent HWND.
5. Callback interface replacing direct app policy calls.
6. Input/IME extraction.
7. Clipboard/selection extraction.
8. DPI/focus/accessibility extraction.
9. External one-surface example.
10. External two-surface example.
11. Zig package export and documentation.

Do not submit one large “make Winghostty embeddable” patch.

## Testing matrix

### Automated

- build with pinned Zig/MSVC/SDK;
- one and two surface creation;
- repeated create/destroy;
- bounds/DPI calculations;
- input encoders;
- clipboard round-trip;
- process exit callbacks;
- leaked HANDLE/HWND/HDC/HGLRC checks;
- upstream Winghostty regression smoke.

### Manual hardware/UX

- Intel/AMD/NVIDIA GPUs;
- 100%, 125%, 150%, 200% DPI;
- multi-monitor mixed DPI;
- US/international/dead-key layouts;
- Chinese/Japanese/Korean IMEs;
- screen reader/UIA;
- remote desktop;
- sleep/wake and GPU driver reset;
- long-running high-output agent TUIs.

## Fork maintenance budget

Reserve ongoing capacity:

- weekly/biweekly upstream review;
- monthly synchronization at minimum;
- immediate security/dependency updates;
- one maintained patch stack with documented upstream bases;
- CI against the pinned compatibility tuple and explicit vendor-bump branches.

Expected steady-state cost: approximately 0.1-0.25 engineer after extraction, with spikes
around major Ghostty/Winghostty renderer or build changes.

## Risks and controls

| Risk | Control |
|---|---|
| Fork diverges | Small layered patch series, atomic baseline sync, upstream generic fixes |
| Host API becomes GraphCode-specific | No GraphCode types/protocol in the fork |
| Renderer/context leaks | Repeated lifecycle tests and explicit ownership |
| Winghostty product regressions | Build/run original app after every extraction PR |
| Tabs/splits duplicated | Winghostty owns surfaces; GraphCode owns workspace layout |
| zmx and terminal host both claim process ownership | Host owns only `zmx attach`; zmx owns agent ConPTY |
| Build toolchain instability | Pin Zig/MSVC/SDK and maintain clean CI images |
| Accessibility postponed | Include UIA in the extracted surface acceptance gate |

## Staffing and schedule

Recommended parallel streams:

| Stream | Work |
|---|---|
| Terminal platform engineer | Winghostty fork, extraction, renderer/input/IME |
| Systems engineer | zmx Windows protocol backend |
| Swift engineer | shared core, daemon, CLI, paths/process/IPC |
| Windows product engineer | GraphCode shell/canvas/workspace |

Critical path:

```text
Winghostty baseline -> embeddable host -> two-surface gate ---+
                                                              |
source-integrated zmx backend -> zmx attach integration ------+-> minimal shell
                                                              |
Windows daemon + CLI + hardened protocol ---------------------+
```

The work listed here plus shared Swift, daemon/CLI, and zmx is approximately **41-70
engineer-weeks**, excluding remote parity and ARM64. A single experienced engineer should
expect roughly 10-18 months. Parallel staffing shortens calendar time but does not remove
the 8-16 week high-uncertainty terminal-host extraction segment.

## First 30 days

1. Create the fork and CI baseline.
2. Fix and document the Winghostty build/toolchain issue.
3. Produce an import/dependency graph rooted at `Surface`.
4. Identify every direct `App`/`Host` policy dependency.
5. Extract caller-owned parent HWND creation.
6. Publish a one-surface external example.
7. Start the source-integrated zmx Windows protocol prototype in parallel.
8. Start the Windows daemon/CLI/path/process/protocol prerequisite in parallel.

At day 30, review:

- whether the surface import graph is shrinking as expected;
- whether original Winghostty behavior remains intact;
- whether upstream is receptive to generic extraction patches;
- whether the expected two-surface gate still fits the estimate.

If not, stop before GraphCode product UI work and reassess the fork cost.
