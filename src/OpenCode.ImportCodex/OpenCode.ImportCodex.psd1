@{
    RootModule = 'OpenCode.ImportCodex.psm1'
    ModuleVersion = '1.0.0'
    GUID = '64a41fb8-a45b-4f31-a868-c1de67a93a48'
    Author = 'OpenCode.ImportCodex contributors'
    CompanyName = 'Community'
    Copyright = 'Copyright (c) OpenCode.ImportCodex contributors. MIT License.'
    Description = 'Converts local Codex sessions into resumable OpenCode sessions.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Get-CodexSession'
        'Select-CodexSession'
        'Convert-CodexSession'
        'Get-CodexSessionImportPlan'
        'Import-CodexSession'
        'Get-OpenCodeSession'
        'Remove-OpenCodeSession'
        'Test-CodexOpenCodeEnvironment'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Codex', 'OpenCode', 'Import', 'PowerShell')
            LicenseUri = 'https://opensource.org/license/mit'
        }
    }
}
