# Red/green/refactor evidence

Every feature, behavior change, extraction, and bug fix records:

```text
RED: <focused command> -> <failure proving missing behavior>
GREEN: <same focused command> -> pass
REGRESSION: <adjacent/full command> -> pass
```

The RED command must fail before implementation for the intended assertion, not because
the toolchain or fixture is missing. The integrated commit contains the green test and
implementation together; deliberately failing commits are not cherry-picked.

Run locally:

```powershell
pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1
pwsh Tools/tdd/Test-TddEvidence.ps1 -BodyPath <pull-request-body.md>
```

The pull-request workflow validates the same contract from the GitHub event payload.

New pull-request bodies that include candidate identity fields must provide a
valid Tier A/B/C selection, branch, `HEAD / tree` hashes with clean/dirty state,
and relevant artifact hashes. A stopping handoff is optional when no stop or
transfer applies; once any handoff value is supplied, every handoff field must
be complete, the positive count must be nonzero, and the blocker category must
use the documented classification. Legacy PR bodies that predate these fields
remain valid when the metadata sections are absent.
