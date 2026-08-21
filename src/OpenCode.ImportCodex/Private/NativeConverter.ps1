function Get-ImportSha1 {
    param([Parameter(Mandatory)][string]$Value)
    $algorithm = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $algorithm.Dispose() }
}

function New-OpenCodeImportId {
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][object[]]$Seed)
    $Prefix + (Get-ImportSha1 (($Seed | ForEach-Object { [string]$_ }) -join ':')).Substring(0, 24)
}

function New-OpenCodeAscendingImportId {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][int64]$TimestampMs,
        [Parameter(Mandatory)][int64]$Ordinal,
        [Parameter(Mandatory)][object[]]$Seed
    )
    $encoded = ($TimestampMs * [int64]0x1000) + $Ordinal
    if ($encoded -lt 0) { $encoded = 0 }
    $timeHex = $encoded.ToString('x14', [Globalization.CultureInfo]::InvariantCulture)
    $entropy = (Get-ImportSha1 (($Seed | ForEach-Object { [string]$_ }) -join ':')).Substring(0, 12)
    "$Prefix$timeHex$entropy"
}

function ConvertTo-ImportEpochMilliseconds {
    param([AllowEmptyString()][string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return [int64]0 }
    try {
        [int64]([datetimeoffset]::Parse($Timestamp).ToUniversalTime() - [datetimeoffset]::Parse('1970-01-01T00:00:00Z')).TotalMilliseconds
    } catch { [int64]0 }
}

function ConvertTo-OpenCodeSlug {
    param([Parameter(Mandatory)][string]$Value)
    $slug = ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
    if (-not $slug) { return 'relocated' }
    if ($slug.Length -gt 40) { return $slug.Substring(0, 40) }
    $slug
}

function Get-OpenCodeImportModel { @{ providerID = 'openai'; modelID = 'gpt-5.1' } }

function ConvertTo-OpenCodeToolName {
    param([Parameter(Mandatory)][string]$Name)
    $mapped = @{ Bash = 'bash'; shell = 'bash'; exec_command = 'bash'; local_shell = 'bash'; Edit = 'edit'; apply_patch = 'apply_patch'; Write = 'write'; Read = 'read'; read_file = 'read'; view_image = 'read' }
    if ($mapped.ContainsKey($Name)) { return $mapped[$Name] }
    $Name.ToLowerInvariant()
}

function ConvertTo-OpenCodeToolInput {
    param($Value)
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) { return $Value }
    if ($Value -is [string]) {
        try {
            $parsed = $Value | ConvertFrom-Json
            if ($parsed -is [System.Collections.IDictionary] -or $parsed -is [pscustomobject]) { return $parsed }
        } catch {}
        return @{ input = $Value }
    }
    if ($null -eq $Value) { return @{} }
    @{ input = $Value }
}

function ConvertFrom-CodexCustomToolOutput {
    param($Value)
    $raw = if ($Value -is [string]) { $Value } else { $Value | ConvertTo-Json -Depth 100 -Compress }
    try {
        $parsed = $raw | ConvertFrom-Json
        $items = @($parsed)
    } catch { return $raw }
    if (-not $items.Count) { return $raw }

    $pieces = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $items) {
        if ($null -eq $item) { return $raw }
        $type = [string](Get-ObjectPropertyValue $item 'type' '')
        if ($type -notin @('input_text', 'output_text', 'text')) { return $raw }
        $text = Get-ObjectPropertyValue $item 'text' $null
        if ($null -eq $text) { return $raw }
        $pieces.Add([string]$text) | Out-Null
    }
    $pieces -join ''
}

function Test-CodexCodeModeCompletion {
    param([Parameter(Mandatory)]$CodeRecord, [Parameter(Mandatory)][string]$CompletedTool)
    $invoked = @(
        [regex]::Matches([string]$CodeRecord.metadata.codex.code, 'tools\.([A-Za-z0-9_]+)') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique
    )
    if ($invoked.Count -ne 1) { return $false }
    if ($CompletedTool -eq 'apply_patch') { return $invoked[0] -eq 'apply_patch' }
    if ($CompletedTool -in @('websearch', 'webfetch')) { return $invoked[0] -eq 'web__run' }
    if ($CompletedTool.StartsWith('mcp__')) { return $invoked[0] -eq $CompletedTool }
    $false
}

