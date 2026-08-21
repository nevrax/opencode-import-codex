# Contributing

Contributions must preserve the module's small public contract and use synthetic
data only. Never submit real Codex rollouts, OpenCode exports, credentials,
private source code, real user paths, or real session IDs.

## Module Conventions

- Exported functions use an approved PowerShell `Verb-SingularNoun` name.
- Public parameter names are explicitly declared in PascalCase.
- Spell product names as `OpenCode`, `Codex`, and `PowerShell` in code, help, and
  documentation.
- Put each exported function in `src/OpenCode.ImportCodex/Public/` with a matching
  file name.
- Put non-exported implementation functions in
  `src/OpenCode.ImportCodex/Private/`.
- Keep the export lists in `OpenCode.ImportCodex.psd1` and
  `OpenCode.ImportCodex.psm1` exact and synchronized.
- Do not expose private implementation controls as public parameters.

Every public function requires comment-based help with a synopsis, description,
description for every public parameter, output type, and at least two examples.
Examples must use portable paths such as `Join-Path $HOME '...'` or repository
relative `./...` paths. Use short synthetic identifiers that cannot be mistaken
for published user data.

## Test Data

All fixtures and generated inputs must be demonstrably synthetic. Extend the
committed synthetic fixture for focused fidelity behavior or use
`tests/Support/New-SyntheticCodexData.ps1` for generated volume and shape tests.
Do not sanitize and commit a real transcript.

Generated data belongs only under `tests/.generated/` or
`tests/Benchmarks/.generated/`. Preserve marker-file checks around recursive
cleanup.

## Verification

Run from the repository root:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny
```

When an OpenCode CLI is available, also run the isolated import test:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny -TestOpenCodeImport
```

For converter performance changes, record a benchmark using only generated data:

```powershell
./tests/Benchmarks/Measure-CodexSessionConversion.ps1 -Preset Medium
```

See [`docs/Testing.md`](docs/Testing.md) for generator, benchmark, and platform
coverage details.
