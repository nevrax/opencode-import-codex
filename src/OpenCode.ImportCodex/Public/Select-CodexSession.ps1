function Select-CodexSession {
    <#
    .SYNOPSIS
    Interactively selects Codex sessions.
    .DESCRIPTION
    Displays a numbered host picker for discovered Codex sessions and returns the selected session objects.
    .PARAMETER CodexDataRoot
    Codex data root. Defaults to CODEX_HOME and then the current user's .codex directory.
    .EXAMPLE
    Select-CodexSession
    .EXAMPLE
    Select-CodexSession -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
    .OUTPUTS
    OpenCode.ImportCodex.CodexSession
    .NOTES
    This is the only Codex inventory command that writes a picker to the host and prompts for input.
    #>
    [CmdletBinding()]
    param([string]$CodexDataRoot)
    $sessions = @(Get-CodexSession -CodexDataRoot $CodexDataRoot)
    if (-not $sessions.Count) { return }
    $rows = for ($index = 0; $index -lt $sessions.Count; $index++) { [pscustomobject]@{ Number = $index + 1; Started = $sessions[$index].Started; Title = $sessions[$index].Title; Id = $sessions[$index].Id; Directory = $sessions[$index].Directory } }
    $rows | Format-Table -AutoSize | Out-Host
    $answer = Read-Host 'Enter session number(s), separated by commas'
    if ([string]::IsNullOrWhiteSpace($answer)) { throw 'No Codex session selected.' }
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($token in $answer.Split(',')) {
        $number = 0
        if (-not [int]::TryParse($token.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $sessions.Count) { throw "Invalid session number: '$token'." }
        $selected.Add($sessions[$number - 1]) | Out-Null
    }
    @($selected | Sort-Object Id -Unique)
}
