function Get-OpenCodeSessionInventory {
    param([Parameter(Mandatory)]$OpenCodeCli)
    $query = 'SELECT id, title, time_updated AS updated, time_created AS created, project_id AS projectId, directory FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC'
    $response = Invoke-ApplicationText $OpenCodeCli.Path @('db', $query, '--format', 'json', '--pure')
    $json = $response.Text.Trim()
    if ($response.ExitCode -ne 0) { throw 'OpenCode session listing failed.' }
    if (-not $json) { return @() }
    $records = $json | ConvertFrom-Json
    @(foreach ($record in @($records)) {
        $session = [pscustomobject]@{
            Id = [string]$record.id
            Title = [string]$record.title
            Updated = [datetimeoffset]::Parse('1970-01-01T00:00:00Z').AddMilliseconds([int64]$record.updated)
            Created = [datetimeoffset]::Parse('1970-01-01T00:00:00Z').AddMilliseconds([int64]$record.created)
            ProjectId = [string]$record.projectId
            Directory = [string]$record.directory
        }
        $session.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.OpenCodeSession')
        $session
    })
}

function Select-OpenCodeSessionReference {
    param([Parameter(Mandatory)][object[]]$Sessions, [Parameter(Mandatory)][string[]]$SessionId)
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($requested in $SessionId) {
        if ([string]::IsNullOrWhiteSpace($requested)) { continue }
        $matches = @($Sessions | Where-Object { $_.Id -eq $requested -or $_.Id.StartsWith($requested) })
        if (-not $matches.Count) { throw "OpenCode session '$requested' was not found." }
        if ($matches.Count -gt 1) { throw "OpenCode session prefix '$requested' is ambiguous." }
        $selected.Add($matches[0]) | Out-Null
    }
    @($selected | Sort-Object Id -Unique)
}

function Import-OpenCodeImportBundle {
    param(
        [Parameter(Mandatory)]$Bundle,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)]$OpenCodeCli,
        [int]$ProgressId = 0,
        [string]$ProgressActivity = 'Importing Codex session'
    )
    Push-Location -LiteralPath $TargetDirectory
    try {
        Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status "Importing $($Bundle.MessageCount) messages into OpenCode"
        Invoke-CheckedApplication $OpenCodeCli.Path @('import', $Bundle.Path, '--pure')
        Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status 'Verifying imported OpenCode session'
        $response = Invoke-ApplicationText $OpenCodeCli.Path @('session', 'list', '-n', '10000', '--format', 'json', '--pure')
        $json = $response.Text
        if ($response.ExitCode -ne 0) { throw 'OpenCode session-list verification failed.' }
        $sessions = $json | ConvertFrom-Json
        $imported = @($sessions | Where-Object { $_.id -eq $Bundle.OpenCodeSessionId })
        if (-not $imported.Count) { throw "OpenCode import verification failed for $($Bundle.OpenCodeSessionId)." }
        if (-not (Test-FileSystemPathEqual ([string]$imported[0].directory) $TargetDirectory)) {
            throw "Session directory mismatch. Expected '$TargetDirectory', got '$($imported[0].directory)'."
        }
    } finally { Pop-Location }
}

function Remove-OpenCodeSessionItem {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$OpenCodeCli)
    Invoke-CheckedApplication $OpenCodeCli.Path @('session', 'delete', [string]$Session.Id, '--pure')
}
