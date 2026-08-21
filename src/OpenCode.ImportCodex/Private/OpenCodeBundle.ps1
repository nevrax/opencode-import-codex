function Test-OpenCodeImportBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetDirectory
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Conversion produced no OpenCode bundle: $Path"
    }
    $bundle = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $bundle.info -or -not $bundle.info.id -or -not $bundle.info.id.StartsWith('ses_')) {
        throw 'Conversion produced a bundle with an invalid OpenCode session ID.'
    }
    if (-not @($bundle.messages).Count) { throw 'Conversion produced a bundle with no messages.' }
    $messageIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $partIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($message in @($bundle.messages)) {
        if ($message.info.role -notin @('user', 'assistant')) { throw 'Bundle contains an invalid message role.' }
        if (-not $message.info.id -or -not @($message.parts).Count) { throw 'Bundle contains an empty or unidentified message.' }
        if (-not $messageIds.Add([string]$message.info.id)) { throw 'Bundle contains duplicate message IDs.' }
        if ($message.info.sessionID -ne $bundle.info.id) { throw 'Bundle contains a message with the wrong session ID.' }
        foreach ($part in @($message.parts)) {
            if ($part.type -notin @('text', 'tool', 'file', 'compaction') -or -not $part.id) { throw 'Bundle contains an invalid message part.' }
            if (-not $partIds.Add([string]$part.id)) { throw 'Bundle contains duplicate part IDs.' }
            if ($part.sessionID -ne $bundle.info.id -or $part.messageID -ne $message.info.id) {
                throw 'Bundle contains a part with inconsistent parent IDs.'
            }
            if ($part.type -eq 'tool' -and $part.state.status -notin @('completed', 'error')) {
                throw 'Bundle contains an invalid tool state.'
            }
            if ($part.type -eq 'file' -and ($part.mime -notmatch '^image/' -or $part.url -notmatch '^data:image/')) {
                throw 'Bundle contains an unsafe or unsupported image part.'
            }
        }
    }
    if (-not (Test-FileSystemPathEqual ([string]$bundle.info.directory) $TargetDirectory)) {
        throw "Bundle directory mismatch. Expected '$TargetDirectory', got '$($bundle.info.directory)'."
    }
    [pscustomobject]@{
        Path = $Path
        OpenCodeSessionId = [string]$bundle.info.id
        MessageCount = @($bundle.messages).Count
        PartCount = $partIds.Count
        EmbeddedDirectory = [string]$bundle.info.directory
    }
}

function ConvertTo-CanonicalData {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $result[$key] = ConvertTo-CanonicalData $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
            $result[$property.Name] = ConvertTo-CanonicalData $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { ConvertTo-CanonicalData $_ })
        return ,$items
    }
    $Value
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)]$Value)
    ConvertTo-CanonicalData $Value | ConvertTo-Json -Depth 100 -Compress
}

function Get-OpenCodeBundleImportPlan {
    param(
        [Parameter(Mandatory)]$Bundle,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OpenCodeSessions,
        [Parameter(Mandatory)]$OpenCodeCli
    )
    $generated = Get-Content -LiteralPath $Bundle.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $generatedMessages = @($generated.messages)
    $generatedParts = @($generatedMessages | ForEach-Object { @($_.parts) })
    $existingSession = $OpenCodeSessions | Where-Object Id -eq $Bundle.OpenCodeSessionId | Select-Object -First 1
    if (-not $existingSession) {
        return [pscustomobject]@{ Action = 'Create'; ExistingMessages = 0; NewMessages = $generatedMessages.Count; NewParts = $generatedParts.Count; OpenCodeOnlyMessages = 0; ChangedMessages = 0; ChangedParts = 0 }
    }
    if (-not (Test-FileSystemPathEqual ([string]$existingSession.Directory) $Bundle.EmbeddedDirectory)) {
        throw "OpenCode session $($Bundle.OpenCodeSessionId) already belongs to '$($existingSession.Directory)', not '$($Bundle.EmbeddedDirectory)'. Use the existing directory or remove the conflicting session first."
    }
    $response = Invoke-ApplicationText $OpenCodeCli.Path @('export', $Bundle.OpenCodeSessionId, '--pure')
    $exportJson = $response.Text
    if ($response.ExitCode -ne 0 -or -not $exportJson.Trim()) {
        throw "Could not export existing OpenCode session $($Bundle.OpenCodeSessionId) for planning."
    }
    $existing = $exportJson | ConvertFrom-Json
    $existingMessages = @($existing.messages)
    $existingParts = @($existingMessages | ForEach-Object { @($_.parts) })
    $existingMessageIds = New-Object 'System.Collections.Generic.HashSet[string]' (,[string[]]@($existingMessages | ForEach-Object { [string]$_.info.id }))
    $existingPartIds = New-Object 'System.Collections.Generic.HashSet[string]' (,[string[]]@($existingParts | ForEach-Object { [string]$_.id }))
    $generatedMessageIds = New-Object 'System.Collections.Generic.HashSet[string]' (,[string[]]@($generatedMessages | ForEach-Object { [string]$_.info.id }))
    $existingMessagesById = @{}
    $existingPartsById = @{}
    foreach ($message in $existingMessages) { $existingMessagesById[[string]$message.info.id] = $message }
    foreach ($part in $existingParts) { $existingPartsById[[string]$part.id] = $part }
    $changedMessages = @($generatedMessages | Where-Object {
        $id = [string]$_.info.id
        $existingMessagesById.ContainsKey($id) -and
            (ConvertTo-CanonicalJson $_.info) -cne (ConvertTo-CanonicalJson $existingMessagesById[$id].info)
    }).Count
    $changedParts = @($generatedParts | Where-Object {
        $id = [string]$_.id
        $existingPartsById.ContainsKey($id) -and
            (ConvertTo-CanonicalJson $_) -cne (ConvertTo-CanonicalJson $existingPartsById[$id])
    }).Count
    [pscustomobject]@{
        Action = if ($changedMessages -or $changedParts) { 'Conflict' } else { 'Append/no-op' }
        ExistingMessages = $existingMessages.Count
        NewMessages = @($generatedMessages | Where-Object { -not $existingMessageIds.Contains([string]$_.info.id) }).Count
        NewParts = @($generatedParts | Where-Object { -not $existingPartIds.Contains([string]$_.id) }).Count
        OpenCodeOnlyMessages = @($existingMessages | Where-Object { -not $generatedMessageIds.Contains([string]$_.info.id) }).Count
        ChangedMessages = $changedMessages
        ChangedParts = $changedParts
    }
}
