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
Workspace reopen and activation restore the selected tab's focused pane rather
than assuming that terminal slot zero or the last active slot is visible.

By default, the pinned Winghostty child HWND already owns the terminal's UI Automation
Text/Text2 provider. GraphCode supplies an owned UTF-8 snapshot of its existing
pane-sized rendered-cell grid, with spaces for empty cells, preserved trailing
blanks, LF row separators, and independent UTF-16 length/cursor offsets. This
deliberately replaces the recent raw VT byte stream: the accessible document is
the current grid, not a transcript or scrollback. Render and accessibility
updates remain separate, best-effort calls.
Failures report through the existing status/diagnostic path without empty-text
fallbacks; a failed accessibility update leaves the provider's last successful
snapshot, which must not be treated as current renderer state. Producer tests use
injected outbound calls, not native UIA. Once no input or pane publication error
remains, the status path replaces only its own exact failure messages with one
neutral error-cleared notice; it does not overwrite unrelated statuses or imply a
reset pane published fresh text. Applied selection, visible caret/geometry,
provider range conformance, and end-to-end accessibility parity remain unverified
or incomplete.

### Terminal VT parser and glyph snapshots

The public `libghostty-vt` C API from the existing Winghostty pin
`6286560d0aa3103e068b2b7afa81eac373d870c9` is the production default. Set
`GRAPHCODE_EXPERIMENTAL_TERMINAL_VT=0` before startup only as a rollback to the
limited legacy parser; an absent variable or exactly `1` enables Ghostty VT.
Other values, including an empty value, fail workspace initialization with
`InvalidTerminalVtFlag` and a diagnostic; there is no silent fallback.

Each pane owns a stable, heap-allocated terminal and copied viewport snapshot.
UTF-8 is parsed incrementally; complete grapheme codepoints, wide-cell occupancy,
styles, resolved/default colors, row wrapping, cursor state, screen identity,
and scrollbar state are retained. Accessible UTF-8/UTF-16 text includes complete
clusters and separate cell-to-UTF-16 offsets; wide spacers do not invent spaces
or split surrogate pairs. This is the authoritative VT viewport, not a claim
that the native host displayed it. Grapheme clustering follows the provider's
terminal modes (including mode 2027); GraphCode does not override their defaults.

GraphCode publishes the viewport through Winghostty's v2 terminal snapshot ABI,
including UTF-8 grapheme spans and narrow, wide, and continuation occupancy.
Winghostty rasterizes those spans as real GDI glyph coverage rather than its v1
pseudo-hash fallback. Inverse and invisible colors are flattened into cell
colors; the current host ABI does not represent the other retained decorations.
Invalid cells reject the projection explicitly rather than being truncated,
replaced by ASCII, or presented as a successful blank frame. Previously
published cells remain, while authoritative accessible text and valid PTY
replies can still advance. The legacy parser rollback also publishes v2 glyph
spans, but its parsing behavior remains intentionally limited.

Query replies are captured synchronously into a per-pane 64 KiB buffer and
enqueued through the existing input queue for the current pane slot. Complete
responses are accepted or an overflow is latched; no partial response is added.
Accepted bytes are consumed exactly once. A rejected enqueue retains the pending
bytes and latches a delivery failure with no automatic retry/replay; later replies
are not accepted in that failed state. Existing input errors take status
precedence. Native input retains its existing per-write event and 50 ms wait,
not a whole-buffer deadline. Pane teardown discards its state and queued input.

The public `vt_write` function returns void and logs some internal errors: a
completed call is **not** proof of parse success. A typed allocator bridge
latches actual provider allocation failures and marks the state unreliable
without replay/recovery; normal resize/remap refusal is not an allocation
failure. Failed VT resize is also non-recovering, since transactional failure
is not guaranteed. Failed owned snapshots are not published as current.
OSC 2 titles are retained without UI changes and bells remain a UI no-op.
The PWD query copies the API's value, but **OSC 7 does not populate it at this
pin**; an explicit public PWD option roundtrip is not OSC 7 support.

Production derives each pane's grid from its live bounds and measured cell
metrics. Initial attach uses that computed size; later topology changes resize
the owned cell/VT state and queue `zmx resize <session> <columns>x<rows>` for the
attached session. Zero-sized or unavailable geometry preserves the previous
grid rather than collapsing it during minimize/restore. Headless tests exercise
the state transition, in-memory resize, reflow, scrollback/viewport, stream
chunk boundaries, v2 glyph spans, projection failures, allocation failures, and
response ownership. They do not prove that a real backend accepted the resize
or that visible wrapping and pixels match the negotiated PTY dimensions.
Wheel/selection integration, live glyph pixels, visible caret geometry, full
TextPattern conformance, and end-to-end terminal parity remain separate work.
No live HWND, UIA, clipboard, device-input, backend-resize, or pixel-readability
proof is claimed.

