# Command Reference

Import the module before using this reference:

```powershell
Import-Module ./src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1 -Force
```

All paths shown below are repository-relative or are built with `Join-Path`.
Exact IDs and unique prefixes are accepted where documented. The `DeepLink`
alias on Codex `SessionId` parameters accepts
`codex://threads/<session-id>`.

## Complete Help Discovery

```powershell
Get-Command -Module OpenCode.ImportCodex
Get-Command Convert-CodexSession -Syntax
Get-Help Get-CodexSession -Full
Get-Help Select-CodexSession -Examples
Get-Help Convert-CodexSession -Detailed
Get-Help Get-CodexSessionImportPlan -Full
Get-Help Import-CodexSession -Full
Get-Help Get-OpenCodeSession -Full
Get-Help Remove-OpenCodeSession -Full
Get-Help Test-CodexOpenCodeEnvironment -Full
Get-Help Import-CodexSession -Parameter '*'
```

## Get-CodexSession

Reads Codex rollout metadata. With no `SessionId`, it returns every discovered
session ordered by `Started` descending.

Syntax:

```powershell
Get-CodexSession [[-SessionId] <String[]>] [[-CodexDataRoot] <String>]
```

Parameters:

| Parameter | Type | Behavior |
| --- | --- | --- |
| `SessionId` | `String[]` | Optional exact IDs, unique prefixes, or deeplinks. `DeepLink` is an alias. Missing or ambiguous references throw. |
| `CodexDataRoot` | `String` | Explicit Codex root. Otherwise uses `CODEX_HOME`, then `.codex` below the user profile. |

This command does not accept pipeline input and does not prompt.

```powershell
Get-CodexSession
Get-CodexSession -SessionId 'demo', 'codex://threads/other-demo' `
    -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
```

Output type: `OpenCode.ImportCodex.CodexSession`.

| Property | PowerShell type | Meaning |
| --- | --- | --- |
| `Id` | `String` | Validated Codex session ID. |
| `Started` | `DateTimeOffset` | Session start timestamp. |
| `Title` | `String` | Indexed thread title, or an empty string. |
| `Directory` | `String` | Working directory recorded by Codex. |
| `SourcePath` | `String` | Full rollout JSONL path. |

## Select-CodexSession

Displays a numbered table, prompts for comma-separated numbers, validates each
number, removes duplicate selections by ID, and returns selected session objects.
It is the only interactive Codex inventory command.

Syntax:

```powershell
Select-CodexSession [[-CodexDataRoot] <String>]
```

`CodexDataRoot` is a `String` with the same resolution rules as
`Get-CodexSession`. The command does not accept pipeline input. An empty answer
or invalid number throws.

```powershell
Select-CodexSession
Select-CodexSession -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
```

Output type and properties are the same as `Get-CodexSession`.

## Convert-CodexSession

Converts selected rollouts and validates each generated bundle. It does not
require OpenCode and does not modify OpenCode.

Parameter sets:

| Set | Required selection | Available selection-specific parameters | Common operation parameters |
| --- | --- | --- | --- |
| `Pipeline` | `InputObject` from the pipeline | `InputObject` (`Object`) | `DestinationDirectory`, `OutputDirectory` |
| `ById` | `SessionId` (`String[]`) | `SessionId`, `CodexDataRoot` | `DestinationDirectory`, `OutputDirectory` |
| `All` | `All` (`SwitchParameter`) | `All`, `CodexDataRoot` | `DestinationDirectory`, `OutputDirectory` |

`InputObject` binds by value and must have valid `Id` and `SourcePath`
properties, normally from `Get-CodexSession` or `Select-CodexSession`. Pipeline
objects are buffered and converted in `end`. `DestinationDirectory` is a
`String`, must identify an existing directory, and is valid only when exactly one
session is selected. Without it, each session's recorded `Directory` must exist.
`OutputDirectory` is a `String`; see [Output directories](#output-directories).

```powershell
Get-CodexSession -SessionId 'demo' |
    Convert-CodexSession -OutputDirectory (Join-Path $HOME 'exports')

Convert-CodexSession -All `
    -CodexDataRoot (Join-Path $HOME 'synthetic-codex') `
    -OutputDirectory ./artifacts/exports
