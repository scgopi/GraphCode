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
