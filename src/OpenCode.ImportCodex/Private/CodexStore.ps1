function Resolve-CodexDataRoot {
    param([string]$CodexDataRoot)
    if (-not [string]::IsNullOrWhiteSpace($CodexDataRoot)) {
        return [System.IO.Path]::GetFullPath($CodexDataRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profile)) {
        throw 'Could not determine the current user profile. Set CODEX_HOME or pass -CodexDataRoot.'
    }
    [System.IO.Path]::GetFullPath((Join-Path $profile '.codex'))
}

function Read-SharedFirstLine {
    param([Parameter(Mandatory)][string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
    try { $reader.ReadLine() } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-CodexSessionTitleMap {
    param([Parameter(Mandatory)][string]$CodexDataRoot)
    $titles = @{}
    $indexPath = Join-Path $CodexDataRoot 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { return $titles }
    foreach ($line in [System.IO.File]::ReadLines($indexPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            if ($entry.id -and $entry.thread_name) { $titles[[string]$entry.id] = [string]$entry.thread_name }
        } catch { Write-Warning 'Ignored malformed Codex session-index line.' }
    }
    $titles
}

function Get-CodexSessionInventory {
    param([Parameter(Mandatory)][string]$CodexDataRoot)
    $sessionsRoot = Join-Path $CodexDataRoot 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return @() }
    $titles = Get-CodexSessionTitleMap $CodexDataRoot
    $sessions = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in Get-ChildItem -LiteralPath $sessionsRoot -Filter 'rollout-*.jsonl' -File -Recurse) {
        try {
            $record = (Read-SharedFirstLine $file.FullName) | ConvertFrom-Json
            if ($record.type -ne 'session_meta') { continue }
            $meta = $record.payload
            $id = if ($meta.id) { [string]$meta.id } else { [string]$meta.session_id }
            if (-not $id) { continue }
            try { Confirm-CodexSessionId $id } catch {
                Write-Warning "Ignored rollout with an unsafe session ID: $($file.FullName)"
                continue
            }
            $title = if ($titles.ContainsKey($id)) { $titles[$id] } else { '' }
            $session = [pscustomobject]@{
                Id = $id
                Started = [datetimeoffset]$meta.timestamp
                Title = $title
                Directory = [string]$meta.cwd
                SourcePath = $file.FullName
            }
            $session.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.CodexSession')
            $sessions.Add($session) | Out-Null
        } catch {
            Write-Warning "Could not read Codex metadata from $($file.FullName): $($_.Exception.Message)"
        }
    }
    @($sessions | Sort-Object Started -Descending)
}

function ConvertFrom-CodexSessionReference {
    param([Parameter(Mandatory)][string]$Reference)
    $value = $Reference.Trim()
    if ($value -match '(?i)^codex://threads/([A-Za-z0-9_-]{1,128})/?$') { return $Matches[1] }
    if ($value -match '(?i)^codex://') {
        throw "Invalid Codex deeplink: '$value'. Expected codex://threads/<session-id>."
    }
    $value
}

function Select-CodexSessionReference {
    param([Parameter(Mandatory)][object[]]$Sessions, [Parameter(Mandatory)][string[]]$SessionId)
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($reference in $SessionId) {
        if ([string]::IsNullOrWhiteSpace($reference)) { continue }
        $requested = ConvertFrom-CodexSessionReference $reference
        $matches = @($Sessions | Where-Object { $_.Id -eq $requested -or $_.Id.StartsWith($requested) })
        if (-not $matches.Count) { throw "Codex session '$requested' was not found." }
        if ($matches.Count -gt 1) { throw "Codex session prefix '$requested' is ambiguous." }
        $selected.Add($matches[0]) | Out-Null
    }
    @($selected | Sort-Object Id -Unique)
}

function Resolve-CodexInputSession {
    param([Parameter(Mandatory)]$InputObject, [string]$CodexDataRoot)
    $id = [string](Get-ObjectPropertyValue $InputObject 'Id' '')
    $sourcePath = [string](Get-ObjectPropertyValue $InputObject 'SourcePath' '')
    if (-not $id -or -not $sourcePath) {
        throw 'InputObject must be an object returned by Get-CodexSession.'
    }
    Confirm-CodexSessionId $id
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Codex source file does not exist: $sourcePath" }
    $root = if ($CodexDataRoot) { Resolve-CodexDataRoot $CodexDataRoot } else { '' }
    if (-not $root) {
        $directory = (Get-Item -LiteralPath $sourcePath).Directory
        while ($directory -and $directory.Name -ne 'sessions') { $directory = $directory.Parent }
        if (-not $directory -or -not $directory.Parent) { throw "Could not infer the Codex data root from SourcePath: $sourcePath" }
        $root = $directory.Parent.FullName
    }
    [pscustomobject]@{
        Id = $id
        Started = Get-ObjectPropertyValue $InputObject 'Started' $null
        Title = [string](Get-ObjectPropertyValue $InputObject 'Title' '')
        Directory = [string](Get-ObjectPropertyValue $InputObject 'Directory' '')
        SourcePath = [System.IO.Path]::GetFullPath($sourcePath)
        CodexDataRoot = [System.IO.Path]::GetFullPath($root)
    }
}