```

Output type: `OpenCode.ImportCodex.ConversionResult`.

| Property | PowerShell type | Conversion value |
| --- | --- | --- |
| `CodexSessionId` | `String` | Source Codex ID. |
| `OpenCodeSessionId` | `String` | Deterministically generated target ID. |
| `Action` | `String` | `Converted`. |
| `ExistingMessages` | `Int32` | `0`. |
| `NewMessages` | `Int32` | Number of generated messages. |
| `NewParts` | `Int32` | Number of generated parts. |
| `OpenCodeOnlyMessages` | `Int32` | `0`. |
| `ChangedMessages` | `Int32` | `0` for conversion-only results. |
| `ChangedParts` | `Int32` | `0` for conversion-only results. |
| `Directory` | `String` | Resolved target working directory. |
| `BundlePath` | `String` | Generated JSON bundle path. |
| `Imported` | `Boolean` | `False`. |

## Get-CodexSessionImportPlan

Converts and validates selected sessions, inventories OpenCode, and compares
deterministic generated IDs with an existing exported session. It requires the
OpenCode CLI. It writes bundles but does not import them.

Its `Pipeline`, `ById`, and `All` parameter sets, parameter types, buffering, and
target-directory rules exactly match `Convert-CodexSession`.

```powershell
Get-CodexSession -SessionId 'demo' |
    Get-CodexSessionImportPlan -OutputDirectory ./artifacts/plans

Get-CodexSessionImportPlan -SessionId 'codex://threads/demo-session' `
    -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
```

Output type: `OpenCode.ImportCodex.ImportPlan`. It has the same twelve properties
and types as `ConversionResult`, with these plan values:

| Property | Plan value |
| --- | --- |
| `Action` | `Create` when absent, `Append/no-op` when matching content is unchanged, or `Conflict` when matching IDs changed. |
| `ExistingMessages` | Count in the existing OpenCode export. |
| `NewMessages` | Generated message IDs absent from OpenCode. |
| `NewParts` | Generated part IDs absent from OpenCode. |
| `OpenCodeOnlyMessages` | Existing message IDs absent from the generated bundle. |
| `ChangedMessages` | Matching message IDs whose canonical message metadata differs. |
| `ChangedParts` | Matching part IDs whose canonical content differs. |
| `Imported` | `False`. |

Changed content produces `Action = 'Conflict'`. Planning also rejects a matching
deterministic session ID that belongs to another target directory. The official
importer is effectively insert-only for existing deterministic message and part
IDs, so a conflict is a diagnostic rather than an in-place update mechanism.

## Import-CodexSession

Converts, validates, imports through OpenCode from the target working directory,
and verifies the resulting ID and directory.

Its `Pipeline`, `ById`, and `All` parameter sets and operation parameters match
`Convert-CodexSession`. It additionally exposes the standard `WhatIf` and
`Confirm` common parameters because it declares `SupportsShouldProcess` with
`ConfirmImpact = 'High'`.

```powershell
Import-CodexSession -SessionId 'demo' -WhatIf

Get-CodexSession -SessionId 'demo' |
    Import-CodexSession `
        -DestinationDirectory (Join-Path $HOME 'projects/relocated') `
        -Confirm:$false
```

Output type: `OpenCode.ImportCodex.ImportResult`. It has the same twelve properties
and types as `ConversionResult`; a successful result has `Action = 'Imported'`
and `Imported = True`. The count fields retain conversion result values rather
than a plan comparison.

Import rejects an existing deterministic session ID associated with another
directory before conversion or live OpenCode modification. It also rejects a
content-conflict plan. Applying a corrected representation requires a separately
approved removal and reimport after checking `OpenCodeOnlyMessages`; matching
same-ID parts are not overwritten by ordinary import.

## Get-OpenCodeSession

Uses a read-only query through `opencode db` to return OpenCode root sessions,
ordered by OpenCode update time. The OpenCode CLI is required.

Syntax:

```powershell
Get-OpenCodeSession [[-SessionId] <String[]>]
```

`SessionId` is an optional `String[]` of exact OpenCode IDs or unique prefixes.
This command does not accept pipeline input.

```powershell
Get-OpenCodeSession
Get-OpenCodeSession -SessionId 'ses_demo'
```

Output type: `OpenCode.ImportCodex.OpenCodeSession`.

