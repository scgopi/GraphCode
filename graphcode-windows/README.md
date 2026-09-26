# GraphCode Windows shell

This is the production Zig/Win32 shell scaffold. It owns the top-level `HWND`,
the single Win32 message loop, sidebar/project chrome, graph surface, workspace
layout, and focus policy. GraphcodeKit and `graphcoded` remain the only owners of
graph/session orchestration and business rules.

The shell connects to the current-user GraphcodeKit Named Pipe using the v2
length-prefixed JSON envelope and falls back to the v1 command/event frame only
when the daemon does not negotiate v2. Commands and events are encoded from the
fixtures in `fixtures/`, which mirror the GraphcodeKit Codable wire shapes.

Each terminal surface is a real Winghostty surface under the GraphCode parent
window and attaches to the persistent zmx session for its selected node. Surface
destruction kills only the attach client; zmx owns the session and survives shell
restarts. The host contract is the accepted two-surface terminal-gate contract,
not a synthetic terminal proof.

The graph surface also provides native Win32 create/edit forms for nodes and
edges, a settings dialog, context menus, and keyboard-accessible actions:
`Ctrl+N` creates a node, `Ctrl+E` edits the selected node, `Ctrl+J` opens the
jump palette (also `Ctrl+P`), `Ctrl+,` opens Advanced Connection Settings, and
`Ctrl+Shift+,` opens product Settings. Mutations are sent as correlated v2 daemon
requests; daemon refusals remain visible as explicit status errors.

The shell exposes a native File/Loop/Terminal/View/Help menu bar. Menu items
share the same application action router as keyboard shortcuts, and project
actions use the Windows `IFileOpenDialog` folder picker. The no-project state
also presents accessible native buttons for opening a folder or the global
overview; recent projects remain selectable in the sidebar.

`F6` (or View > Focus Window Toolbar) enters the window toolbar; `Shift+F6`
enters at its last visible control. Within the toolbar, `Tab`/`Shift+Tab` and
Left/Right move between controls, Home/End select the first/last control, and
Enter/Space activate it. `F6`, `Shift+F6`, or Escape leave the toolbar and restore
the still-visible app-owned focus target. Outside the toolbar, Tab/Shift+Tab keep
their loop-navigation behavior and Ctrl+Tab still advances attention selection.
The header's loop-panel button is available only in a loop workspace with
supported detail content (connections or metric history); it collapses/expands
the detail rail without navigating away from the workspace.

Repository ingress covers four sources: a local folder, an HTTPS clone, an SSH
remote (`Ctrl+Shift+R`), and a GitHub Codespace (`Ctrl+Shift+K`). The codespace
sheet asks the GitHub CLI for the account's codespaces, validates the chosen
workspace path by dialing through `gh codespace ssh` before it closes, and then
opens the result as a `codespace://` project through the same daemon
`openProject` call every other source uses. It needs `gh` on the machine, an
authenticated account, and the `codespace` token scope — without the scope,
discovery reports the exact `gh auth refresh -h github.com -s codespace` command
that grants it.

Parity actions are reachable without App-specific view coupling: `Ctrl+P` opens
the searchable jump/palette form, `Ctrl+Up`/`Ctrl+Down` navigate by stable
project/node identity, `Ctrl+Tab` advances attention, and `Ctrl+Shift+R`,
`Ctrl+Shift+P`, and `Ctrl+Shift+A` toggle the workspace rail, panel, and
activity settings. `Ctrl+Q` creates a daemon-owned Quick Chat; `Ctrl+Shift+Q`
renames the selected chat and `Ctrl+Shift+X` deletes it.

Custom canvas, sidebar, header, and detail layout use 96-DPI logical units.
UI Automation receives physical client pixels: logical bounds, including the
fixed graph group, are scaled once at the reporting boundary. Terminal tab and
control bounds already use physical pixels shared with MM_TEXT painting and
hit-testing, so they must not be scaled again. Touch pinch locations and client
bounds are converted to logical units before graph routing and anchored zoom.
App regression tests exercise these production boundaries at 96, 144, and 192
DPI; they do not substitute for live touch or multi-monitor validation.
The destination toolbar and its focus ring render at the end of the buffered
logical pass, before the physical frame is copied to the window. Header UIA
controls use that same logical layout with one physical-boundary conversion;
the workspace identity region remains separate from the terminal's physical tabs.

## Workspace lifecycle

The Workspace menu lists `Default` and `.graphcode-*` directories under
`USERPROFILE`, with the current workspace marked by the native checked state.
New Workspace creates a normalized sibling directory and requests one separate
app instance using a child-only `GRAPHCODE_SUPPORT_DIR` environment. The child
does not inherit `GRAPHCODE_DAEMON_PIPE`: it derives its daemon endpoint from
the new support directory rather than reusing the parent's explicit override.
The parent's environment and other inherited variables remain unchanged.
Selecting the current workspace does nothing; selecting an identified running
workspace restores its exact window rather than the first GraphCode window.
`Ctrl+Alt+PageUp` / `Ctrl+Alt+PageDown` cycles the discovered list, including
workspaces not yet open.

Instance reservations, selected identity, and mutation guards share lexical
Windows path normalization: drive/ASCII case, separators, dot segments, and
trailing separators. Non-ASCII bytes are preserved; this does not establish
Unicode case, symlink, junction, or hard-link equivalence. Rename and Delete
refuse Default, the current workspace, and a workspace reserved by another
instance. Reservations cover the destructive confirmation and final recheck.
Compatibility checks include the older raw-path mutex; a same-user GraphCode
window without identifiable workspace metadata, or an uncertain owner lookup,
blocks mutations instead of being treated as a closed workspace.

