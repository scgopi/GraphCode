# Windows UI parity ledger

This is a source-derived completion ledger, not a requirements sketch. A row is
`Validated` only when the Windows implementation exposes the same user-visible
information and actions as macOS and has runtime evidence. Platform-native chrome may
differ, but hiding a feature behind an undocumented shortcut or replacing a structured
screen with raw protocol fields is not parity.

Statuses:

- `Validated`: source mapping, automated coverage, and live walkthrough agree.
- `Partial`: some behavior exists, but visible controls, state, or interaction is absent
  or materially different.
- `Missing`: no equivalent reachable Windows surface.
- `Blocked`: requires a deliberate platform decision or unavailable dependency.
- `Divergent`: Windows exposes a different product concept in the place where the macOS
  surface belongs; it must be separated or redesigned before parity.

## Application shell and navigation

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Main split view | Persistent sidebar; detail switches among welcome, global graph, project canvas, Quick Chats canvas, and loop workspace | Explicit project, overview, Quick Chats, and workspace destinations now exist. Live stub walkthrough verified project → overview → full workspace → Show in Graph with the sidebar retained; destination-specific toolbar and accessibility semantics remain incomplete | Partial |
| Window toolbar | Needs-you chip, worktree notice, jump field, contextual loop-panel toggle | The native header now exposes clickable needs-you and reclaimable-worktree chips, a visible Ctrl+P jump affordance, and a contextual loop-panel toggle alongside status. Focused hit-testing and a real populated fixture validate the controls; native focus/UIA semantics and macOS visual treatment remain incomplete | Partial |
| Jump palette | Search field, ranked cross-project results, type/state/project context, mouse and keyboard selection | Ctrl+P and Ctrl+J open a native modal palette with live exact-ID, exact-title, title-prefix, and substring ranking across projects. Results visibly include project, loop type, and state; Up/Down, Return, Escape, and mouse double-click are supported. The deterministic UIA gate verifies a visible search field, contextual cross-project results, and keyboard navigation changing the selected loop. | Validated |
| File/Loop/Terminal menus | Discoverable project, worktree, navigation, workspace, update, settings, and help commands with state-aware enablement | Startup menu replacement and UTF-16 corruption are fixed and the five readable runtime groups were probed; project-management and contextual parity remains incomplete | Partial |
| Help menu | GraphCode Basics and normal About entry | The live Help menu exposes GraphCode Basics, which reopens onboarding, and About GraphCode, which opens a native versioned product dialog. The populated UIA gate verifies the dialog identity, version text, and close behavior | Validated |
| Update command | Check for Updates, disabled while checking/installing | Reachable from Help, immediately reports checking state, and is disabled while a check is active. In-app installation remains incomplete | Partial |
| Tray lifecycle | Restore and exit without foreground daemon window | `TrayLive.Tests.ps1` exercises the physical icon, Open, close-to-hide, single-instance restore, Explorer recovery, popup contents, and visible Exit activation | Validated |
| Connection failure presentation | Explicit visible failure without replacing normal navigation | A persistent inline canvas banner now reports daemon unavailability while leaving sidebar and destination navigation intact; ingress errors take precedence when present. The live UIA gate forces the disconnected state and verifies the dedicated banner text and bounds | Validated |

## First-run and empty states

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Four-page onboarding | Visual terminology tour, Skip/Back/Continue/Get Started, backend selection, reopen, persisted seen state | Custom rounded Win32 onboarding; all pages exercised and persistence verified | Validated |
| No-project Welcome detail | Graph icon, pitch, explanatory copy, Open Folder action, inline error | Windows matches the centered Graph identity, pitch, explanatory copy, and single Open Folder action. Persistent project-ingress failures now also render as a bounded, wrapped inline canvas alert without replacing navigation; focused geometry coverage and the populated UIA gate verify the alert text and live bounds | Validated |
| Empty global graph | “Nothing running yet”, explanatory copy, Open Folder action, New Loop action | The dedicated overview empty state exposes both bounded Open Folder and New Loop actions; New Loop targets the daemon's `graphcode://global` project. The live UIA gate switches to an empty model, verifies both visible native controls, invokes New Loop, and observes the node form | Validated |
| Empty project canvas | Project-specific empty message and New Loop action | The dedicated “No loops yet” project state exposes its visible New Loop action. The live UIA gate installs an empty local project, invokes that exact command, and observes the project-scoped node form | Validated |
| Empty Quick Chats canvas | Explanation of Quick Chats and New Chat action | Live walkthrough verified the dedicated explanation and New Chat action with corrected non-overlapping layout | Validated |

