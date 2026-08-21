# Test Suite

All inputs are deterministic and synthetic. Tests never read the live Codex
store or normal OpenCode data home. Generated data stays below
`tests/.generated/` or `tests/Benchmarks/.generated/`; both locations are ignored and
the publication audit rejects them when left in a publication tree.

## Run Everything

Run the canonical suite from the repository root:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny
```

When an OpenCode CLI is installed, include the official isolated
import/export round trip:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny -TestOpenCodeImport
```

The integration workload accepts `Tiny`, `Small`, or `Medium`. Generated files
are removed unless `-KeepGenerated` is supplied.

## Layout

| Path | Scope |
| --- | --- |
| `Invoke-AllTests.ps1` | Runs every repository test in a stable order and reports per-test timing. |
| `Benchmarks/Measure-CodexSessionConversion.ps1` | Measures conversion performance with generated synthetic data. |
| `Contract/Test-ModuleContract.ps1` | Parses PowerShell, validates the manifest, exact eight-command API, help, naming, safety rejection, and side-effect-free module load. |
| `Documentation/Test-Documentation.ps1` | Checks Markdown links, documented commands/source files, current paths, naming conventions, and required safety/fidelity disclosures. |
| `Integration/Test-SyntheticConversion.ps1` | Exercises public discovery, conversion, deterministic IDs, typed and legacy fidelity, code-mode archives, compaction, planning, and optional official import/export. |
| `Publication/Test-Publication.ps1` | Rejects generated/private artifacts, real-looking IDs and paths, credentials, sensitive names, and legacy architecture paths. |
| `Unit/Test-CodexCustomToolOutput.ps1` | Covers exact textual-envelope flattening and conservative preservation of malformed, null, unknown, and mixed content. |
| `Unit/Test-OpenCodeBundleValidation.ps1` | Covers valid part counts and rejection of duplicate IDs, bad parents, invalid tool states, unsafe images, wrong directories, empty bundles, and invalid sessions. |
| `Support/New-SyntheticCodexData.ps1` | Generates seeded synthetic Codex stores for tests and benchmarks. |
| `Fixtures/ComplexLegacy/Codex/` | Small but deliberately feature-rich committed legacy-rollout fixture. |

PowerShell project directories use PascalCase. External Codex store names such
as `sessions` and `session_index.jsonl` retain their source-defined spelling.
PowerShell files use approved `Verb-Noun` names with PascalCase components.

## Integration Coverage

The integration runner verifies inventory, `CODEX_HOME`, exact IDs and
deeplinks, pipeline and all-session conversion, paths containing spaces,
Unicode, incomplete calls, deterministic IDs, atomic replacement, chronological
message and part IDs, typed tools, legacy events, compaction, and conflict
reporting.

The committed `complex-legacy` fixture adds text, image, generic tool, patch,
MCP, web, duplicate and stale events, structural opaque-wrapper correlation,
UI-hidden synthetic archive notes, exact metadata-only code-mode source/output,
and authoritative native completion coverage. A generated paginated fixture
uses official core item wire shapes for commands, file changes, MCP, web,
image-view, dynamic tools, plans, extensions, errors, ordering, and duplicate
suppression.

With `-TestOpenCodeImport`, the runner assigns an isolated `XDG_DATA_HOME` and
exercises public planning, import, global inventory, content-conflict detection,
relocation rejection, exact tool/archive import-export round trips, and removal.
The normal OpenCode data home is never used.

## Generator

The generator supports `Tiny`, `Small`, `Medium`, `Large`, `Huge`, and `Custom`.

```powershell
./tests/Support/New-SyntheticCodexData.ps1 -Preset Tiny -Force

./tests/Support/New-SyntheticCodexData.ps1 `
    -Preset Custom `
    -Sessions 2 `
    -Turns 25 `
    -ToolCallsPerTurn 3 `
    -TextCharacters 1024 `
    -ToolPayloadCharacters 8192 `
    -IncludeUnicode `
    -IncompleteFinalToolCall `
    -Force

./tests/Support/New-SyntheticCodexData.ps1 -Preset Huge -AllowHuge -Force
```

Generation writes JSONL incrementally. Marker files protect every recursive
cleanup, and `-Force` refuses to remove an unmarked directory.

## Benchmark

The benchmark is not part of the correctness suite:

```powershell
./tests/Benchmarks/Measure-CodexSessionConversion.ps1 -Preset Medium
```

It writes CSV and JSON reports below
`tests/Benchmarks/.generated/conversion-results/`. See
[`../docs/Testing.md`](../docs/Testing.md) for platform coverage and detailed
verification semantics.
