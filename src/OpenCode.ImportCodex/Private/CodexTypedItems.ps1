function Get-CodexAliasedValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names,
        $Default = $null
    )
    foreach ($name in $Names) {
        $value = Get-ObjectPropertyValue $InputObject $name $null
        if ($null -ne $value) { return $value }
    }
    $Default
}

function Get-CodexNormalizedItemType {
    param([AllowEmptyString()][string]$Type)
    ([regex]::Replace($Type, '[^A-Za-z0-9]', '')).ToLowerInvariant()
}

function ConvertTo-CodexDurationMilliseconds {
    param($Value)
    if ($null -eq $Value) { return [int64]0 }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [double] -or $Value -is [decimal]) {
        return [int64]$Value
    }
    if ($Value -is [string]) {
        $number = 0.0
        if ([double]::TryParse($Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
            return [int64]$number
        }
        if ($Value -match '^([0-9]+(?:\.[0-9]+)?)s$') { return [int64]([double]$Matches[1] * 1000) }
    }
    $seconds = Get-CodexAliasedValue $Value @('secs', 'seconds') 0
    $nanoseconds = Get-CodexAliasedValue $Value @('nanos', 'nanoseconds') 0
    [int64]([double]$seconds * 1000 + [double]$nanoseconds / 1000000)
}

function Get-CodexTextOutput {
    param($Value, [AllowEmptyString()][string]$Fallback = '')
    if ($null -eq $Value) { return $Fallback }
    if ($Value -is [string]) { return $Value }
    $Value | ConvertTo-Json -Depth 100 -Compress
}

function ConvertTo-CodexShlexCommand {
    param([Parameter(Mandatory)][object[]]$Arguments)
    $quoted = foreach ($argumentValue in $Arguments) {
        $argument = [string]$argumentValue
        if ($argument.IndexOf([char]0) -ge 0) { return '<command included NUL byte>' }
        if ($argument -match '^[A-Za-z0-9_@%+=:,./-]+$') { $argument }
        else {
            $replacement = [string]::Concat([char]39, [char]34, [char]39, [char]34, [char]39)
            ([string][char]39) + $argument.Replace([string][char]39, $replacement) + [char]39
        }
    }
    $quoted -join ' '
}

function ConvertFrom-CodexPathUri {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '^file:') { return $Value }
    try { $uri = [uri]$Value } catch { return $Value }
    if (-not $uri.IsFile) { return $Value }
    $path = [uri]::UnescapeDataString($uri.AbsolutePath)
    if ($path -match '^/?([A-Za-z]):(.*)$') { return $Matches[1].ToUpperInvariant() + ':' + $Matches[2].Replace([char]47, [char]92) }
    if ($uri.Host -and $uri.Host -ne 'localhost') { return '\\' + $uri.Host + $path.Replace([char]47, [char]92) }
    $path
}

function Get-CodexPatchCounts {
    param([AllowEmptyString()][string]$Patch)
    $additions = 0
    $deletions = 0
    foreach ($line in @($Patch -split "`r?`n")) {
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { $additions++ }
        if ($line.StartsWith('-') -and -not $line.StartsWith('---')) { $deletions++ }
    }
    [pscustomobject]@{ Additions = $additions; Deletions = $deletions }
}

function Get-CodexContentLineCount {
    param([AllowEmptyString()][string]$Content)
    if (-not $Content) { return 0 }
    $lines = @($Content -split "`r?`n")
    if ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -eq '') { return $lines.Count - 1 }
    $lines.Count
}