## Sidebar

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Graph row | Pinned global graph row with graph glyph | The sidebar now keeps a dedicated Graph destination visible even with no open project, labels it with a graph identity glyph, and routes it through the existing global-overview hit target and UIA destination | Validated |
| Quick Chats group | Selectable header, hover New Chat, disclosure, child rows | The native header remains selectable, reveals a hover-only New Chat action and disclosure, and exposes stable selectable child rows with Rename/Delete context actions. Focused menu tests cover stable chat identity; the live UIA gate invokes New Chat, collapses and restores children, and verifies child runtime identity survives. | Validated |
| Local/remote sections | Group labels, independent collapse, folder/network glyphs | LOCAL and REMOTE retain local/folder and remote/network identity and now toggle independently as native section actions. Focused layout coverage validates mixed ordering, and the live UIA gate collapses LOCAL while proving the REMOTE row and its stable automation identity remain present before restoring LOCAL. | Validated |
| Project rows | Selection, folder type, hover New Loop, disclosure | Open project rows retain selection and local/remote glyphs, reveal hover-only New Loop and disclosure controls, and collapse/restore their own loop tree without changing row identity. The live UIA gate invokes the project-row New Loop action into the real native node form and exercises project collapse/expand through stable UIA actions. | Validated |
| Nested loop tree | Edge-derived hierarchy, persisted expansion, drag reorder of roots | Handoff edges derive a cycle-safe root/descendant tree; nested rows disclose and collapse by stable node ID, and expanded IDs persist atomically in the GraphCode support directory. Focused tests cover collapsed visibility, non-hierarchical message/spawn edges, and state round-trip; the live UIA gate expands a real nested fixture and verifies the child remains expanded after process restart. Root drag reorder is still absent: Windows has no persisted/sidebar-order command or safe reorder transaction, so this row remains incomplete. | Partial |
| Loop row presentation | Type stripe, title, elapsed time, state indicator | Rows now show a loop-type stripe, title, and compact state indicator using the same semantic colors as workspace chrome. Elapsed time remains absent | Partial |
| Project context menu | Move, worktrees, settings, Explorer, remote info, close, remove, delete loops/project | Recent and open sidebar project rows now expose Open, New Loop, Worktrees, Project Settings, Explorer or remote connection information, Close, Remove, and Delete All Loops actions. Move and filesystem Trash remain absent | Partial |
| Loop context menu | Open, composite actions, rename, stop, delete | Sidebar and canvas loop rows share stable-ID Open, Rename, Stop, and Delete actions. Composite cards expose Open Group, Pilot Once, and Arm Schedule; the drilled-in canvas addresses mutations through the parent composite. Final live menu and accessibility evidence remains incomplete | Partial |
| Recent projects | Reachable from Add Folder menu | Recent rows are shown directly under “Projects”, without Add Folder grouping or recent/open distinction | Partial |
| Add Folder menu | Open Folder, Clone, Add Remote, recents | The restored File menu visibly exposes Open Folder, Clone Repository, and Add Remote Repository with shortcuts; a recent-folder submenu remains absent | Partial |
| Sidebar update banner | Available version and click-to-install action | A persistent footer banner now shows the retained offered version and reopens the native update offer when clicked. A deterministic live fixture captured the banner and verified the click raises `GraphCode Update Available`; the offer still hands installation off to the verified release page | Partial |
| Sidebar error footer | Persistent, scoped project-ingress error | Folder, clone, remote, and daemon-open failures now persist in a dedicated red sidebar footer independently of transient status. Successful project ingress clears it, and a deterministic live fixture verifies it stacks below the update offer; long-message wrapping and dedicated UIA semantics remain incomplete | Partial |
| Needs-you section | Navigable list with reason/project and Stop action | Up to four entries now show title plus project context (or compact state fallback) with semantic attention coloring. Selection, explicit reason copy, and Stop context action remain incomplete | Partial |
| Activity strip | Optional bottom strip, summary, attention-only filter, horizontally scrolling actionable events | The optional bottom strip now shows a recent-event count and state-colored event cards with compact state detail. Filtering, timestamps, scrolling, and click navigation remain incomplete | Partial |

