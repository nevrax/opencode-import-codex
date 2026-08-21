function Import-CodexSession {
    <#
    .SYNOPSIS
    Imports Codex sessions into OpenCode.
    .DESCRIPTION
    Converts selected Codex sessions, imports each bundle from its target working directory, and verifies the resulting OpenCode session and directory.
    .PARAMETER InputObject
    Codex session objects received from Get-CodexSession.
    .PARAMETER SessionId
    Exact Codex IDs, unique prefixes, or deeplinks to import.
    .PARAMETER All
    Imports every discovered Codex session.
    .PARAMETER CodexDataRoot
    Codex data root used for ID or all-session selection.
    .PARAMETER DestinationDirectory
    Existing target directory for one selected session.
    .PARAMETER OutputDirectory
    Bundle output directory.
    .EXAMPLE
    Get-CodexSession -SessionId 'demo' | Import-CodexSession -WhatIf
    .EXAMPLE
    Import-CodexSession -SessionId 'demo' -CodexDataRoot (Join-Path $HOME 'synthetic-codex') -Confirm:$false
    .OUTPUTS
    OpenCode.ImportCodex.ImportResult
    .NOTES
    This high-impact operation modifies live OpenCode data. If ShouldProcess is declined, neither conversion nor import occurs. Bundles retain session content.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
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
    end { $sessions = @(Resolve-CodexOperationSelection $PSCmdlet.ParameterSetName $inputs.ToArray() $SessionId $CodexDataRoot); Invoke-CodexImportOperation $sessions $DestinationDirectory $OutputDirectory $PSCmdlet }
}