| Property | PowerShell type | Meaning |
| --- | --- | --- |
| `Id` | `String` | OpenCode session ID. |
| `Title` | `String` | Session title. |
| `Updated` | `DateTimeOffset` | Converted OpenCode update timestamp. |
| `Created` | `DateTimeOffset` | Converted OpenCode creation timestamp. |
| `ProjectId` | `String` | OpenCode project ID. |
| `Directory` | `String` | Associated working directory. |

## Remove-OpenCodeSession

Permanently deletes OpenCode root sessions through the OpenCode CLI and verifies
that their IDs are no longer present.

Parameter sets:

| Set | Parameters | Pipeline behavior |
| --- | --- | --- |
| `ById` | Mandatory `SessionId` (`String[]`) | None. Exact IDs and unique prefixes are resolved against current inventory. |
| `Pipeline` | Mandatory `InputObject` (`Object`) | Binds by value, buffers objects, reads each `Id`, then resolves against current inventory. |
| `All` | Mandatory `All` (`SwitchParameter`), optional `Force` (`SwitchParameter`) | None. Selects every root session. |

```powershell
Remove-OpenCodeSession -SessionId 'ses_demo' -WhatIf

Get-OpenCodeSession -SessionId 'ses_demo' |
    Remove-OpenCodeSession -Confirm:$false
```

Output type: `OpenCode.ImportCodex.OpenCodeSession`, with the same properties and
types returned by `Get-OpenCodeSession`. Only successfully submitted and verified
removed targets are returned.

## Test-CodexOpenCodeEnvironment

Returns best-effort environment diagnostics. It checks application command
discovery and versions, candidate desktop locations, and Codex session directory
availability. It does not convert, import, install, or download anything.

Syntax:

```powershell
Test-CodexOpenCodeEnvironment [[-CodexDataRoot] <String>]
```

```powershell
Test-CodexOpenCodeEnvironment
Test-CodexOpenCodeEnvironment -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
```

Output type: `OpenCode.ImportCodex.EnvironmentDiagnostic`.

| Property | PowerShell type | Meaning |
| --- | --- | --- |
| `Platform` | `String` | `Windows`, `macOS`, or `Linux`. |
| `CodexDataRoot` | `String` | Resolved Codex root. |
| `CodexSessionsPath` | `String` | Expected `sessions` child path. |
| `CodexSessionsAvailable` | `Boolean` | Whether that child is an existing directory. |
| `CodexCli` | `PSCustomObject` | `Installed` (`Boolean`), `Path` (`String`), and `Version` (`String`). |
| `OpenCodeCli` | `PSCustomObject` | `Installed` (`Boolean`), `Path` (`String`), and `Version` (`String`). |
| `CodexDesktop` | `Object[]` of `String` | Existing candidate, registry, package, or launcher entries. |
| `OpenCodeDesktop` | `Object[]` of `String` | Existing candidate, registry, package, or launcher entries. |

## ShouldProcess Semantics

`Import-CodexSession` and `Remove-OpenCodeSession` are the only commands with
`SupportsShouldProcess`; both have high confirmation impact.

- `Import-CodexSession -WhatIf` resolves the CLI, selections, and target paths,
  but declines `ShouldProcess` before conversion. It creates no bundle and does
  not import.
- `Import-CodexSession -Confirm:$false` suppresses the standard high-impact
  prompt. It does not weaken validation or post-import verification.
- `Remove-OpenCodeSession -WhatIf` inventories and resolves targets but does not
  delete them.
- `Remove-OpenCodeSession -All` adds a literal `DELETE ALL` prompt unless
  `-Force` or `-WhatIf` is present.
- `-Force` suppresses only the literal all-session prompt. Standard
  `ShouldProcess` confirmation still applies; use `-Confirm:$false` separately
  only when intentional.
- `Convert-CodexSession` and `Get-CodexSessionImportPlan` do not implement
  `ShouldProcess`. Both intentionally create or replace plaintext bundles.

## Output Directories

When `OutputDirectory` is explicit, it is converted to a full path. Otherwise the
module uses `OpenCode.ImportCodex/exports` below user-local application data, or
falls back to `Join-Path $HOME '.opencode-import-codex/exports'`. One file named
`<CodexSessionId>.json` is written per selected session. Output cannot be equal to
or lexically inside the resolved Codex root.
