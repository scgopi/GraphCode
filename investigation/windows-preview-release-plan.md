# GraphCode Windows preview-readiness plan

## Release verdict

**An invitation-only tester preview need not wait for full macOS parity, but a
useful agent-terminal alpha is not yet qualified.** The distribution machinery
exists now; building a ZIP is a different milestone from proving that someone
can install it, work with an actual agent, and safely resume their project.
The critical path is terminal correctness plus a packaged production-daemon
flight, followed by fixes for any reproduced core bugs. It is not closing all
36 Partial rows, and it is not just visual polish.

Assessment date: **2026-10-02**. The verified active local qualification
candidate is `0958109ee41c7215e3ccf91319e5a102d0fb7069`, the normal merge commit
for [#606](https://github.com/scgopi/GraphCode/pull/606), with parents
`fc6d40ccba4afc3b073c75b90ebeae60af15497c` and
`dfdb3cd1cac5359ee024cbe9d166ee191e4b110e`. Candidate source, the clean
detached build HEAD, `origin/main` at tag creation, and final audited main were
all exactly that SHA. Later movement of main, if any, does not change this
frozen identity. The local annotated tag/version `0.1.78-beta3` has tag object
`0c62e6f21f58c97ca4fbe3154f60887cac2bf52d` and peels exactly to the candidate
source. The tag is local and unpushed, no beta3 GitHub release exists, and
publication remains false.

The candidate retains the preview-only Worktrees safety guard from
[#604](https://github.com/scgopi/GraphCode/pull/604) and adds the LFS-aware
offline source-custody tooling from #606. Nod is experimental macOS
functionality and remained unsupported and outside this Windows preview: it
caused no wait, Nod testing, backend selection, or scope expansion. Merged
[#600](https://github.com/scgopi/GraphCode/pull/600) and
[#602](https://github.com/scgopi/GraphCode/pull/602) touched shared daemon/CLI
source after beta2 but received only ordinary build/package exercise here, not
a runtime claim. Open [#607](https://github.com/scgopi/GraphCode/pull/607) is
Nod/macOS app work and is excluded from the frozen candidate assessment.

The superseded beta1 and beta2 candidates remain immutable custody evidence,
not failed or deleted artifacts:

- beta1 source/tag
  `e62583b192a13dd92986f68fb7883f3358eb9d23` / `0.1.78-beta1`, ZIP SHA-256
  `9b5b78478e665ace0d7d297769e707dfb1face46e9ee973386b6216a70ab24e5`,
  and eight-entry handoff inventory SHA-256
  `46283ccd3c8d65ae38715bd557fac9be575281f37722e50f540e2e31fdef5acd`;
- beta2 source/tag
  `a406a28cb9aec856c934e7253d1a79c2cc6706ed` / `0.1.78-beta2`, ZIP SHA-256
  `fe8c7dff60e38b04f37b15b474e32c22b670c764e69ecd64db91280cae48ed25`,
  and eight-entry handoff inventory SHA-256
  `87cf8ab5720d114621d4aa113694e66b3ee5ca3c2192826223cc0168ef29f862`.

Both historical handoff inventories remain **8/8 valid**. All three beta tags
remain local and unpushed. Retain beta1 and beta2 as immutable historical
records; neither is the active transfer or qualification candidate.

At this approved candidate, a row-by-row review of the
[parity ledger](ui-parity-matrix.md) still contains exactly **98 surfaces:
62 Validated and 36 Partial**, with zero Missing, Blocked, or Divergent rows.
These source, contributor-flow, and evidence-pipeline fixes supply no installed
production-daemon/native-client or matched macOS observation that closes the
remaining residuals of a whole row. A newer candidate must be qualified at its
own exact source and package hashes.

The earlier `0765419a6d1e7ad401422903edf9102dbf0c9a17` assessment recorded
63 Validated and 35 Partial before a clean-clone setup and manual launch showed
that "Four-page onboarding" was not supported as `Validated`. That demotion is
still correct; no additional promotion or demotion is supported by the current
source and runtime evidence.

Accepted work since that historical floor includes the Edit Details truncation
fix [#565](https://github.com/scgopi/GraphCode/pull/565), terminal exit-tail
draining [#566](https://github.com/scgopi/GraphCode/pull/566), Tab/backtab
routing [#567](https://github.com/scgopi/GraphCode/pull/567), launch-free
packaged-core preparation [#568](https://github.com/scgopi/GraphCode/pull/568),
workspace recovery preservation
[#570](https://github.com/scgopi/GraphCode/pull/570), and the completed
implementation waves summarized below. These improve accepted source, focused
coverage, and qualification readiness; none independently supplies the missing
installed production-daemon, owned native-input, authenticated-backend,
destructive-lifecycle, cross-platform, or published-artifact evidence required
to promote a parity row.

The live release API was checked on this date:
[v0.1.77](https://github.com/scgopi/GraphCode/releases/tag/v0.1.77), published
2026-09-29, is the latest stable release and contains only
`graphcode-macos-arm64.dmg`, not a Windows ZIP. The beta3 candidate described below was built locally and remains unpublished
and uninstalled; no GitHub release or remote beta tag was created.

**Engineering distance:** if the proposed profile passes the production flight,
the remaining release work is bounded qualification and tester handoff, not a
parity programme. If an actual agent's output is unreadable, input is lost,
resize corrupts output, or persistence fails, real implementation work remains
before even this narrow preview. Those paths are not sufficiently witnessed to
give a credible calendar estimate. A successful package build or one harness
pass cannot settle that uncertainty.

### 2026-10-02 local qualification execution record

The local plan was executed through creation and independent verification of a
new LFS-aware offline custody artifact and versioned Dev Box handoff:

- **Phase L0 repository and concurrent-change audit — Passed.** Candidate
  source, clean detached HEAD, `origin/main` at tag creation, and final audited
  main were exactly `0958109ee41c7215e3ccf91319e5a102d0fb7069`, with parents
  `fc6d40ccba4afc3b073c75b90ebeae60af15497c` and
  `dfdb3cd1cac5359ee024cbe9d166ee191e4b110e`. The ledger parser found a
  positive **98** rows: **62 Validated** and **36 Partial**, with zero other
  statuses. No row was promoted. Open PRs were inventoried: #607 is excluded
  Nod/macOS work; #587 remains harness-only; #548 is open shared
  `RemoteGraphAccess`/`ZmxSessionLauncher` work not in the candidate; #274,
  #263, and #110 are open shared work not in the candidate; and #207 is
  unrelated macOS app-only work. None invalidates the frozen candidate.
- **Dependency, toolchain, provider, and executable provenance — Passed.**
  `Package.resolved` SHA-256 is
  `65c114f5f233c83529930782a0d422aa7a4b7c86160e66c1c955149c398288b8`;
  `provider-pins.json` SHA-256 is
  `c1c927e3995cb1b241894658e10698a4c6ca256066254f2a321a5aabb1b675f9`.
  Swift 6.3.3 hashes to
  `e1d0a0b20d95a92b22f4906e7ca331a7c8b89be86b2d9a2d215ac24f753e945a`;
  shell Zig 0.15.2 to
  `d408dd38eed3e5204af841bcebf70502a4dbbb8399a3a3262be55059370bc018`;
  and zmx Zig 0.16.0 to
  `086ce9d47ba42f33a514e1a6e04eb1d4a8fa1d75e0868e0213caad447c91e864`.
  Winghostty source
  `6286560d0aa3103e068b2b7afa81eac373d870c9` produced artifact SHA-256
  `b1aed4f7656ce2a68390c5a304d63b22622426bb9a2bb30d9603130f9bea5aac`;
  zmx source `785b3fd15dcafd1882b495c831a10f98c201b908` produced artifact SHA-256
  `71027ffac716c38082335cc7778734dac0811edf86580887d25633f31176baef`.
  Final executable SHA-256 values are shell
  `85113b1111530b0974853bd1ee2790fd103f37583dcf8b26af621a3d9bb4508b`,
  daemon
  `2d6d2b1a2082de63a7530a006aee3d4df3344d78f94bf07ddd6c0baaa864fab4`,
  CLI
  `29c029a2bce2e63838170381bda9da409208a113b2fbf5e59037660fc93245cd`,
  and zmx
  `71027ffac716c38082335cc7778734dac0811edf86580887d25633f31176baef`.
- **Approval A and Worktrees guard reconciliation — Passed for authorized
  scope.** Approval A remains the bounded Dev Box profile and does not authorize
  publication or a full dump. Package metadata records
  `previewFeatures.worktreesDeferred=true`; the binary
  `--worktrees-preview-state` output is exactly `deferred`; and the exact
  unavailable reason is `Worktrees are deferred for this preview`. The #604
  guard remains in force, #560 remains open, and #587 remains open and
  harness-only at `c249b9f8731741167bd11ca400691f26f0639903`. This is guarded
  and deferred, not fixed or parity-valid; no dump is authorized.
- **Candidate build and package verification — Passed.** The local annotated
  tag/version `0.1.78-beta3`, tag object
  `0c62e6f21f58c97ca4fbe3154f60887cac2bf52d`, peels exactly to the approved
  source and is not remote. The unpublished release build used neither
  `-Publish` nor `-AllowTagMismatch`. The unsigned **48,137,828-byte** candidate
  ZIP has SHA-256
  `9533116c025d4883ab7761f20f7e62499408209421f70264a3638e8347d2d0f9`;
  its **50-file** payload manifest has SHA-256
  `a2a7e1b8b95eb0dc77f7af8d9039eabee052443bc459be609f7dab90e140fb73`.
  Package kind is `release-candidate`; signing is
  `UNSIGNED (not code signed)`; publication is false. Exactly one repository
  package verification PASS and one extracted setup verification PASS were
  recorded.
- **LFS-aware offline source custody — Passed.**
  `GraphCode-source-custody.zip` is **61,131,130 bytes** with SHA-256
  `d20a64f78340baed6e417c7f94abae30e81c5abade20c8c53e2df75f3ef38407`.
  Its internal integrity-manifest SHA-256 is
  `e5b61571fdc7af34dc862bc9f5e32ad1d8d681727b8a5ba37a402d4d10a6056b`;
  internal Git bundle SHA-256 is
  `a25a2e637dd82f9f910cda0ab758a34e61c4a11200a8852f40bbd2c973aad676`;
  and included `Restore-GraphCodeSource.ps1` SHA-256 is
  `16bd8010ad5325e72a1166aea35d14497f0a17ebe65039f5a6e88fd9c665455b`.
  The custody uses Git LFS 3.7.1 and contains **43 objects / 43 tracked files /
  43 materialized files**, with zero pointers or hash mismatches;
  `git lfs fsck` passed and source-custody regressions passed **4/4**.
  Custody `Verify` and `Restore` both passed from a fresh extracted root with
  process-only network denial (`protocol.http.allow=never`,
  `protocol.https.allow=never`, `protocol.ssh.allow=never`,
  `protocol.git.allow=never`, loopback proxies, and terminal prompting
  disabled). Restore produced the exact detached candidate HEAD, the annotated
  tag peeled exactly, all 43 LFS files materialized locally, and
  `git status --short` was empty without a network fetch. The coordinator
  independently repeated Verify/Restore under the same denial and confirmed
  exact HEAD/tag, 43 files/43 objects, zero pointers/hash mismatches, and clean
  status. A corrected assertion was used for `git lfs ls-files --json`'s
  `{files:[...]}` shape; the successful corrected check is the custody result.
- **Versioned handoff and evidence inventory — Passed for custody, not
  transfer.** `GraphCode-DevBox-Handoff-0.1.78-beta3` has `hashes.sha256`
  SHA-256
  `ff553f9445c300cafecdced6d4f974a97088ea3b23e45bf9849bd16acbf47813`;
  all **8/8** payload entries verified: Approval A
  `12a60b720514043fdfe0608ec8db013f30e0b3adc2afb13f33d50a47b3235131`,
  candidate manifest
  `2eaa332f8df4d1e4b42b8fe2cc3f299fb42775f3767103e6ff85c106bdfda30b`,
  candidate ZIP
  `9533116c025d4883ab7761f20f7e62499408209421f70264a3638e8347d2d0f9`,
  ZIP sidecar
  `ca801e32051085b41668f0e5daee35ad701fd838fad845be5963c7081d1c13c4`,
  exact candidate Dev Box plan
  `f250629ad6812049ec1beb5409cfa05afd09433ea5cd1a3818b3fccd9c0cb8b6`,
  README-FIRST
  `7a40155238a69fb078ae4c7753e441796f46718a40b913fec8caff4ca05e7985`,
  source-custody ZIP
  `d20a64f78340baed6e417c7f94abae30e81c5abade20c8c53e2df75f3ef38407`,
  and custody sidecar
  `e1a6f5f067d54f5e41c4a264a16c39a5fb6bd093fdb4b67f23123d6fe227b7ff`.
  The evidence inventory verified **80/80** entries and has SHA-256
  `e9c7869a458f83288968dcf46ed954fe3ac6e8c2ff4e0ae0d7eae09da7cd4a48`.
  README-FIRST requires the included custody restore script and forbids GitHub
  or bare-bundle cloning. The privacy scan passed after retained provider
  remotes were sanitized to public URLs.
- **Phases L4-L6 — NotExecuted.** No Dev Box provisioning/profile identity,
  transfer, installation, native/UIA/backend/destructive/lifecycle flight,
  returned evidence bundle, other layout/IME evidence, screen-reader claim,
  upgrade/rollback, dump, tester packet, Approval B, pushed tag, release asset,
  or publication exists. Exact artifact is complete for beta3; the other six
  alpha gates remain open.

## Delivery lanes

Delivery priority and macOS equivalence are independent. The lanes below overlay
the ledger; they do not replace its definition of `Validated`.

| Lane | Meaning | Preview rule |
|---|---|---|
| **F - FUNCTIONAL BUGS / core qualification** | Broken or insufficiently qualified behavior needed for the advertised local workflow; includes input/output correctness, navigation, persistence, legibility, liveness and data safety | Fix reproduced product bugs and witness the core path before inviting testers. Missing evidence is not itself proof of a bug. |
| **O - OPTIONAL FUNCTIONALITY** | Real features outside the narrow preview, not cosmetic work: remote projects, richer topology, custody/promotion, worktree automation and self-update | Defer explicitly. If an exposed action could corrupt data or leave the app unusable, qualify or guard it; a disclaimer is not a safety mechanism. |
| **P - POLISH** | Appearance and discoverability improvements after controls and text are already usable: exact palette/materials, shape smoothing, ClearType refinement and extra hints | Continue after preview. Unreadable text, indistinguishable state or unreachable controls move to F. |
| **E - EVIDENCE GAPS** | The required observation has not run or is not reliable: production versus stub, native input versus helper, real pixels versus metadata, client hardware versus hosted server | Obtain the specific evidence. A core-path gap holds qualification; an optional/parity-only gap can remain open. Never convert NotExecuted or an empty result into PASS. |

Mixed rows are split within their notes. Clipboard, IME, DPI, accessibility and
font quality are not blanket polish categories. Existing code bugs blocking
either parity or ordinary app features are legitimate functional work.

### Evidence-state vocabulary and completed implementation waves

Use these states literally rather than treating "merged" as "release-ready":

| State | Meaning in this plan |
|---|---|
| **Source-fixed** | The diagnosed source or tooling defect is corrected in accepted main. This does not establish the installed behavior. |
| **Locally/CI qualified** | Focused tests, builds, harnesses, or required checks ran with positive execution. This is narrower than a packaged native-client flight. |
| **Preview-guarded** | A candidate-only build boundary makes an unsafe or unqualified route unavailable with an explicit reason and proves the guarded route is not invoked. This does not fix the underlying product path, qualify native responsiveness, or establish parity. |
| **Packaged/native-client qualified** | The exact built artifact ran on the declared owned Windows client with production components and the required real input/lifecycle evidence. None of the implementation-wave PRs reached this state. |
| **Published** | An authorized Windows artifact is attached to a release with recorded provenance/checksum. No Windows artifact is published. |
| **Deferred** | Work is deliberately outside the current critical path unless a concrete dependency appears. |
| **Evidence-only** | The work changes documentation, attribution, or observation reliability without itself changing the product behavior being assessed. |

| Delivery | Accepted mapping | State at audited main | Residual |
|---|---|---|---|
| Audit reconciliation | [#572](https://github.com/scgopi/GraphCode/pull/572) | **Evidence-only**, merged | Superseded by this post-wave audit; no product or parity-row change. |
| Post-wave documentation reconciliation | [#584](https://github.com/scgopi/GraphCode/pull/584) | **Evidence-only**, merged as `f1c5a57f3ba7e9f5743c34a87628806992e1089f` | Superseded by this second-wave audit; no product or parity-row change. |
| Onboarding support directory | [#573](https://github.com/scgopi/GraphCode/pull/573) closes [#554](https://github.com/scgopi/GraphCode/issues/554) | **Source-fixed; locally/CI qualified** by 3/3 focused and 10/10 full onboarding tests | Exact packaged first launch must prove the selected support directory changes while the real profile remains byte-for-byte unchanged. |
| Provider bootstrap paths | [#574](https://github.com/scgopi/GraphCode/pull/574) closes [#551](https://github.com/scgopi/GraphCode/issues/551) | **Source/tooling-fixed; locally/CI qualified** by 5/5 bootstrap tests and the provider-pin contract | Contributor setup improvement only; not packaged-client evidence. |
| Deep worktree fixtures | [#575](https://github.com/scgopi/GraphCode/pull/575) closes [#561](https://github.com/scgopi/GraphCode/issues/561) | **Source/tooling-fixed; locally qualified** by a deep-root positive run and 21 immutable regression case logs | Evidence-pipeline reliability only; no product parity effect. |
| Validation profile isolation | [#576](https://github.com/scgopi/GraphCode/pull/576) closes [#562](https://github.com/scgopi/GraphCode/issues/562) | **Source/tooling-fixed; locally/CI qualified** by 4/4 isolation tests and 380 validation-runner contracts | Qualification launches are isolated; this does not establish installed-product profile behavior. |
| Missing-secret daemon startup | [#577](https://github.com/scgopi/GraphCode/pull/577) closes [#555](https://github.com/scgopi/GraphCode/issues/555) | **Source-fixed; locally/CI qualified** by the focused startup contract and 177/177 DaemonClient tests | The ordinary packaged empty-support-directory first run remains part of the production-core flight. |
| Explicit local package mode | [#578](https://github.com/scgopi/GraphCode/pull/578) closes [#553](https://github.com/scgopi/GraphCode/issues/553) | **Source/tooling-fixed; packaging-gate qualified** with local provenance and publication refusal | No exact candidate was installed on a client or published; local mode is not release authorization. |
| First-run connection and UIA | App-native stack `#581` (not a GitHub PR): [#579](https://github.com/scgopi/GraphCode/pull/579) + [#580](https://github.com/scgopi/GraphCode/pull/580); [#556](https://github.com/scgopi/GraphCode/issues/556) remains open | **Source-fixed; locally/CI qualified**, including 734/734 App tests and a shown-window UIA/message probe | Evidence remains for packaged install through connected Welcome, desktop-level native keyboard input, and any claimed assistive-technology behavior. |
| Resilient pinned Zig downloads | [#586](https://github.com/scgopi/GraphCode/pull/586) closes [#559](https://github.com/scgopi/GraphCode/issues/559) | **Source/tooling-fixed; locally/CI qualified** by 12/12 bootstrap contracts, deterministic HTTP Range/stall fixtures, provider-pin checks, and privacy validation | Contributor bootstrap reliability only; real ziglang.org transport was not part of the PR evidence and no packaged-client gate changes. |
| Checkout-owned build/run/stop | App-native stack `#595`: [#585](https://github.com/scgopi/GraphCode/pull/585) closes [#557](https://github.com/scgopi/GraphCode/issues/557) | **Source/tooling-fixed; real pinned cycle qualified** at merge `7d5cf3be8a86b7562b527f90d854845a52f2ac82` | The final pinned build produced all four executables; run started production daemon before shell in owned roots; stop removed only captured checkout-owned processes and preserved the real profile. This is not installation, native UI, agent, persistence, accessibility, or packaging evidence. |
| Contributor quick-start documentation | App-native stack `#595`: [#594](https://github.com/scgopi/GraphCode/pull/594) closes [#552](https://github.com/scgopi/GraphCode/issues/552) | **Evidence-only**, merged atomically with #585 | Documents measured bootstrap/build/run/stop durations, status markers, and honest failure/evidence limits; it changes no product behavior or parity status. |
| Redirected `USERPROFILE` daemon startup | [#593](https://github.com/scgopi/GraphCode/pull/593) closes [#558](https://github.com/scgopi/GraphCode/issues/558) | **Source-fixed; locally/CI qualified** by the direct-process RED/GREEN, 101 XCTest plus 6 Swift Testing cases, release builds, clean smoke, and exact-head Windows/macOS CI | Removes the `0xC000001D` trap. It does not substitute for the installed production-core, onboarding, native-input, terminal, or persistence flight. |
| Worktrees preview guard | [#604](https://github.com/scgopi/GraphCode/pull/604), merged normally as `a406a28cb9aec856c934e7253d1a79c2cc6706ed`, part of open [#560](https://github.com/scgopi/GraphCode/issues/560) | **Source safety guard; locally/CI qualified for beta3 packaging** | Release-candidate packaging enables `-Dworktrees-deferred`, reports binary state `deferred`, exposes `Worktrees are deferred for this preview`, and records zero inspection attempts. Normal developer/local builds remain non-deferred. This is not the speculative async fix, native UIA responsiveness evidence, or parity validation. |
| Worktrees UIA timeout attribution | Open [#587](https://github.com/scgopi/GraphCode/pull/587) at head `c249b9f8731741167bd11ca400691f26f0639903`, part of open [#560](https://github.com/scgopi/GraphCode/issues/560) | **Evidence-only, harness-only boundary** | The PR still changes only `Tools/windows/Tests/WindowsShell.Tests.ps1` and `Tools/windows/uia-live-gate.ps1`. Bounded workers and cleanup attribute the synchronous product path; #604 defers that path in beta3 rather than fixing it. #560 and #587 remain open. Any future product fix still requires separately authorized dump-backed attribution. |

## Provider work deferred for preview prioritization

**2026-10-01 user-directed decision:** pause both provider workstreams rather
than continue expanding validation before attempting the installed GraphCode
core workflow. Preserve their open draft PRs, branches, working changes and
evidence; pausing is not completion, abandonment or a passing check. The
accepted GraphCode candidate floor is
`0958109ee41c7215e3ccf91319e5a102d0fb7069`; the beta3 candidate changes no
provider pin and
neither provider branch is included in the pinned providers. No parity status
changes here.

The pause is a priority reset, not a permanent prohibition or a requirement for
another explicit blanket reprioritization. The current audit still ranks both
provider branches behind ordinary startup/onboarding, one real backend's
readable terminal input/output, persisted reopen, and safe exit: no installed
GraphCode reproduction currently makes either provider branch a prerequisite.
Resume a bounded existing-owner chunk when client qualification or an actual
core reproduction demonstrates that dependency. The #11 owner also retains
unpushed working changes beyond its remote head; they are preserved, not
accepted source or final validation.

| Preserved work | Classification | Preview disposition and resume condition |
|---|---|---|
| [coneilen/winghostty#11](https://github.com/coneilen/winghostty/pull/11), remote head `f31f62cf08cdf656be223766cacacd8bf74fc7cf` | Validation infrastructure and harness bug fixes, not UI polish | Deferred. It unblocks the existing provider PR checks but is not intrinsically a tester-release prerequisite if credible owned Windows client qualification is available. Resume a bounded chunk when the core flight demonstrates a validation dependency or owned client qualification is unavailable. |
| [coneilen/winghostty#10](https://github.com/coneilen/winghostty/pull/10), remote head `c4d9a0dd8ebbc710485443321071577ccc34250f` | Conditional functional rendering risk, not polish | Deferred. Unsupported glyph-capacity behavior can blank a frame; block the preview if the advertised backend/display profile reproduces that failure. No installed GraphCode reproduction establishes that dependency yet. Resume when the chosen backend/display evidence reproduces or materially elevates that risk. |

The latest #11 source run demonstrated owned desktop/input capture, real Mesa
GL 4.6, the snapshot-to-handle disappearance branch, and zero remaining among
12 observed processes without secondary errors. It still failed the smoke
app's unchanged 10-second startup deadline; the last Debug-app log was font-grid
initialization before the expected ConPTY startup receipt. That log boundary
does not establish a deadlock or prove packaged GraphCode has the same failure.
A proposed hosted-only ReleaseSafe profile remains an unqualified, uncommitted change;
no deadline, assertion, required check or provider pin is waived.

**Next priority:** qualify ordinary production startup/onboarding, local-folder
opening, one named actual backend's readable terminal input/output, persisted
reopen and safe exit. Fix reproduced blockers in that path first. The remaining
open source/tooling and evidence items below can proceed in bounded independent
lanes; stub success, package builds and provider PR counts are not that flight.
Do not restart either paused workstream merely to clear its PR or reduce a
Partial-row count. Exposed unsafe behavior still requires qualification or a
real safety boundary before inviting testers.

## Proposed invitation-only scope

The first audience is technical **Windows x64** testers using their own or
disposable **local** projects and an already installed, authenticated agent CLI.
Propose Windows 11 x64 as the first client qualification profile; record the
actual OS build, display work area, scaling, graphics adapter, shell and agent
CLI version before advertising support. Qualify at least 100% and 150% scaling
and a declared minimum viewport. Other OS/display/input profiles are not
implicitly covered by server CI.

The useful minimum is: install without developer toolchains; open a local
folder; create, render and select loops; rename and edit basic fields; open a
readable, responsive terminal for **one named, actually tested backend** from
the supported Copilot/Claude/Codex choices; send input, observe output and stop
the intended loop; reopen the same saved project/session state. Do not advertise
all three backends merely because their selectors exist.

Manual verified-ZIP updates are acceptable. Full remote/SSH/Codespaces support,
multi-workspace automation, every graph topology, touchscreen/trackpad fidelity,
GPU-wide coverage, exact macOS visuals and self-update are not prerequisites
unless the chosen core workflow actually depends on them. Visible deferred
features must have honest capability/error behavior and safe boundaries.
This is an opt-in unsigned technical preview, not GA, a mature beta, or a claim
of accessibility or macOS parity.

This narrower milestone is distinct from the broader
[Windows implementation plan](windows-implementation-plan.md), whose release
gate includes remote and complete parity work. Its historical "complete"
acceptance statement is not current preview qualification. No broad release
policy or macOS policy is changed here.

## Current evidence and attribution limits

The ledger's validated empty states, local ingress, settings,
sidebar identities, project canvas controls, Quick Chat entry points, workspace
chrome, explicit connection errors and tray lifecycle support the proposed core
flow. They are useful existing evidence, not 62 certifications of an installed
production-agent experience; many observations use deterministic fixtures.
First-run onboarding now selects the configured support directory
([#573](https://github.com/scgopi/GraphCode/pull/573)), can schedule daemon
connection before entering the modal
([#579](https://github.com/scgopi/GraphCode/pull/579)), exposes a native UIA
fragment/action model ([#580](https://github.com/scgopi/GraphCode/pull/580)),
and can obtain a startup endpoint before the rendezvous secret exists
([#577](https://github.com/scgopi/GraphCode/pull/577)). Those are accepted
source and focused runtime improvements. [#556](https://github.com/scgopi/GraphCode/issues/556)
correctly remains open as **source-fixed, evidence-remaining** because no
ordinary packaged install has yet demonstrated first launch through connected
Welcome with owned desktop keyboard input.

- **Terminal:** the [Windows shell README](../graphcode-windows/README.md)
  describes a default legacy ASCII path/current pane-sized text grid and an opt-in
  `GRAPHCODE_EXPERIMENTAL_TERMINAL_VT` parser. The existing pinned VT library
  retains grapheme metadata, but the native host still uses narrow,
  single-codepoint 5x7 patterns. Unsupported opt-in host cells explicitly refuse
  publication and retain old pixels while accessible text may advance. That
  is an honest failure, not matching visible output. Current source derives the
  grid from pane bounds and measured cell metrics, preserves the old size across
  zero geometry, and queues `zmx resize` after topology changes. Unit/headless
  state evidence does not prove that a real backend accepted the resize or that
  visible pixels, wrapping, and PTY dimensions agree. Record those values in the
  production flight. Scrollback/wheel/selection, native glyph/caret rendering
  and terminal UIA conformance remain incomplete or unqualified. An ASCII-only
  promise is not sufficient for a Copilot/Claude/Codex TUI without witnessing
  its actual output and required interaction.
- **Worktrees:** beta3 release-candidate packaging sets
  `-Dworktrees-deferred`, package metadata records
  `previewFeatures.worktreesDeferred=true`, and the packaged binary reports
  `deferred` from `--worktrees-preview-state`. Production Worktrees routes
  return `Worktrees are deferred for this preview`, with zero guarded
  inspection attempts in the focused contracts. Normal developer/local builds
  retain their existing behavior. This removes the starving inspection route
  from the narrow beta3 preview; it does not implement the speculative async
  fix, close #560 or #587, qualify local native UIA responsiveness, or promote
  the Worktree notice chip ledger row.
- **Packaging:** [existing packaging machinery](../Tools/windows/PACKAGING.md)
  and reported CI lifecycle evidence cover real scheduled-task installation,
  locked upgrade, upgrade, rollback, uninstall and standalone Windows
  PowerShell 5.1/PowerShell 7 paths. Clean-environment tests are not a new
  physical clean-machine flight. These paths do not prove the installed UI,
  production `graphcoded` and an actual agent working together. Likewise, a
  successful packaging/release-gate step does not make a failed overall
  workflow green.
- **Refresh and input:** #549 is already included in the audited source, even
  while whole parity rows remain unchanged. The separate
  [rename/refresh qualification #547](https://github.com/scgopi/GraphCode/pull/547)
  is also merged and supplied exact same-run isolated stub/native navigation,
  four sequenced rename entries, and complete peer receipts. That is meaningful
  accepted native qualification, not production-daemon persistence, client
  hardware, glyph, or global accessibility proof. The later Edit Details
  capture fix in #565 preserves complete checked text instead of accepting a
  truncated prefix, but native long paste and production persistence remain
  separate. These accepted results narrow the residuals without qualifying the
  combined installed production path or richer global topology.
- **Provider:** [coneilen/winghostty#10](https://github.com/coneilen/winghostty/pull/10)
  originally had a queued interactive check with no available runner. The
  separate hosted Windows Server x64/Mesa route in
  [coneilen/winghostty#11](https://github.com/coneilen/winghostty/pull/11)
  subsequently produced real canary/GL and partial GUI evidence, but not complete
  nine-group/shader qualification. Both are now paused under the prioritization
  decision above, not completed or release-qualified. Provider availability
  and a standalone Debug-app startup failure do not prove every GraphCode
  terminal is unusable. Neither hosted Server CPU nor offscreen provider
  readback establishes Windows 11 client/hardware behavior. No GraphCode repin
  follows without a demonstrated dependency and separate validation/approval.
- **Modal and visual evidence:** bounded historical 96-DPI production drawing
  captures exist. There are zero accepted matched current Windows/macOS
  reference pairs, not zero Windows captures of any kind. The separate modal
  diagnostics exhausted four native trials without accepted input/cancel/
  teardown proof; a 75-case matrix with 70 NotExecuted entries is not a pass.
  Unclassified processes blocking diagnostic-artifact retirement do not
  establish an app leak. Those gaps remain distinct from reproduced app bugs
  and from accepted private geometry/capture-mock results.
- **Updater:** implementation and helper coverage exist despite older README
  wording saying installation is not implemented. The absent published Windows
  asset still prevents the real enabled-offer/download/install/relaunch flight.
  Publishing an asset alone will not prove upgrading the running EXE or
  preserving sessions through that upgrade.

The accepted provider inputs remain Winghostty
`6286560d0aa3103e068b2b7afa81eac373d870c9` and zmx
`785b3fd15dcafd1882b495c831a10f98c201b908`, with shell Zig 0.15.2,
zmx Zig 0.16.0 and Swift 6.3.3. This plan proposes no pin or toolchain changes.

## Partial-surface delivery map

All **36** current Partial surface names appear once below, in ledger order.
An alpha disposition is conditional on the gates, not a promotion to parity.
F means core usability/safety qualification; O means optional functionality;
P means genuinely cosmetic/discovery refinement; E identifies the missing
observation. Notes distinguish the parts of mixed rows.

| Partial ledger surface | Delivery lane | Alpha disposition | Remaining behavior and evidence |
|---|---|---|---|
| Main split view | F + P + E | Qualify core | Require stable local canvas/workspace/sidebar transitions, including welcome and narrow viewport, without focus theft. Existing live destination evidence supports this; populated production content and small-display usability still need a flight. Exact visual layout matching can follow. |
| Window toolbar | F + O + P + E | Qualify core; defer extras | Reachable Jump and workspace/detail navigation must not overlap or lose focus at the declared viewport/DPI. Populated Needs You and threshold-driven worktree content lack a complete comparison; defer unneeded worktree aggregation and exact chrome, not unreachable core actions. |
| File/Loop/Terminal menus | F + P + E | Qualify core | Witness core commands and state-aware enablement in graph and terminal contexts with actual keyboard/menu use. Live subsets and hidden HMENU tests are not the complete route. Extra shortcut hints and macOS ordering fidelity can wait after commands work. |
| Workspace lifecycle | F + O + E | Qualify safety; defer multi-instance features | Default/local reopen must preserve state. New/Rename/Delete and running-instance paging have helper coverage but no complete shown native lifecycle; delete's recycle/daemon/session effects are injected. Qualify exposed destructive behavior in disposable fixtures or guard it before preview; defer live totals and multi-instance automation, not safety. |
| Four-page onboarding | F + E | Core release gate | Source defects are fixed: [#573](https://github.com/scgopi/GraphCode/pull/573) honors the effective support directory, [#577](https://github.com/scgopi/GraphCode/pull/577) permits startup before the rendezvous secret exists, and app-native stack `#581` ([#579](https://github.com/scgopi/GraphCode/pull/579) + [#580](https://github.com/scgopi/GraphCode/pull/580)) schedules connection before the modal and exposes its actions through UIA. The row remains Partial because [#556](https://github.com/scgopi/GraphCode/issues/556) still needs the exact packaged install → first launch → onboarding → connected Welcome flight, desktop-level native keyboard evidence, and any claimed assistive-technology evidence. Exact page artwork can follow. |
| Loop row presentation | F + P + E | Qualify identity; defer refinement | Require readable correct title/state/identity in the agent flow. Elapsed formatting has unit coverage but no rendered-column observation; exact time-column spacing and pixel parity can wait. Incorrect or misleading live state is functional, not decoration. |
| Cross-project global graph | F + O + E | Qualify navigation; defer richer topology | Local lane selection must retain the intended project during foreign refreshes; #549 fixes a real reset bug and is included in the audited source. Two-project production navigation still needs a flight. Defer richer topology/START furniture, filtering and remote/all-project worktree binding; accepted harness success does not close those residuals. |
| Notebook grid | P + E | Defer | Grid geometry follows pan/zoom in helper tests, but live line spacing has not been pixel-asserted. Finish direct rendered grid evidence and macOS styling later unless the grid makes content unreadable or impedes hit testing. |
| Pan and anchored zoom | F + O + E | Qualify mouse; defer hardware expansion | Verify mouse pan/wheel/visible zoom controls keep local cards reachable and selection accurate. Touchscreen routing is source/unit-covered, not hardware-witnessed; Precision Touchpad pinch is separate. Defer those additional device profiles rather than claiming support. |
| Loop card identity | F + P + E | Qualify meaning; defer exact styling | Live type/title/state/entry meaning must be readable and match the actual node. Focused stripe tests are not rendered evidence for this row. Exact stripe colors and macOS shape matching are polish only after state distinctions remain clear. |
| Edge presentation | F + P + E | Qualify exposed meaning; defer exact styling | For exposed connections, labels/endpoints/fired state must not misrepresent configuration or obscure actions. Exact strings/static bounds are covered; visible wording and rendered state still need review. Full style, collision placement and macOS summary fidelity can follow. |
| Edge creation sheet | F + O + E | Qualify exposed form; defer advanced graph scope | Real native input/validation/dispatch ran with a protocol stub; real-daemon persistence was separately headless. Qualify cancellation, exact endpoint/configuration preservation and visible result on the packaged path if offered. Defer advanced transforms/cycles outside the profile only with safe refusal; no combined production-UI persistence proof yet. |
| Custody child creation | O + F + E | Defer feature; guard exposed path | Owned-target queue tests cover unresolved parents and inherited backend, not native selection or production acceptance/persistence. Defer custody/report-back workflows. If reachable, cancellation/stale-scope/attachment handling must remain safe; template-backend and downstream-send failure residuals are functional, not polish. |
| Edge editing | F + O + E | Qualify exposed editing; defer deeper scope | Stub-backed native edit/cancel and separate headless production persistence exist. Require exact unchanged ID/endpoints/runtime count, one intended change and no cancellation mutation on the package if exposed. Deeper wrappers remain refused; edge UIA and macOS-equivalent edit surface are absent, not cosmetic gaps. |
| Node creation sheet | F + O + P + E | Qualify basic creation; defer advanced choices | Native type/validation/result evidence uses a stub, while production persistence is separately headless. Qualify typed exact input, scrolling, cancel and retained project context with the real package. The recorded stale tile recap defect was fixed by [#543](https://github.com/scgopi/GraphCode/pull/543); lost UIA census still needs attribution. Nondefault inspected branches, attachments/picker/paste/drop and templates can be deferred with safe boundaries; teaching-tile styling can follow. |
| Node update/rename | F + O + E | Qualify rename and basic edits | Require exact title propagation to graph/sidebar with stable ID, open/cancel/submit Edit Details, clear-versus-unchanged semantics and reload persistence. #549 and pending #547 do not substitute for that combined flight. Diagnose driver clear/focus sequencing separately from product input; defer nonessential typed retypes, not required basic edits. |
| Canvas context menu | F + O + P + E | Qualify core actions and safety | Live menus and one edge edit/cancel were observed, not every invoked outcome. Open/Rename/Edit/Stop and named destructive cancellation need the packaged flight. Defer child/import/export/promotion flows safely; exact menu presentation is polish only after reachable commands target the right object. |
| Sketch promotion | O + F + E | Defer feature; guard exposed path | Queue/helper and headless daemon acceptance exist; [#542](https://github.com/scgopi/GraphCode/pull/542) observed hosted stub-backed native Goal/Turn/Timed promotions. Active real-backend/session continuity remains unqualified, so the row stays Partial. Defer conversion outside the preview scope; if exposed, verify or guard identity/session/history preservation and cancellation. Synthetic session markers do not establish real continuity. |
| Terminal VT state and rendering | F + O + P + E | Core release gate | Witness actual agent output, Unicode/graphemes it emits, wrapping, resize negotiation, cursor/input and liveness with visible pixels matching current state; unsupported-cell rejection/old pixels is not success. Parser memory tests and surface-size helpers cannot prove this. Extended scrollback/selection features may defer only if the CLI remains usable; font smoothing is polish only after readable correct rendering. |
| Mounted background tabs | F + O + E | Qualify exposed continuity | Corrected selectors exclude close buttons, but no new complete live tab/backend round trip is proven. If tabs/splits are offered, switch back to the same session/output/focus without unintended close or input delivery. Defer extra topology automation, not continuity of an exposed control. |
| Show in Graph | F + P + E | Qualify round trip | Focused live evidence supports action/identity return, not a new complete gate or native Loop-menu route. Verify the production terminal-to-card-to-same-loop transition and focus. Extra hints are polish; wrong destination or stale provider binding is functional. |
| Add Codespace sheet | O + E | Defer | Only real 403/remediation ran; successful discovery, selection, validated dial and sheet walkthrough remain absent. Keep Codespaces outside this local preview with explicit capability/error handling; do not require new credentials/scopes to qualify the local app. |
| Worktree notice chip | O + F + P + E | Deferred in beta3; qualify honest status later | Beta3 release-candidate builds replace production Worktrees routes with `Worktrees are deferred for this preview` and never invoke inspection; ordinary developer/local builds retain existing behavior. This safety guard is not the async fix or parity evidence. Automatic discovery, aggregation, authentic review/reclaim and native responsiveness remain unqualified, so the row stays Partial. |
| Available update alert | O + F + E | Defer self-update; qualify honest offer | The real feed currently supplies no Windows ZIP, so Install is disabled with a reason. Enabled installation has not run end to end. Manual verified ZIP updates suffice; do not offer a non-Windows or unverified payload as an installable update. |
| Install progress | O + F + P + E | Defer self-update | Real HTTPS progress/checksum refusal does not prove real Windows extraction/upgrade, especially with the running EXE locked. Keep automatic install outside preview until that flight passes; verify manual upgrade/rollback instead. Progress styling can wait, but integrity and recoverable failure cannot. |
| Relaunch prompt | O + F + E | Defer self-update | Unit outcome/copy does not prove real installed relaunch or zmx continuity through self-upgrade. Require manual-update reopen continuity for alpha; defer Now/Later automation until a real Windows asset and running-process upgrade flight establish the claimed behavior. |
| Install failure | O + F + P + E | Defer self-update; qualify safe recovery | Value-owned error mapping and injected browser invocation are covered, not an actual failing install/browser handoff. Manual installation must report cause and recovery paths without false success or lost data. Automated failure UX and exact presentation can follow with the updater. |
| UI Automation tree | F + O + P + E | Qualify core reachability; defer full conformance | Stable live shell identities do not prove every dialog or terminal Text/Text2 range/selection/caret. Qualify named core controls, focus and keyboard reachability for the declared profile; treat production repros of inaccessible required actions as functional. Full provider/range conformance and extra HelpText remain separate work, not a blanket cosmetic waiver. |
| Keyboard discovery | F + P + E | Qualify reachable commands; defer extra hints | Current menu/Help labels cover mapped core shortcuts, but canvas gestures and sidebar reorder lack visible hints. Verify usable mouse/keyboard routes for core tasks and exact text entry; then defer supplementary gesture guidance. A missing effective route is functional, not just a hint gap. |
| IME/dead keys/layouts | F + O + P + E | Qualify declared input profile | Committed Japanese callback and hidden native dead-key/layout tests do not prove foreground terminal composition. No lost/duplicated committed text in supported form/terminal input is allowed; explicitly qualify supported layouts and non-ASCII scope. Defer additional language profiles and preedit presentation only where basic input remains usable, not required committed text. |
| Clipboard/selection | F + O + P + E | Qualify relied-on paste; defer richer selection | Conversion/classification tests did not access the real clipboard or witness terminal selection. Verify exact safe single-line paste and no unsafe multiline/control execution if paste is offered or needed; visible refusal must be usable. Mouse selection/copy/offset correctness requires a leased desktop fixture; richer selection and hints can defer, silent input/data loss cannot. |
| Per-monitor DPI | F + O + P + E | Qualify supported scales; defer wider monitor matrix | Startup awareness/font-scale propagation and metrics tests are not a real multi-monitor flight. At declared scales and viewport, all required controls/text must remain reachable/readable with correct hit bounds. Defer unadvertised monitor combinations and exact sizing fidelity, not clipped essential controls or wrong input coordinates. |
| Dark visual language | F + P + E | Qualify legibility; defer full styling | Historical 96-DPI captures cover bounded canvas/settings/workspace samples, not all sheets/states. Review core contrast, state hierarchy and readable error/disabled text on the candidate. Exact dark materials and macOS matching can wait; illegible status or indistinguishable actions are functional failures. |
| Font rendering quality | F + P + E | Qualify readability; defer exact smoothing | Segoe UI/ClearType requests and color-count samples do not certify every face or legibility, especially terminal glyphs. Qualify readable native controls and actual agent output at declared DPI first. ClearType/anti-alias refinement and matched macOS typography then become polish. |
| Line/shape anti-aliasing | P + E | Defer | Bounded real GDI+ captures show selected-card/sparkline samples, not all edge styles/DPI states or macOS equality. Improve dashed/grid/preview smoothing and collect matched evidence after the relevant lines/actions are already distinguishable and usable. |
| Color palette fidelity | P + E | Defer | A bounded COLORREF channel bug was corrected with real before/after samples and static token mapping; that is meaningful progress, not every tone/material/state matched to macOS. Defer exact gradients and full matched captures while preserving core contrast and redundant state meaning. |

## Alpha release gates

These are acceptance conditions for a future authorized flight, **not results
of this documentation change**. Keep a versioned record with positive executed
counts, expected/actual values, failures and retained evidence. Required native
input, clipboard, display and destructive tests need an owned Windows desktop
lease or equivalent authorized hosted evidence. No desktop available means a
proof gap, not PASS; hosted server evidence must not be relabelled client proof.

- [x] **Exact artifact:** candidate source
  `0958109ee41c7215e3ccf91319e5a102d0fb7069`, version/tag
  `0.1.78-beta3`, annotated tag object
  `0c62e6f21f58c97ca4fbe3154f60887cac2bf52d`, package SHA-256
  `9533116c025d4883ab7761f20f7e62499408209421f70264a3638e8347d2d0f9`,
  50-file payload manifest SHA-256
  `a2a7e1b8b95eb0dc77f7af8d9039eabee052443bc459be609f7dab90e140fb73`,
  and provider provenance are recorded in
  `GraphCode-DevBox-Handoff-0.1.78-beta3`. Tag/source match. The repository ZIP
  verifier and extracted standalone setup each reported exactly one PASS; the
  package explicitly declares `UNSIGNED (not code signed)`, records
  `previewFeatures.worktreesDeferred=true`, reports preview state `deferred`,
  and contains production daemon/CLI/runtime inputs. The coordinator
  independently reverified the handoff and all eight payload hashes. The
  LFS-aware source-custody ZIP verified and restored the exact detached source,
  annotated tag, and all 43 LFS objects/files under process-only network denial
  with a clean status.
- [ ] **Clean installation and recovery:** install the extracted candidate on
  the declared client profile without Git/Swift/Zig/SDK developer dependencies.
  Observe the installed scheduled daemon endpoint and normal app launch.
  Approval A requires uninstall with data preservation and reinstall, with
  fixture user-data bytes compared before/after. Upgrade, locked-upgrade
  refusal and rollback are NotExecuted for this pass, remain unsupported, and
  keep the broader recovery gate open. Existing CI supports, but does not
  replace, this chosen-package check.
- [ ] **Production core flow:** with production `graphcoded`, not the protocol
  stub or gate-seeded model, open an owned fixture project; create exactly one
  intended loop, render/select it, rename and edit basic fields, then reopen
  and read the persisted state. Use exact typed sentinels such as
  `AlphaRenamed` and `A-start-Z-end`; graph/sidebar/model must agree on title
  and stable ID. A changed editor cancellation must leave configuration
  unchanged. A driver failure requires attribution or an independently
  qualified manual flight, not an inferred product cause.
- [ ] **Useful agent terminal:** run one named supported agent CLI/version in
  that project. Observe real readable prompts/output, type and receive exact
  expected input/output markers, interact with its required controls and stop
  the intended loop without freezing the app or losing unrelated output.
  Exercise resize, wrap, minimize/restore and any offered tab switch; verify
  visible state against actual PTY dimensions/output. Include non-ASCII text
  in the declared scope and the glyphs/graphemes the CLI itself emits. Old
  pixels after unsupported-cell rejection, a parser snapshot, or queued input
  counts cannot satisfy this gate.
- [ ] **Reachability and lifecycle:** at the declared minimum viewport and
  supported 100%/150% profiles, actually reach every required form control,
  validation/error, menu and terminal action with native input. Confirm exact
  supported non-ASCII/dead-key entry and any relied-on clipboard paste without
  loss or unintended execution. Exercise close-to-tray, explicit app Exit,
  daemon interruption/recovery and reopen; record which processes/sessions
  should persist or stop, and verify those boundaries and saved state.
  No crash, freeze, focus trap, unexplained output loss or silent error passes.
- [ ] **Safe mutations:** in disposable fixtures, exercise named cancel and
  confirmed delete/remove flows, including reachable workspace destructive
  operations. Cancellation must leave files/configuration/session identities
  unchanged; confirmation must affect only its captured target and report
  partial failure accurately. Any unqualified unsafe exposed operation must
  be fixed or guarded before preview, not waived by "use at your own risk."
- [ ] **Honest tester handoff:** provide supported OS/display/backend versions,
  known limitations, unsigned/SmartScreen and organization-policy warnings,
  verified download/checksum instructions, install/manual-update/uninstall
  steps, recovery locations and a bug-report route. Never ask testers to bypass
  security policy. Invite only after the core gates have actual evidence.

The **Exact artifact** gate is complete for beta3. The other **six** gates
remain open and require evidence that source, hosted CI, and hidden-window
tests cannot manufacture:

| Required external capability | Exact permission/evidence needed |
|---|---|
| Packaged install and recovery | An authorized owned Windows 11 x64 client; permission to install the unsigned candidate, create/remove its scheduled task, run upgrade/rollback/uninstall, and preserve before/after user-data hashes plus package/source/provenance records. |
| Owned desktop and native input | An exclusive or otherwise controlled interactive desktop at the declared 100%/150% profiles; permission to foreground the app, send physical/native keyboard and pointer input, exercise relied-on clipboard/IME paths, and retain screenshots/logs without exposing unrelated user data. Posted messages and hosted server UIA are not substitutes. |
| Named authenticated backend and credits | Authorization to use one explicitly named supported backend/version with a test account, valid authentication, and sufficient credits/quota; retained prompts/output markers and billing-safe stop criteria. Selector presence does not grant this permission. |
| Destructive fixture lifecycle | Permission to create disposable local projects/workspaces/sessions, delete or recycle named fixtures, stop the fixture daemon/session processes, inspect the Recycle Bin/recovery result, and compare exact untouched sentinels outside the captured target. |
| Publication | Maintainer approval for the exact qualified SHA/version/tag and permission to upload the unsigned ZIP plus checksum to the intended prerelease. Build permission, local-package mode, and an existing release-upload capability are not publication approval. |

## Publication and tester handoff

Use the existing [release workflow](../.github/workflows/windows-release.yml)
and [release script](../Tools/windows/release.ps1); no new installer, signing
programme or automated release policy is needed for this preview. The workflow
is manual-dispatch only, checks out an **existing tag**, and defaults
`publish` to `false`. The script builds/verifies the ordinary **UNSIGNED** ZIP
and produces `graphcode-windows-x86_64.zip` plus its `.sha256` sidecar.
Checksums detect corruption; they do not authenticate the publisher.

The completed local exact-artifact record is the unpublished beta3 candidate:
source/tag `0958109ee41c7215e3ccf91319e5a102d0fb7069` /
`0.1.78-beta3`, ZIP SHA-256
`9533116c025d4883ab7761f20f7e62499408209421f70264a3638e8347d2d0f9`,
source-custody ZIP SHA-256
`d20a64f78340baed6e417c7f94abae30e81c5abade20c8c53e2df75f3ef38407`,
and versioned handoff `GraphCode-DevBox-Handoff-0.1.78-beta3`. The beta3 tag is
local and unpushed, there is no beta3 release, and publication is false.
README-FIRST requires restoration through the included
`Restore-GraphCodeSource.ps1`; it forbids GitHub cloning and bare-bundle
cloning for this custody path. The superseded beta1 and beta2 tags, ZIPs, and
original handoffs remain immutable historical evidence; do not transfer or
qualify them and do not delete or rewrite their records.

After qualification, the maintainer chooses an authorized preview version/tag
for the **qualified source**, builds with publication disabled, verifies that
artifact and its provenance, and separately approves publication. Do not reuse
the older v0.1.77 tag for unrelated newer HEAD, overwrite its assets, or change
macOS release policy. `release.ps1` refuses a tag/source mismatch before
publication, and forbids `-AllowTagMismatch` with `-Publish`. Its upload
overwrite capability is not authorization to replace a released artifact.
Give testers the explicit preview release URL, not an assumption that a
prerelease is served by the stable `latest` route.

The tester packet should name one supported initial workflow, the exact
artifact/checksum, safe local-fixture setup, the actual demonstrated support
profile and the deferred features above. Manual updates use the new extracted
`GraphCode-Setup.ps1` and its existing verification/upgrade/recovery path.
Do not enable or advertise in-app install/relaunch until its own real
running-EXE/session-continuity flight passes. This plan neither creates a tag
or release nor dispatches CI, uploads assets, installs an app or changes pins.

### Qualification execution plans

The remaining evidence work is split at the machine boundary so a new agent can
execute either side without relying on hidden session state:

- [Local candidate and release plan](windows-preview-local-qualification-plan.md)
  selects/audits the source, creates the local unpushed tag, builds and verifies
  the exact ZIP, produces the self-contained Dev Box handoff, reviews returned
  evidence and performs publication only after a separate final approval.
- [Microsoft Dev Box qualification plan](windows-preview-devbox-qualification-plan.md)
  is standalone. It verifies the handoff, installs the unchanged candidate,
  runs the production/native/backend/lifecycle evidence on a new corporate
  Dev Box, cleans up and returns a hashed evidence bundle. It never publishes.

For beta3, the versioned handoff binds the exact candidate source/tag, ZIP,
source-custody ZIP, provider/toolchain identities, Approval A, and the exact
candidate Dev Box plan whose SHA-256 is
`f250629ad6812049ec1beb5409cfa05afd09433ea5cd1a3818b3fccd9c0cb8b6`.
Use the included custody restore script before any Dev Box qualification; do
not substitute GitHub or a bare Git bundle. Any identity change invalidates
downstream evidence and restarts qualification from the local plan. The
repository plan documents remain procedures, not evidence; they do not change
any gate or parity status.

## Assigned work inventory after the clean-clone queue

The 2026-10-01 assignment audit resolved the canonical programme assignee as
`coneilen` (GitHub user ID `41757757`) separately from the authenticated writer
`coneilen_microsoft`. The same 13 assigned `windows`-label issues remain the
audited inventory, all in `scgopi/GraphCode`; live GitHub state at this commit is
exactly **3 open / 10 closed**. The two provider repositories still have zero matching
assigned issues. Empty provider results are inventory facts, not passing
product evidence.

| Issue | Live state and accepted source | Evidence tier | Remaining criterion |
|---|---|---|---|
| [#551](https://github.com/scgopi/GraphCode/issues/551) | **Closed** by [#574](https://github.com/scgopi/GraphCode/pull/574) | Source/tooling-fixed; 5/5 bootstrap tests plus provider-pin regression | No preview gate; retain the documented short-root remedy for legacy path budgets. |
| [#552](https://github.com/scgopi/GraphCode/issues/552) | **Closed** by [#594](https://github.com/scgopi/GraphCode/pull/594), merged with lower [#585](https://github.com/scgopi/GraphCode/pull/585) in app-native stack `#595` at `7d5cf3be8a86b7562b527f90d854845a52f2ac82` | Evidence-only documentation; 3 focused documentation cases plus inherited 4-case dev regression | The quick start now records measured timings, supported commands, known failures, and evidence limits. It does not qualify native UI, installation, an authenticated backend, or parity. |
| [#553](https://github.com/scgopi/GraphCode/issues/553) | **Closed** by [#578](https://github.com/scgopi/GraphCode/pull/578) | Source/tooling-fixed; packaging gate qualified | Local packages have explicit provenance and publication refusal; installed-client and publication evidence remain separate alpha gates. |
| [#554](https://github.com/scgopi/GraphCode/issues/554) | **Closed** by [#573](https://github.com/scgopi/GraphCode/pull/573) | Source-fixed; 3/3 focused and 10/10 full tests | Prove the exact packaged first launch writes only the selected support directory and leaves the real profile unchanged. |
| [#555](https://github.com/scgopi/GraphCode/issues/555) | **Closed** by [#577](https://github.com/scgopi/GraphCode/pull/577) | Source-fixed; focused contract and 177/177 DaemonClient tests | Prove the production daemon starts/connects from an empty support directory in the packaged core flight. |
| [#556](https://github.com/scgopi/GraphCode/issues/556) | **Open; source-fixed/evidence-remaining** through app-native stack `#581` ([#579](https://github.com/scgopi/GraphCode/pull/579) + [#580](https://github.com/scgopi/GraphCode/pull/580)) | Local/CI and shown-window probe evidence; no packaged/native-client qualification | Witness ordinary install → first launch → onboarding → connected Welcome with production `graphcoded`, desktop-level keyboard input, and any claimed assistive-technology behavior. |
| [#557](https://github.com/scgopi/GraphCode/issues/557) | **Closed** by [#585](https://github.com/scgopi/GraphCode/pull/585), merged with upper [#594](https://github.com/scgopi/GraphCode/pull/594) in app-native stack `#595` at `7d5cf3be8a86b7562b527f90d854845a52f2ac82` | Source/tooling-fixed; 4 focused behavioral cases plus a real pinned build/run/stop cycle | The supported entry point builds the runnable layout, launches production daemon before shell in checkout-owned roots, and stops only revalidated captured identities. Full validation and every native/product release gate remain separate. |
| [#558](https://github.com/scgopi/GraphCode/issues/558) | **Closed** by [#593](https://github.com/scgopi/GraphCode/pull/593), accepted source-fix merge `ca535d0c4042a60ab748f7ff01d6460e9c9ec0d1` from head `285b73e8e5a7634a9033b8e72f950efc703b4f60` | Source-fixed; direct-process behavioral regression, Swift production suite, Windows shell, and mandatory macOS shared CI passed at exact head | The redirected-profile trap is fixed. Continue to use explicit owned support/temp roots for qualification isolation; this closure does not prove installed-product behavior. |
| [#559](https://github.com/scgopi/GraphCode/issues/559) | **Closed** by [#586](https://github.com/scgopi/GraphCode/pull/586), merged as `c19e277eef2728ef5046770a34fef8f0bbd63f33` | Source/tooling-fixed; 12/12 bootstrap tests plus deterministic Range/resume/stall/mirror/cache/checksum fixtures | Preserve checksum enforcement, bounded retry/timeout behavior, useful partial archives, and explicit mirror semantics. Real ziglang.org transport was not claimed by the PR. |
| [#560](https://github.com/scgopi/GraphCode/issues/560) | **Open; preview guarded, underlying product lane unresolved** with harness-only open [#587](https://github.com/scgopi/GraphCode/pull/587) at `c249b9f8731741167bd11ca400691f26f0639903` | #604's beta3-retained contracts prove the deferred message, packaged `deferred` state and zero inspection attempts; #587 still changes only the two harness files and local native UIA responsiveness is NotExecuted | Keep #560 and #587 open. Beta3 safely defers the starving path; it does not fix it. No dump is authorized. Any later source fix requires separate dump authorization, child-process inventory and stack/lock attribution before changing shared product files. |
| [#561](https://github.com/scgopi/GraphCode/issues/561) | **Closed** by [#575](https://github.com/scgopi/GraphCode/pull/575) | Source/tooling-fixed; deep-root positive execution and 21 regression logs | No product gate; preserve positive execution counts and bounded fixture roots. |
| [#562](https://github.com/scgopi/GraphCode/issues/562) | **Closed** by [#576](https://github.com/scgopi/GraphCode/pull/576) | Source/tooling-fixed; 4/4 isolation tests and 380 runner contracts | Qualification isolation is accepted; installed-product profile behavior remains a separate flight. |
| [#564](https://github.com/scgopi/GraphCode/issues/564) | **Open; deferred** | No extraction accepted | Keep deferred unless a concrete next-wave overlap requires one small ownership extraction; do not turn the broad split into a preview prerequisite. |

Closing an issue does not promote a ledger row by itself. The ten closures
record real source/tooling/documentation completion; packaged/native-client qualification,
publication, and parity promotion retain their separate evidence standards.

## Post-queue orchestration and dependency map

The bounded source/tooling queue is complete. Remaining work is bottom-up and
permission-bound; it should not start with another parity-row sweep:

1. **Installed production-core and onboarding qualification - #556:** the
   exact source-bound beta3 candidate
   `0958109ee41c7215e3ccf91319e5a102d0fb7069` was built through
   [#578](https://github.com/scgopi/GraphCode/pull/578)'s supported route with
   the #604 release-candidate guard. Its independently reverified
   LFS-aware custody ZIP and versioned handoff now exist; transfer and Dev Box
   execution are still NotExecuted. After authorization, use the included
   restore script and the exact candidate Dev Box plan to run
   install → first launch → onboarding → connected Welcome → local project →
   one named authenticated backend → readable input/output → persisted reopen
   → safe exit. This packaged/native-client flight **can close #556** only when
   its exact residuals pass; missing desktop, backend, destructive-fixture, or
   assistive-technology permission remains NotExecuted rather than failure or
   success.
2. **Deferred Worktrees and future attribution - #560 / #587:** keep open
   [#587](https://github.com/scgopi/GraphCode/pull/587) harness-only and
   evidence-only at head `c249b9f8731741167bd11ca400691f26f0639903`.
   #604 establishes the safety contract retained by beta3:
   release-candidate builds report `deferred`, show
   `Worktrees are deferred for this preview`, and do not invoke inspection.
   Local native UIA responsiveness remains NotExecuted, and no Dev Box runtime
   evidence exists. Approval A authorizes no full dump and keeps #560 open. A
   future dump-backed diagnosis requires separate authorization and a new
   candidate if product code changes.
3. **Keep the release gates honest:** **Exact artifact** is complete for beta3;
   the other **six** gates remain open. The installed production-core result,
   native input and destructive fixture permission, named authenticated backend
   authorization, handoff transfer and execution, Approval B, and publication
   permission are independent. A green
   build/run/stop cycle, a local package, or harness attribution does not
   authorize tester publication or promote a ledger row.
4. **Keep #564 deferred:** do not split shared files merely to create work.
   Open a bounded extraction session/PR only if the #556 flight or the
   dump-backed #560 fix identifies a concrete ownership dependency. Such an
   extraction may unblock delivery but is not preview qualification by itself.
5. **Keep provider work deferred:** retain
   [coneilen/winghostty#11](https://github.com/coneilen/winghostty/pull/11) and
   [coneilen/winghostty#10](https://github.com/coneilen/winghostty/pull/10)
   paused unless actual client/backend evidence demonstrates respectively a
   provider-validation dependency or the glyph-capacity failure. No PR count,
   provider branch, or full parity-row closure is an implicit preview
   prerequisite.

## Measuring progress

Track two independent outcomes: **whole-row parity closures** under the ledger's
unchanged macOS-equivalence/runtime rule, and **observable product bugs fixed or
core release behaviors newly qualified** with exact source/evidence. The
unchanged 63/35 split across the last eight ledger commits (September 28-30;
62/36 after the 2026-10-01 onboarding correction, which is a more accurate
record, not a regression)
does not mean no progress: narrowed evidence, cancellation/persistence work and
the landed refresh-navigation fix matter even when a row has other residuals.
Conversely, PR counts, unit-test totals and harness enqueue counts are not
user-visible completion.

For each core gate, record NotExecuted/Failed/Passed on the chosen package,
the reproduced product issue (if any), and the next specific missing
observation. Keep optional-feature and polish backlog progress separate.
Release the scoped preview when the core/safety gates pass; continue parity
and polish afterward without renaming, splitting or promoting ledger rows to
make the release appear closer.
