# Windows parity lane kickoff (canonical)

Every Windows parity worker reads this file. Read it from `origin/main`, in full, before
anything else.

## Two workers per issue: plan first, then implement

Each issue gets two workers, in order (operator decision, 2026-10-14):

1. **A planning worker** investigates the issue fully and writes the implementation plan.
   It doesn't change product code. Model: `gpt-6.1-sol`, high, long_context.
2. **The coordinator reviews the plan**, approves or corrects its file scope, and records the
   approval on the issue.
3. **An implementation worker** then executes the approved plan.
   - It doesn't redo the investigation.
   - When the plan turns out wrong, it says so: it sends the coordinator a lease-scope question,
     with the evidence. It doesn't improvise a different design.

### If you are the planning worker

Produce the plan from evidence, not memory. Read-only on the repository; you may build, and
you may run focused hidden-window tests, to confirm current behaviour. Don't use the desktop.

1. **Read** the issue, its comments (including earlier attempts' findings), the ledger rows,
   the macOS captures and the macOS source.
2. **For every acceptance box**, write down:
   - the exact macOS behaviour, with `file:line`;
   - the current Windows behaviour, with `file:line`;
   - the gap and its root cause. Name the function and the reason; "looks wrong" is not a cause.
3. **Choose the slice** for the first PR: the primary defect first, small enough to review in
   one pass. List the boxes it closes and the boxes it leaves.
4. **Write the implementation steps**, each with:
   - the file and function to change;
   - the change itself;
   - the test that proves it. Name the test, its root file, its assertion, and what it shows
     on `main`, which is the expected RED.
5. **List the file scope** the implementation needs. Mark everything outside the lane's lease,
   so the coordinator can approve it up front.
6. **List the risks:**
   - shared files and other lanes' open PRs;
   - edits to the gate or harness;
   - DPI or theme interactions;
   - known environment traps (see "Environment" below).
7. **Rate the complexity:** `standard` or `highly complex`, with the reason. Highly complex means a new shared
   framework or mechanism used by many surfaces, or architecture spanning several lanes' files. The
   rating picks the implementer: `gpt-6-luna` for standard, `gpt-6.1-sol` for highly complex.
8. **List the evidence plan:**
   - the exact surfaces and states to capture;
   - the fixture data needed;
   - the macOS capture to pair each one with.
9. **Publish the plan** as one issue comment titled `Implementation plan (wave 2)`, using
   `gh issue comment`. Then message the coordinator `PLAN READY #<n>` with the comment URL.
   Don't start implementing.

### If you are the implementation worker

Your issue block links the **approved** plan. Follow it step by step; the gate below still
applies to every step. Record in the PR any deviation from the plan, with the reason.

The coordinator's kickoff message adds only an issue block:
- the issue number;
- the lane letter and session id (for example `c4`);
- the file lease;
- the implementer and reviewer models;
- any decisions already made.

Everything else is here, so lanes don't depend on hand-copied instructions.
This file was introduced after wave 1 (2026-10-14), where copied kickoffs drifted.
That drift caused validation roots that were too long, wrong `Refs` lines and
wrong reviewer models.

Read also:
- `AGENTS.md`;
- `investigation/windows-parity-orchestration-plan.md`, for the per-PR gate and the escalation rule;
- `investigation/ui-parity-matrix.md`, the ledger;
- the issue: `gh issue view <n> -R scgopi/GraphCode --comments`, with `$env:GH_TOKEN = gh auth token --user coneilen`.

## Ground truth

The shipping macOS app is the reference. Match what macOS shows: information, actions,
layout, hierarchy, density, components, typography, spacing, colour and wording. Only
platform chrome may differ: the title bar, window buttons, menu-bar location and native
file pickers. Read the macOS **source** first (`graphcode/Sources/...`) and cite `file:line`;
captures confirm it. Don't add Windows-only extras. Don't remove a Windows action unless
the macOS path to the same result exists on Windows; if it doesn't, keep the action and
record it as a deliberate extra.

References on this machine:
- **macOS captures:** `%USERPROFILE%\Downloads\GraphCode-macOS-Reference-RunA\GraphCode-macOS-Reference-RunA\`.
  Use the `@1x-srgb.png` files and `README.md`.
- **Windows beta26 "before" captures:** `C:\GraphCode-DevBox-Return\media\`.
- **Side-by-side review:** `C:\gc-logs\visual-parity-review.md`.
- **macOS source audit:** `C:\gc-logs\parity-extras-audit.md`.
- **Privacy:** never upload or quote `734/*.zip` contents or `721-needs-you-chip-clicked`.

## Scope

- **One issue, one PR, one coherent slice.** The first PR fixes the issue's primary
  defect. Leave remaining acceptance boxes unticked and list them. Small PRs merge;
  large ones loop through review.
- **Edit only your lane's files.** For anything else, send the coordinator the exact file,
  function and reason, and wait for approval.
- **`App.zig` is shared.** Keep edits narrow.

## Environment: do exactly this

Replace `<id>` with your lane id, for example `c4`.

| What | Where |
| --- | --- |
| Scratch, logs, caches | `C:\gcs\<id>\` |
| Tools | `C:\gct\<id>\` |
| Providers | `C:\gcp\<id>\` |
| Validation root | `C:\gc<id>`: a real folder (not a junction), **7 characters at most** in total, because the UIA live-gate preflight has an 81-character path budget |

1. **Seed** Zig from `C:\gc-cache\zig\` into `C:\gct\<id>\`. Clone `winghostty` and `zmx` from
   `C:\gc-cache\git\*.git` into `C:\gcp\<id>\`. Check out the pins in
   `graphcode-windows/provider-pins.json`, and set `origin` to GitHub.
2. **Bootstrap:** `pwsh -NoProfile -File Tools\windows\bootstrap.ps1 -ToolRoot C:\gct\<id> -ProviderRoot C:\gcp\<id>`,
   then dot-source the `environment.ps1` it writes.
3. **Use pinned tools only:** `$env:GRAPHCODE_ZIG0152` and `$env:GRAPHCODE_SWIFT633`, never PATH.
   - For Zig, pass `--cache-dir` and `--global-cache-dir` under `C:\gcs\<id>`.
   - Set `TEMP` and `TMP` process-only.
   - Pester 5.7.1 is at `C:\v5modules`; prepend it to `PSModulePath` for that process only.
4. **Profiles and fixtures:**
   - Use a process-scoped scratch profile. A stale delete-pending
     `%LOCALAPPDATA%\GraphCode\zmx-validation-ee\logs\zmx.log` breaks the default-profile guard.
   - Seed `onboarding-seen` (and fixture data such as `quick-chats.json`) in the fixture's
     `GRAPHCODE_SUPPORT_DIR`, not under `LOCALAPPDATA`.
5. **Tests:**
   - A `--test-filter` that matches nothing exits 0. Quote the executed count, which must be positive.
   - Register new Zig test roots in `Tools/windows/Tests/WindowsShell.Tests.ps1`.
   - The native UIA provider suite (`Tools\windows\Tests\AccessibilityProvider.Native.Tests.ps1`)
     runs hidden and needs no desktop.
6. **GitHub, as `coneilen`, done by you:**
   - Set `$t = gh auth token --user coneilen` and `$env:GH_TOKEN = $t`.
   - Push with `git -c http.https://github.com/.extraheader="AUTHORIZATION: basic <base64 of x-access-token:$t>" push origin HEAD:<branch>`.
     If your PR's head lives in a fork, push to that fork.
   - Create your PR with `gh pr create --draft`, and edit its body with
     `gh pr edit <n> --body-file <file>`. The app's PR tools fail here, so don't use them.
   - Sign off every commit (`git commit -s`) and add the trailer
     `Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>`.
7. **Rebase hygiene:**
   - Rebase onto `origin/main` before every push.
   - After every rebase, read `git diff origin/main...HEAD`. Every hunk must be yours and
     intended. A conflict resolution that keeps your branch's copy of code another PR changed
     silently reverts that PR; wave 1 lost #789's geometry helpers this way.
8. **Shared gate script (`Tools/windows/uia-live-gate.ps1`):**
   - Edit it only with approval.
   - Assert on **named** elements; don't count broad sets. In wave 1 a canvas held loop cards,
     worktree cards and a banner.
   - Add positive and negative functional cases to `Tools/windows/Tests/ValidationRunner.Tests.ps1`,
     and run that file locally before pushing.

## Order of work (the per-PR gate)

Report each step's result, or NotExecuted with the reason.

1. **Boxes.** Copy from the approved plan which acceptance boxes this PR satisfies and which it leaves.
2. **RED.**
   - Write the failing test first, and keep its output.
   - Layout criteria are testable as geometry: rects lie inside the client area and above
     the footer, text bounds come from the container, and nothing overlaps.
   - A compile error is not RED.
3. **GREEN.** Run the focused tests and quote "All N tests passed", with N positive.
4. **Push a draft PR; exact-head CI is your regression gate.**
   - Don't run the full unit or integration part locally. They need the desktop, and CI runs
     them in parallel and authoritatively.
   - Run locally only what doesn't need the desktop: focused roots, `ValidationRunner.Tests.ps1`
     when scripts change, and `-Task visual-baseline` when tokens, palette, fonts or visual
     contracts change.
   - Every workflow on the exact head must be green. Cite run and job IDs, with counts, in
     the `REGRESSION:` line.
5. **Code review.**
   - Start a `rubber-duck` agent with the reviewer model named in your issue block. It must be
     from a different vendor than you.
   - Give it the diff (`git diff origin/main...HEAD`), the PR body and the log paths.
   - It must open each log it cites, confirm every RED, GREEN and REGRESSION line, check that
     no unrelated file changed, and check the rebase diff.
   - Fix or answer every finding.
6. **Screenshots, once, last.** Only after steps 4 and 5 pass on the final head:
   - send `LEASE REQUEST lane=<id> purpose=<surfaces> est=<15 at most>`, and wait for `LEASE GRANTED`;
   - capture before (main) and after (your head) at 100%, with `PrintWindow(hwnd, hdc, 2)` plus
     pixel verification. For owned popups that `PrintWindow` omits, use an ownership-checked
     screen capture (`WindowFromPoint` at the centre and on a 40 px grid);
   - don't call `ActivateWindow` from `uia-live-gate.ps1` (#797);
   - end the shell with File > Exit, stop by PID every process you own, including `zmx.exe`
     daemons, and verify that none remain;
   - send `LEASE RELEASED`.
7. **Image review.**
   - Upload privacy-safe fixture images with the github-pr-media skill.
   - Add a table: macOS capture, Windows before, Windows after, and the boxes each row shows.
   - The reviewer opens every image and confirms or rejects each box.
8. **Hand over.**
   - Fill in `.github/PULL_REQUEST_TEMPLATE.md`, add a **Not verified** list, and use `Refs #<n>`,
     never `Fixes`.
   - Check the body with `pwsh -NoProfile -File Tools\tdd\Test-TddEvidence.ps1 -BodyPath <file>`.
   - Run `gh pr ready <n>`, and wait for exact-head CI to be green again (DCO re-runs).
   - Message the coordinator with `PR READY #<n>`, the head SHA and a five-line evidence summary.
     Don't merge.

## Evidence honesty

- Say exactly what ran. Distinguish compile failures from behavioural ones, and injected
  input from physical input.
- A green build, unit test or UIA readback doesn't prove rendering, layout, input or parity.
- An empty result is not a pass.
- Keep failed attempts. Label harness failures separately from product failures.

## When it isn't working

- A failed iteration is one of:
  - a fix attempt after which the same test still fails;
  - a substantive review rejection;
  - an exact-head CI failure that you caused.
- After **5 failed iterations of the same kind**, stop and send `STUCK` with a handoff note:
  what you tried, the failing output, the reviewer findings, and what's worth keeping.
- Before that, keep iterating in this session. Waiting for the desktop, CI or review is not
  a failure.

## Communication

Message the coordinator only for:
- `PLAN READY` (planning worker);
- `LEASE REQUEST` and `LEASE RELEASED`;
- a lease-scope question (outside-lane files or a scope decision);
- `STUCK`;
- `PR READY`.

Don't send progress messages.
