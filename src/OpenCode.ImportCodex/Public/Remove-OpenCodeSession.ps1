function Remove-OpenCodeSession {
    <#
    .SYNOPSIS
    Removes OpenCode root sessions.
    .DESCRIPTION
    Resolves exact IDs or unique prefixes, requests confirmation through ShouldProcess, deletes selected sessions with the OpenCode CLI, and verifies their removal.
    .PARAMETER SessionId
    Exact OpenCode session IDs or unique prefixes to remove.
    .PARAMETER InputObject
    OpenCode session objects received from Get-OpenCodeSession.
    .PARAMETER All
    Removes all OpenCode root sessions.
    .PARAMETER Force
    Suppresses the literal DELETE ALL prompt for -All. It does not suppress ShouldProcess confirmation.
    .EXAMPLE
    Remove-OpenCodeSession -SessionId 'ses_1234' -WhatIf
    .EXAMPLE
    Get-OpenCodeSession -SessionId 'ses_1234' | Remove-OpenCodeSession -Confirm:$false
    .OUTPUTS
    OpenCode.ImportCodex.OpenCodeSession
    .NOTES
    Permanently deletes live OpenCode sessions. The -All parameter adds a literal DELETE ALL prompt unless -Force is supplied; standard -WhatIf and -Confirm still apply.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')][string[]]$SessionId,
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Pipeline')]$InputObject,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All,
        [Parameter(ParameterSetName = 'All')][switch]$Force
    )
    begin { $inputs = New-Object 'System.Collections.Generic.List[object]' }
    process { if ($PSCmdlet.ParameterSetName -eq 'Pipeline') { $inputs.Add($InputObject) | Out-Null } }
    end {
        $cli = Get-RequiredOpenCodeCli; $inventory = @(Get-OpenCodeSessionInventory $cli)
        if ($PSCmdlet.ParameterSetName -eq 'All') {
            $targets = $inventory
            if ($targets.Count -and -not $Force -and -not $WhatIfPreference) {
                Write-Warning "This will permanently delete all $($targets.Count) OpenCode root sessions."
                if ((Read-Host 'Type DELETE ALL to continue') -cne 'DELETE ALL') { return }
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'ById') { $targets = @(Select-OpenCodeSessionReference $inventory $SessionId) }
        else {
            $pipelineIds = @($inputs | ForEach-Object { [string](Get-ObjectPropertyValue $_ 'Id' '') })
            if (@($pipelineIds | Where-Object { -not $_ }).Count) { throw 'InputObject must contain an Id property.' }
            $targets = @(Select-OpenCodeSessionReference $inventory $pipelineIds)
        }
        $removed = New-Object 'System.Collections.Generic.List[object]'
        foreach ($target in @($targets)) {
            if ($PSCmdlet.ShouldProcess("OpenCode session '$($target.Id)'", 'Permanently delete')) { Remove-OpenCodeSessionItem $target $cli; $removed.Add($target) | Out-Null }
        }
        if (-not $removed.Count) { return }
        $remaining = @(Get-OpenCodeSessionInventory $cli); $remainingIds = New-Object 'System.Collections.Generic.HashSet[string]' (,[string[]]@($remaining | ForEach-Object Id))
        $failed = @($removed | Where-Object { $remainingIds.Contains([string]$_.Id) })
        if ($failed.Count) { throw "OpenCode still reports deleted session(s): $($failed.Id -join ', ')" }
        $removed.ToArray()
    }
}