`build.zig` builds the VT library separately from the unchanged Win32 host and
links its generated static artifact into the application. The
`prepare-terminal-vt` step installs the same artifact to
`graphcode-windows\zig-out\lib\ghostty-vt-static.lib` for memory tests.
The dedicated provider invocation uses Zig 0.15.2, `ReleaseSafe`,
`x86_64-windows-msvc`, `-Demit-lib-vt=true`, and `-Dsimd=false`: the pinned
Windows static library does not bundle its SIMD dependencies. This selects
the existing scalar implementation, not a different parser or provider pin;
no SIMD performance or benchmark equivalence is claimed. Provider build cwd,
cache, and prefix are isolated from the host build. The normal Windows shell
regression runner prepares the artifact before the memory and terminal tests,
and propagates preparation/test failures.

The graph surface also provides native Win32 create/edit forms for nodes and
edges, a settings dialog, context menus, and keyboard-accessible actions:
`Ctrl+N` creates a node, `Ctrl+J` opens the jump palette, and `Ctrl+,` opens
Advanced Connection Settings. `Ctrl+Shift+,` opens product Settings.
With the graph canvas owning the keyboard,
`F2` or `Ctrl+E` renames the selected loop; `Ctrl+E` edits the selected edge
instead when an edge is selected. Full **Edit Details...** remains a node
context-menu action, not the `Ctrl+E` action. **Open Terminal** is also in that
menu; Enter is not a standalone shortcut for it. Mutations are sent as
correlated v2 daemon requests; daemon refusals remain visible as explicit status
errors.

Edge editing queues one checked `updateEdge` command, never delete/recreate.
The existing edge ID and endpoints stay fixed, and the daemon retains its current
fire count. The editor owns the complete initial configuration across the modal,
then rechecks the displayed project, cached graph, composite address and edge
configuration before queueing. A configuration conflict is refused; a runtime
count advance alone is not a conflict. An observation subscription to a different
cached project does not prohibit editing the selected project.

Unchanged legacy values are retained, including an absent versus present-empty
cycle guard and nil versus empty text. Changed guards use the existing daemon
creation rule; clearing changed guard controls removes the guard. Only root and
one directly addressed composite are supported by this new command; deeper edit
wrappers are explicitly refused without changing existing non-edit commands.
The command requires a supporting daemon and has no destructive compatibility
fallback. "Queued" is not daemon acceptance or persistence. Native interaction,
real daemon persistence and macOS runtime behavior remain unverified by the
data-only regression coverage.

Edge edits use length-aware text capture for both live changes and submission.
Unreadable text, invalid selections and allocation failures block submission
until that field is read successfully; recovering one field does not clear
another field's error. This checked reader is edit-only. Creation, node and
settings forms retain their existing bounded reader and are outside this
capture validation.

Unresolved project-canvas and sidebar node menus expose **New Child Node...**.
The normal creation form starts with the parent's backend (still editable) and
keeps its ordinary type/default fields. It sends one `createNode` draft with
`createdBy`; the daemon owns the already-fired custody link, report-back memo,
and normal session-start policy. No extra edge or start command is sent.
The clicked project, root/composite scope, parent, settings, and exact-project
worktree choices are owned before the popup. Project/scope drift, parent deletion,
resolution, type changes, or backend changes refuse submission before attachment
transfer; rename, reorder, and unresolved state progress are allowed. Templates
preserve custody and the edited backend. Pure coverage runs via
`Tools\windows\Tests\CustodyChild.Tests.ps1` and the normal Windows shell runner.
Existing node menu actions keep their owned targets even when child settings or
snapshot allocation are unavailable; only New Child Node is disabled. Resolved
nodes omit New Child Node without capturing child settings at all.
Initial project selection now refuses either identity-allocation failure without
changing the old project/composite/node selection; later legacy snapshot
rebuilding is unchanged and is not covered by that preparation guarantee.
Parity remains **Partial**: overview right-click, shown native-menu/form behavior,
and real-daemon acceptance/persistence are not established by these queue tests.

Sketch loop context menus on the project canvas and in the sidebar offer
**Promote to... > Goal / Turn / Timed**. Each native form asks only for its
target's decision: a done check, where to pause, or a cadence. Timed promotion
uses the captured sketch's first instruction, with the same fallback and
interval choices as macOS. Promotion uses the existing daemon command; it does
not recreate the node or replace its session, history, worktree, or edges.
The clicked project can differ from the observation subscription. Popup and
form contexts are owned and rechecked; stale project/composite, selection,
deleted-node, or changed-type results do not send or retarget a command.
"Queued" reports local queue insertion, not daemon acceptance or persistence.
Pure production-adapter tests and Swift fixture decoding cover this path;
native keyboard/UIA and real-daemon promotion remain unverified.

Live graph updates reach every open project, not only the focused one. The
daemon connection is a sidebar client (`restoreOpenProjects`), and its v2 hello
carries no `subscription.projectPaths` filter; the "observation subscription"
above records the focused project and drives a drained re-dial, never a delivery
filter. Presence/activity ticks arrive as `nodesChanged` deltas, which the model
folds into the held snapshot by node ID (ignoring unknown loops and deltas no
newer than the held `revision`) and then applies like a `graphChanged`, matching
macOS `AppFeature.foldDelta`. Unit tests cover the hello and the delta fold; the
Dev Box multi-project and Needs-you walkthroughs are the runtime evidence.

