function Get-OpenCodeSession {
    <#
    .SYNOPSIS
    Gets OpenCode root sessions.
    .DESCRIPTION
    Queries the OpenCode CLI and returns normalized objects without applying display formatting.
    .PARAMETER SessionId
    Optional exact OpenCode session IDs or unique prefixes.
    .EXAMPLE
    Get-OpenCodeSession
    .EXAMPLE
    Get-OpenCodeSession -SessionId 'ses_1234'
    .OUTPUTS
    OpenCode.ImportCodex.OpenCodeSession
    .NOTES
    Requires the OpenCode CLI and reads its local session database.
    #>
    [CmdletBinding()]
    param([string[]]$SessionId)
    $cli = Get-RequiredOpenCodeCli
    $sessions = @(Get-OpenCodeSessionInventory $cli)
    if (-not $PSBoundParameters.ContainsKey('SessionId')) { return $sessions }
    @(Select-OpenCodeSessionReference $sessions $SessionId)
}