## Graph overview and project canvas

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Cross-project global graph | Every open folder as a lane on one canvas | Windows renders every loaded graph summary as a lane; the real executable was exercised against the protocol stub and multi-project identity/layout has automated coverage | Partial |
| Folder lanes/bands | Project caption, worktree chip, open/close and folder actions | Project-captioned bands and loop cards exist; worktree chips and lane actions remain absent | Partial |
| Notebook grid | Grid pans and zooms with canvas | GDI grid pans and zooms with the same transform used by project, overview, and Quick Chats content | Partial |
| Pan and anchored zoom | Pan, pointer-centered wheel/pinch zoom | Mouse pan and pointer-centered wheel zoom exist; no pinch/trackpad gesture evidence | Partial |
| Zoom controls | Zoom out, actual size, zoom in, fit with shortcuts/help | Visible bottom-right controls provide zoom out, percentage/actual size, zoom in, and fit. Ctrl+-, Ctrl+0, Ctrl+=, and Ctrl+9 are represented in the View menu, and the live UIA provider exposes invokable controls with bounds. The real Quick Chats canvas was exercised from 100% to 110%; hover help and trackpad pinch evidence remain absent | Partial |
| New Loop canvas button | Visible top-right add action | A live-validated top-right New Loop button is now present on non-empty project canvases and remains centered in the empty state | Validated |
| Composite breadcrumb | Current group, project back action, loop count | Open Group swaps the project canvas to the authoritative nested graph, renders its cards and edges through the normal interactive canvas, and exposes a clickable `Project > Group` breadcrumb with loop count that restores and reselects the parent. Nested graph selection survives daemon refreshes, and the populated live UIA gate invokes Open Group, verifies both nested cards, and invokes the bounded Back breadcrumb to restore the parent canvas | Validated |
| Canvas attention rail | Count/oldest context and Review action | Painted count banner with shortcut text; no click action or oldest age | Partial |
| Node positioning | Persisted positions and direct card movement where supported | Project cards can be dragged directly, with movement transformed correctly at non-default zoom, shared geometry/hit testing updated during the drag, and capture-loss cancellation restoring the prior position. Offsets are keyed to stable node identity, remapped across daemon reorder, and atomically persisted under the configured GraphCode support directory. Focused reorder/reload regressions and a real physical drag capture validate the complete flow | Validated |
| Connector handles | Hover handles and drag-to-connect | Always-hit-testable right edge supports drag; no visible hover handles or parent-create affordance | Partial |
| Loop card identity | Loop-type stripe, title, state pill, entry/cycle role | Stripe is state-colored rather than type-colored; title/state text and START label only | Partial |
| Loop card live detail | Goal/prompt/check line, progress, metric change, elapsed/backend/model/worktree metadata | Cards now prioritize goal, trigger, or check detail, retain current activity, and show model/worktree or metric metadata in compact secondary lines. Focused tests and a real goal-loop fixture validate the richer card; measured progress/change, elapsed time, backend identity, and token usage remain incomplete | Partial |
| Loop card attention | Reason-aware amber presentation and primary action | NEEDS YOU label exists; no actionable button or reason-specific presentation | Partial |
| Unwired card recovery | Explanation, Wire it up, Mark as entry | Cards with no inbound or outbound edge now show an explicit UNWIRED warning and recovery explanation. Their native context menu exposes Wire it up, which enters the existing drag-to-connect flow, and Mark as entry, which changes the card to START for the session. Focused role/action tests plus live menu and post-action captures validate the flow | Validated |
| Worktree reclaim offer | Reclaim and Keep actions on resolved card | Safe resolved cards with a matching landed, clean, pushed worktree now expose separate Reclaim and Keep targets. Reclaim revalidates safety, names the worktree in a fail-closed confirmation, and uses the verified removal path; Keep suppresses the offer for the session. Focused geometry/safety tests and a real resolved-card fixture validate the offer; dedicated UIA descendants remain incomplete | Partial |
| Composite card actions | Open Group, Pilot Once, Arm Schedule | Canvas and sidebar composite menus expose all three actions. Open Group is live-validated; nested creates, edits, deletes, edge changes, pilot, and arm commands use the daemon's authoritative `subGraphCommand` envelope; and Arm Schedule is disabled unless the decoded pilot state is exactly `piloted` | Validated |
| Edge presentation | Kind style, fired state, cycle label | Project edges now use kind-specific solid/dotted/dashed styling and color, show condition plus fired count in a visible label, and retain selected-edge emphasis. Focused tests and a real-executable fired-message fixture verify the presentation; full cycle-guard wording and collision-free label layout for dense graphs remain incomplete | Partial |
| Edge creation sheet | Kind/condition/transform/cycle controls with conditional validation | A guided native form now provides title-plus-ID endpoint selectors for generic creation, locked identities for drag/edit flows, kind/condition/transform controls, conditional transform/spawn fields, cycle guards, inline validation, keyboard traversal, and scrolling. Focused tests and a real-executable capture validate the form; teaching polish and macOS visual treatment remain different | Partial |
| Node creation sheet | Loop-type teaching tiles, conditional fields, backend/model/branch pickers, recap, validation reason | A guided native form now hides internal metadata, provides loop-type/backend/model choices, type-specific fields, explanatory copy, descriptive checkbox accessibility, inline validation, keyboard traversal, and scrolling while preserving hidden wire values. Focused tests and a real-executable capture validate the form; teaching tiles, branch picker, recap, and macOS visual treatment remain incomplete | Partial |
| Node update/rename | Dedicated rename prompt and safe typed updates | Rename now uses a dedicated single-title prompt, trims input, rejects empty titles, re-resolves stable node identity after the modal, and sends the authoritative rename command. A purpose-built typed update editor is still absent | Partial |
| Delete confirmations | Named object, consequences, safe default | Loop deletion names the loop and explains graph-connection removal. Edge deletion now names both endpoint loops and the connection kind, explains that the loops remain, re-resolves the stable edge after confirmation, and defaults to cancellation | Validated |
| Canvas context menu | Folder actions on background; complete node/edge actions | Background offers Create Edge only; node menu adds non-macOS Message/Memo and omits composite/open-group actions | Partial |