Advanced connection Settings can reconnect to another support directory, but
that does not migrate every workspace store or layout. If the effective support
identity differs from the instance's reserved identity, or cannot be verified,
the shell removes its workspace attribution and blocks lifecycle mutations and
switching with a persistent restart-required status. It retains the original
reservation until exit. Restoring the original support directory revalidates
attribution; pipe-only changes and equivalent lexical paths keep lifecycle
actions available. No data-store migration is implied by a connection change.

Delete remains permanent. Cancel in the name form and every confirmation result
other than explicit Yes preserve the workspace; No is the warning's default.
Accepted form text is captured before native controls are destroyed, with
allocation/read failures rejecting the result. Rename does not overwrite an
existing destination and preserves the directory's saved files.

Executable coverage includes production helpers, allocation failures, disposable
filesystem mutations, exact launch/restore routing, and never-shown native
controls/windows/menus. This is not a live multi-instance, keyboard, UIA, or
real-daemon walkthrough. The lifecycle parity row remains Partial: macOS also
provides a structured Manage view, content summaries, creation-order/running-only
cycling, and recoverable deletion with daemon/session teardown.

## Build

From a fresh checkout, bootstrap the exact Zig toolchains, Swift 6.3.3, and
detached public provider pins:

```powershell
pwsh -NoProfile -File Tools\windows\bootstrap.ps1
. .\.graphcode-tools\environment.ps1
pwsh -NoProfile -File Tools\windows\validate.ps1 `
  -Task windows-shell `
  -SwiftExecutable $env:GRAPHCODE_SWIFT633
```

To build the complete release inputs and verify packaging from a developer
shell (including a Visual Studio Developer Command Prompt), use:

```powershell
. .\.graphcode-tools\environment.ps1
pwsh -NoProfile -File Tools\windows\stage-swift-products.ps1
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task packaging
```

The Swift scripts select the SDK and runtime that ship with the pinned Swift
toolchain and ignore inherited Visual Studio `INCLUDE`/`LIB` settings. This
prevents mixed VS/Swift SDK environments from producing false missing-module
errors for `_complex` or `ucrt`.

`Tools\windows\validate.ps1 -Task windows-shell` performs pin, clean-worktree,
format, lifecycle-contract, real provider build, and native UI Automation live
event checks. `Tools\windows\package.ps1` builds and verifies self-contained ZIP
packages and supports per-user install/upgrade/rollback. Each ZIP includes a
standalone `GraphCode-Setup.ps1` for Windows PowerShell 5.1 or PowerShell 7, so
installation and uninstall no longer require a source checkout or build tools.
`Tools\windows\release.ps1` and `.github\workflows\windows-release.yml` add the
maintainer-triggered path that builds, verifies, and can attach the standard
unsigned Windows ZIP to an existing release. Package metadata and `SIGNING.txt`
state that the artifact is not code signed; the SHA-256 sidecar detects download
corruption but does not authenticate the publisher. Optional Authenticode
packaging support remains documented in `Tools\windows\PACKAGING.md`, but it is
not a release prerequisite. There is not yet an automatic install/relaunch path
in the native updater.

## Update checks

The native client checks `scgopi/GraphCode`'s GitHub releases API, accepting
additive release/asset metadata while retaining type checks on consumed fields.
The greatest eligible version from the fetched 30-release page is selected;
stable checks exclude prereleases and both channels exclude drafts. Existing
version ordering and cancellation/generation behavior are unchanged. Startup
and settings-refresh checks update status/sidebar offers without opening a modal;
only an explicit Check for Updates action or banner click opens the offer.

An offer opens only the HTTPS release overview or a single-segment version-tag
page in that repository; encoded paths, dot segments, query/fragment additions,
and backslash separators are rejected. It is a project-release notification,
not proof of an installable Windows artifact: the dialog notes that assets may target other
platforms and that Windows installation/relaunch is not implemented.
No installer is downloaded or executed.

`Tools\windows\Tests\WindowsShell.Tests.ps1` runs the native updater contracts,
including realistic GitHub response fields, URL handoff validation, stable/beta
selection, malformed consumed fields, and allocation-failure cleanup.

## Tray lifecycle coverage

The shell registers a version-4 notification icon with a stable `HWND`/icon ID
identity, restores through the same callback path used by Explorer, and
re-registers after `TaskbarCreated`. `TrayLive.Tests.ps1` retains physical
`Shell_NotifyIconGetRect` discovery (including monitor and DPI checks), while
its test-only registered-message hook relays Open and context events back
through and observes the production notification callback. This avoids treating
injected screen coordinates as a reliable substitute for overflow-tray
activation. The context test locates the live popup and its actual `Exit` item,
verifies the menu label and command ID, and activates it with physical input
rather than injecting a command message.

When another shell owns the named startup reservation, daemon supervision opens
it for synchronization and waits only for the bounded reservation interval.
The spawning shell retains that reservation until its child has acquired the
lifetime lock and published its named-pipe listener through a child-ready event.
The child recognizes this handoff and does not wait on the parent-held
reservation. On timeout or incomplete publication the parent terminates only
its own child; contenders then recheck the endpoint and lifetime lock. The live
handoff test starts two distinct shell instances, verifies exactly one daemon,
and verifies that only the owning shell shuts it down.
