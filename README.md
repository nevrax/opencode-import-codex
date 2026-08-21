# Bring your Codex sessions to OpenCode

**OpenCode.ImportCodex** helps you continue local Codex conversations in
OpenCode—without losing the prompts, answers, commands, file changes, and tool
results that explain how the work happened.

It is a PowerShell module, it runs locally, and it never replays anything from
your history. You choose a session, preview the result, and decide whether to
import it.

> Independent community project. Not affiliated with or endorsed by OpenAI,
> Codex, or OpenCode.

## Keep more than the final diff

A coding session contains useful context that the finished files cannot show:
the question that started the work, the alternatives you explored, the commands
you ran, and the reason a change was made.

OpenCode.ImportCodex turns that history into a readable OpenCode session so you
can:

- Continue working with the earlier conversation available as context.
- Review prompts, responses, patches, and terminal output together.
- Keep historical shell, file, web, MCP, and plan activity visible as cards.
- Export a session to a validated JSON bundle without changing OpenCode.
- See what a later import would add or conflict with before it happens.

## What is preserved?

| From Codex | In OpenCode |
| --- | --- |
| Prompts and assistant responses | Conversation text in its original order. |
| Shell commands and saved output | Completed or failed shell cards. |
| File edits and patches | Structured file-change cards when details are available. |
| MCP, web, plan, and other tools | Specialized or generic historical tool cards. |
| Portable inline images | Image attachments. |
| Timestamps, usage, and compaction | Historical ordering and continuation context. |

Historical activity is displayable context, not a replay script. The importer
does not rerun commands, apply old patches, repeat network requests, call MCP
tools, or evaluate saved Codex code-mode JavaScript.

The [conversion guide](docs/Conversion.md) explains the exact mappings and
fidelity limits.

## Get started

You need:

- PowerShell 7 on Windows, macOS, or Linux; or Windows PowerShell 5.1.
- A local Codex session store.
- The OpenCode CLI for planning and importing. Conversion alone does not require
  OpenCode.

Download or clone the repository, open PowerShell in its root directory, and
load the module:

```powershell
Import-Module ./src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1 -Force
```

Check what is available on your machine:

```powershell
Test-CodexOpenCodeEnvironment
```

Choose a session:

```powershell
$session = Select-CodexSession
```

Preview what the import would do:

```powershell
$session | Get-CodexSessionImportPlan
```

Import when you are ready:

```powershell
$session | Import-CodexSession
```

Import is a high-impact PowerShell operation and asks for confirmation. To check
the command without creating a bundle or changing OpenCode, use:

```powershell
$session | Import-CodexSession -WhatIf
```

If the project has moved, select another existing directory:

```powershell
$session | Import-CodexSession -DestinationDirectory ./path/to/project
```

Need only a bundle? This converts the session without modifying OpenCode:

```powershell
$session | Convert-CodexSession -OutputDirectory ./exports
```

## Local by design

The module reads Codex rollout files and `session_index.jsonl` without changing
them. Conversion uses PowerShell and .NET and performs no network requests.
Imports go through your installed `opencode` command instead of editing its
database directly.

Deterministic IDs let the module recognize previously imported history. A plan
can report `Create`, `Append/no-op`, or `Conflict`, helping you understand the
result before OpenCode changes.

## Keep private history private

Generated bundles are plaintext JSON. They can contain prompts, source code,
commands, tool output, images, local paths, and secrets that appeared in the
original session. Inspect bundles before sharing them and remove them when you no
longer need them.

OpenCode import is effectively insert-only for matching deterministic message
and part IDs. Changed historical content can be reported as a conflict without
being overwritten. Before deleting and re-importing, check for OpenCode-only
continuation that you want to keep.

Read the [security policy](SECURITY.md) before working with sensitive histories
or replacing an earlier import.

## Documentation

The README is the front door; the detailed guides live here:

| Guide | What you will find |
| --- | --- |
| [Commands](docs/Commands.md) | Installation, every command and parameter, examples, and returned objects. |
| [Conversion](docs/Conversion.md) | How conversations, cards, images, compaction, and IDs are translated. |
| [Architecture](docs/Architecture.md) | Repository layout, data flow, boundaries, and source responsibilities. |
| [Testing](docs/Testing.md) | Local tests, isolated OpenCode verification, generators, and benchmarks. |
| [Security](SECURITY.md) | Plaintext data, source protection, replacement risks, and safe handling. |
| [Contributing](CONTRIBUTING.md) | Project conventions and synthetic-data requirements. |

PowerShell can also show help directly:

```powershell
Get-Command -Module OpenCode.ImportCodex
Get-Help Import-CodexSession -Full
```

## Test locally

Run the complete repository suite from the project root:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny
```

Include an isolated OpenCode import/export round trip when the CLI is available:

```powershell
./tests/Invoke-AllTests.ps1 -Preset Tiny -TestOpenCodeImport
```

Tests use synthetic sessions and isolated generated directories, not your normal
Codex or OpenCode data.

## Contributing

Contributions are welcome. Please use synthetic fixtures only and run the local
test suite before submitting changes. Start with the
[contributing guide](CONTRIBUTING.md).

## License

OpenCode.ImportCodex is available under the [MIT License](LICENSE).
