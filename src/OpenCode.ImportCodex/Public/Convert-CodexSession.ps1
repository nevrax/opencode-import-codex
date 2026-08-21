function Convert-CodexSession {
    <#
    .SYNOPSIS
    Converts Codex sessions to OpenCode bundles.
    .DESCRIPTION
    Converts selected Codex rollout sessions with deterministic IDs and validates each generated OpenCode bundle without modifying OpenCode.
    .PARAMETER InputObject
    Codex session objects received from Get-CodexSession.
    .PARAMETER SessionId
    Exact Codex IDs, unique prefixes, or deeplinks to convert.
    .PARAMETER All
    Converts every discovered Codex session.
    .PARAMETER CodexDataRoot
    Codex data root used for ID or all-session selection.
    .PARAMETER DestinationDirectory
    Existing project directory embedded in one converted session. Valid only when one session is selected.
    .PARAMETER OutputDirectory
    Bundle directory. Defaults to the user-local OpenCode.ImportCodex exports directory.
    .EXAMPLE
    Get-CodexSession -SessionId 'demo' | Convert-CodexSession -OutputDirectory (Join-Path $HOME 'exports')
    .EXAMPLE
    Convert-CodexSession -SessionId 'demo' -CodexDataRoot (Join-Path $HOME 'synthetic-codex') -DestinationDirectory (Join-Path $HOME 'projects/demo')
    .OUTPUTS
    OpenCode.ImportCodex.ConversionResult
    .NOTES
    Bundles can contain conversation text, tool input and output, and embedded images. Protect the output directory accordingly.
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
    end {
        $sessions = @(Resolve-CodexOperationSelection $PSCmdlet.ParameterSetName $inputs.ToArray() $SessionId $CodexDataRoot)
        Invoke-CodexConversionOperation $sessions $DestinationDirectory $OutputDirectory
    }
}
