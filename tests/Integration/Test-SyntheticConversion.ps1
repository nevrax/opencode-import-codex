[CmdletBinding()]
param(
    [ValidateSet('Tiny', 'Small', 'Medium')]
    [string]$Preset = 'Tiny',
    [switch]$TestOpenCodeImport,
    [switch]$KeepGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleManifest = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1'
$Generator = Join-Path $TestsRoot 'Support/New-SyntheticCodexData.ps1'
$GeneratedRoot = Join-Path $TestsRoot '.generated/test-run'
$GeneratedMarker = Join-Path $GeneratedRoot '.synthetic-test-run'
$CodexRoot = Join-Path $GeneratedRoot 'codex'
$OutputRoot = Join-Path $GeneratedRoot 'outputs'
$RichCodexRoot = Join-Path $TestsRoot 'Fixtures/ComplexLegacy/Codex'
$PaginatedCodexRoot = Join-Path $GeneratedRoot 'paginated codex store'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Read-Bundle {
    param([string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Get-BundleIds {
    param($Bundle)
    @(
        $Bundle.info.id
        @($Bundle.messages | ForEach-Object { $_.info.id })
        @($Bundle.messages | ForEach-Object { @($_.parts) } | ForEach-Object { $_.id })
        @($Bundle.messages | ForEach-Object { @($_.parts) } | Where-Object type -eq 'tool' | ForEach-Object { $_.callID })
    )
}

function ConvertTo-TestCanonicalData {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) { $result[$key] = ConvertTo-TestCanonicalData $Value[$key] }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = ConvertTo-TestCanonicalData $property.Value }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return ,@($Value | ForEach-Object { ConvertTo-TestCanonicalData $_ }) }
    $Value
}

function ConvertTo-TestCanonicalJson {
    param($Value)
    ConvertTo-TestCanonicalData $Value | ConvertTo-Json -Depth 100 -Compress
}

function Assert-BundleIdChronology {
    param($Bundle, [string]$Description)
    $previousMessageId = ''
    $previousCreated = [int64]::MinValue
    foreach ($message in @($Bundle.messages)) {
        $messageId = [string]$message.info.id
        $created = [int64]$message.info.time.created
        Assert-True ($messageId -cmatch '^msg_[0-9a-f]{26}$') "$Description message ID has the wrong shape: $messageId"
        Assert-True ($created -ge $previousCreated) "$Description message creation times must be monotonic"
        if ($previousMessageId) {
            Assert-True ([string]::CompareOrdinal($previousMessageId, $messageId) -lt 0) "$Description message IDs must be in strict lexical chronology"
        }
        $previousMessageId = $messageId
        $previousCreated = $created
        $previousPartId = ''
        foreach ($part in @($message.parts)) {
            $partId = [string]$part.id
            Assert-True ($partId -cmatch '^prt_[0-9a-f]{26}$') "$Description part ID has the wrong shape: $partId"
            if ($previousPartId) {
                Assert-True ([string]::CompareOrdinal($previousPartId, $partId) -lt 0) "$Description part IDs must be strictly lexical within each message"
            }
            $previousPartId = $partId
        }
    }
    Assert-True ([int64]$Bundle.info.time.updated -ge $previousCreated) "$Description session update time must not precede its messages"
}

function Write-JsonLines {
    param([string]$Path, [object[]]$Rows)
    $lines = @($Rows | ForEach-Object { $_ | ConvertTo-Json -Depth 100 -Compress })
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
}

if (Test-Path -LiteralPath $GeneratedRoot) {
    if (-not (Test-Path -LiteralPath $GeneratedMarker -PathType Leaf)) {
        throw "Refusing to replace an unmarked generated test directory: $GeneratedRoot"
    }
    Remove-Item -LiteralPath $GeneratedRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $GeneratedRoot | Out-Null
[System.IO.File]::WriteAllText($GeneratedMarker, 'Generated synthetic test data only.', [System.Text.UTF8Encoding]::new($false))

try {
    Import-Module $ModuleManifest -Force
    Write-Host "Creating isolated $Preset synthetic Codex data..." -ForegroundColor Cyan
    $generatedManifest = & $Generator -OutputDirectory $CodexRoot -Preset $Preset `
        -IncludeUnicode -IncompleteFinalToolCall -Force
    $settings = $generatedManifest.settings

    $paginatedSessionId = 'paginated-synthetic'
    $paginatedTurnId = 'turn-paginated-synthetic'
    $paginatedTarget = Join-Path $GeneratedRoot 'paginated destination with spaces'
    $paginatedSessionDirectory = Join-Path $PaginatedCodexRoot 'sessions/2026/02/03'
    New-Item -ItemType Directory -Force -Path $paginatedSessionDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $paginatedTarget | Out-Null
    $paginatedSource = Join-Path $paginatedSessionDirectory 'rollout-paginated-synthetic.jsonl'
    $longOpaqueText = 'Opaque outer paginated output head.' + ('x' * 5000) + 'Opaque outer paginated output tail.'
    $longOpaqueOutput = @(
        [ordered]@{ type = 'input_text'; text = "Script completed`n" },
        [ordered]@{ type = 'output_text'; text = $longOpaqueText }
    ) | ConvertTo-Json -Depth 10 -Compress
    $paginatedRows = @(
        [ordered]@{ timestamp = '2026-08-13T04:05:06.000Z'; type = 'session_meta'; payload = [ordered]@{ id = $paginatedSessionId; timestamp = '2026-08-13T04:05:06.000Z'; cwd = $paginatedTarget; history_mode = 'paginated'; originator = 'synthetic-test' } },
        @{ timestamp = '2026-08-13T04:05:06.010Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = 'Exercise paginated typed items.' }) } },
        @{ timestamp = '2026-08-15T04:05:06.020Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'Preserving typed tool history.' }) } },
        @{ timestamp = '2026-08-15T04:05:06.030Z'; type = 'response_item'; payload = @{ type = 'custom_tool_call'; name = 'exec'; call_id = 'outer-paginated-exec'; input = 'const result = await tools.shell_command({ command: ''outer command'' }); text(result);'; internal_chat_message_metadata_passthrough = @{ turn_id = $paginatedTurnId } } },
        @{ timestamp = '2026-08-15T04:05:06.040Z'; type = 'response_item'; payload = @{ type = 'custom_tool_call_output'; call_id = 'outer-paginated-exec'; output = $longOpaqueOutput } },
        @{ timestamp = '2026-02-03T04:05:06.050Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; started_at_ms = 1770091506050; completed_at_ms = 1770091506060; item = @{ type = 'CommandExecution'; id = 'typed-command'; command = @('printf', '%s', 'hello world', "it's"); cwd = 'file:///C:/synthetic%20project'; parsed_cmd = @(@{ type = 'unknown'; cmd = 'printf' }); source = 'agent'; status = 'completed'; aggregated_output = 'typed command output'; exit_code = 7; duration = @{ secs = 0; nanos = 10000000 } } } },
        @{ timestamp = '2026-02-03T04:05:06.055Z'; type = 'response_item'; payload = @{ type = 'custom_tool_call'; name = 'exec'; call_id = 'outer-bracketed-patch'; input = 'const result = await tools.apply_patch({ patch: ''synthetic'' }); text(result);'; internal_chat_message_metadata_passthrough = @{ turn_id = $paginatedTurnId } } },
        @{ timestamp = '2026-02-03T04:05:06.060Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506070; item = @{ type = 'FileChange'; id = 'typed-patch'; status = 'completed'; stdout = 'typed patch output'; stderr = ''; changes = [ordered]@{
            'alpha.txt' = @{ type = 'update'; unified_diff = "@@ -1 +1 @@`n-old alpha`n+new alpha"; move_path = $null }
            'updated.txt' = @{ type = 'update'; unified_diff = "--- a/updated.txt`n+++ b/updated.txt`n@@ -1 +1,2 @@`n-old`n+new`n+line"; move_path = $null }
            'deleted.txt' = @{ type = 'delete'; content = "gone`nlines`n" }
            'Zeta.txt' = @{ type = 'update'; unified_diff = "@@ -1 +1 @@`n-old zeta`n+new zeta"; move_path = $null }
            'before-name.txt' = @{ type = 'update'; unified_diff = "--- a/before-name.txt`n+++ b/after-name.txt`n@@ -1 +1 @@`n-before`n+after"; move_path = 'after-name.txt' }
            'added.txt' = @{ type = 'add'; content = "alpha`nbeta`n" }
        } } } },
        @{ timestamp = '2026-02-03T04:05:06.065Z'; type = 'response_item'; payload = @{ type = 'custom_tool_call_output'; call_id = 'outer-bracketed-patch'; output = 'Duplicate outer patch output.' } },
        @{ timestamp = '2026-02-03T04:05:06.070Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506080; item = @{ type = 'McpToolCall'; id = 'typed-mcp'; server = 'safe server'; tool = 'inspect/item'; arguments = @{ depth = 2; enabled = $true }; result = @{ content = @(@{ type = 'text'; text = 'typed MCP result' }); structuredContent = @{ retained = $true }; isError = $false }; status = 'completed' } } },
        @{ timestamp = '2026-02-03T04:05:06.075Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506085; item = @{ type = 'McpToolCall'; id = 'typed-mcp-error'; server = 'safe server'; tool = 'fail/item'; arguments = @{ fail = $true }; result = @{ content = @(@{ type = 'text'; text = 'typed MCP failure' }); isError = $true }; status = 'completed' } } },
        @{ timestamp = '2026-02-03T04:05:06.080Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506090; item = @{ type = 'Extension'; kind = 'web.search'; id = 'typed-web'; query = 'typed query'; action = @{ type = 'search'; query = 'typed query'; queries = $null }; results = @(@{ title = 'Typed result'; url = 'https://example.invalid/typed'; snippet = 'typed web output' }) } } },
        @{ timestamp = '2026-02-03T04:05:06.090Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506100; item = @{ type = 'ImageView'; id = 'typed-image'; path = 'file:///tmp/image%20sample.png' } } },
        @{ timestamp = '2026-02-03T04:05:06.100Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506110; item = @{ type = 'DynamicToolCall'; id = 'typed-dynamic'; namespace = 'safe namespace'; tool = 'lookup/item'; arguments = @{ key = 'typed-key' }; content_items = @(@{ type = 'inputText'; text = 'typed dynamic output' }, @{ type = 'inputImage'; imageUrl = 'https://example.invalid/image.png' }, @{ type = 'inputAudio'; audioUrl = 'https://example.invalid/audio.wav' }); success = $true; status = 'completed' } } },
        @{ timestamp = '2026-02-03T04:05:06.105Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506115; item = @{ type = 'Plan'; id = 'typed-plan'; text = '1. Preserve exact history.' } } },
        @{ timestamp = '2026-02-03T04:05:06.106Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506116; item = @{ type = 'Extension'; kind = 'clock.sleep'; id = 'typed-sleep'; durationMs = 25 } } },
        @{ timestamp = '2026-02-03T04:05:06.110Z'; type = 'event_msg'; payload = @{ type = 'item_completed'; thread_id = $paginatedSessionId; turn_id = $paginatedTurnId; completed_at_ms = 1770091506120; item = @{ type = 'DynamicToolCall'; id = 'typed-dynamic'; namespace = 'duplicate'; tool = 'must-not-emit'; arguments = @{ duplicate = $true }; content_items = @(@{ type = 'text'; text = 'duplicate typed output' }); success = $true; status = 'completed' } } },
        @{ timestamp = '2026-02-03T04:05:06.112Z'; type = 'compacted'; payload = @{ message = ''; replacement_history = @(
            @{ type = 'compaction'; id = 'encrypted-synthetic-checkpoint'; encrypted_content = 'synthetic-not-a-real-provider-payload'; internal_chat_message_metadata_passthrough = @{} },
            @{ type = 'message'; id = 'retained-developer'; role = 'developer'; content = @(@{ type = 'input_text'; text = 'Synthetic retained developer instruction.' }); internal_chat_message_metadata_passthrough = @{} },
            @{ type = 'message'; id = 'retained-user'; role = 'user'; content = @(@{ type = 'input_text'; text = 'Synthetic retained user context.' }, @{ type = 'input_image'; image_url = 'data:image/png;base64,c3ludGhldGlj' }); internal_chat_message_metadata_passthrough = @{} }
        ); window_number = 1; first_window_id = 'window-synthetic'; previous_window_id = $null; window_id = 'window-synthetic' } },
        @{ timestamp = '2026-02-03T04:05:06.113Z'; type = 'event_msg'; payload = @{ type = 'context_compacted' } },
        @{ timestamp = '2026-02-03T04:05:06.015Z'; type = 'response_item'; payload = @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = 'A regressing source timestamp must not reorder stored messages.' }) } }
    )
    Write-JsonLines -Path $paginatedSource -Rows $paginatedRows
    Write-JsonLines -Path (Join-Path $PaginatedCodexRoot 'session_index.jsonl') -Rows @(
        @{ id = $paginatedSessionId; thread_name = 'Paginated typed synthetic'; updated_at = '2026-02-03T04:05:06.110Z' }
    )

    $allSessions = @(Get-CodexSession -CodexDataRoot $CodexRoot)
    Assert-True ($allSessions.Count -eq [int]$settings.sessions) 'Get-CodexSession should return every generated session'
    $session = $allSessions[0]

    $oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    try {
        $env:CODEX_HOME = $CodexRoot
        $homeSessions = @(Get-CodexSession)
        Assert-True ($homeSessions.Count -eq $allSessions.Count) 'CODEX_HOME should select the generated Codex root'
        Assert-True ($homeSessions[0].Id -eq $session.Id) 'CODEX_HOME should return the generated session'
    } finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldCodexHome }
    }

    $destinationWithSpaces = Join-Path $GeneratedRoot 'generated destination with spaces'
    New-Item -ItemType Directory -Force -Path $destinationWithSpaces | Out-Null
    $byId = Convert-CodexSession -SessionId $session.Id -CodexDataRoot $CodexRoot `
        -DestinationDirectory $destinationWithSpaces -OutputDirectory (Join-Path $OutputRoot 'by-id')
    $all = @(Convert-CodexSession -All -CodexDataRoot $CodexRoot -OutputDirectory (Join-Path $OutputRoot 'all'))
    $deeplink = Convert-CodexSession -SessionId "codex://threads/$($session.Id)" -CodexDataRoot $CodexRoot `
        -DestinationDirectory $destinationWithSpaces -OutputDirectory (Join-Path $OutputRoot 'deeplink')
    $selectedByDeepLink = @(Get-CodexSession -SessionId "codex://threads/$($session.Id)" -CodexDataRoot $CodexRoot)
    $pipeline = $session | Convert-CodexSession -DestinationDirectory $destinationWithSpaces `
        -OutputDirectory (Join-Path $OutputRoot 'pipeline')

    Assert-True ($all.Count -eq $allSessions.Count) '-All should convert every generated session'
    Assert-True ($selectedByDeepLink.Count -eq 1 -and $selectedByDeepLink[0].Id -eq $session.Id) 'Get-CodexSession should resolve a deeplink'
    Assert-True ($byId.CodexSessionId -eq $session.Id) 'ById should convert the selected session'
    Assert-True ($deeplink.CodexSessionId -eq $session.Id) 'Convert-CodexSession should resolve a deeplink'
    Assert-True ($pipeline.CodexSessionId -eq $session.Id) 'pipeline input should convert the selected session'
    Assert-True ($pipeline.Directory -eq (Resolve-Path -LiteralPath $destinationWithSpaces).Path) 'destination paths containing spaces should be preserved'

    $generatedBundle = Read-Bundle $pipeline.BundlePath
    $generatedMessages = @($generatedBundle.messages)
    $generatedParts = @($generatedMessages | ForEach-Object { @($_.parts) })
    $generatedText = @($generatedParts | Where-Object type -eq 'text')
    $generatedTools = @($generatedParts | Where-Object type -eq 'tool')
    $byIdBundle = Read-Bundle $byId.BundlePath
    $expectedMessages = [int]$settings.turns * 2
    $expectedText = [int]$settings.turns * 3
    $expectedTools = [int]$settings.turns * [int]$settings.toolCallsPerTurn
    Assert-True ($generatedBundle.info.id.StartsWith('ses_')) 'generated bundle session ID must use the OpenCode prefix'
    Assert-True ($generatedMessages.Count -eq $expectedMessages) "expected $expectedMessages generated messages, got $($generatedMessages.Count)"
    Assert-True ($generatedText.Count -eq $expectedText) "expected $expectedText generated text parts, got $($generatedText.Count)"
    Assert-True ($generatedTools.Count -eq $expectedTools) "expected $expectedTools generated tool parts, got $($generatedTools.Count)"
    $latestGeneratedAssistant = @($generatedMessages | Where-Object { $_.info.role -eq 'assistant' })[-1]
    Assert-True ([int64]$latestGeneratedAssistant.info.tokens.total -eq 140) 'Codex total token usage should be preserved on the corresponding assistant message'
    Assert-True ([int64]$latestGeneratedAssistant.info.tokens.input -eq 60 -and [int64]$latestGeneratedAssistant.info.tokens.output -eq 25) 'Codex input and output usage should exclude cache and reasoning tokens like OpenCode usage'
    Assert-True ([int64]$latestGeneratedAssistant.info.tokens.cache.read -eq 40 -and [int64]$latestGeneratedAssistant.info.tokens.cache.write -eq 10 -and [int64]$latestGeneratedAssistant.info.tokens.reasoning -eq 5) 'Codex cache and reasoning usage should retain their OpenCode fields'
    Assert-BundleIdChronology $generatedBundle 'generated bundle'
    Assert-True (((Get-BundleIds $byIdBundle) -join "`n") -ceq ((Get-BundleIds $generatedBundle) -join "`n")) 'repeated generated conversion should produce deterministic IDs'
    Assert-True (-not (($generatedText.text -join "`n") -match 'PRIVATE_DATA_CANARY_(USER|PROJECT|SESSION)')) 'generated data unexpectedly contains a private-data canary'
    $allGeneratedText = $generatedText.text -join "`n"
    $expectedUnicodeWords = 'caf{0} na{1}ve {2}{3} {4}{5}{6}{7}{8}{9}' -f @(
        [char]0x00e9,
        [char]0x00ef,
        [char]0x6771,
        [char]0x4eac,
        [char]0x03b4,
        [char]0x03bf,
        [char]0x03ba,
        [char]0x03b9,
        [char]0x03bc,
        [char]0x03ae
    )
    Assert-True $allGeneratedText.Contains($expectedUnicodeWords) 'generated Unicode text should survive conversion exactly'
    $incompleteTools = @($generatedTools | Where-Object {
        $_.state.status -eq 'error' -and
        [string]$_.state.error -eq 'Tool call ended before a result was recorded.'
    })
    Assert-True ($incompleteTools.Count -eq 1) 'one incomplete generated tool call should become an error-state tool part'

    $richSession = @(Get-CodexSession -CodexDataRoot $RichCodexRoot)[0]
    $richTarget = Join-Path $GeneratedRoot 'rich fixture destination with spaces'
    $richOutput = Join-Path $OutputRoot 'rich'
    New-Item -ItemType Directory -Force -Path $richTarget | Out-Null
    $firstRichResult = $richSession | Convert-CodexSession -DestinationDirectory $richTarget -OutputDirectory $richOutput
    $firstRich = Read-Bundle $firstRichResult.BundlePath
    $firstRichIds = Get-BundleIds $firstRich

    # The same public conversion and output path exercises atomic replacement.
    $secondRichResult = $richSession | Convert-CodexSession -DestinationDirectory $richTarget -OutputDirectory $richOutput
    $rich = Read-Bundle $secondRichResult.BundlePath
    $secondRichIds = Get-BundleIds $rich
    $richParts = @($rich.messages | ForEach-Object { @($_.parts) })
    Assert-BundleIdChronology $rich 'rich bundle'
    Assert-True (@($rich.messages).Count -eq 2) 'rich fixture should produce two messages'
    Assert-True (($firstRichIds -join "`n") -ceq ($secondRichIds -join "`n")) 'repeated conversion should produce deterministic session, message, part, and call IDs'
    Assert-True (@($richParts | Where-Object type -eq 'text').Count -eq 6) 'rich fixture should produce four transcript text parts and two synthetic code-mode archive notes'
    Assert-True (@($richParts | Where-Object type -eq 'tool').Count -eq 5) 'rich fixture should preserve five independently evidenced native tool parts without opaque code-mode cards'
    Assert-True (@($richParts | Where-Object type -eq 'file').Count -eq 1) 'rich fixture should preserve one image part'
    Assert-True ([int]$secondRichResult.NewParts -eq $richParts.Count) 'conversion results should report the generated part count'

    $richTools = @($richParts | Where-Object type -eq 'tool')
    Assert-True (-not @($richTools | Where-Object tool -eq 'codex_exec').Count) 'no obsolete codex_exec tool name should be emitted'
    Assert-True (-not @($richTools | Where-Object tool -eq 'codex_code_mode').Count) 'opaque code-mode history must not render as OpenCode tool cards'
    $codeModeArchives = @($richParts | Where-Object { $_.type -eq 'text' -and $_.PSObject.Properties['synthetic'] -and [bool]$_.synthetic -and [string]$_.metadata.codex.kind -eq 'code_mode_archive' })
    Assert-True ($codeModeArchives.Count -eq 2) 'rich fixture should preserve two opaque execution groups as synthetic context archives'
    $richMessagesById = @{}
    foreach ($message in @($rich.messages)) { $richMessagesById[[string]$message.info.id] = $message }
    foreach ($archive in $codeModeArchives) {
        Assert-True ([string]$richMessagesById[[string]$archive.messageID].info.role -eq 'user') 'every code-mode archive must attach to its originating user message'
        Assert-True (-not $archive.PSObject.Properties['ignored']) 'code-mode archives must not rely on the ignored field, which changes model projection semantics'
        Assert-True (@($archive.metadata.codex.executions).Count -ge 1) 'every archive must retain at least one exact opaque execution'
    }
    $codeModeArchive = @($codeModeArchives | Where-Object { @($_.metadata.codex.executions | Where-Object source -match 'tools\.update_plan').Count })[0]
    Assert-True ($null -ne $codeModeArchive) 'rich fixture should preserve the plan code-mode call'
    Assert-True ([string]$codeModeArchive.text -match '1 opaque Codex code-mode execution' -and [string]$codeModeArchive.text -match 'intentionally excluded from model context') 'synthetic context should disclose the model/archive boundary'
    Assert-True ([string]$codeModeArchive.metadata.codex.modelRepresentation -eq 'count_only_synthetic_note' -and [string]$codeModeArchive.metadata.codex.outputRepresentation -eq 'metadata_only') 'code-mode metadata should identify the exact representation'
    Assert-True ([string]$codeModeArchive.metadata.codex.executions[0].callId -eq 'call_synthetic_code_mode_plan') 'plan archive should retain the original call ID'
    Assert-True ([string]$codeModeArchive.metadata.codex.executions[0].source -eq 'const result = await tools.update_plan({ plan: [] }); text(result);') 'plan archive should retain full nonempty source'
    Assert-True ([string]$codeModeArchive.metadata.codex.executions[0].outputs[0] -eq '{}') 'plan archive metadata should retain the exact outer output'
    Assert-True (-not ([string]$codeModeArchive.text -match 'tools\.update_plan|\{\}')) 'raw source and output must not be promoted into model-visible synthetic context'
    $staleArchive = @($codeModeArchives | Where-Object { @($_.metadata.codex.executions | Where-Object source -match 'tools\.shell_command').Count })[0]
    Assert-True ($null -ne $staleArchive) 'an unrelated later event must not suppress a stale code-mode call'
    Assert-True ([string]$staleArchive.metadata.codex.executions[0].callId -eq 'call_synthetic_stale_code_mode') 'stale archive should retain its original call ID'
    Assert-True ([string]$staleArchive.metadata.codex.executions[0].source -eq 'const result = await tools.shell_command({ command: ''synthetic'' }); text(result);') 'stale archive should retain full nonempty source'
    Assert-True ([string]$staleArchive.metadata.codex.executions[0].outputs[0] -eq 'Synthetic stale code-mode output.') 'stale archive should retain the exact output'
    Assert-True ((@($codeModeArchives | ForEach-Object { [string]$_.metadata.codex.executions[0].callId }) -join ',') -ceq 'call_synthetic_stale_code_mode,call_synthetic_code_mode_plan') 'unrelated code-mode archives should retain source chronology'
    Assert-True (-not (($richParts | ConvertTo-Json -Depth 100 -Compress) -match 'call_synthetic_code_mode_(patch|mcp|web)')) 'opaque wrappers bracketing authoritative legacy events should be suppressed'
    $patchParts = @($richParts | Where-Object { $_.type -eq 'tool' -and $_.tool -eq 'apply_patch' })
    Assert-True ($patchParts.Count -eq 2) 'duplicate patch completion events should emit one card per unique call ID'
    $patchPart = @($patchParts | Where-Object { [string]$_.state.metadata.codex.source -eq 'patch_apply_end' })[0]
    Assert-True ($null -ne $patchPart) 'authoritative Codex patch events should become structured patch parts'
    Assert-True (@($patchPart.state.metadata.files).Count -eq 1) 'structured patch metadata should preserve changed files'
    Assert-True ($null -eq $patchPart.state.metadata.codex.PSObject.Properties['codeMode']) 'a patch must not claim an opaque outer execution without call-level evidence'
    $mcpPart = @($richParts | Where-Object { $_.type -eq 'tool' -and $_.tool -eq 'mcp__synthetic__inspect' })[0]
    Assert-True ($null -ne $mcpPart) 'authoritative MCP completion events should become structured MCP parts'
    Assert-True ([string]$mcpPart.state.output -eq 'Synthetic MCP output.') 'MCP output should be preserved'
    Assert-True ($null -eq $mcpPart.state.metadata.codex.PSObject.Properties['codeMode']) 'MCP history must not claim an opaque outer execution without call-level evidence'
    $webPart = @($richParts | Where-Object { $_.type -eq 'tool' -and $_.tool -eq 'websearch' })[0]
    Assert-True ($null -ne $webPart) 'authoritative web completion events should become structured web parts'
    Assert-True ([string]$webPart.state.input.query -eq 'synthetic query') 'web query should be preserved'
    Assert-True ($null -eq $webPart.state.metadata.codex.PSObject.Properties['codeMode']) 'web history must not claim an opaque outer execution without call-level evidence'
    Assert-True (-not ((@($richParts | Where-Object type -eq 'tool').state.output -join "`n") -match 'Synthetic duplicate should be ignored')) 'duplicate event output should not be rendered'

    $paginatedSession = @(Get-CodexSession -SessionId $paginatedSessionId -CodexDataRoot $PaginatedCodexRoot)[0]
    Assert-True ($null -ne $paginatedSession -and $paginatedSession.Id -eq $paginatedSessionId) 'public discovery should find the isolated paginated session'
    $paginatedOutput = Join-Path $OutputRoot 'paginated'
    $firstPaginatedResult = $paginatedSession | Convert-CodexSession -DestinationDirectory $paginatedTarget -OutputDirectory $paginatedOutput
    $firstPaginated = Read-Bundle $firstPaginatedResult.BundlePath
    $secondPaginatedResult = $paginatedSession | Convert-CodexSession -DestinationDirectory $paginatedTarget -OutputDirectory $paginatedOutput
    $paginated = Read-Bundle $secondPaginatedResult.BundlePath
    Assert-True (((Get-BundleIds $firstPaginated) -join "`n") -ceq ((Get-BundleIds $paginated) -join "`n")) 'repeated paginated conversion should produce deterministic IDs'
    Assert-BundleIdChronology $paginated 'paginated bundle'
    $paginatedParts = @($paginated.messages | ForEach-Object { @($_.parts) })
    $paginatedTools = @($paginatedParts | Where-Object type -eq 'tool')
    $paginatedToolNames = @($paginatedTools | ForEach-Object tool)
    Assert-True ($paginatedTools.Count -eq 9) 'paginated history should preserve eight typed items and one MCP failure without an opaque tool card, and suppress its duplicate item ID'
    Assert-True (-not @($paginatedTools | Where-Object tool -eq 'codex_exec').Count) 'obsolete codex_exec cards must not be emitted'
    Assert-True (-not @($paginatedTools | Where-Object tool -eq 'codex_code_mode').Count) 'paginated opaque history must not render as a tool card'
    Assert-True (($paginatedToolNames -join "`n") -ceq (@('bash', 'apply_patch', 'mcp__safe_server__inspect_item', 'mcp__safe_server__fail_item', 'websearch', 'read', 'dynamic__safe_namespace__lookup_item', 'codex_plan', 'codex_item') -join "`n")) 'paginated native tools should retain expected names and source order'
    Assert-True (-not (($paginatedParts | ConvertTo-Json -Depth 100 -Compress) -match 'duplicate typed output|must-not-emit')) 'duplicate typed item content should be suppressed'

    $bashPart = @($paginatedTools | Where-Object tool -eq 'bash')[0]
    $expectedCommand = "printf %s 'hello world' 'it'`"'`"'s'"
    Assert-True ([string]$bashPart.state.input.command -eq $expectedCommand) 'typed command input should preserve Codex-compatible shell quoting'
    Assert-True ([string]$bashPart.state.output -eq 'typed command output') 'typed command output should be model-visible'
    Assert-True ([string]$bashPart.state.metadata.command -eq $expectedCommand) 'typed command metadata should preserve the rendered command'
    Assert-True ((@($bashPart.state.metadata.commandArguments) -join '|') -ceq "printf|%s|hello world|it's") 'typed command metadata should preserve the raw argument array'
    Assert-True ([string]$bashPart.state.metadata.output -eq 'typed command output') 'typed command metadata should preserve output'
    Assert-True ([string]$bashPart.state.metadata.cwd -eq 'C:\synthetic project') 'typed command metadata should decode a Windows PathUri'
    Assert-True ([string]$bashPart.state.input.workdir -eq 'C:\synthetic project') 'typed command input should expose the decoded Windows working directory'
    Assert-True ([int]$bashPart.state.metadata.exitCode -eq 7) 'typed command metadata should preserve numeric exit code'
    $paginatedCodeMode = @($paginatedParts | Where-Object { $_.type -eq 'text' -and $_.PSObject.Properties['synthetic'] -and [bool]$_.synthetic -and [string]$_.metadata.codex.kind -eq 'code_mode_archive' })[0]
    Assert-True ([string]$paginatedCodeMode.metadata.codex.executions[0].callId -eq 'outer-paginated-exec') 'unrelated opaque execution should retain its original call ID'
    Assert-True ([string]$paginatedCodeMode.metadata.codex.outputRepresentation -eq 'metadata_only') 'large opaque output should be explicitly metadata-only'
    Assert-True ([string]$paginatedCodeMode.metadata.codex.executions[0].outputs[0] -ceq $longOpaqueOutput) 'opaque metadata should archive the exact unbounded persisted JSON envelope'
    Assert-True ([string]$paginatedCodeMode.text -notmatch 'Opaque outer paginated output head|Opaque outer paginated output tail|tools\.') 'raw opaque source and output should be absent from model-visible context'
    Assert-True (-not (($paginatedParts | ConvertTo-Json -Depth 100 -Compress) -match 'outer-bracketed-patch|Duplicate outer patch output')) 'an opaque wrapper bracketing an authoritative typed item should be suppressed'

    $typedPatch = @($paginatedTools | Where-Object tool -eq 'apply_patch')[0]
    $patchFiles = @($typedPatch.state.metadata.files)
    Assert-True ($patchFiles.Count -eq 6) 'typed patch should preserve all six file changes'
    Assert-True (($patchFiles.filePath -join ',') -ceq 'Zeta.txt,added.txt,alpha.txt,before-name.txt,deleted.txt,updated.txt') 'typed patch should use ordinal Codex app-server path ordering'
    $addedFile = @($patchFiles | Where-Object filePath -eq 'added.txt')[0]
    $moveFile = @($patchFiles | Where-Object filePath -eq 'before-name.txt')[0]
    $deleteFile = @($patchFiles | Where-Object filePath -eq 'deleted.txt')[0]
    $updateFile = @($patchFiles | Where-Object filePath -eq 'updated.txt')[0]
    Assert-True ((@($addedFile.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'additions,after,before,deletions,filePath,relativePath,type') 'add patch metadata should have the exact OpenCode shape'
    Assert-True ((@($moveFile.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'additions,deletions,filePath,movePath,patch,relativePath,type') 'move patch metadata should have the exact OpenCode shape'
    Assert-True ((@($deleteFile.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'additions,after,before,deletions,filePath,relativePath,type') 'delete patch metadata should have the exact OpenCode shape'
    Assert-True ((@($updateFile.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'additions,deletions,filePath,patch,relativePath,type') 'update patch metadata should have the exact OpenCode shape'
    Assert-True ([int]$addedFile.additions -eq 2 -and [int]$addedFile.deletions -eq 0 -and [string]$addedFile.before -eq '' -and [string]$addedFile.after -eq "alpha`nbeta`n") 'add patch metadata should preserve content and numeric counts'
    Assert-True ([int]$moveFile.additions -eq 1 -and [int]$moveFile.deletions -eq 1 -and [string]$moveFile.relativePath -eq 'after-name.txt') 'move patch metadata should use the destination relative path and preserve counts'
    Assert-True ([int]$deleteFile.additions -eq 0 -and [int]$deleteFile.deletions -eq 2 -and [string]$deleteFile.after -eq '') 'delete patch metadata should preserve content and numeric counts'
    Assert-True ([int]$updateFile.additions -eq 2 -and [int]$updateFile.deletions -eq 1) 'update patch metadata should preserve numeric diff counts'
    Assert-True ($null -ne $typedPatch.state.input.changes.PSObject.Properties['updated.txt']) 'typed patch input should expose exact persisted changes to resumed models'

    $typedMcp = @($paginatedTools | Where-Object tool -eq 'mcp__safe_server__inspect_item')[0]
    Assert-True ([int]$typedMcp.state.input.depth -eq 2 -and [bool]$typedMcp.state.input.enabled) 'typed MCP arguments should be preserved'
    Assert-True ([string]$typedMcp.state.output -match 'typed MCP result') 'typed MCP result should be preserved'
    Assert-True ([string]$typedMcp.state.output -match 'retained') 'typed MCP structured content should be model-visible'
    $typedMcpError = @($paginatedTools | Where-Object tool -eq 'mcp__safe_server__fail_item')[0]
    Assert-True ([string]$typedMcpError.state.status -eq 'error' -and [string]$typedMcpError.state.error -match 'typed MCP failure') 'typed MCP is_error results should become model-visible OpenCode errors'
    $typedWeb = @($paginatedTools | Where-Object tool -eq 'websearch')[0]
    Assert-True ([string]$typedWeb.state.input.query -eq 'typed query') 'typed web input should preserve query'
    Assert-True ([string]$typedWeb.state.output -match 'Typed result' -and [string]$typedWeb.state.output -match 'typed web output') 'typed web output should preserve persisted results'
    $typedRead = @($paginatedTools | Where-Object tool -eq 'read')[0]
    Assert-True ([string]$typedRead.state.input.filePath -eq '/tmp/image sample.png') 'typed image view should decode a POSIX PathUri'
    $typedDynamic = @($paginatedTools | Where-Object tool -eq 'dynamic__safe_namespace__lookup_item')[0]
    Assert-True ([string]$typedDynamic.state.input.key -eq 'typed-key') 'typed dynamic arguments should be preserved'
    Assert-True ([string]$typedDynamic.state.output -eq "typed dynamic output`n[Dynamic tool image: https://example.invalid/image.png]`n[Dynamic tool audio: https://example.invalid/audio.wav]") 'official dynamic text and media variants should become readable model-visible output'
    $typedPlan = @($paginatedTools | Where-Object tool -eq 'codex_plan')[0]
    Assert-True ([string]$typedPlan.state.input.text -eq '1. Preserve exact history.' -and [string]$typedPlan.state.output -eq '1. Preserve exact history.') 'completed plans should remain model-visible'
    $typedSleep = @($paginatedTools | Where-Object tool -eq 'codex_item')[0]
    Assert-True ([string]$typedSleep.state.input.item.kind -eq 'clock.sleep' -and [int]$typedSleep.state.input.item.durationMs -eq 25) 'unsupported extension items should be preserved generically rather than discarded'
    $compactionParts = @($paginatedParts | Where-Object type -eq 'compaction')
    Assert-True ($compactionParts.Count -eq 1 -and -not [bool]$compactionParts[0].auto) 'the latest Codex checkpoint should become one completed manual OpenCode compaction marker'
    $compactionSummary = @($paginated.messages | Where-Object { $_.info.role -eq 'assistant' -and $_.info.PSObject.Properties['summary'] -and $_.info.summary -eq $true })
    Assert-True ($compactionSummary.Count -eq 1 -and [string]$compactionSummary[0].info.mode -eq 'compaction') 'the imported checkpoint should have one completed OpenCode compaction summary message'
    $compactionText = @($compactionSummary[0].parts | Where-Object type -eq 'text')[0].text
    Assert-True ([string]$compactionText -match 'encrypted provider data' -and [string]$compactionText -match 'Preserving typed tool history') 'the checkpoint should explain the encrypted boundary and retain the last readable assistant response'
    Assert-True ([string]$compactionText -notmatch 'Synthetic retained developer instruction|Synthetic retained user context') 'the checkpoint must not duplicate retained developer or user history'
    Assert-True ([string]$compactionText -notmatch 'c3ludGhldGlj') 'checkpoint summaries must not copy embedded image data into model-visible text'

    $importStatus = 'not requested'
    if ($TestOpenCodeImport) {
        $openCode = Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $openCode) {
            throw 'OpenCode CLI is required for -TestOpenCodeImport.'
        }
        $isolatedData = Join-Path $GeneratedRoot 'isolated-opencode'
        $oldDataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')
        try {
            $env:XDG_DATA_HOME = $isolatedData
            foreach ($item in @(
                [pscustomobject]@{ Source = $session; Directory = $destinationWithSpaces; Name = 'generated'; Bundle = $generatedBundle },
                [pscustomobject]@{ Source = $richSession; Directory = $richTarget; Name = 'rich'; Bundle = $rich },
                [pscustomobject]@{ Source = $paginatedSession; Directory = $paginatedTarget; Name = 'paginated'; Bundle = $paginated }
            )) {
                $plan = $item.Source | Get-CodexSessionImportPlan `
                    -DestinationDirectory $item.Directory `
                    -OutputDirectory (Join-Path $OutputRoot "plan-$($item.Name)")
                Assert-True ($plan.Action -eq 'Create') "isolated $($item.Name) plan should create a session"
                $imported = $item.Source | Import-CodexSession `
                    -DestinationDirectory $item.Directory `
                    -OutputDirectory (Join-Path $OutputRoot "import-$($item.Name)") `
                    -Confirm:$false
                Assert-True ($imported.Imported) "public import should report the $($item.Name) session as imported"
                $found = @(Get-OpenCodeSession -SessionId $imported.OpenCodeSessionId)
                Assert-True ($found.Count -eq 1) "public inventory should contain the $($item.Name) session"
                $exportText = & $openCode.Path export $imported.OpenCodeSessionId --pure
                Assert-True ($LASTEXITCODE -eq 0) "official OpenCode export should succeed for the $($item.Name) session"
                $storedBundle = ($exportText -join "`n") | ConvertFrom-Json
                $expectedMessageIds = @($item.Bundle.messages | ForEach-Object { [string]$_.info.id })
                $storedMessageIds = @($storedBundle.messages | ForEach-Object { [string]$_.info.id })
                Assert-True (($storedMessageIds -join "`n") -ceq ($expectedMessageIds -join "`n")) "stored $($item.Name) message order should equal bundle chronology"
                $expectedPartIds = @($item.Bundle.messages | ForEach-Object { @($_.parts) } | ForEach-Object { [string]$_.id })
                $storedPartIds = @($storedBundle.messages | ForEach-Object { @($_.parts) } | ForEach-Object { [string]$_.id })
                Assert-True (($storedPartIds -join "`n") -ceq ($expectedPartIds -join "`n")) "stored $($item.Name) part order should equal bundle chronology"
                $expectedToolNames = @($item.Bundle.messages | ForEach-Object { @($_.parts) } | Where-Object type -eq 'tool' | ForEach-Object { [string]$_.tool })
                $storedToolNames = @($storedBundle.messages | ForEach-Object { @($_.parts) } | Where-Object type -eq 'tool' | ForEach-Object { [string]$_.tool })
                Assert-True (($storedToolNames -join "`n") -ceq ($expectedToolNames -join "`n")) "stored $($item.Name) native tool names should survive official import/export"
                if ($item.Name -ne 'generated') {
                    $expectedToolsById = @{}
                    foreach ($toolPart in @($item.Bundle.messages | ForEach-Object { @($_.parts) } | Where-Object type -eq 'tool')) { $expectedToolsById[[string]$toolPart.id] = $toolPart }
                    foreach ($storedTool in @($storedBundle.messages | ForEach-Object { @($_.parts) } | Where-Object type -eq 'tool')) {
                        $expectedTool = $expectedToolsById[[string]$storedTool.id]
                        Assert-True ($null -ne $expectedTool) "stored $($item.Name) tool should retain its generated part ID"
                        $storedStateJson = ConvertTo-TestCanonicalJson $storedTool.state
                        $expectedStateJson = ConvertTo-TestCanonicalJson $expectedTool.state
                        Assert-True ($storedStateJson -ceq $expectedStateJson) "stored $($item.Name) tool input, output/error, timing, and metadata should survive official import/export"
                    }
                    $expectedArchives = @($item.Bundle.messages | ForEach-Object { @($_.parts) } | Where-Object { $_.type -eq 'text' -and $_.PSObject.Properties['synthetic'] -and [bool]$_.synthetic -and [string]$_.metadata.codex.kind -eq 'code_mode_archive' })
                    $storedArchives = @($storedBundle.messages | ForEach-Object { @($_.parts) } | Where-Object { $_.type -eq 'text' -and $_.PSObject.Properties['synthetic'] -and [bool]$_.synthetic -and [string]$_.metadata.codex.kind -eq 'code_mode_archive' })
                    Assert-True ($storedArchives.Count -eq $expectedArchives.Count) "stored $($item.Name) code-mode archive count should survive official import/export"
                    $expectedArchivesById = @{}
                    foreach ($archivePart in $expectedArchives) { $expectedArchivesById[[string]$archivePart.id] = $archivePart }
                    foreach ($storedArchive in $storedArchives) {
                        $expectedArchive = $expectedArchivesById[[string]$storedArchive.id]
                        Assert-True ($null -ne $expectedArchive) "stored $($item.Name) code-mode archive should retain its generated part ID"
                        Assert-True ([string]$storedArchive.text -ceq [string]$expectedArchive.text) "stored $($item.Name) synthetic archive note should survive official import/export"
                        Assert-True ((ConvertTo-TestCanonicalJson $storedArchive.metadata) -ceq (ConvertTo-TestCanonicalJson $expectedArchive.metadata)) "stored $($item.Name) exact code-mode archive metadata should survive official import/export"
                    }
                }
                $replan = $item.Source | Get-CodexSessionImportPlan `
                    -DestinationDirectory $item.Directory `
                    -OutputDirectory (Join-Path $OutputRoot "replan-$($item.Name)")
                Assert-True ($replan.Action -eq 'Append/no-op') `
                    "unchanged $($item.Name) history should plan as append/no-op, got $($replan.Action) with $($replan.ChangedMessages) changed messages and $($replan.ChangedParts) changed parts"
                Assert-True ($replan.ChangedMessages -eq 0 -and $replan.ChangedParts -eq 0) `
                    "unchanged $($item.Name) history should have no content conflicts"
                if ($item.Name -eq 'generated') {
                    $sourceText = [System.IO.File]::ReadAllText($item.Source.SourcePath, [System.Text.Encoding]::UTF8)
                    try {
                        $changedSourceText = $sourceText.Replace('synthetic-user-1', 'synthetic-user-X')
                        Assert-True ($changedSourceText -cne $sourceText) 'generated conflict test should change source text'
                        [System.IO.File]::WriteAllText(
                            $item.Source.SourcePath,
                            $changedSourceText,
                            [System.Text.UTF8Encoding]::new($false)
                        )
                        $changedPlan = $item.Source | Get-CodexSessionImportPlan `
                            -DestinationDirectory $item.Directory `
                            -OutputDirectory (Join-Path $OutputRoot 'changed-plan-generated')
                        Assert-True ($changedPlan.Action -eq 'Conflict') 'changed history with matching IDs should plan as a conflict'
                        Assert-True ($changedPlan.ChangedParts -gt 0) 'changed history should report changed parts'
                    }
                    finally {
                        [System.IO.File]::WriteAllText(
                            $item.Source.SourcePath,
                            $sourceText,
                            [System.Text.UTF8Encoding]::new($false)
                        )
                    }
                }
                $conflictDirectory = Join-Path $GeneratedRoot "conflicting destination $($item.Name)"
                New-Item -ItemType Directory -Force -Path $conflictDirectory | Out-Null
                $conflictRejected = $false
                try {
                    $item.Source | Get-CodexSessionImportPlan `
                        -DestinationDirectory $conflictDirectory `
                        -OutputDirectory (Join-Path $OutputRoot "conflict-$($item.Name)") | Out-Null
                } catch {
                    if ($_.Exception.Message -match 'already belongs to') { $conflictRejected = $true }
                    else { throw }
                }
                Assert-True $conflictRejected "relocating the imported $($item.Name) session should report an ID collision"
                $importConflictOutput = Join-Path $OutputRoot "import-conflict-$($item.Name)"
                $importConflictRejected = $false
                try {
                    $item.Source | Import-CodexSession `
                        -DestinationDirectory $conflictDirectory `
                        -OutputDirectory $importConflictOutput `
                        -Confirm:$false | Out-Null
                } catch {
                    if ($_.Exception.Message -match 'already belongs to') { $importConflictRejected = $true }
                    else { throw }
                }
                Assert-True $importConflictRejected "public import should reject relocation of the $($item.Name) session"
                Assert-True (-not (Test-Path -LiteralPath $importConflictOutput)) `
                    "rejected relocation should not convert the $($item.Name) session"
                $removed = @($found | Remove-OpenCodeSession -Confirm:$false)
                Assert-True ($removed.Count -eq 1) "public removal should delete the $($item.Name) session"
                Assert-True (-not @(Get-OpenCodeSession | Where-Object Id -eq $imported.OpenCodeSessionId).Count) `
                    "public inventory should verify removal of the $($item.Name) session"
            }

            $batchFirstDirectory = Join-Path $GeneratedRoot 'batch destination first'
            $batchSecondDirectory = Join-Path $GeneratedRoot 'batch destination second'
            New-Item -ItemType Directory -Force -Path $batchFirstDirectory | Out-Null
            New-Item -ItemType Directory -Force -Path $batchSecondDirectory | Out-Null
            $batchFirst = [pscustomobject]@{
                Id = $session.Id
                Started = $session.Started
                Title = $session.Title
                Directory = $batchFirstDirectory
                SourcePath = $session.SourcePath
            }
            $batchSecond = [pscustomobject]@{
                Id = $session.Id
                Started = $session.Started
                Title = $session.Title
                Directory = $batchSecondDirectory
                SourcePath = $session.SourcePath
            }
            $batchConflictRejected = $false
            try {
                @($batchFirst, $batchSecond) | Import-CodexSession `
                    -OutputDirectory (Join-Path $OutputRoot 'batch-conflict') `
                    -Confirm:$false | Out-Null
            } catch {
                if ($_.Exception.Message -match 'already belongs to') { $batchConflictRejected = $true }
                else { throw }
            }
            Assert-True $batchConflictRejected 'a duplicate source ID with different batch directories should be rejected'
            $batchSessions = @(Get-OpenCodeSession)
            Assert-True ($batchSessions.Count -eq 1) 'batch collision should leave exactly the first imported session'
            Assert-True (
                [System.IO.Path]::GetFullPath($batchSessions[0].Directory) -eq
                [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $batchFirstDirectory).Path)
            ) 'batch collision should not reassociate the first imported session'
            $batchSessions | Remove-OpenCodeSession -Confirm:$false | Out-Null
        } finally {
            if ($null -eq $oldDataHome) { Remove-Item Env:XDG_DATA_HOME -ErrorAction SilentlyContinue }
            else { $env:XDG_DATA_HOME = $oldDataHome }
        }
        $importStatus = 'passed'
    }

    $result = [pscustomobject]@{
        Preset = $Preset
        SessionId = $session.Id
        SourceBytes = (Get-Item -LiteralPath $session.SourcePath).Length
        Messages = $generatedMessages.Count
        TextParts = $generatedText.Count
        ToolParts = $generatedTools.Count
        RichFixture = 'passed'
        PublicParameterSets = 'passed'
        CodexHomeOverride = 'passed'
        IsolatedOpenCodeImport = $importStatus
    }
    Write-Host "`nSynthetic module tests passed." -ForegroundColor Green
    $result | Format-List | Out-Host
} finally {
    if (-not $KeepGenerated -and (Test-Path -LiteralPath $GeneratedRoot)) {
        if (-not (Test-Path -LiteralPath $GeneratedMarker -PathType Leaf)) {
            throw "Refusing to remove an unmarked generated test directory: $GeneratedRoot"
        }
        Remove-Item -LiteralPath $GeneratedRoot -Recurse -Force
        $generatedParent = Split-Path -Parent $GeneratedRoot
        if ((Test-Path -LiteralPath $generatedParent) -and -not @(Get-ChildItem -LiteralPath $generatedParent -Force).Count) {
            Remove-Item -LiteralPath $generatedParent -Force
        }
        Write-Host 'Removed generated test data.'
    }
}
