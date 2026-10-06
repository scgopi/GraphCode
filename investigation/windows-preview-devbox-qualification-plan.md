# Windows preview — Microsoft Dev Box qualification plan

## Read this first

This is a standalone execution plan for a new agent on a new Microsoft Dev Box.

Do not assume access to:

- the original Copilot session;
- any local worktree or build cache;
- the development machine's environment variables;
- untransferred logs or artifacts;
- credentials stored in chat.

The only trusted inputs are the verified handoff bundle described below and
explicit Approval A values inside it.

This plan never builds a new candidate and never publishes a release.

## Product and repository context

GraphCode is a coding-agent orchestration application. The Windows port is in:

- `graphcode-windows/` — Zig shell;
- `Tools/windows/` — bootstrap, build, packaging, and validation;
- `GraphcodeKit/` — shared Swift;
- `graphcoded/` — production daemon;
- `graphcode-cli/` — CLI.

Repository: `scgopi/GraphCode`

The candidate package contains the Windows shell, production daemon/CLI,
runtime DLLs, providers, setup script, metadata, and manifests.

The preview is invitation-only and unsigned. Full parity closure is not the
goal. Runtime observations never promote a parity row unless its complete
visible contract passes.

## Expected handoff bundle

The operator provides:

```text
GraphCode-DevBox-Handoff\
  candidate\
    graphcode-windows-x86_64.zip
    graphcode-windows-x86_64.zip.sha256
    candidate-manifest.json
  source\
    GraphCode-source-custody.zip
    GraphCode-source-custody.zip.sha256
  plans\
    windows-preview-devbox-qualification-plan.md
  approvals\
    approval-a.json
  hashes.sha256
  README-FIRST.md
```

Stop immediately if a required file is absent.

## Non-negotiable evidence rules

1. Do not rebuild or substitute the candidate.
2. Every observation is `Passed`, `Failed`, or `NotExecuted`.
3. `Passed` requires a positive executed count and retained expected/actual
   evidence. Empty results are never PASS.
4. Do not substitute a stub daemon, copied provider, hidden HWND, posted
   message, fixture model, cached UIA tree, or stale pixels.
5. Credentials are provisioned outside chat and evidence.
6. Use only local synthetic/disposable fixtures. Never mutate corporate
   repositories, remote resources, account-wide settings, or non-fixture
   backend sessions.
7. Native evidence requires one exclusive interactive session.
8. Stop if candidate identity, foreground ownership, process identity, remote
   geometry, monitor, DPI, keyboard layout, or clipboard owner changes
   unexpectedly.
9. Do not upload or publish anything.
10. Full dumps remain encrypted and local-only unless separately authorized.

## Phase D0 — verify handoff before doing anything else

1. Copy the handoff bundle to:

   ```text
   C:\GraphCode-Handoff
   ```

2. Verify `hashes.sha256`.
3. Verify product and source-custody ZIP SHA-256 against the candidate manifest.
4. Verify every Approval A field is filled.
5. Verify the plan file hash matches the manifest.
6. Record Dev Box:

   - definition/image;
   - Windows edition/build;
   - remote client/version;
   - graphics adapter;
   - CPU/RAM/disk;
   - organization policy identifiers relevant to install/dumps;
   - session resolution and scaling.

Any mismatch is FAIL. Do not continue.

## Phase D1 — settle the corporate Dev Box profile

The Dev Box may use the operator's normal corporate identity.

1. Let device policy, profile provisioning, endpoint protection, and required
   corporate sign-in settle.
2. Close unrelated applications.
3. Ensure only one interactive session is attached.
4. Create:

   ```text
   C:\GraphCode-Evidence\<version>-<source12>-<zip12>\
     manifest.json
     hashes.sha256
     logs\
     identities\
     uia\
     media\
     readbacks\
     dumps-local-only\
     cleanup\
   ```

5. Create local synthetic fixture roots:

   ```text
   C:\GraphCode-Fixtures\Core
   C:\GraphCode-Fixtures\Destructive
   C:\GraphCode-Fixtures\Outside-Sentinel
   ```

6. Hash the outside sentinel and named protected profile paths.
7. Record exact allowed GraphCode mutations:

   - install root;
   - GraphCode support directory;
   - current-user scheduled task;
   - Start menu shortcut;
   - allowed user PATH entry.

Do not snapshot or retain SSO tokens, cookies, credential-manager contents,
corporate resource names, unrelated processes, or unrelated environment data.