function New-CodexLegacyEventPair {
    param([Parameter(Mandatory)]$Payload, [AllowEmptyString()][string]$Timestamp)
    $payloadType = [string](Get-ObjectPropertyValue $Payload 'type' '')
    $callId = [string](Get-ObjectPropertyValue $Payload 'call_id' '')
    if (-not $callId) { return $null }
    switch ($payloadType) {
        'patch_apply_end' {
            $files = New-Object 'System.Collections.Generic.List[object]'
            $paths = New-Object 'System.Collections.Generic.List[string]'
            $changes = Get-ObjectPropertyValue $Payload 'changes' @{}
            foreach ($file in @(ConvertTo-OpenCodePatchFiles $changes)) { $files.Add($file) | Out-Null; $paths.Add([string]$file.relativePath) | Out-Null }
            $output = @([string](Get-ObjectPropertyValue $Payload 'stdout' ''), [string](Get-ObjectPropertyValue $Payload 'stderr' '')) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $output = $output -join "`n"; if (-not $output) { $output = "Applied changes to $($files.Count) file(s)." }
            $success = [bool](Get-ObjectPropertyValue $Payload 'success' $false)
            return [pscustomobject]@{
                Call = @{ kind = 'toolCall'; callId = $callId; name = 'apply_patch'; input = @{ files = $paths.ToArray() }; metadata = @{ files = $files.ToArray(); status = Get-ObjectPropertyValue $Payload 'status' ''; stdout = Get-ObjectPropertyValue $Payload 'stdout' ''; stderr = Get-ObjectPropertyValue $Payload 'stderr' ''; codex = @{ source = 'patch_apply_end'; changes = $changes; status = Get-ObjectPropertyValue $Payload 'status' '' } }; timestamp = $Timestamp; suppress = $false; authority = 2 }
                Result = @{ kind = 'toolResult'; callId = $callId; output = $output; timestamp = $Timestamp; isError = -not $success; authority = 2 }
            }
        }
        'mcp_tool_call_end' {
            $invocation = Get-ObjectPropertyValue $Payload 'invocation' $null; if (-not $invocation) { return $null }
            $server = [string](Get-ObjectPropertyValue $invocation 'server' 'mcp'); $tool = [string](Get-ObjectPropertyValue $invocation 'tool' 'tool')
            $safeName = "mcp__$server`__$tool" -replace '[^A-Za-z0-9_-]', '_'
            $envelope = Get-ObjectPropertyValue $Payload 'result' $null
            $ok = if ($envelope) { Get-ObjectPropertyValue $envelope 'Ok' $null } else { $null }
            $err = if ($envelope) { Get-ObjectPropertyValue $envelope 'Err' $null } else { $null }
            $pieces = New-Object 'System.Collections.Generic.List[string]'
            if ($ok) { foreach ($content in @(Get-ObjectPropertyValue $ok 'content' @())) {
                if ((Get-ObjectPropertyValue $content 'type' '') -eq 'text') { $text = [string](Get-ObjectPropertyValue $content 'text' ''); if ($text) { $pieces.Add($text) | Out-Null } }
                elseif ((Get-ObjectPropertyValue $content 'type' '') -eq 'image') { $pieces.Add("[MCP image: $([string](Get-ObjectPropertyValue $content 'mimeType' 'unknown'))]") | Out-Null }
            } }
            if ($err) { $pieces.Add([string]$err) | Out-Null }
            $isError = [bool]$err -or ($ok -and [bool](Get-ObjectPropertyValue $ok 'isError' $false))
            return [pscustomobject]@{
                Call = @{ kind = 'toolCall'; callId = $callId; name = $safeName; input = ConvertTo-OpenCodeToolInput (Get-ObjectPropertyValue $invocation 'arguments' $null); metadata = @{ codex = @{ source = 'mcp_tool_call_end'; server = $server; tool = $tool; result = $envelope } }; timestamp = $Timestamp; suppress = $false; authority = 2 }
                Result = @{ kind = 'toolResult'; callId = $callId; output = ($pieces -join "`n"); timestamp = $Timestamp; isError = [bool]$isError; authority = 2 }
            }
        }
        'web_search_end' {
            $action = Get-ObjectPropertyValue $Payload 'action' $null
            $actionType = if ($action) { [string](Get-ObjectPropertyValue $action 'type' 'other') } else { 'other' }
            $name = if ($actionType -in @('open_page', 'find_in_page')) { 'webfetch' } else { 'websearch' }
            $input = @{}
            if ($action) {
                $query = [string](Get-ObjectPropertyValue $action 'query' ''); $queries = @(Get-ObjectPropertyValue $action 'queries' @())
                $url = [string](Get-ObjectPropertyValue $action 'url' ''); $pattern = [string](Get-ObjectPropertyValue $action 'pattern' '')
                if ($query) { $input.query = $query } elseif ($queries.Count) { $input.query = $queries -join '; ' } elseif ([string](Get-ObjectPropertyValue $Payload 'query' '')) { $input.query = [string](Get-ObjectPropertyValue $Payload 'query' '') }
                if ($url) { $input.url = $url }; if ($pattern) { $input.pattern = $pattern }
            }
            $results = @(Get-ObjectPropertyValue $Payload 'results' @())
            $output = if ($results.Count) { $results | ConvertTo-Json -Depth 20 } else { 'No persisted web results.' }
            return [pscustomobject]@{
                Call = @{ kind = 'toolCall'; callId = $callId; name = $name; input = $input; metadata = @{ codex = @{ source = 'web_search_end'; action = $action; results = $results } }; timestamp = $Timestamp; suppress = $false; authority = 2 }
                Result = @{ kind = 'toolResult'; callId = $callId; output = $output; timestamp = $Timestamp; isError = $false; authority = 2 }
            }
        }
    }
    $null
}

