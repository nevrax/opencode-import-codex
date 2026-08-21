function Get-CodexSession {
    <#
    .SYNOPSIS
    Gets local Codex sessions.
    .DESCRIPTION
    Reads Codex rollout metadata and returns normalized session objects. With no SessionId, all discovered sessions are returned.
    .PARAMETER SessionId
    One or more exact IDs, unique ID prefixes, or codex://threads/<id> deeplinks.
    .PARAMETER CodexDataRoot
    Codex data root. Defaults to CODEX_HOME and then the current user's .codex directory.
    .EXAMPLE
    Get-CodexSession
    .EXAMPLE
    Get-CodexSession -SessionId 'demo', 'codex://threads/other-demo'
    .OUTPUTS
    OpenCode.ImportCodex.CodexSession
    #>
    [CmdletBinding()]
    param([Alias('DeepLink')][string[]]$SessionId, [string]$CodexDataRoot)
    $root = Resolve-CodexDataRoot $CodexDataRoot
    $sessions = @(Get-CodexSessionInventory $root)
    if (-not $PSBoundParameters.ContainsKey('SessionId')) { return $sessions }
    @(Select-CodexSessionReference $sessions $SessionId)
}
