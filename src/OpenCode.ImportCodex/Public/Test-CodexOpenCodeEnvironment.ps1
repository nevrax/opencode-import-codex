function Test-CodexOpenCodeEnvironment {
    <#
    .SYNOPSIS
    Tests the Codex and OpenCode environment.
    .DESCRIPTION
    Returns one best-effort diagnostics object describing CLI commands, desktop application candidates, and the Codex session store on Windows, macOS, or Linux.
    .PARAMETER CodexDataRoot
    Codex data root to inspect. Defaults to CODEX_HOME and then the current user's .codex directory.
    .EXAMPLE
    Test-CodexOpenCodeEnvironment
    .EXAMPLE
    Test-CodexOpenCodeEnvironment -CodexDataRoot (Join-Path $HOME 'synthetic-codex')
    .OUTPUTS
    OpenCode.ImportCodex.EnvironmentDiagnostic
    .NOTES
    Detection is informational and best effort. This command does not install software, execute conversion code, or modify files.
    #>
    [CmdletBinding()]
    param([string]$CodexDataRoot)
    $root = Resolve-CodexDataRoot $CodexDataRoot; $codexCli = Get-ApplicationCommandInfo 'codex'; $openCodeCli = Get-ApplicationCommandInfo 'opencode'
    $codexCandidates = New-Object 'System.Collections.Generic.List[string]'; $openCodeCandidates = New-Object 'System.Collections.Generic.List[string]'
    $platform = 'Linux'
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        $platform = 'Windows'
        if ($env:LOCALAPPDATA) { $codexCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs/Codex/Codex.exe')) | Out-Null; $codexCandidates.Add((Join-Path $env:LOCALAPPDATA 'Codex/Codex.exe')) | Out-Null; $openCodeCandidates.Add((Join-Path $env:LOCALAPPDATA 'Programs/OpenCode/OpenCode.exe')) | Out-Null; $openCodeCandidates.Add((Join-Path $env:LOCALAPPDATA 'OpenCode/OpenCode.exe')) | Out-Null }
        if ($env:ProgramFiles) { $codexCandidates.Add((Join-Path $env:ProgramFiles 'Codex/Codex.exe')) | Out-Null; $openCodeCandidates.Add((Join-Path $env:ProgramFiles 'OpenCode/OpenCode.exe')) | Out-Null }
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $platform = 'macOS'; $codexCandidates.Add('/Applications/Codex.app') | Out-Null; $openCodeCandidates.Add('/Applications/OpenCode.app') | Out-Null
        $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ($profile) { $codexCandidates.Add((Join-Path $profile 'Applications/Codex.app')) | Out-Null; $openCodeCandidates.Add((Join-Path $profile 'Applications/OpenCode.app')) | Out-Null }
    } else {
        $codexDesktopCommand = Get-Command chatgpt -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $openCodeDesktopCommand = Get-Command opencode-desktop -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($codexDesktopCommand) { $codexCandidates.Add($codexDesktopCommand.Path) | Out-Null }; if ($openCodeDesktopCommand) { $openCodeCandidates.Add($openCodeDesktopCommand.Path) | Out-Null }
    }
    $diagnostic = [pscustomobject]@{
        Platform = $platform; CodexDataRoot = $root; CodexSessionsPath = Join-Path $root 'sessions'; CodexSessionsAvailable = Test-Path -LiteralPath (Join-Path $root 'sessions') -PathType Container
        CodexCli = $codexCli; OpenCodeCli = $openCodeCli
        CodexDesktop = @(Find-DesktopApplication '(^|\s)Codex(\s|$)|OpenAI.*Codex' @($codexCandidates))
        OpenCodeDesktop = @(Find-DesktopApplication '(^|\s)OpenCode(\s|$)|OpenCode Desktop' @($openCodeCandidates))
    }
    $diagnostic.PSObject.TypeNames.Insert(0, 'OpenCode.ImportCodex.EnvironmentDiagnostic'); $diagnostic
}
