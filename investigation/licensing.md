# Licensing notes

| Component | License | Windows-port consequence |
|---|---|---|
| `GraphcodeKit/` | MIT | May be reused, modified, and redistributed with notice. |
| `graphcode-cli/` | MIT | Same. |
| `graphcoded/`, app, remaining repository | FSL-1.1-MIT | Internal, non-commercial research, education, and permitted professional services are allowed. A competing commercial product/service is restricted until each version's two-year MIT future-license date. Preserve the license on redistribution. |
| Ghostty / `libghostty-vt` | MIT | Reuse is permitted with copyright/license notice. |
| zmx and GraphCode's zmx fork | MIT | Reuse/port is permitted with upstream notice. Record fork SHA and upstream base. |
| Winghostty | Ghostty-derived MIT code; verify per-file headers | Concepts and code may be adapted with notices, but copied files need provenance and header review. |

GraphCode's current zmx fork is 26 upstream commits behind and carries a GraphCode-specific
mouse-input patch. Windows work should rebase that patch before building a new backend.

This is an engineering inventory, not legal advice. Before public Windows distribution,
generate a third-party notice/SBOM from the exact pinned commits and review every copied
Winghostty file rather than relying only on repository-level READMEs.
