# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in GraphCode, please report it
responsibly by emailing **graphcode@sravani.dev**.

**Please do not report security vulnerabilities through public GitHub issues.**

Include as much of the following information as possible:

- Type of issue (e.g., buffer overflow, privilege escalation, code injection)
- Full paths of source file(s) related to the issue
- The location of the affected source code (tag/branch/commit or direct URL)
- Any special configuration required to reproduce the issue
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue, including how an attacker might exploit it

You should receive a response within 48 hours. If the issue is confirmed, we
will release a patch as soon as possible depending on complexity.

## Security Considerations

GraphCode orchestrates CLI-based AI agents that can read and write files on
your machine. By design:

- **Permission modes**: Each backend (Claude Code, Copilot CLI, Codex) has
  configurable permission levels. The default `auto` mode keeps guardrails
  intact; `bypassPermissions` removes all checks and should only be used when
  you understand the implications.

- **Worktree isolation**: Loops can run in isolated git worktrees to contain
  their changes to a branch rather than your main checkout.

- **Session briefings**: When enabled, sessions are told they're part of a
  graph and can create child loops. Disable this if you want loops to operate
  in complete isolation.

Review your Settings before running unattended loops on sensitive codebases.