function Get-CodexImageFileName {
    param([Parameter(Mandatory)][string]$Mime, [Parameter(Mandatory)][int]$Ordinal)
    $extension = switch ($Mime.ToLowerInvariant()) { 'image/jpeg' { 'jpg' }; 'image/svg+xml' { 'svg' }; default { ($Mime -replace '^image/', '' -replace '[^a-z0-9]+', '') } }
    if (-not $extension) { $extension = 'image' }
    "codex-image-$Ordinal.$extension"
}

function ConvertTo-CodexCompactionSummary {
    param([Parameter(Mandatory)]$Payload, [Parameter(Mandatory)]$Records)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('Imported Codex compaction checkpoint')
    [void]$builder.AppendLine()
    $message = [string](Get-ObjectPropertyValue $Payload 'message' '')
    if ($message) {
        [void]$builder.AppendLine('Codex summary:')
        [void]$builder.AppendLine($message)
    } else {
        [void]$builder.AppendLine('Codex stored its summary as encrypted provider data that OpenCode cannot transfer. Earlier messages remain available in the session archive but are excluded from resumed model context.')
        $recentAssistant = ''
        for ($recordIndex = $Records.Count - 1; $recordIndex -ge 0; $recordIndex--) {
            $record = $Records[$recordIndex]
            if ($record.kind -eq 'assistant' -and -not [bool](Get-ObjectPropertyValue $record 'summary' $false)) {
                $recentAssistant = [string](Get-ObjectPropertyValue $record 'text' '')
                if ($recentAssistant) { break }
            }
        }
        if ($recentAssistant) {
            $limit = 12000
            if ($recentAssistant.Length -gt $limit) {
                $recentAssistant = "[Earlier text omitted from imported checkpoint.]`n" + $recentAssistant.Substring($recentAssistant.Length - $limit)
            }
            [void]$builder.AppendLine()
            [void]$builder.AppendLine('Last readable assistant response before the checkpoint:')
            [void]$builder.AppendLine($recentAssistant)
        }
    }
    $builder.ToString().TrimEnd()
}