The shell exposes a native File/Loop/Terminal/View/Help menu bar. Menu items
share the same application action router as keyboard shortcuts, and project
actions use the Windows `IFileOpenDialog` folder picker. The no-project state
also presents accessible native buttons for opening a folder or the global
overview; recent projects remain selectable in the sidebar.

Pressing and releasing unmodified `F10` enters the native menu bar. While an
embedded terminal has focus, `F10` and `F6` belong to the program in it and are
sent through the key encoder (`ESC[21~` and `ESC[17~`, with modifier
parameters such as `Shift+F6` -> `ESC[17;2~`); use `Ctrl+Shift+F10` to enter
the menu bar and `Ctrl+Shift+F6` to enter the window toolbar from a terminal.
`Alt+Space` still opens the window menu and `Alt+F4` closes the window. Alt
alone and Alt+letter chords are terminal input (an ESC prefix), so the menu
mnemonics (Alt+F, Alt+E, ...) are unavailable while a terminal has focus; use
`Ctrl+Shift+F10`, or click the menu bar, instead.
Outside a terminal, the shell passes the original key pair
to Windows default menu processing only when the release still targets the
same eligible, app-owned window. Observed focus/activation changes, modal
disablement, and intervening input cancel the pending pair; modified `F10`
(including `Shift+F10`) retains its existing input route (in a terminal,
`Shift+F10` opens the terminal context menu). A terminal-owned `F10` is never
buffered, so the menu bar cannot be left active by a key that went to the
terminal.
Both ordinary and system-key plain `F10` messages use this route; an Alt-context
message is excluded even if the modifier snapshot no longer shows Alt pressed.

`F6` (or View > Focus Window Toolbar) enters the window toolbar; `Shift+F6`
enters at its last visible control; `Ctrl+Shift+F6` enters it at the first
control and works while a terminal has focus. Within the toolbar, `Tab`/`Shift+Tab` and
Left/Right move between controls, Home/End select the first/last control, and
Enter/Space activate it. `F6`, `Shift+F6`, `Ctrl+Shift+F6`, or Escape leave the toolbar and restore
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

When the app root owns the keyboard, `Ctrl+P` is another route to the same
searchable jump palette as `Ctrl+J`, and `Ctrl+Up`/`Ctrl+Down` navigate by stable
project/node identity. `Ctrl+Shift+L`, `Ctrl+Shift+B`, and `Ctrl+Shift+A` toggle
the application sidebar, terminal workspace, and activity strip, respectively.
`Ctrl+Q` creates a daemon-owned Quick Chat; `Ctrl+Shift+Q` renames the selected
chat and `Ctrl+Shift+Delete` requests its deletion with confirmation.
`Ctrl+Shift+R` adds an SSH repository, `Ctrl+Shift+P` opens worktree policy,
and `Ctrl+Shift+X` cancels a clone; they are not aliases for those toggles or
chat deletion.