## Quick Chats

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Quick Chats canvas | Band, cards, pan/zoom, add button, empty state | The real executable was exercised with two deterministic chats. The band, transformed cards, top-right New Chat action, bottom-right zoom controls, and 100% → 110% zoom transition were captured live. Context actions are wired, and the populated live UIA gate validates named, bounded, invokable Quick Chat cards | Partial |
| Quick Chat cards | Title, chat identity, optional backend badge, open/rename/delete menu | A populated live fixture verified title/default-chat identity/optional backend rendering and direct opening (`openQuickChat` was observed by the protocol stub). Cards now expose Open Chat, Rename, and Delete Chat context actions | Validated |
| Create chat | Visible New Chat controls | Empty and populated Quick Chats canvases now expose the New Chat action in the macOS placements; empty-state invocation is live-validated | Partial |
| Rename chat | Single title prompt from row/card | Uses a dedicated single-title modal from the card/keyboard action, trims input, and rejects empty titles | Validated |
| Delete chat | Named confirmation explaining session/scrollback deletion | Uses a named warning that explains terminal-session and scrollback removal, defaults to cancellation, and only sends deletion after confirmation | Validated |
| Chat workspace | Opens a persistent terminal workspace | Session opens in terminal panel | Partial |

## Loop terminal workspace

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Workspace detail screen | Selected loop replaces canvas detail while sidebar remains | Selecting a sidebar or overview loop now replaces the canvas detail with the full terminal workspace while retaining the sidebar; live stub walkthrough verified the transition and Show in Graph return path | Partial |
| Folder toolbar identity | Project name and local/remote identity | The workspace header now replaces the generic product title with the selected project name and a Local folder/Remote identity; live fixture capture verifies the native rendering | Partial |
| Loop bar | Type stripe, title/state pill, live goal, pass trend, elapsed/usage, Stop, Show in graph | A native 46px workspace band now shows loop-type stripe, title, state, current activity, Stop for unresolved loops, and Show in graph. It reserves terminal geometry, remains visible when terminal initialization fails, and has focused hit-testing coverage. Pass trend, elapsed/usage, and dedicated UIA elements remain incomplete | Partial |
| Tab pills | Named tabs, selection, state indicator, shortcuts, per-tab close | The native tab strip distinguishes agent, shell, and split tabs, paints selection, and supports menu/keyboard tab navigation. Per-tab state indicators, shortcut hints, and close affordances remain incomplete | Partial |
| Split controls | Visible Split Right, Split Down, New Tab buttons | The terminal tab bar now renders distinct New Tab, Split R, and Split D controls wired to the same persistent workspace actions as the menu/shortcuts; geometry and routing have focused regression coverage | Partial |
| Pane headers | agent/shell identity, backend/shell detail, focused state | Product-owned pane headers now distinguish agent and shell panes, label the zmx session detail, and draw an explicit focused-pane accent. Backend-specific detail and final side-by-side live evidence remain incomplete | Partial |
| Mounted background tabs | Switching preserves live terminal surfaces | Covered by workspace implementation tests | Partial |
| Right loop panel | Minimap, upstream/downstream, fired conditions, metric sparkline, branch/start/usage footer | The full workspace now reserves a native right rail with a selected-loop map, upstream/downstream cards, fired-edge coloring, edge conditions, branch/worktree identity, metric/goal detail, and model tier. Metric sparkline, start time, token usage, collapse control, and dedicated UIA children remain incomplete | Partial |
| Show in Graph | Visible loop-bar and menu action | The restored Loop menu and native loop bar both expose Show in Graph; the live workspace walkthrough verified return to the selected graph card, and focused loop-bar hit testing covers the visible action | Partial |

