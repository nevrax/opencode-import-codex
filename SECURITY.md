# Security Policy

## Reporting A Vulnerability

Use the repository host's private security advisory feature when available. Do
not open a public issue containing transcripts, credentials, private source,
machine-specific paths, generated bundles, or other sensitive data. Provide a
minimal synthetic reproduction, affected module version, PowerShell version,
operating system, and OpenCode version when relevant.

## Plaintext Output

The module processes plaintext coding-agent history. Generated bundles can
contain prompts, responses, source code, shell commands, tool input and output,
embedded images, local paths, and credentials printed during a session.

Opaque Codex code-mode executions are not displayed as tool cards and their raw
content is not projected into resumed model context. This is not encryption or
redaction: exact JavaScript source and persisted outer output remain plaintext
in `metadata.codex.executions` on synthetic text parts and survive official
OpenCode import/export. Treat those archives as equally sensitive as visible
transcript content.

When `-OutputDirectory` is omitted, bundles are written to
`OpenCode.ImportCodex/exports` below the user-local application data directory.
If that directory cannot be resolved, the fallback is
`Join-Path $HOME '.opencode-import-codex/exports'`. These files are not encrypted.
Use an explicit protected directory when necessary, inspect files before sharing,
and delete them after use.

Never commit real input or output. Tests and reports use only synthetic data
under ignored `tests/.generated/` and `tests/Benchmarks/.generated/`
directories.

## Converter And Downloads

The converter is private module code in
`src/OpenCode.ImportCodex/Private/NativeConverter.ps1`; it is not exported as a
command. Conversion uses PowerShell and .NET APIs and does not execute historical
tools or Codex code-mode JavaScript. The module performs no network or package
downloads and does not install Codex, OpenCode, PowerShell, or desktop apps.

Operations that need OpenCode invoke an already installed `opencode` executable.
Review the selected executable path with `Test-CodexOpenCodeEnvironment` when the
execution environment is not trusted.

## Source Safety

Codex rollouts and `session_index.jsonl` are read only. The module does not
archive, rename, delete, truncate, or write Codex source data. It opens rollout
files with shared read access so an active Codex process can continue writing.
Filesystem access can still update access-time metadata on systems where access
time tracking is enabled.

Output is rejected when it is lexically equal to or below the Codex data root,
and unsafe session IDs are rejected before they can become file names. Conversion
writes a temporary bundle and replaces an existing bundle with recovery handling.

## Link Containment Caveat

Path containment checks normalize full lexical paths but do not resolve symbolic
links, mount aliases, or Windows junction targets. A link inside an apparently
safe output tree could point into the Codex source tree, and equivalent linked
paths may compare as different. Do not place the Codex data root, output
directory, or target project behind untrusted links or junctions. Choose paths
whose resolved locations you control.

## OpenCode Changes

`Import-CodexSession` and `Remove-OpenCodeSession` are high-impact commands with
PowerShell `ShouldProcess` support. Use `-WhatIf`, inspect plans, and back up
important OpenCode data. `Remove-OpenCodeSession` permanently deletes sessions
through the supported OpenCode CLI and verifies removal; it never deletes Codex
sessions.

OpenCode import is effectively insert-only for existing deterministic message
and part IDs. A corrected bundle can plan as a content conflict but cannot
overwrite those live parts. Before replacing a session, verify that no
OpenCode-only continuation would be lost, obtain explicit approval, remove the
session through the supported command, and then import the corrected bundle.