These root-window bindings are not universal terminal or dialog shortcuts.
While a terminal has focus it keeps `Ctrl+D` (EOF), `Ctrl+W` (delete word),
`Ctrl+S`, `Ctrl+T`, `Ctrl+N`, `Ctrl+[`, `Ctrl+]`, `F6` and `F10` for the program running in
it, so those menu accelerators apply only elsewhere. The terminal-safe
alternatives work everywhere: `Ctrl+Shift+T` (new tab), `Ctrl+Shift+N` (new
loop), `Alt+Shift+D` (split right), `Ctrl+Shift+D` (split down),
`Ctrl+Shift+[` / `Ctrl+Shift+]` (pane focus), `Ctrl+Shift+F6` (window toolbar),
and `Ctrl+Shift+F10` (menu bar); `Ctrl+Shift+W` closes the tab
while a terminal has focus (it opens Worktrees elsewhere). `Ctrl+J` and
`Ctrl+O` remain application keys in a terminal and `Ctrl+P` is not forwarded.
The terminal sends editing, cursor, Home/End, Insert/Delete, Page, and function
keys through the pinned Ghostty key encoder, so cursor-key application mode,
modifier parameters, and Alt's ESC prefix match the macOS terminal; Backspace
sends DEL and Ctrl+Backspace sends BS. Plain `Ctrl+S` is sent as the raw 0x13
byte, like `Ctrl+T`, `Ctrl+D`, `Ctrl+W` and `Ctrl+N` (0x14, 0x04, 0x17, 0x0E).
Known limitation: in a program that reads keys with line input enabled (for
example PowerShell's `[Console]::ReadKey`), the Windows console's pause-output
handling swallows `Ctrl+S` and then the next key; `Ctrl+T` on its own works. A
workaround that sent `Ctrl+S` as a win32-input-mode key pair was rejected because
it broke Git MSYS vim (Enter no longer honored) and made cmd.exe insert a literal
`^S` instead of pausing output. This comes from an isolated zmx matrix, not a Dev
Box walkthrough, and `Ctrl+S` is not claimed to work in such programs. In the jump palette,
Up/Down moves through results and Enter accepts the selection, returning to
the selected loop in the graph rather than opening its terminal. Native forms
keep their own text editing, Tab navigation, and acceptance/cancellation;
Enter in an already-open menu activates its highlighted item.

Help > **Keyboard Shortcuts** lists the remaining keyboard routes: sending a
loop, context-sensitive `Ctrl+E`, project or node identity navigation,
worktree-row selection, terminal focus, clone cancellation, terminal paste,
focused-toolbar navigation, and jump-palette navigation. The Loop, View, and
File menu items also show `Ctrl+Shift+G` for Show in Graph, `Ctrl+R` for
Reconnect, and `Ctrl+Shift+P` for Project Worktree Policy. `Ctrl+P` remains
unlisted because it duplicates the `Ctrl+J` jump-palette route;
`Ctrl+Shift+I` remains unlisted because it duplicates the `Ctrl+Shift+W`
Worktrees route. `Ctrl+Shift+C` is shown only for Clone Repository: the
terminal context also uses it to copy a selection, so Help does not present
the context-dependent collision as a second shortcut.

Terminal clipboard follows Winghostty's Windows defaults. `Ctrl+Shift+V` or
`Shift+Insert` pastes and `Ctrl+Shift+C` or `Ctrl+Insert` copies the
terminal's selected text; the Terminal menu and the terminal's context menu
(right-click, Menu key, `Shift+F10`) offer the same Copy and Paste. Dragging
selects text with a visible highlight, double click selects a word, triple click
a whole line, `Shift`+click extends the selection, and a click or typing clears
it. Copy puts exactly the selected text on the clipboard: soft-wrapped rows join
into one line and trailing blanks are dropped. Plain
`Ctrl+V` stays terminal input and plain `Ctrl+C` stays the interrupt, except
that `Ctrl+C` copies while the terminal has a selection. Paste reads only
`CF_UNICODETEXT`, normalises line endings, blanks the control bytes xterm blanks
(NUL, BS, ESC, DEL and the tty's special characters; BEL and tab pass through), and
wraps the text in bracketed-paste markers only when the running program asked
for them (DECSET 2004); text over 1,000,000 bytes is refused. A copy that the
Windows clipboard refuses puts the previous clipboard text back and says whether
that worked (other clipboard formats, such as an image, are not preserved). Multi-line text for a program that did not ask asks for
confirmation first instead of running each line as it is pasted. That includes
`pwsh` and `cmd.exe`: neither asks for bracketed paste under ConPTY, and each
runs the pasted lines as they arrive. macOS auto-confirms that case without a
dialog. Dragging past the edge of the terminal does not scroll it, and there is
no block selection.

Canvas and pointer actions still have no visible gesture hints: clicking
selects/opens canvas items; dragging blank canvas pans, dragging a node moves
it, and dragging a connector to another node creates an edge; wheel and
touchscreen pinch zoom the canvas; right-click opens item-specific context
menus; and dragging a top-level sidebar loop reorders it. Closing this gap
requires hints in the owning `GraphCanvas.zig` and `Sidebar.zig` rendering
surfaces, both outside this change's scope.

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

### Sidebar scrolling and short windows

The sidebar rows, Needs you, and Activity scroll under the fixed GRAPH/Projects
header and above the footer (status line, update banner, inline error footer).
What is painted, what UIA publishes, and what a click hits are the same rect,
clipped to that scroll region; the right-hand Activity control sits inside the
220-pixel rail.

Keyboard and assistive clients reach offscreen rows through UIA, not a hidden
shortcut: each sidebar list (Projects, Loops, Worktrees) exposes a vertical-only
`IScrollProvider` over the one sidebar offset, and every element that scrolls
with it (rows, controls, the Graph and Quick Chats destinations) exposes
`IScrollItemProvider`; the shell reveals the element through
`Accessibility.wm_sidebar_scroll`. The fixed header, update banner, and error
footer do not scroll and expose no scroll item. The root's coordinate hit-test
returns the element under the point (banner above header above scrolled rows).

Short windows: the sidebar keeps a 52 px scroll region (`Sidebar.min_content_region`,
room for two 24 px row slots; the tests assert the region height and at least one
published element, not two elements at every offset, and a 34 px Needs-you or
Activity card can fill it). If the footer would leave less, the error footer collapses
first, then the update banner; the status line is the floor. A collapsed part is
not painted, published, or clickable. The window's minimum height is the smallest
client height at which the status line, Activity strip, and open Workspace panel
still leave that region (`min_client_height`, enforced through
`WM_GETMINMAXINFO`; width keeps the system minimum). This is layout and message
evidence from App and native provider tests, not a screen-reader or Dev Box run.

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
`Ctrl+Alt+PageUp` / `Ctrl+Alt+PageDown` and Previous/Next Workspace cycle only
identified running workspaces. Each invocation rereads the manager's discovery
order: Default first, named directories by creation time (ordinal name ties,
unreadable dates last), then the current workspace outside the home listing.
Closed workspaces are skipped; the current validated instance anchors the cycle,
and both directions wrap. With no other identified window, cycling does nothing
except report that status. A separate restore-only API has no launch operation:
the selected identity is checked again, and the final native lookup used for
activation must contain an identified target and no unidentified-window flag.
That same target goes directly to the existing activation implementation without
another lookup discarding the flag. Disappearance or restore failure reports an
error, never a cold launch. Normal workspace selection, New, and manager Open keep
their existing restore-or-launch behavior and the ordinary menu's list order.

Discovery and restore retain the existing SID/session, GraphCode window-class,
and published workspace-metadata checks; these are not executable-path
attestation. Any unidentified-window flag refuses the cycle, even alongside an
identified target, and owner/lookup errors are not treated as closed windows.
Menu enablement follows the macOS known-count policy, not a periodically polled
running count: it includes the implicit current workspace when the sole listed
row is elsewhere. Runtime filtering is authoritative; opening the menu does not
start global window polling.

Both paging shortcuts are registered in the actual native accelerator descriptor.
The app also intercepts their exact Ctrl+Alt modifiers before dispatching normal
or system key-down messages to an owned terminal child, using the same cycle
action as the menu. Active/enabled/visible ownership gates remain in effect;
modal dialogs keep their own disabled-owner message loops. The top-level fallback
does not reinterpret Alt paging as Ctrl-only terminal-tab switching. Existing
Ctrl+PageUp/Down, header F6, and system F10 behavior retain their separate routes.
This is source wiring plus pure descriptor/classifier/message-data evidence,
not a physical-keyboard, native accelerator, or live terminal-window proof.

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
real-daemon walkthrough. Running-only cycling adds injected data-only coverage
for creation order, wrapping, identity refusals at the final observed lookup,
close-before-restore, fresh owned paths, allocation failure, and never-launch
routing. This does not claim an atomic snapshot of all windows. These tests run through the
existing App/MainWindow test roots without requiring native window activity.
The lifecycle parity row remains Partial: real cycling keyboard/window proof
and recoverable deletion with daemon/session teardown are still missing.

Manage Workspaces now opens a native list with owned workspace names, full paths,
saved-summary states, and current/default/open-elsewhere or uncertain-window
refusals. Its discovery order follows macOS: Default first, named directories by
creation time (ordinal name ties, unreadable dates last), then the current
workspace outside the home directory if its lexical identity is not already
listed. Running-only cycling reuses this order; the ordinary menu's list order
is unchanged. Manage remains available with zero or one old-menu rows,
so New and the current-outside-home row stay reachable. Open and targeted Rename
capture an owned identity, not a row index; New uses the existing guarded
creation flow. The manager releases
its modal lease and destroys its controls before any follow-up name dialog.
Identity, default/current, directory, window ownership, and applicable canonical
and legacy reservation checks run again before acting. Done is the default;
Done/Escape cancels any pending handoff without changing the current workspace.

The manager's Delete button is disabled with an explicit explanation: recoverable
deletion and owned daemon/session teardown are still separate work. This does not
change the existing Workspace menu's permanent-delete behavior.

Saved summaries are a conservative read-only projection of the existing
`projects\*.json` graph headers and top-level node arrays, not a new graph decoder.
Like macOS `Workspace.contents`, they count top-level nodes, not descendants.
They are labelled **saved top-level loops**, not live totals; this window's live
total is unavailable because the shell has no reliable workspace-wide inventory.
Documented `*.mailroom.json` arrays are sidecars; a graph object with that suffix
is still counted. A missing projects directory is unavailable, while a readable
empty projects directory has a genuine saved zero count. Invalid consumed fields,
unreadable files, duplicate exact project paths, or exceeded limits make the whole
summary unavailable rather than presenting partial counts. Unconsumed graph
fields are not validated, and a saved summary is not evidence of graph validity.

One App-owned, joinable worker reads only fixed local-drive paths, refusing
network/device paths and reparse points at each opened component and entry.
It does not start a daemon, connect to a backend, inspect terminal layouts, or
activate windows. Limits are 256 directory entries, 1 MiB/file, 8 MiB/workspace,
32 MiB/dialog, 8 MiB JSON parser scratch, and nesting depth 128; exceeding depth
is an availability limit, not a claim that a graph is corrupt. Results are cached
for the dialog. Polling observes completion before copying the final snapshot,
then joins the worker before stopping updates; a completion racing an earlier
copy is collected on the next poll, not discarded. Done/Escape cancels without
waiting for the reader; App retains the job, and reopening cannot start another
until it has been joined. A requested
Open/New/Rename waits in the responsive modal until cancellation finishes and
the reader is joined, then revalidates the captured target. Shutdown cancels and
joins before App/allocator teardown. A stalled local disk can delay shutdown:
synchronous reads have no finite cancellation-time guarantee.

Manager coverage is pure owned-data/fixture testing, controlled memory-only
joined-worker tests, and a Windows ReleaseSafe build, without launching the app
or exercising native controls, actual user windows, UIA, or real workspaces.
The parity row remains **Partial**: shown-dialog accessibility/keyboard/layout
and multi-instance behavior, complete live totals, real running-cycle keyboard/window proof, and
recoverable deletion still need their own evidence or implementation.

## Worktree discovery processes

`WorktreeStatus` runs local Git with explicit `-C` paths and a child-only copy of
the environment. `RemoteWorktrees` runs the same read-only discovery over SSH or
`gh codespace ssh`, and uses remote `du -sk` for streamed size updates. Windows
environment names are matched case-insensitively.

Reclaim re-inspects every selected local row immediately before mutation and verifies
that the worktree still belongs to the captured repository, its branch and tip have
not moved, and the branch is neither the current nor a protected/default branch.
Locked owned rows remain selectable and are unlocked before removal. After removing a
worktree, GraphCode appends `<ISO-8601 timestamp> <branch> <tip> <worktree path>` to
`~/.graphcode/removed-branches.log`, flushes that record, and only then deletes the
branch with Git's expected-old-tip compare-and-swap semantics. If logging or branch
deletion fails, the branch is preserved and the row reports partial success; other
selected rows continue and retain individual success/failure receipts.
The App never runs inspection or reclaim on the Win32 message thread: it captures
the project, bindings, selection, and policy into owned requests, shows
reading, size-pending, empty, partial-error, and completed states in pixels and UIA,
publishes rows before recursive sizing, and applies each size result on the UI
thread. A newer inspection supersedes an older result, one size failure retains the
other rows, and shutdown joins both owned workers before model teardown. This keeps
menus, keyboard routing, hit testing, and UIA responsive while Git and directory
sizing run; it does not turn a slow provider operation into a successful one.
The following inherited overrides are removed:

| Variables | Reason |
|---|---|
| `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_IMPLICIT_WORK_TREE` | Repository/worktree location |
| `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES` | Index and object storage routing |
| `GIT_SHALLOW_FILE`, `GIT_GRAFT_FILE`, `GIT_REPLACE_REF_BASE`, `GIT_NO_REPLACE_OBJECTS`, `GIT_NAMESPACE` | Alternate history/ref interpretation |
| `GIT_PREFIX`, `GIT_INTERNAL_SUPER_PREFIX`, `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM` | Inherited repository-discovery context |
| `GIT_CONFIG`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS` | Config target and invocation-local injected settings, which can override repository settings |

Invocation-local injected configuration is intentionally not preserved.
Numbered `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` entries are inert without
`GIT_CONFIG_COUNT`. Ordinary config locations (`GIT_CONFIG_GLOBAL`,
`GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`, HOME/profile/XDG paths), PATH,
`GIT_EXEC_PATH`, askpass, SSH and authentication settings remain inherited.
This is not a sandbox against trusted Git configuration or executables, and it
does not change reclaim safety, selection, or confirmation policy.

The helper starts no console window, ignores stdin, and uses Zig 0.15.2
`Child.collectOutput` to drain both pipes with a 1 MiB limit per stream.
Oversized output reports `StdoutStreamTooLong` or `StderrStreamTooLong`; nonzero
exit still reports `GitFailed`. Capture/allocation failures terminate and reap
the owned child; cleanup failures log both error names without command output
or environment values. Output transfers only after wait succeeds. Removal
callers free successful output and the complete inspection.
There is **no production wall-clock timeout or descendant-process-tree guarantee**.

`Tools\windows\Tests\WindowsShell.Tests.ps1` invokes the dedicated regression
script after the pure WorktreeStatus tests. To run only this no-UI suite:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\WorktreeGitProcess.Tests.ps1 `
  -Zig <path-to-zig-0.15.2.exe> -EvidenceDirectory <new-owned-directory>
```

The script creates its own target/outside-control repositories, isolates fixture
configuration before the first Git command, and gates each test process until
it belongs to a kill-on-close Windows job. Every case has a 60-second external
deadline; missing setup and native/test/cleanup failures fail the script.
Evidence directories must be new and are retained, including failed RED logs.
Explicit case selections must contain at least one of the exact, case-sensitive
17 supported names; invalid/empty selections fail during parameter binding
before setup. The suite also checks that raw Zig invalid selectors return
`UnknownFixtureScenario` before creating or running repository fixtures.
Real Git scope/index/object/config and selected-removal coverage is distinct
from synthetic stream/output-ownership cases. Allocation-failure coverage
checks allocations and process-handle balance. Standalone module tests remain
no-spawn; invoking the dedicated test executable without its harness fails.
These checks are not a GUI, live-provider, or full worktree-parity walkthrough.

## Graph decoder ownership

Graph snapshots own their project, node, edge, and optional string storage.
`GraphModel.decodeGraph` propagates allocation failures, including failures while
preparing attention, activity, restore-generation, selection, and legacy/nested
snapshots. It prepares owned replacements before its final fallible summary
update. On error, existing model data remains intact; list capacity may grow.
This guarantee covers the decoder, not all model operations or the sequence
bookkeeping performed by `updateFromFrame` before decoding. Nondecoder navigation
and attention APIs retain their best-effort interface. If attention rebuilding
fails after nondecoder project eviction, both owned attention lists are cleared
so removed projects cannot remain visible. Wire defaults and the
existing malformed-open-subgraph fallback to the top-level graph are unchanged.

From `graphcode-windows`, run `zig test src\GraphModel.zig --test-filter "decoder ownership"`
with Zig 0.15.2 for direct test-allocator, exhaustive allocation-fault, malformed
input, and temporary-JSON-lifetime coverage. Run `zig test src\GraphModel.zig`
for the existing semantic root as well. These are offline allocation simulations,
not evidence of true OS memory exhaustion or live UI behavior.

Graph decoding resolves immediate JSON object fields, not the first occurrence
of a key anywhere in a frame. The v2 `event.graphChanged` (or legacy root
`graphChanged`) supplies the graph; only that graph's `project`, `nodes`, and
`edges` are used. Nested graphs retain their own arrays and inherit the parent
project when opened. Metadata, nested children, and key-like string contents
cannot supply parent fields. The nonfallible subgraph display count remains
allocation-free and counts only immediate node objects.

Node goal, usage, presence, and worktree fields use their explicit containing
objects. Canonical goal metric/poll/stall fields take precedence over the
existing direct-node legacy fields; a missing field in a goal object can use
that legacy fallback, but an explicit null/wrong-type goal or canonical field
cannot. Goal summary/predicate come only from `goal`. A present `usage` owns its
token fields even when empty, null, or the wrong type; only absent usage uses
direct-node token fields. Within a worktree binding, a string `path` precedes
`worktreePath`, with the existing alias fallback for absent/nonstring `path`.
Scalar presence strings and same-object token-count aliases remain supported.
Scoped graph/node lookups retain first-field precedence. Their
missing/null/wrong-type fields keep existing defaults, including the existing
unsigned numeric-prefix conversion. Once the owning graph's edge array is
selected, the independent typed edge decoder retains its stricter contract:
duplicate fields and invalid edge elements are errors, `fireCount` is a signed
integer, and cycle guards, transforms, and spawn configuration remain owned.

Temporary field indexes/decoded keys and mixed-delimiter stacks use the caller's
allocator and propagate allocation errors. Values borrow input only during
decoding; all retained model strings, including raw `subGraph`, are owned.
Object/array punctuation, key escapes, and primitive tokens are checked using
scoped traversal and standard JSON lexing. Structural validation advances one
cursor through nested containers, rather than scanning descendants again at each
level; work is linear in input size, with stack storage proportional to depth.
Bounded depth/width tests count actual span-scan byte visits and validator
iterations, not elapsed time, and exhaustively exercise stack allocation failure.
Stored `subGraph` contents remain
opaque until opened (apart from balanced string/container boundaries), preserving
the malformed-child-string fallback. Other string payloads retain the existing
`Wire.decodeJsonString` validation when consumed; ignored strings are not newly
schema-validated. Malformed decoded graph structure reports `MalformedGraph` or
`MalformedSubgraph`, and invalid decoded string escapes report
`MalformedJsonString`. The typed edge decoder preserves `SyntaxError`,
`MalformedEdge`, and `DuplicateField`; the nested fallback explicitly propagates
`OutOfMemory` before handling malformed data. Unrelated recursive Wire envelope
queries are unchanged.

Run `zig test src\GraphModel.zig --test-filter "field scope"` for key-order,
root/child identity, escaped-key/string, defaults/precedence, malformed-input,
temporary-lifetime, and exhaustive allocation-failure regressions. This is pure
decoder evidence, not live graph rendering or a parity-status promotion.

## Windows contributor quick start

This is the shortest supported route from a Windows checkout to a running
development shell. It uses the repository-pinned toolchains and providers,
starts the production daemon before the shell, and isolates app state under
this checkout by default.

### Prerequisites

- Windows 11 x64 with Visual Studio Build Tools 2022 (MSVC) and a Windows SDK.
- PowerShell 7 (`pwsh`), Git, and `winget`.
- A short checkout path when possible, such as `C:\src\GraphCode`.

The bootstrap installs Swift 6.3.3 through `winget` when it is absent. The
current `Swift.Toolchain` 6.3.3 package declares Python 3.10 and the x64 Visual
C++ redistributable as dependencies. It also downloads Zig 0.15.2 for the
shell, Zig 0.16.0 for zmx, and the exact provider commits in
`provider-pins.json`; do not substitute tools found on `PATH`.

From the repository root:

```powershell
pwsh -NoProfile -File Tools\windows\bootstrap.ps1 `
  -ToolRoot .\.graphcode-tools `
  -ProviderRoot .\.graphcode-tools\providers
. .\.graphcode-tools\environment.ps1
```

Load `environment.ps1` again in each new shell. The explicit roots keep every
download and provider checkout owned by this worktree and are the locations
`Tools\windows\dev.ps1` expects.

Reference timings from one Windows x64 worktree on 2026-10-01 are not
performance guarantees: the initial bootstrap took **34 minutes 24 seconds**
(mostly provider network transfer), initial provider/Swift/shell artifact
population took **8 minutes 9 seconds**, an unchanged cached build took
**10.7 seconds**, launch took **1.2 seconds**, and stop took **0.7 seconds**.

### Build, run, and stop

```powershell
pwsh -NoProfile -File Tools\windows\dev.ps1 -Build
pwsh -NoProfile -File Tools\windows\dev.ps1 -Run

# After process-level checks or development, stop only this checkout's run.
pwsh -NoProfile -File Tools\windows\dev.ps1 -Stop
```

`-Build` publishes the runnable layout under `.build\windows\dev\bin`:

- `graphcoded.exe` - production daemon
- `graphcode.exe` - CLI
- `graphcode-windows.exe` - Windows shell
- `zmx.exe` - pinned terminal-session provider

The script prints `LAYOUT_ROOT=...`, `DAEMON_ARTIFACT=...`,
`CLI_ARTIFACT=...`, `SHELL_ARTIFACT=...`, and `ZMX_ARTIFACT=...`. A
successful build ends with `BUILD_STATUS=BUILT`. A successful launch prints
`LAUNCH_STATUS=LAUNCHED runId=...`, followed by `SUPPORT_ROOT`,
`LOCALAPPDATA_ROOT`, and `TEMP_ROOT`. The run record is
`.build\windows\dev\run.json`.

By default, every launch creates fresh roots under
`.build\windows\dev\runs\<run-id>`. The daemon starts first and must create its
rendezvous state before the shell starts. Because the support root is fresh,
the shell follows the real first-run onboarding path; the script does not
pre-seed or dismiss it. It redirects `GRAPHCODE_SUPPORT_DIR`, `LOCALAPPDATA`,
`TEMP`, and `TMP`, but deliberately does **not** redirect `USERPROFILE`.

Use `-RealProfile` only as an explicit opt-in:

```powershell
pwsh -NoProfile -File Tools\windows\dev.ps1 -Run -RealProfile
```

That mode inherits normal profile roots and can read or modify real GraphCode
state. The default sandbox is the safe contributor choice.

`-Stop` reads `run.json`, revalidates each captured executable path and process
creation identity, discovers only run-prefixed zmx processes from this
checkout's layout, and then removes the run record. It refuses an identity
mismatch rather than terminating a reused PID or an unrelated process. Running
`-Stop` when no checkout-owned run is recorded is safe.

### Current remedies

- **Deep paths / `MAX_PATH`:** move the checkout to a short root such as
  `C:\src\GraphCode`. Bootstrap enables provider-local `core.longpaths=true`,
  but Swift, Zig, Windows tools, and test fixtures can still exceed legacy path
  limits.
- **Slow Zig downloads:** bootstrap suppresses progress rendering, so a
  `ziglang.org` download can appear idle. Let the transfer finish; if it fails,
  rerun the same bootstrap command. Checksums remain mandatory, and using a
  different Zig from `PATH` is not a supported workaround.
- **Missing or invalid pinned environment:** rerun bootstrap and reload
  `.graphcode-tools\environment.ps1`; do not hand-build an environment.
- **An existing `run.json` blocks build or launch:** run
  `pwsh -NoProfile -File Tools\windows\dev.ps1 -Stop`. If stop reports an
  identity mismatch, preserve the message and inspect the record instead of
  deleting it or killing by process name.
- **Local packaging from an untagged commit:** release-provenance packaging
  requires a release tag. Use the documented `package.ps1 -Command Build
  -Local` route in [Windows release packaging](../Tools/windows/PACKAGING.md)
  for an unmistakably local, non-publishable package.

### Evidence limits

This entrypoint is for iteration, not qualification. It always prints
`VALIDATION_STATUS=NOT_RUN`; a green build/run/stop cycle proves runnable
artifacts, process readiness, daemon-before-shell ordering, checkout-owned
profile roots, and guarded cleanup only. It does not prove onboarding
interaction, native keyboard input, terminal rendering, accessibility,
authenticated agent behavior, persistence, packaging, installation, or
macOS parity.

Run the relevant repository gates separately:

```powershell
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task windows-shell -SkipTrayLive
pwsh -NoProfile -File Tools\windows\validate.ps1 -Task packaging
```

Keep claims aligned with the
[Windows UI parity ledger](../investigation/ui-parity-matrix.md) and the
[preview-readiness plan](../investigation/windows-preview-release-plan.md).

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

Standalone `Tools\windows\Tests\WindowsShell.Tests.ps1` requires the pinned
Winghostty static host library, not only its headers. After loading the bootstrap
environment, build that prerequisite before running the native contracts:

```powershell
Push-Location $env:GRAPHCODE_WINGHOSTTY_ROOT
try { & $env:GRAPHCODE_ZIG0152 build -Demit-win32-host=true }
finally { Pop-Location }
```

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