## Repository ingress

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Open Folder | Native picker from Welcome and Add Folder menu | Welcome and File menu commands use the Windows folder-only File Open dialog with filesystem/path validation. The live UIA gate invokes the empty-state action, verifies the titled native picker, and cancels it safely | Validated |
| Clone Repository sheet | Repository, location picker, derived folder, branch, depth, progress, inline failure, cancel | A purpose-built native dialog now provides HTTPS repository URL, destination browser, derived repository-folder hint, optional branch/depth, inline validation space, Clone/Cancel defaults, and standard keyboard traversal. Clone progress still appears in the application status rather than inside the sheet | Partial |
| Add Remote Repository sheet | Server/user/port/path, explanation, validation progress, inline selectable error | A purpose-built native SSH dialog now provides host, user, default port, absolute path, explanatory copy, inline validation space, Connect/Cancel defaults, and standard keyboard traversal. Connection validation remains blocking after submission | Partial |
| Remote Connection info | Read-only selectable connection sheet | Remote project context menus expose a dedicated read-only connection-information dialog with the encoded remote project identity and management guidance. The live UIA gate opens the native sheet, verifies both pieces of content, and closes it | Validated |

## Settings and worktrees

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Product Settings window | Backend, three permission pickers, model picker/auto toggle, activity, briefing, beta with explanatory copy | `WindowsProductSettings.zig` exposes native backend/model/Claude/Copilot/Codex selectors, routing/activity/briefing/beta controls, macOS-equivalent consequence copy, and Save/Cancel. Focused tests cover settings preservation and selector copy; `GRAPHCODE_UIA_GATE` mutation 15 opens the real window against an isolated settings file, verifies every required visible control/explanation, proves control-targeted Return saves while preserving unknown fields, and proves Escape cancels byte-for-byte | Validated |
| Infrastructure diagnostics | If retained, separate advanced surface | Daemon pipe/support-directory overrides are now explicitly labeled “Advanced Connection Settings...” while the normal Settings command opens product settings | Validated |
| Project Settings sheet | Resolve policy radio rows, safety explanation, size/count thresholds, immediate save | A purpose-built native Project Settings sheet now presents Remove/Ask/Keep radio rows with consequences, the safe-tier explanation, positive GB/count notice thresholds, and Done/Cancel keyboard semantics. The expanded policy format remains backward-compatible with the two legacy booleans, saves directly on Done without a separate shortcut, and is covered by policy round-trip tests plus a real-executable capture; per-keystroke immediate persistence remains different | Partial |
| Worktree sweep sheet | Safe/look/in-use grouping, size summaries, default selections, reveal, inline destructive confirmation, recovery note | A dedicated native modal now opens from Worktrees after real inspection, labels Safe / Look Before Removing / In Use rows, preselects only fully safe rows, disables blocked rows, states the safety/reflog contract, and executes a revalidated safe batch removal. Presentation is capped at 20 rows and size totals, inline reveal, and dirty forced-removal confirmation remain incomplete | Partial |
| Worktree notice chip | Threshold-driven titlebar and lane notice | A clickable titlebar chip now reports total or reclaimable worktrees and opens the scoped inspection flow. The real populated fixture validates the titlebar notice; configured size/count thresholds and per-lane notice chips remain incomplete | Partial |