function ConvertTo-OpenCodePatchFiles {
    param([Parameter(Mandatory)]$Changes)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $entries = if ($Changes -is [System.Collections.IDictionary]) {
        @($Changes.Keys | ForEach-Object { [pscustomobject]@{ Path = [string]$_; Change = $Changes[$_] } })
    } elseif ($Changes -is [pscustomobject] -and -not (Get-ObjectPropertyValue $Changes 'path' $null)) {
        @($Changes.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Path = $_.Name; Change = $_.Value } })
    } else {
        @($Changes | ForEach-Object { [pscustomobject]@{ Path = [string](Get-CodexAliasedValue $_ @('path', 'filePath') ''); Change = $_ } })
    }
    $entries = [object[]]@($entries)
    for ($index = 1; $index -lt $entries.Count; $index++) {
        $entryToInsert = $entries[$index]
        $position = $index - 1
        while ($position -ge 0 -and [string]::CompareOrdinal([string]$entries[$position].Path, [string]$entryToInsert.Path) -gt 0) {
            $entries[$position + 1] = $entries[$position]
            $position--
        }
        $entries[$position + 1] = $entryToInsert
    }
    foreach ($entry in $entries) {
        $change = $entry.Change
        $kindValue = Get-ObjectPropertyValue $change 'kind' (Get-ObjectPropertyValue $change 'type' 'update')
        $kind = if ($kindValue -is [string]) { Get-CodexNormalizedItemType $kindValue } else { Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $kindValue 'type' 'update')) }
        $movePath = [string](Get-CodexAliasedValue $change @('move_path', 'movePath') '')
        if (-not $movePath -and $kindValue -and -not ($kindValue -is [string])) { $movePath = [string](Get-CodexAliasedValue $kindValue @('move_path', 'movePath') '') }
        $patch = [string](Get-CodexAliasedValue $change @('diff', 'unified_diff', 'unifiedDiff', 'patch') '')
        $content = [string](Get-ObjectPropertyValue $change 'content' $patch)
        $type = if ($movePath) { 'move' } elseif ($kind -eq 'add') { 'add' } elseif ($kind -eq 'delete') { 'delete' } else { 'update' }
        $file = @{ filePath = $entry.Path; relativePath = if ($movePath) { $movePath } else { $entry.Path }; type = $type }
        if ($type -eq 'add') {
            $file.before = ''
            $file.after = $content
            $file.additions = Get-CodexContentLineCount $content
            $file.deletions = 0
        } elseif ($type -eq 'delete') {
            $file.before = $content
            $file.after = ''
            $file.additions = 0
            $file.deletions = Get-CodexContentLineCount $content
        } else {
            $file.patch = $patch
            if ($movePath) { $file.movePath = $movePath }
            $counts = Get-CodexPatchCounts $patch
            $file.additions = $counts.Additions
            $file.deletions = $counts.Deletions
        }
        $files.Add($file) | Out-Null
    }
    $files.ToArray()
}