## Phase D2 — restore exact source for evidence scripts

Git may be installed on the Dev Box.

```powershell
Expand-Archive `
  -LiteralPath C:\GraphCode-Handoff\source\GraphCode-source-custody.zip `
  -DestinationPath C:\GraphCode-Evidence\source-custody
powershell.exe -NoProfile `
  -File C:\GraphCode-Evidence\source-custody\Restore-GraphCodeSource.ps1 `
  -Command Verify -ArtifactRoot C:\GraphCode-Evidence\source-custody
powershell.exe -NoProfile `
  -File C:\GraphCode-Evidence\source-custody\Restore-GraphCodeSource.ps1 `
  -Command Restore -ArtifactRoot C:\GraphCode-Evidence\source-custody `
  -Destination C:\GraphCode-Evidence\source
Set-Location C:\GraphCode-Evidence\source
git rev-parse HEAD
git rev-parse "<local-tag>^{commit}"
git status --short
```

Require HEAD and the peeled tag to equal the candidate manifest SHA. Require a
clean checkout and the restore command's positive materialized-LFS count. Do not
set `GIT_LFS_SKIP_SMUDGE` as a workaround and do not accept pointer-only or
dirty source.

The source checkout is used only for evidence scripts and inspection. The
installed product must execute from the package installation.

## Phase D3 — verify and install the exact candidate

1. Copy the ZIP to the evidence root without modifying it.
2. Verify its SHA-256 again.
3. Extract it into a fresh incoming directory.
4. Run the included setup verifier:

   ```powershell
   powershell.exe -NoProfile -File .\GraphCode\GraphCode-Setup.ps1 -Command Verify
   ```

5. Record one positive verification result and positive payload count.
6. Install:

   ```powershell
   powershell.exe -NoProfile -File .\GraphCode\GraphCode-Setup.ps1 -Command Install
   ```

7. Record:

   - installed file hashes;
   - setup output;
   - scheduled task identity;
   - daemon PID, creation time, executable path, and hash;
   - Start menu/PATH changes;
   - install and support roots.

Stop on hash mismatch, missing payload, multiple tasks/daemons, unexpected
signer state, foreign install root, or unexplained profile mutation.

## Phase D4 — process-scrubbed startup independence check

Git and developer tools may remain installed on the Dev Box. The proof is that
startup does not rely on them.

1. Build a process-only environment containing exactly these keys:

   - `SystemRoot`;
   - `windir`;
   - `USERPROFILE`;
   - `LOCALAPPDATA`;
   - `APPDATA`;
   - `TEMP`;
   - `TMP`;
   - `ProgramData`;
   - `HOMEDRIVE`;
   - `HOMEPATH`;
   - `PATH`.

   `PATH` may contain only Windows system paths, Windows PowerShell, and the
   installed GraphCode runtime directory. Do not add `USERNAME` or `USER`;
   GraphCode resolves the Windows account identity through the operating
   system rather than process environment text.

2. Remove from the candidate process environment:

   - Git path;
   - Swift/Zig/SDK paths;
   - repository checkout paths;
   - provider build roots;
   - toolchain-specific environment variables.

3. Start the installed scheduled daemon and normal installed app using that
   scrubbed environment.
4. Observe no Git/Swift/Zig/SDK child during:

   - daemon startup;
   - first app launch;
   - onboarding;
   - connected Welcome.

5. Record process tree, executable paths/hashes, and environment-key names
   only. Do not retain secret values.

PASS requires first-run onboarding to close, the main window and daemon to
remain alive, the CLI endpoint to respond, connected Welcome, no fatal startup
event, and no hidden developer dependency. A genuinely required variable must
fail with a bounded diagnostic naming the startup operation and variable; a raw
`EnvironmentVariableNotFound` diagnostic is a failure.

After this step, restore the one declared Git executable for Git-backed
project/worktree features and record its path, version, and hash.

## Phase D5 — onboarding and clean first run

Using native foreground mouse and keyboard:

1. Start from an empty GraphCode support directory.
2. Complete all onboarding pages.
3. Verify Back/Continue/Skip/Get Started and backend selection as applicable.
4. Reach a connected Welcome with production `graphcoded`.
5. Close and reopen.
6. Verify onboarding seen-state persists.
7. Export the required UIA tree and record positive named-control counts.

PASS can close #556 only if:

- ordinary installed route was used;
- production daemon connected;
- native keyboard/mouse worked;
- required UIA controls were reachable;
- no false disconnected state occurred;
- no unauthorized profile location changed.

## Phase D6 — production core and safe mutations

Use only:

- `C:\GraphCode-Fixtures\Core`
- `C:\GraphCode-Fixtures\Destructive`

### Core fixture

1. Open the fixture project.
2. Create exactly one intended loop; require zero edges initially.
3. Record loop ID/title/type/state from graph and sidebar.
4. Rename it.
5. Open Edit Details, cancel once, and prove persisted bytes unchanged.
6. Submit one intended edit.
7. Close/reopen the app and project.
8. Read saved graph state and verify stable ID and exact intended values.

### Destructive fixture

1. Hash target files and outside sentinel.
2. Exercise named cancellation; prove no mutation.
3. Exercise one approved confirmed delete/remove.
4. Verify only the captured target changed.
5. Verify outside sentinel and unrelated fixture remain unchanged.
6. Record Recycle Bin or recovery behavior only for the owned fixture.

Stop on ambiguous target, unintended mutation, data loss, silent failure, or
changed outside sentinel.

## Phase D7 — one real backend terminal

Use Approval A's backend/version/model/account. Credentials are entered through
the backend's normal flow outside chat and evidence.

1. Verify executable path/version/hash.
2. Create or use the intended fixture loop.
3. Run exactly two turns.
4. Use unique expected input/output markers.
5. Record backend conversation ID and zmx session name; they must be distinct.
6. Verify readable current pixels, expected markers, cursor/input, wrapping,
   resize, tab switching, stop, and reopen.
7. Verify stop affects only the intended loop, using the Stop contract below.
8. Stop immediately at two turns or the USD 5 ceiling.

Do not record credentials, tokens, private prompts, or unrelated output.

### Stop contract

Stop is the reversible verb. It does not promise to end the loop's session.
Before pressing Stop, record `zmx list` (names only) and create at least two
owned sentinel sessions: one unprefixed, and one decoy named
`graphcode-<another UUID>`. Then press **Stop loop** with native input.

Stop passes only if all of these hold:

- the intended loop's state becomes `stopped` and its Stop control disappears;
- no other loop changes state;
- the loop's memory log (`memory\<project>\<loop id>\LOG.txt` under the support
  directory) records exactly one new stop entry, which takes exactly one of
  the two paths below, and that path matches what you observe;
- every other zmx session, including both sentinels, keeps the same PID, and no
  sentinel receives input;
- the shell and the production daemon stay responsive.

The two daemon paths are:

| Memory-log entry | Expected observation |
| --- | --- |
| `its session was asked to stop looping` | `graphcode-<loop UUID>` is still listed with the same PID. Its terminal shows the daemon's `[graphcode] Stop requested from the graph…` request, which tells the agent to stay in the session. The agent process may stay alive. |
| `its session could not be reached, so it was killed` | `graphcode-<loop UUID>` is absent from `zmx list` within 15 seconds, and its agent process has exited. |

Classify `TerminalSessionOwnership` and stop if:

- the log claims a kill but the session survives (the beta9 Dev Box result);
- the log claims a request was delivered but the request appears in no session,
  or in a different one;
- a different session dies;
- the loop does not reach `stopped`.

Do not require a reachable session to end, and do not use `zmx kill` or Restart
to make Stop pass.

## Phase D8 — native reachability and input

Run separate fixed-geometry profiles for 100% and 150%.

For each profile:

1. Record resolution, Windows scaling, app/client bounds, remote client/version,
   and graphics adapter.
2. Do not resize or reconnect during the profile.
3. Reach every supported core menu, form control, validation/error state, graph
   action, and terminal action with native foreground input.
4. Verify UIA names, roles, actions, focus, and live result for the supported
   route.
5. Verify PR #597 canvas/sidebar guidance is visible and usable.
6. Verify declared dead-key/IME committed text in a form and terminal.
7. Verify exact safe single-line paste, unsafe paste handling, and clipboard
   restoration.
8. Verify no focus trap, clipped essential control, incorrect hit bounds,
   illegible required text, or silent input/output loss.

Dev Box evidence does not claim physical touchscreen, Precision Touchpad,
local-monitor handoff, HDR, or unobserved multi-monitor behavior.

## Phase D9 — #560 decision

Read Approval A.

### If Worktrees is deferred/guarded

1. Verify the supported preview cannot invoke the known starving path.
2. Verify the unavailable reason is visible and accurate.
3. Keep #560 and the Worktree notice parity row open.

### If dump-backed Worktrees is approved

1. Confirm corporate policy allows a full process dump on this Dev Box.
2. Close unrelated apps and clear the clipboard.
3. Use only synthetic local fixtures.
4. Launch GraphCode with a minimized sanitized environment.
5. At the first post-click timeout, capture:

   - full `graphcode-windows.exe` dump;
   - app PID/creation time/path/hash;
   - child process inventory and local-only raw command lines.

6. Determine whether the UI thread is in the synchronous worktree inspection
   path or provider locking.
7. Do not edit shared product code on the Dev Box.
8. Keep the dump encrypted, non-synced, current-user ACL, local-only, maximum
   seven days. Do not put it in the return bundle.
9. Return only a sanitized stack/child-state conclusion unless raw transfer was
   separately approved.

If policy forbids the dump, mark it `NotExecuted` and use the deferred/guarded
preview option.

## Phase D10 — lifecycle, uninstall, and reinstall

Run after all prior evidence is finalized.

1. Hash installed files and fixture user data.
2. Uninstall without `-RemoveUserData`:

   ```powershell
   powershell.exe -NoProfile -File <installed>\GraphCode-Setup.ps1 -Command Uninstall
   ```

3. Verify install/task/shortcut/PATH removal.
4. Verify fixture user data remains byte-for-byte.
5. Reinstall the exact candidate ZIP.
6. Verify exact installed hashes, one daemon task, endpoint reachability,
   fixture project/session continuity, and ordinary reopen.

If Approval A includes a distinct predecessor:

1. install predecessor;
2. verify locked upgrade refusal preserves it;
3. upgrade to candidate;
4. run one controlled failure/recovery case;
5. verify rollback and recovery reporting.

Otherwise record upgrade/rollback `NotExecuted`. Do not substitute a
same-version reinstall.

## Phase D11 — cleanup and return bundle

1. Stop only captured GraphCode processes.
2. Remove installed package/task/shortcut/PATH according to the approved final
   state.
3. Preserve or remove fixture data exactly as approved.
4. Verify outside sentinel and protected paths.
5. Finalize logs and evidence.
6. Generate `hashes.sha256`.
7. Create:

   ```text
   GraphCode-DevBox-Return\
     result-summary.md
     manifest.json
     hashes.sha256
     logs\
     identities\
     uia\
     media\
     readbacks\
     cleanup\
   ```

8. Exclude credentials, tokens, cookies, private corporate names, unrelated
   process/environment data, raw dumps, and raw command lines.
9. Verify the return bundle once before transfer.
10. Transfer through an approved corporate mechanism.

`result-summary.md` must state:

- candidate SHA/tag/ZIP hash;
- each step `Passed`, `Failed`, or `NotExecuted`;
- positive counts;
- gate implications;
- cleanup status;
- blockers and required follow-up;
- whether #556 can close;
- #560 decision/result;
- whether invitation is recommended.

## Dev Box go/no-go

Recommend tester invitation only if:

- candidate identity never drifted;
- exact package verification passed;
- install/start/onboarding/connected Welcome passed;
- core CRUD/reopen and safe mutation passed;
- exactly two backend turns passed within budget;
- required native/UIA/input profiles passed at 100% and 150%;
- lifecycle/uninstall-reinstall passed;
- no required gate step failed;
- every `NotExecuted` behavior is explicitly excluded from support;
- cleanup and evidence hashes passed.

The Dev Box agent does not publish. It returns evidence to the local plan.

## Dev Box completion checklist

- [ ] handoff hashes verified
- [ ] Approval A complete
- [ ] policy/profile settled
- [ ] evidence root and sentinels created
- [ ] exact source/tag verified from bundle
- [ ] package verified and installed
- [ ] scrubbed startup passed
- [ ] onboarding/connected Welcome passed
- [ ] production core passed
- [ ] safe mutations passed
- [ ] two-turn backend terminal passed
- [ ] 100% native/UIA/input profile passed
- [ ] 150% native/UIA/input profile passed
- [ ] #560 decision executed or NotExecuted honestly
- [ ] uninstall/reinstall lifecycle passed
- [ ] cleanup passed
- [ ] return bundle hashed and transferred