## Updates and dialogs

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| Available update alert | Install, Release Notes, Later | A successful update check now retains the offered version and authoritative release URL, presents a native available-update alert, and can open the verified GitHub release page for notes/download. Direct in-app Install and separately labeled Later remain incomplete | Partial |
| Install progress | In-window progress indicator | Blocked on a publishable Windows installer asset and integrity/signing metadata. Every current upstream release contains only a macOS DMG (verified through the GitHub releases API on 2026-08-17), so an in-app Windows download cannot yet select or authenticate an installable artifact without inventing an unsafe source | Blocked |
| Relaunch prompt | Relaunch Now/Later and session continuity explanation | Blocked with installation because there is no published Windows artifact to stage or relaunch into. The native tray lifecycle and zmx-backed sessions already preserve daemon/terminal continuity, but the updater cannot truthfully offer Relaunch Now until a signed Windows package exists | Blocked |
| Install failure | Download in Browser/Cancel with reason | The Windows flow deliberately hands off to the verified browser download and reports browser-launch failure, but it does not yet attempt an in-app install first | Partial |
| Loop rename | Title field, Return submits, explanatory text | The dedicated single-title modal explains where the title appears, prepopulates the current value, trims and validates submission, and re-resolves the stable loop ID after the modal. The populated UIA gate edits the native field and verifies Return submits and closes the dialog | Validated |
| Loop delete | Named loop and full consequence message | Names the loop, explains graph-connection removal, and defaults to cancellation | Validated |
| Chat rename/delete | Dedicated prompts | Dedicated single-title rename modal and named fail-closed deletion warning are wired from card actions and shortcuts | Validated |
| Project delete loops | Dedicated confirmation | Sidebar project menus expose Delete All Loops through one fail-closed implementation with graph and filesystem consequence copy, safe cancellation default, and the dedicated daemon command. The live UIA gate verifies the native confirmation and cancellation path | Validated |
| Project remove/trash | Distinct reversible remove and filesystem Trash choices | Remove from GraphCode is now distinct, confirmed, and explicitly preserves files. A separate filesystem Trash action remains absent | Partial |

## Accessibility, input, and visual behavior

| macOS surface | Required visible behavior | Windows evidence | Status |
|---|---|---|---|
| UI Automation tree | Names, roles, selection, invoke/toggle, focus, live status for every visible surface | The synchronized live C++ provider exposes stable project rows, loop rows, project/overview/Quick Chat cards, worktree rows, destinations, canvas primary action, zoom controls, policy actions, focus, selection-change events, and status. The live gate uses explicitly in-process deterministic fixtures to validate populated RawView/ControlView navigation, real bounds, observable Quick Chat/workspace invocation effects, tagged-command isolation, identity-preserving reorder/removal, events, concurrency, and teardown. Daemon-to-model UIA integration, embedded terminal text providers, and several remaining dialogs still need end-to-end evidence | Partial |
| Keyboard discovery | Every shortcut represented by a menu item or visible hint where practical | Restored File, Loop, Terminal, View, and Help menus expose the primary project, graph, terminal, workspace, settings, update, and zoom commands with shortcut labels. Some context-only actions and canvas gestures still lack visible hints | Partial |
| IME/dead keys/layouts | Native composition in forms and terminal | Winghostty gate covers terminal IME; generic EDIT controls cover forms | Partial |
| Clipboard/selection | Terminal copy/paste and mouse selection | Winghostty terminal gates cover core behavior | Partial |
| Per-monitor DPI | Layout and controls scale correctly across monitors | No complete live multi-DPI walkthrough recorded | Partial |
| Dark visual language | Dark canvas/cards/sheets and legible state hierarchy | Main canvas, onboarding, product settings, and workspace chrome use the dark native language; several legacy graph/repository forms still use default Win32 controls | Partial |

## Audit conclusion

The Windows branch has substantial protocol, lifecycle, persistence, terminal, graph
mutation, tray, and packaging behavior, but it does **not** currently have complete UI
or screen parity. The previous parity statement conflated backend reachability with
user-visible parity. The largest corrective work is:

1. Restore and complete the application menu and navigation state model.
2. Implement the sidebar, global graph, Quick Chats canvas, project canvas chrome, and
   loop workspace as distinct application-owned surfaces.
3. Replace raw protocol forms with structured node, edge, settings, repository, and
   worktree screens.
4. Implement the missing update, project-management, rename/delete, empty, and
   connection-info states.
5. Expand UI Automation and live walkthrough coverage to every row above before any
   complete-parity claim.
