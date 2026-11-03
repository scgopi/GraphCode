# Residual root source wiring

Register
`GraphCode.Validation.Host.RootContracts.ResidualScopeRegistration.CreateSuites()`
once, in addition to the frozen six-family registration. Merge the single
`ResidualScope-manifest-fragment.json` entry into the existing host unit rather
than adding a duplicate unit.

The residual audit leaves seven original packaging predicates: six contract
invocations inside the fixture-only part guard before real packaging, and real
input initialization before the real packaging invocation. The suite expands
these to **16 cases: seven production-source observations and nine negative
controls**. Successful adapter groups must match those 16 identities exactly.

These are actual PowerShell AST observations against `validate.ps1`, not matches
against comments, inventories or a reimplemented packaging executor. The checks
require the correct task clause, correct part guards, unique direct command
invocations and source ordering. Independently authored source mutations remove
each contract call, remove initialization, invert the guard and comment out a
call. Mutants are parsed and inspected only; production packaging is never run
by this unit.

The long existing mandatory unit ID
`host.root-source-scope-mock-environment-error-streams` is retained for manifest
compatibility. It does not imply that these static wiring cases prove runtime
scope restoration, error streams, LASTEXITCODE behavior, packaging lifecycle or
native UIA behavior. Those remain the responsibility of their actual behavioral
suites.

`ResidualScope-source-correspondence.json` records exact frozen lines and foreign
ownership. In particular, the existing Ui unit `ui.root.source.line-5342`
already covers ProviderPins-before-TerminalGate. The smoke-before-UIA predicate
is `ui.root.source.line-5350`, not line 5342. Neither is counted here. The two
delayed-stub observations at line 5346 remain with the Host implementation.

Build the nested host project normally. For focused development, use
`ResidualScopeFocused.ps1` with `-RepositoryRoot`, `-ArtifactRoot` and
`-AssemblyPath`, as with `Focused.ps1`. It invokes the public protected
`CaseScriptSuite` transport, preserves unknown ownership through the outer
terminal hold, requires a positive exact count and never emits a full-host
success marker.
