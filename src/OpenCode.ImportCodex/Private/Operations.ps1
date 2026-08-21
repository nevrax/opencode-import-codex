function Resolve-CodexOperationSelection {
    param(
        [Parameter(Mandatory)][ValidateSet('Pipeline', 'ById', 'All')][string]$ParameterSetName,
        [object[]]$InputObject,
        [string[]]$SessionId,
        [string]$CodexDataRoot
    )
    if ($ParameterSetName -eq 'Pipeline') {
        return @($InputObject | ForEach-Object { Resolve-CodexInputSession $_ $CodexDataRoot })
    }
    $root = Resolve-CodexDataRoot $CodexDataRoot
    $sessions = @(Get-CodexSessionInventory $root)
    $selected = if ($ParameterSetName -eq 'All') {
        $sessions
    }
    else {
        @(Select-CodexSessionReference $sessions $SessionId)
    }
    @($selected | ForEach-Object { Resolve-CodexInputSession $_ $root })
}

function Resolve-CodexTargetDirectory {
    param([Parameter(Mandatory)]$Session, [string]$DestinationDirectory, [Parameter(Mandatory)][int]$SelectionCount)
    if ($DestinationDirectory -and $SelectionCount -ne 1) {
        throw '-DestinationDirectory can only be used with one Codex session.'
    }
    $candidate = if ($DestinationDirectory) { $DestinationDirectory } else { [string]$Session.Directory }
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Target directory does not exist for Codex session $($Session.Id): '$candidate'. Pass -DestinationDirectory."
    }
    (Resolve-Path -LiteralPath $candidate).Path
}

function Convert-CodexOperationSession {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [string]$OutputDirectory,
        [int]$ProgressId = 0,
        [string]$ProgressActivity = 'Converting Codex session'
    )
    $root = [string]$Session.CodexDataRoot
    $exportRoot = Get-OpenCodeImportOutputDirectory $OutputDirectory $root
    $outputPath = [System.IO.Path]::GetFullPath((Join-Path $exportRoot "$($Session.Id).json"))
    if (-not (Test-FileSystemPathInside $outputPath $exportRoot)) { throw "Output path escaped OutputDirectory: $outputPath" }
    Invoke-NativeCodexConversion -SourcePath $Session.SourcePath -SourceSessionId $Session.Id -TargetDirectory $TargetDirectory -Title $Session.Title -OutputPath $outputPath -ProgressId $ProgressId -ProgressActivity $ProgressActivity
    Write-Progress -Id $ProgressId -Activity $ProgressActivity -Status 'Validating generated bundle'
    $bundle = Test-OpenCodeImportBundle $outputPath $TargetDirectory
    $result = [pscustomobject]@{
        CodexSessionId = $Session.Id
        OpenCodeSessionId = $bundle.OpenCodeSessionId
        Action = 'Converted'
        ExistingMessages = 0
        NewMessages = $bundle.MessageCount
        NewParts = $bundle.PartCount
        OpenCodeOnlyMessages = 0
        ChangedMessages = 0
        ChangedParts = 0
        Directory = $TargetDirectory
        BundlePath = $bundle.Path
        Imported = $false
    }
    $result.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.ConversionResult')
    $result
}

function Invoke-CodexConversionOperation {
    param([object[]]$Sessions, [string]$DestinationDirectory, [string]$OutputDirectory)
    if (-not @($Sessions).Count) { return }
    foreach ($session in @($Sessions)) {
        $target = Resolve-CodexTargetDirectory $session $DestinationDirectory @($Sessions).Count
        $activity = "Converting Codex session $($session.Id)"
        try { Convert-CodexOperationSession -Session $session -TargetDirectory $target -OutputDirectory $OutputDirectory -ProgressId 0 -ProgressActivity $activity }
        finally { Write-Progress -Id 0 -Activity $activity -Completed }
    }
}

function Invoke-CodexPlanOperation {
    param([object[]]$Sessions, [string]$DestinationDirectory, [string]$OutputDirectory)
    $cli = Get-RequiredOpenCodeCli
    $inventory = @(Get-OpenCodeSessionInventory $cli)
    foreach ($session in @($Sessions)) {
        $target = Resolve-CodexTargetDirectory $session $DestinationDirectory @($Sessions).Count
        $activity = "Planning Codex session $($session.Id)"
        try {
            $converted = Convert-CodexOperationSession -Session $session -TargetDirectory $target -OutputDirectory $OutputDirectory -ProgressId 0 -ProgressActivity $activity
            $bundle = Test-OpenCodeImportBundle $converted.BundlePath $target
            $plan = Get-OpenCodeBundleImportPlan $bundle $inventory $cli
            $converted.Action = $plan.Action
            $converted.ExistingMessages = $plan.ExistingMessages
            $converted.NewMessages = $plan.NewMessages
            $converted.NewParts = $plan.NewParts
            $converted.OpenCodeOnlyMessages = $plan.OpenCodeOnlyMessages
            $converted.ChangedMessages = $plan.ChangedMessages
            $converted.ChangedParts = $plan.ChangedParts
            $converted.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.ImportPlan')
            $converted
        } finally { Write-Progress -Id 0 -Activity $activity -Completed }
    }
}

function Invoke-CodexImportOperation {
    param([object[]]$Sessions, [string]$DestinationDirectory, [string]$OutputDirectory, [Parameter(Mandatory)]$Cmdlet)
    $cli = Get-RequiredOpenCodeCli
    foreach ($session in @($Sessions)) {
        $target = Resolve-CodexTargetDirectory $session $DestinationDirectory @($Sessions).Count
        $openCodeSessionId = New-OpenCodeImportId 'ses_' @($session.Id)
        $inventory = @(Get-OpenCodeSessionInventory $cli)
        $existingSession = $inventory | Where-Object Id -eq $openCodeSessionId | Select-Object -First 1
        if ($existingSession -and -not (Test-FileSystemPathEqual ([string]$existingSession.Directory) $target)) {
            throw "OpenCode session $openCodeSessionId already belongs to '$($existingSession.Directory)', not '$target'. Use the existing directory or remove the conflicting session first."
        }
        if (-not $Cmdlet.ShouldProcess("Codex session '$($session.Id)' in '$target'", 'Convert and import into OpenCode')) { continue }
        $activity = "Importing Codex session $($session.Id)"
        try {
            $converted = Convert-CodexOperationSession -Session $session -TargetDirectory $target -OutputDirectory $OutputDirectory -ProgressId 0 -ProgressActivity $activity
            $bundle = Test-OpenCodeImportBundle $converted.BundlePath $target
            Import-OpenCodeImportBundle -Bundle $bundle -TargetDirectory $target -OpenCodeCli $cli -ProgressId 0 -ProgressActivity $activity
            $converted.Action = 'Imported'
            $converted.Imported = $true
            $converted.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.ImportResult')
            $converted
        } finally { Write-Progress -Id 0 -Activity $activity -Completed }
    }
}
