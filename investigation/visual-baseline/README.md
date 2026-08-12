# Windows visual baseline

This fixture set is a public-source contract for the Windows shell. It freezes the
GraphCode-owned geometry, state words, colors, IDs, timestamps, metrics, and static
terminal text needed for deterministic review without building the Windows UI.

`manifest.json` cites the existing GraphCode screenshot, `Theme.swift`, card
presentation, canvas, sidebar, workspace, and parity sources. The four DPI entries are
layout variants, not screenshots tied to a particular machine.

The GraphCode-owned regions are safe for screenshot comparison. Terminal rendering,
input, IME, clipboard, resize, and accessibility remain live Winghostty functional
tests; the text files in `fixtures` are only stable placeholders for testing workspace
layout and split ownership.
