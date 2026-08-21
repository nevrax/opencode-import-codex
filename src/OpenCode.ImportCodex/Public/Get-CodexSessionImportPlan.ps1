function Get-CodexSessionImportPlan {
    <#
    .SYNOPSIS
    Gets OpenCode import plans for Codex sessions.
    .DESCRIPTION
    Converts and validates selected sessions, then compares deterministic message and part IDs with existing OpenCode data. OpenCode is not modified.
    .PARAMETER InputObject
    Codex session objects received from Get-CodexSession.
    .PARAMETER SessionId
    Exact Codex IDs, unique prefixes, or deeplinks to plan.
    .PARAMETER All
    Plans every discovered Codex session.
    .PARAMETER CodexDataRoot
    Codex data root used for ID or all-session selection.
    .PARAMETER DestinationDirectory
    Existing target directory for one selected session.
    .PARAMETER OutputDirectory
    Bundle output directory.
    .EXAMPLE
    Get-CodexSession -SessionId 'demo' | Get-CodexSessionImportPlan
    .EXAMPLE
    Get-CodexSessionImportPlan -All -CodexDataRoot (Join-Path $HOME 'synthetic-codex') -OutputDirectory (Join-Path $HOME 'exports')
    .OUTPUTS
    OpenCode.ImportCodex.ImportPlan
    .NOTES
    Requires the OpenCode CLI. Generated bundles can contain sensitive session content.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Pipeline')]$InputObject,
        [Parameter(Mandatory, ParameterSetName = 'ById')][Alias('DeepLink')][string[]]$SessionId,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All,
        [Parameter(ParameterSetName = 'ById')][Parameter(ParameterSetName = 'All')][string]$CodexDataRoot,
        [string]$DestinationDirectory,
        [string]$OutputDirectory
    )
    begin { $inputs = New-Object 'System.Collections.Generic.List[object]' }
    process { if ($PSCmdlet.ParameterSetName -eq 'Pipeline') { $inputs.Add($InputObject) | Out-Null } }
    end { $sessions = @(Resolve-CodexOperationSelection $PSCmdlet.ParameterSetName $inputs.ToArray() $SessionId $CodexDataRoot); Invoke-CodexPlanOperation $sessions $DestinationDirectory $OutputDirectory }
}