function New-CodexTypedItemPair {
    param(
        [Parameter(Mandatory)]$Payload,
        [AllowEmptyString()][string]$Timestamp
    )
    $item = Get-ObjectPropertyValue $Payload 'item' $null
    if (-not $item) { return $null }
    $type = Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $item 'type' ''))
    if ($type -eq 'extension' -and [string](Get-ObjectPropertyValue $item 'kind' '') -eq 'web.search') { $type = 'websearch' }
    if ($type -in @('usermessage', 'agentmessage', 'reasoning')) { return $null }
    $id = [string](Get-ObjectPropertyValue $item 'id' '')
    if (-not $id) { $id = 'anonymous-' + (Get-ImportSha1 ($item | ConvertTo-Json -Depth 100 -Compress)).Substring(0, 16) }
    $turnId = [string](Get-CodexAliasedValue $Payload @('turn_id', 'turnId') '')
    $startedMs = [int64](Get-CodexAliasedValue $Payload @('started_at_ms', 'startedAtMs') 0)
    $completedMs = [int64](Get-CodexAliasedValue $Payload @('completed_at_ms', 'completedAtMs') 0)
    $status = ([string](Get-ObjectPropertyValue $item 'status' 'completed')).ToLowerInvariant()
    $duration = ConvertTo-CodexDurationMilliseconds (Get-CodexAliasedValue $item @('duration_ms', 'durationMs', 'duration') $null)
    if (-not $startedMs -and $completedMs -and $duration) { $startedMs = $completedMs - $duration }
    $call = @{ kind = 'toolCall'; callId = $id; timestamp = $Timestamp; startMs = $startedMs; endMs = $completedMs; turnId = $turnId; suppress = $false; authority = 3 }
    $result = @{ kind = 'toolResult'; callId = $call.callId; timestamp = $Timestamp; endMs = $completedMs; authority = 3; isError = $status -in @('failed', 'declined') }

    switch ($type) {
        'commandexecution' {
            $commandValue = Get-ObjectPropertyValue $item 'command' ''
            $command = if ($commandValue -is [array]) { ConvertTo-CodexShlexCommand @($commandValue) } else { [string]$commandValue }
            $cwd = ConvertFrom-CodexPathUri ([string](Get-CodexAliasedValue $item @('cwd', 'workdir') ''))
            $stdout = [string](Get-ObjectPropertyValue $item 'stdout' '')
            $stderr = [string](Get-ObjectPropertyValue $item 'stderr' '')
            $output = [string](Get-CodexAliasedValue $item @('aggregated_output', 'aggregatedOutput') '')
            if (-not $output) { $output = @($stdout, $stderr) | Where-Object { $_ }; $output = $output -join "`n" }
            if (-not $output) { $output = [string](Get-CodexAliasedValue $item @('formatted_output', 'formattedOutput') '') }
            $actions = Get-CodexAliasedValue $item @('parsed_cmd', 'parsedCmd', 'command_actions', 'commandActions') @()
            $exitCode = Get-CodexAliasedValue $item @('exit_code', 'exitCode') $null
            $call.name = 'bash'
            $call.input = @{ command = $command }
            if ($cwd) { $call.input.workdir = $cwd }
            $call.metadata = @{ command = $command; commandArguments = if ($commandValue -is [array]) { @($commandValue) } else { $null }; output = $output; exitCode = $exitCode; status = $status; start = $startedMs; end = $completedMs; duration = $duration; cwd = $cwd; parsedAction = $actions; codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            $result.output = $output
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'filechange' {
            $changes = Get-ObjectPropertyValue $item 'changes' @()
            $files = @(ConvertTo-OpenCodePatchFiles $changes)
            $call.name = 'apply_patch'
            $call.input = @{ files = @($files | ForEach-Object { $_.relativePath }); changes = $changes }
            $call.metadata = @{ files = $files; status = $status; stdout = [string](Get-ObjectPropertyValue $item 'stdout' ''); stderr = [string](Get-ObjectPropertyValue $item 'stderr' ''); codex = @{ source = 'item_completed'; item = $item; changes = $changes; turnId = $turnId } }
            $result.output = @($call.metadata.stdout, $call.metadata.stderr) | Where-Object { $_ }
            $result.output = $result.output -join "`n"
            if (-not $result.output) { $result.output = "Applied changes to $($files.Count) file(s)." }
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'mcptoolcall' {
            $server = [string](Get-ObjectPropertyValue $item 'server' 'mcp')
            $tool = [string](Get-ObjectPropertyValue $item 'tool' 'tool')
            $call.name = ("mcp__$server`__$tool" -replace '[^A-Za-z0-9_-]', '_')
            $call.input = ConvertTo-OpenCodeToolInput (Get-ObjectPropertyValue $item 'arguments' $null)
            $call.metadata = @{ status = $status; duration = $duration; server = $server; tool = $tool; codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            $errorValue = Get-ObjectPropertyValue $item 'error' $null
            $resultValue = Get-ObjectPropertyValue $item 'result' $null
            $resultIsError = if ($resultValue) { [bool](Get-CodexAliasedValue $resultValue @('is_error', 'isError') $false) } else { $false }
            $result.isError = $result.isError -or $resultIsError -or $null -ne $errorValue
            if ($errorValue) { $result.output = [string](Get-ObjectPropertyValue $errorValue 'message' $errorValue) }
            elseif ($resultValue) {
                $pieces = New-Object 'System.Collections.Generic.List[string]'
                foreach ($content in @(Get-ObjectPropertyValue $resultValue 'content' @())) {
                    $contentType = Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $content 'type' ''))
                    if ($contentType -eq 'text') { $text = [string](Get-ObjectPropertyValue $content 'text' ''); if ($text) { $pieces.Add($text) | Out-Null } }
                    elseif ($contentType -eq 'image') { $pieces.Add("[MCP image: $([string](Get-CodexAliasedValue $content @('mimeType', 'mime_type') 'unknown'))]") | Out-Null }
                    else { $pieces.Add((Get-CodexTextOutput $content '')) | Out-Null }
                }
                $structured = Get-CodexAliasedValue $resultValue @('structured_content', 'structuredContent') $null
                if ($null -ne $structured) { $pieces.Add((Get-CodexTextOutput $structured '')) | Out-Null }
                $result.output = if ($pieces.Count) { $pieces -join "`n" } else { Get-CodexTextOutput $resultValue 'MCP tool completed without persisted output.' }
            } else { $result.output = 'MCP tool completed without persisted output.' }
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'websearch' {
            $action = Get-ObjectPropertyValue $item 'action' $null
            $actionType = Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $action 'type' 'search'))
            $call.name = if ($actionType -in @('openpage', 'findinpage')) { 'webfetch' } else { 'websearch' }
            $call.input = @{}
            $query = [string](Get-ObjectPropertyValue $item 'query' '')
            $url = [string](Get-ObjectPropertyValue $action 'url' '')
            if ($query) { $call.input.query = $query }
            if ($url) { $call.input.url = $url }
            $call.metadata = @{ action = $action; results = @(Get-ObjectPropertyValue $item 'results' @()); codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            $result.output = Get-CodexTextOutput $call.metadata.results 'No persisted web results.'
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'imageview' {
            $path = ConvertFrom-CodexPathUri ([string](Get-CodexAliasedValue $item @('path', 'filePath') ''))
            $call.name = 'read'
            $call.input = @{ filePath = $path }
            $call.metadata = @{ codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            $result.output = "Viewed image at $path. Image bytes are not stored in this transcript."
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'dynamictoolcall' {
            $namespace = [string](Get-ObjectPropertyValue $item 'namespace' '')
            $tool = [string](Get-ObjectPropertyValue $item 'tool' 'dynamic')
            $rawName = if ($namespace) { "dynamic__$namespace`__$tool" } else { "dynamic__$tool" }
            $call.name = $rawName -replace '[^A-Za-z0-9_-]', '_'
            $call.input = ConvertTo-OpenCodeToolInput (Get-ObjectPropertyValue $item 'arguments' $null)
            $content = Get-CodexAliasedValue $item @('content_items', 'contentItems') $null
            $errorValue = Get-ObjectPropertyValue $item 'error' $null
            $success = Get-ObjectPropertyValue $item 'success' $null
            $result.isError = $result.isError -or $success -eq $false -or $null -ne $errorValue
            if ($errorValue) { $result.output = [string]$errorValue }
            elseif ($null -ne $content) {
                $pieces = New-Object 'System.Collections.Generic.List[string]'
                foreach ($contentItem in @($content)) {
                    $contentType = Get-CodexNormalizedItemType ([string](Get-ObjectPropertyValue $contentItem 'type' ''))
                    if ($contentType -eq 'inputtext') { $pieces.Add([string](Get-ObjectPropertyValue $contentItem 'text' '')) | Out-Null }
                    elseif ($contentType -eq 'inputimage') { $pieces.Add("[Dynamic tool image: $([string](Get-CodexAliasedValue $contentItem @('imageUrl', 'image_url') ''))]") | Out-Null }
                    elseif ($contentType -eq 'inputaudio') { $pieces.Add("[Dynamic tool audio: $([string](Get-CodexAliasedValue $contentItem @('audioUrl', 'audio_url') ''))]") | Out-Null }
                    else { $pieces.Add((Get-CodexTextOutput $contentItem '')) | Out-Null }
                }
                $result.output = if ($pieces.Count) { $pieces -join "`n" } else { 'Dynamic tool completed without persisted output.' }
            } else { $result.output = 'Dynamic tool completed without persisted output.' }
            $call.metadata = @{ status = $status; success = $success; duration = $duration; contentItems = $content; codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
        'plan' {
            $text = [string](Get-ObjectPropertyValue $item 'text' '')
            $call.name = 'codex_plan'
            $call.input = @{ text = $text }
            $call.metadata = @{ codex = @{ source = 'item_completed'; item = $item; turnId = $turnId } }
            $result.output = if ($text) { $text } else { 'Codex recorded an empty plan.' }
            return [pscustomobject]@{ Call = $call; Result = $result }
        }
    }
    $call.name = 'codex_item'
    $call.input = @{ itemType = [string](Get-ObjectPropertyValue $item 'type' 'unknown'); item = $item }
    $call.metadata = @{ codex = @{ source = 'item_completed'; item = $item; turnId = $turnId; fidelity = 'generic_typed_item' } }
    $result.output = "Preserved unsupported Codex typed item '$([string](Get-ObjectPropertyValue $item 'type' 'unknown'))'."
    [pscustomobject]@{ Call = $call; Result = $result }
}