function Invoke-NativeCodexConversion {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$SourceSessionId,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$ProgressId = 0,
        [string]$ProgressActivity = 'Converting Codex session'
    )
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw "Codex source file does not exist: $SourcePath" }
    Confirm-CodexSessionId $SourceSessionId
    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath); $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $TargetDirectory = [System.IO.Path]::GetFullPath($TargetDirectory)
    if (Test-FileSystemPathEqual $outputFullPath $sourceFullPath) { throw 'OutputPath must not overwrite SourcePath.' }
    $records = New-Object 'System.Collections.Generic.List[object]'; $startedAt = ''; $imageOrdinal = 0; $historyMode = 'legacy'
    $activeCodeMode = $null; $completedCodeMode = $null; $activeCompactionRecords = @(); $seenLegacyEvents = New-Object 'System.Collections.Generic.HashSet[string]'
    $seenTypedItems = New-Object 'System.Collections.Generic.HashSet[string]'
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $sourceStream = New-Object System.IO.FileStream($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $sourceReader = New-Object System.IO.StreamReader($sourceStream, [System.Text.Encoding]::UTF8, $true)
    $sourceLength = [math]::Max([int64]1, $sourceStream.Length); $sourceLineCount = 0
    try {
        while (-not $sourceReader.EndOfStream) {
        $line = $sourceReader.ReadLine(); $sourceLineCount++
        if (($sourceLineCount % 100) -eq 0) {
            $percent = [math]::Min(100, [int](($sourceStream.Position * 100) / $sourceLength))
            Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Reading and converting source: $sourceLineCount records" -PercentComplete $percent
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }; try { $row = $line | ConvertFrom-Json } catch { continue }
        if ($row.type -eq 'session_meta') {
            $startedAt = [string](Get-ObjectPropertyValue $row.payload 'timestamp' '')
            $persistedMode = [string](Get-ObjectPropertyValue $row.payload 'history_mode' ''); if ($persistedMode) { $historyMode = $persistedMode }; continue
        }
        if ($row.type -eq 'compacted') {
            $completedCodeMode = $null
            foreach ($previous in $activeCompactionRecords) { $previous.suppress = $true; if ($previous.kind -eq 'assistant') { $previous.text = '' } }
            $timestamp = [string](Get-ObjectPropertyValue $row 'timestamp' '')
            $compaction = @{ kind = 'compaction'; timestamp = $timestamp; suppress = $false }
            $summary = @{ kind = 'assistant'; text = ConvertTo-CodexCompactionSummary $row.payload $records; timestamp = $timestamp; summary = $true; suppress = $false }
            $records.Add($compaction) | Out-Null; $records.Add($summary) | Out-Null
            $activeCompactionRecords = @($compaction, $summary)
            continue
        }
        if ($row.type -eq 'event_msg' -and [string](Get-ObjectPropertyValue $row.payload 'type' '') -eq 'token_count') {
            $info = Get-ObjectPropertyValue $row.payload 'info' $null
            if ($info) {
                $usage = Get-ObjectPropertyValue $info 'last_token_usage' $null
                if ($usage) {
                    $inputTokens = [int64](Get-ObjectPropertyValue $usage 'input_tokens' 0)
                    $cacheRead = [int64](Get-ObjectPropertyValue $usage 'cached_input_tokens' 0)
                    $cacheWrite = [int64](Get-ObjectPropertyValue $usage 'cache_write_input_tokens' 0)
                    $outputTokens = [int64](Get-ObjectPropertyValue $usage 'output_tokens' 0)
                    $reasoningTokens = [int64](Get-ObjectPropertyValue $usage 'reasoning_output_tokens' 0)
                    $records.Add(@{ kind = 'usage'; timestamp = [string](Get-ObjectPropertyValue $row 'timestamp' ''); tokens = @{ total = [math]::Max(0, [int64](Get-ObjectPropertyValue $usage 'total_tokens' 0)); input = [math]::Max(0, $inputTokens - $cacheRead - $cacheWrite); output = [math]::Max(0, $outputTokens - $reasoningTokens); reasoning = [math]::Max(0, $reasoningTokens); cache = @{ write = [math]::Max(0, $cacheWrite); read = [math]::Max(0, $cacheRead) } } }) | Out-Null
                }
            }
            continue
        }
        if ($row.type -eq 'event_msg' -and (Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $row.payload 'type' ''))) -eq 'itemcompleted') {
            $item = Get-ObjectPropertyValue $row.payload 'item' $null
            $itemId = if ($item) { [string](Get-ObjectPropertyValue $item 'id' '') } else { '' }
            if (-not $itemId -or $seenTypedItems.Add($itemId)) {
                $pair = New-CodexTypedItemPair $row.payload ([string](Get-ObjectPropertyValue $row 'timestamp' ''))
                if ($pair) {
                    if ($activeCodeMode) { $activeCodeMode.suppress = $true }
                    elseif ($completedCodeMode -and (Test-CodexCodeModeCompletion $completedCodeMode ([string]$pair.Call.name))) { $completedCodeMode.suppress = $true }
                    $completedCodeMode = $null
                    $records.Add($pair.Call) | Out-Null; $records.Add($pair.Result) | Out-Null
                }
            }
            continue
        }
        if ($row.type -eq 'event_msg' -and $historyMode -eq 'legacy') {
            $eventType = [string](Get-ObjectPropertyValue $row.payload 'type' ''); $eventCallId = [string](Get-ObjectPropertyValue $row.payload 'call_id' '')
            if ($eventCallId -and -not $seenLegacyEvents.Add("$eventType|$eventCallId")) { continue }
            $pair = New-CodexLegacyEventPair $row.payload ([string](Get-ObjectPropertyValue $row 'timestamp' ''))
            if ($pair) {
                if ($activeCodeMode) { $activeCodeMode.suppress = $true }
                elseif ($completedCodeMode -and (Test-CodexCodeModeCompletion $completedCodeMode ([string]$pair.Call.name))) { $completedCodeMode.suppress = $true }
                $completedCodeMode = $null
                $records.Add($pair.Call) | Out-Null; $records.Add($pair.Result) | Out-Null
            }; continue
        }
        if ($row.type -ne 'response_item') { continue }
        $payload = $row.payload; $payloadType = [string](Get-ObjectPropertyValue $payload 'type' ''); $timestamp = [string](Get-ObjectPropertyValue $row 'timestamp' '')
        if ($payloadType -ne 'custom_tool_call_output') { $completedCodeMode = $null }
        $incomingCallId = [string](Get-ObjectPropertyValue $payload 'call_id' '')
        $matchingCodeOutput = $payloadType -eq 'custom_tool_call_output' -and $activeCodeMode -and $incomingCallId -eq $activeCodeMode.callId
        if ($activeCodeMode -and -not $matchingCodeOutput) { $activeCodeMode = $null }
        switch ($payloadType) {
            'reasoning' { continue }
            'message' {
                $role = [string](Get-ObjectPropertyValue $payload 'role' ''); if ($role -eq 'developer') { continue }
                foreach ($content in @(Get-ObjectPropertyValue $payload 'content' @())) {
                    $contentType = [string](Get-ObjectPropertyValue $content 'type' '')
                    if ($contentType -in @('input_text', 'output_text', 'text')) {
                        $text = [string](Get-ObjectPropertyValue $content 'text' '')
                        if (-not [string]::IsNullOrWhiteSpace($text)) { $records.Add(@{ kind = if ($role -eq 'assistant') { 'assistant' } else { 'user' }; text = $text; timestamp = $timestamp }) | Out-Null }
                    } elseif ($contentType -eq 'input_image') {
                        $url = [string](Get-ObjectPropertyValue $content 'image_url' '')
                        if ($url -match '^data:(image/[A-Za-z0-9.+-]+);base64,') {
                            $imageOrdinal++; $mime = $Matches[1].ToLowerInvariant()
                            $records.Add(@{ kind = 'image'; role = if ($role -eq 'assistant') { 'assistant' } else { 'user' }; mime = $mime; url = $url; filename = Get-CodexImageFileName $mime $imageOrdinal; timestamp = $timestamp }) | Out-Null
                        } else { $records.Add(@{ kind = if ($role -eq 'assistant') { 'assistant' } else { 'user' }; text = '[Image omitted during import: unsupported Codex image reference.]'; timestamp = $timestamp }) | Out-Null }
                    }
                }
            }
            { $_ -in @('function_call', 'custom_tool_call') } {
                $rawInput = Get-ObjectPropertyValue $payload 'arguments' (Get-ObjectPropertyValue $payload 'input' ''); $name = [string](Get-ObjectPropertyValue $payload 'name' 'tool'); $metadata = @{}
                if ($payloadType -eq 'custom_tool_call' -and $name -eq 'exec' -and $rawInput -is [string]) { $name = 'codex_exec'; $input = @{}; $metadata = @{ codex = @{ kind = 'code_mode'; sourceTool = 'exec'; code = $rawInput } } }
                elseif ($rawInput -is [string]) { try { $input = $rawInput | ConvertFrom-Json } catch { $input = @{ raw = $rawInput } } }
                elseif ($rawInput -is [System.Collections.IDictionary]) { $input = $rawInput } else { $input = @{ input = $rawInput } }
                $passthrough = Get-ObjectPropertyValue $payload 'internal_chat_message_metadata_passthrough' @{}
                $toolRecord = @{ kind = 'toolCall'; callId = [string](Get-ObjectPropertyValue $payload 'call_id' ''); name = $name; input = $input; metadata = $metadata; timestamp = $timestamp; suppress = $false; authority = 1; turnId = [string](Get-CodexAliasedValue $passthrough @('turn_id', 'turnId') '') }
                $records.Add($toolRecord) | Out-Null
                if ($payloadType -eq 'custom_tool_call' -and $name -eq 'codex_exec') { $toolRecord.metadata.codex.outputs = New-Object 'System.Collections.Generic.List[string]'; $activeCodeMode = $toolRecord }
            }
            { $_ -in @('function_call_output', 'custom_tool_call_output') } {
                $rawOutput = Get-ObjectPropertyValue $payload 'output' ''
                $output = if ($payloadType -eq 'custom_tool_call_output') { ConvertFrom-CodexCustomToolOutput $rawOutput } elseif ($rawOutput -is [string]) { $rawOutput } else { $rawOutput | ConvertTo-Json -Depth 100 -Compress }
                $outputCallId = [string](Get-ObjectPropertyValue $payload 'call_id' '')
                if ($activeCodeMode -and $activeCodeMode.callId -eq $outputCallId) { $completedCodeMode = $activeCodeMode; $activeCodeMode = $null }
                $resultRecord = @{ kind = 'toolResult'; callId = $outputCallId; output = $output; timestamp = $timestamp; isError = $false; authority = 1 }
                if ($payloadType -eq 'custom_tool_call_output') {
                    $resultRecord.persistedOutput = if ($rawOutput -is [string]) { $rawOutput } else { $rawOutput | ConvertTo-Json -Depth 100 -Compress }
                }
                $records.Add($resultRecord) | Out-Null
            }
        }
        }
        Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Converted $sourceLineCount source records" -PercentComplete 100
    } finally { $sourceReader.Dispose(); $sourceStream.Dispose() }
    if (-not $records.Count) { throw 'The Codex session contains no importable records.' }

    $toolResultsByCallId = @{}
    foreach ($record in $records) {
        if ($record.kind -ne 'toolResult' -or -not $record.callId) { continue }
        if (-not $toolResultsByCallId.ContainsKey([string]$record.callId)) {
            $toolResultsByCallId[[string]$record.callId] = New-Object 'System.Collections.Generic.List[object]'
        }
        $toolResultsByCallId[[string]$record.callId].Add($record) | Out-Null
    }
    $groups = New-Object 'System.Collections.Generic.List[object]'
    $activeGroup = $null
    for ($recordIndex = 0; $recordIndex -lt $records.Count; $recordIndex++) {
        if (($recordIndex % 250) -eq 0) {
            Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Correlating tools: record $($recordIndex + 1) of $($records.Count)" -PercentComplete ([int](($recordIndex * 100) / $records.Count))
        }
        $record = $records[$recordIndex]
        if ($record.kind -eq 'toolCall' -and $record.name -eq 'codex_exec' -and -not [bool](Get-ObjectPropertyValue $record 'suppress' $false)) {
            if (-not $activeGroup -or [string]$activeGroup.turnId -cne [string]$record.turnId) {
                $activeGroup = [pscustomobject]@{ turnId = [string]$record.turnId; calls = New-Object 'System.Collections.Generic.List[object]'; callIds = New-Object 'System.Collections.Generic.HashSet[string]' }
                $groups.Add($activeGroup) | Out-Null
            }
            $activeGroup.calls.Add($record) | Out-Null
            $activeGroup.callIds.Add([string]$record.callId) | Out-Null
            continue
        }
        if ($record.kind -eq 'toolResult' -and $activeGroup -and $activeGroup.callIds.Contains([string]$record.callId)) { continue }
        if ($record.kind -eq 'usage') { continue }
        $activeGroup = $null
    }
    for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
        if (($groupIndex % 10) -eq 0) {
            $groupPercent = if ($groups.Count) { [int](($groupIndex * 100) / $groups.Count) } else { 100 }
            Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Combining code-mode group $($groupIndex + 1) of $($groups.Count)" -PercentComplete $groupPercent
        }
        $groupInfo = $groups[$groupIndex]
        $group = $groupInfo.calls
        $first = $group[0]
        $executions = New-Object 'System.Collections.Generic.List[object]'
        $hasError = $false
        for ($executionIndex = 0; $executionIndex -lt $group.Count; $executionIndex++) {
            $outer = $group[$executionIndex]
            if ($toolResultsByCallId.ContainsKey([string]$outer.callId)) { $matchingResults = $toolResultsByCallId[[string]$outer.callId].ToArray() } else { $matchingResults = @() }
            $savedOutputs = @($matchingResults | ForEach-Object {
                [string](Get-ObjectPropertyValue $_ 'persistedOutput' $_.output)
            })
            $execution = @{ callId = $outer.callId; source = [string]$outer.metadata.codex.code; outputs = $savedOutputs }
            $executions.Add($execution) | Out-Null
            if (-not $matchingResults.Count) {
                $hasError = $true
            } else {
                if (@($matchingResults | Where-Object { $_.isError }).Count) { $hasError = $true }
            }
            if ($executionIndex -gt 0) { $outer.suppress = $true }
        }
        $summary = "Archived $($executions.Count) opaque Codex code-mode execution(s). Exact JavaScript and outer output are retained in import metadata; no nested calls were inferred or executed."
        $first.name = 'codex_code_mode'
        $first.input = @{ description = $summary; executionCount = $executions.Count }
        $first.metadata = @{ codex = @{ kind = 'code_mode_archive'; fidelity = if ($historyMode -eq 'legacy') { 'opaque_legacy' } else { 'opaque_untyped' }; modelRepresentation = 'count_only_synthetic_note'; outputRepresentation = 'metadata_only'; executions = $executions.ToArray(); turnId = $first.turnId; hadError = $hasError } }
        $firstResult = if ($toolResultsByCallId.ContainsKey([string]$first.callId)) { $toolResultsByCallId[[string]$first.callId][0] } else { $null }
        if (-not $firstResult) {
            $firstResult = @{ kind = 'toolResult'; callId = $first.callId; timestamp = $first.timestamp; authority = 1 }
            $records.Add($firstResult) | Out-Null
        }
        $firstResult.output = $summary
        $firstResult.isError = $hasError
    }

    Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status 'Pairing tool calls and results' -PercentComplete 0
    $calls = @{}; $results = @{}
    foreach ($record in $records) {
        if ($record.kind -eq 'toolCall' -and $record.callId -and -not [bool](Get-ObjectPropertyValue $record 'suppress' $false)) {
            if (-not $calls.ContainsKey($record.callId)) { $calls[$record.callId] = $record }
            elseif ([int](Get-ObjectPropertyValue $record 'authority' 1) -gt [int](Get-ObjectPropertyValue $calls[$record.callId] 'authority' 1)) { $calls[$record.callId].suppress = $true; $calls[$record.callId] = $record } else { $record.suppress = $true }
        }
        if ($record.kind -eq 'toolResult' -and $record.callId -and (-not $results.ContainsKey($record.callId) -or [int](Get-ObjectPropertyValue $record 'authority' 1) -gt [int](Get-ObjectPropertyValue $results[$record.callId] 'authority' 1))) { $results[$record.callId] = $record }
    }
    foreach ($callId in $calls.Keys) { if (-not $results.ContainsKey($callId)) { $results[$callId] = @{ kind = 'toolResult'; callId = $callId; output = 'Tool call ended before a result was recorded.'; timestamp = $calls[$callId].timestamp; isError = $true } } }
    $sessionId = New-OpenCodeImportId 'ses_' @($SourceSessionId); $model = Get-OpenCodeImportModel
    $runs = New-Object 'System.Collections.Generic.List[object]'; $side = ''
    foreach ($record in $records) {
        if ([bool](Get-ObjectPropertyValue $record 'suppress' $false)) { continue }; if ($record.kind -eq 'toolResult' -and $calls.ContainsKey($record.callId)) { continue }
        if ($record.kind -eq 'usage') {
            for ($usageRunIndex = $runs.Count - 1; $usageRunIndex -ge 0; $usageRunIndex--) {
                if ($runs[$usageRunIndex].role -eq 'assistant') { $runs[$usageRunIndex].records.Add($record) | Out-Null; break }
            }
            continue
        }
        $recordSide = if ($record.kind -eq 'image') { $record.role } elseif ($record.kind -in @('user', 'compaction')) { 'user' } else { 'assistant' }
        if ($recordSide -ne $side) { $runs.Add(@{ role = $recordSide; records = New-Object 'System.Collections.Generic.List[object]' }) | Out-Null; $side = $recordSide }
        $runs[$runs.Count - 1].records.Add($record) | Out-Null
    }
    $messages = New-Object 'System.Collections.Generic.List[object]'; $previousMessageId = ''; $logicalMessageMs = [int64]0; $messageOrdinal = [int64]0; $activeUserMessage = $null
    for ($runIndex = 0; $runIndex -lt $runs.Count; $runIndex++) {
        if (($runIndex % 10) -eq 0) {
            Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Building message $($runIndex + 1) of $($runs.Count)" -PercentComplete ([int](($runIndex * 100) / $runs.Count))
        }
        $run = $runs[$runIndex]
        $candidateMessageMs = ConvertTo-ImportEpochMilliseconds $run.records[0].timestamp
        if (-not $candidateMessageMs) { $candidateMessageMs = ConvertTo-ImportEpochMilliseconds $startedAt }
        if ($candidateMessageMs -gt $logicalMessageMs) { $logicalMessageMs = $candidateMessageMs; $messageOrdinal = 1 } else { $messageOrdinal++ }
        if ($messageOrdinal -gt 4095) { $logicalMessageMs++; $messageOrdinal = 1 }
        $messageId = New-OpenCodeAscendingImportId 'msg_' $logicalMessageMs $messageOrdinal @($sessionId, $runIndex)
        $parts = New-Object 'System.Collections.Generic.List[object]'
        for ($partIndex = 0; $partIndex -lt $run.records.Count; $partIndex++) {
            $record = $run.records[$partIndex]; $partId = New-OpenCodeAscendingImportId 'prt_' $logicalMessageMs ([int64]$partIndex + 1) @($sessionId, $messageId, $partIndex)
            if ($record.kind -in @('user', 'assistant')) { $parts.Add(@{ type = 'text'; text = $record.text; id = $partId; sessionID = $sessionId; messageID = $messageId }) | Out-Null; continue }
            if ($record.kind -eq 'compaction') { $parts.Add(@{ type = 'compaction'; auto = $false; id = $partId; sessionID = $sessionId; messageID = $messageId }) | Out-Null; continue }
            if ($record.kind -eq 'image') { $parts.Add(@{ type = 'file'; mime = $record.mime; url = $record.url; filename = $record.filename; id = $partId; sessionID = $sessionId; messageID = $messageId }) | Out-Null; continue }
            if ($record.kind -eq 'toolCall') {
                $result = $results[$record.callId]; $startMs = [int64](Get-ObjectPropertyValue $record 'startMs' 0); if (-not $startMs) { $startMs = ConvertTo-ImportEpochMilliseconds $record.timestamp }; if (-not $startMs) { $startMs = ConvertTo-ImportEpochMilliseconds $startedAt }
                $endMs = [int64](Get-ObjectPropertyValue $result 'endMs' 0); if (-not $endMs) { $endMs = ConvertTo-ImportEpochMilliseconds $result.timestamp }; if (-not $endMs) { $endMs = $startMs }
                if ($record.name -eq 'codex_code_mode') {
                    if (-not $activeUserMessage) { throw 'Cannot archive Codex code-mode history without a preceding user message.' }
                    $executionCount = [int](Get-ObjectPropertyValue $record.input 'executionCount' 0)
                    $archiveText = "[Imported history note: $executionCount opaque Codex code-mode execution(s) occurred during the following historical assistant response. Exact JavaScript and persisted outer outputs are archived in this synthetic part's metadata and intentionally excluded from model context. Nothing was re-executed and no nested calls were inferred.]"
                    $activeUserMessage.parts.Add(@{ type = 'text'; text = $archiveText; synthetic = $true; metadata = $record.metadata; id = $partId; sessionID = $sessionId; messageID = $activeUserMessage.info.id }) | Out-Null
                    continue
                }
                $state = @{ status = if ($result.isError) { 'error' } else { 'completed' }; input = $record.input; time = @{ start = $startMs; end = $endMs }; metadata = $record.metadata }
                if ($result.isError) { $state.error = $result.output } else { $state.output = $result.output; $state.title = ConvertTo-OpenCodeToolName $record.name }
                $parts.Add(@{ type = 'tool'; tool = ConvertTo-OpenCodeToolName $record.name; callID = New-OpenCodeImportId 'call_' @($record.callId); state = $state; id = $partId; sessionID = $sessionId; messageID = $messageId }) | Out-Null
            }
        }
        if (-not $parts.Count) { continue }; $created = $logicalMessageMs
        if ($run.role -eq 'user') { $info = @{ role = 'user'; time = @{ created = $created }; agent = 'build'; model = $model; summary = @{ diffs = @() }; id = $messageId; sessionID = $sessionId } }
        else {
            if (-not $previousMessageId) {
                throw 'Cannot convert a Codex history whose first importable message is an assistant response.'
            }
            $usage = @($run.records | Where-Object kind -eq 'usage' | Select-Object -Last 1)
            $tokens = if ($usage.Count) { $usage[0].tokens } else { @{ total = 0; input = 0; output = 0; reasoning = 0; cache = @{ write = 0; read = 0 } } }
            $isSummary = @($run.records | Where-Object { $_.kind -eq 'assistant' -and [bool](Get-ObjectPropertyValue $_ 'summary' $false) }).Count -gt 0
            $info = @{ parentID = $previousMessageId; role = 'assistant'; mode = if ($isSummary) { 'compaction' } else { 'build' }; agent = if ($isSummary) { 'compaction' } else { 'build' }; path = @{ cwd = $TargetDirectory; root = $TargetDirectory }; cost = 0; tokens = $tokens; modelID = $model.modelID; providerID = $model.providerID; time = @{ created = $created; completed = $created }; finish = 'stop'; id = $messageId; sessionID = $sessionId }
            if ($isSummary) { $info.summary = $true }
        }
        $message = @{ info = $info; parts = $parts }
        $messages.Add($message) | Out-Null
        if ($run.role -eq 'user') { $activeUserMessage = $message }
        $previousMessageId = $messageId
    }
    $effectiveTitle = if ($Title) { $Title } else { 'Relocated session' }; $createdMs = ConvertTo-ImportEpochMilliseconds $startedAt
    $lastMs = $createdMs
    foreach ($record in $records) { $recordMs = ConvertTo-ImportEpochMilliseconds $record.timestamp; if ($recordMs -gt $lastMs) { $lastMs = $recordMs } }
    if ($logicalMessageMs -gt $lastMs) { $lastMs = $logicalMessageMs }
    $document = @{ info = @{ id = $sessionId; slug = ConvertTo-OpenCodeSlug $effectiveTitle; directory = $TargetDirectory; projectID = Get-ImportSha1 $TargetDirectory; title = $effectiveTitle; version = '1.0.0'; summary = @{ additions = 0; deletions = 0; files = 0 }; time = @{ created = $createdMs; updated = $lastMs } }; messages = $messages }
    Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Writing bundle with $($messages.Count) messages"
    $outputDirectory = Split-Path -Parent $OutputPath; New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $json = $document | ConvertTo-Json -Depth 100 -Compress; $temporaryOutput = "$OutputPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"; $backupOutput = "$OutputPath.bak-$PID-$([guid]::NewGuid().ToString('N'))"; $removeBackup = $false
    try {
        [System.IO.File]::WriteAllText($temporaryOutput, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $OutputPath) {
            try { [System.IO.File]::Replace($temporaryOutput, $OutputPath, $backupOutput, $true); $removeBackup = $true }
            catch {
                [System.IO.File]::Move($OutputPath, $backupOutput)
                try { [System.IO.File]::Move($temporaryOutput, $OutputPath); $removeBackup = $true }
                catch { if (Test-Path -LiteralPath $backupOutput) { try { [System.IO.File]::Move($backupOutput, $OutputPath) } catch { Write-Warning "Could not restore the previous bundle. Recovery copy retained at $backupOutput" } }; throw }
            }
        } else { [System.IO.File]::Move($temporaryOutput, $OutputPath) }
    } finally {
        if (Test-Path -LiteralPath $temporaryOutput) { Remove-Item -LiteralPath $temporaryOutput -Force }
        if ($removeBackup -and (Test-Path -LiteralPath $backupOutput)) { Remove-Item -LiteralPath $backupOutput -Force }
    }
}
