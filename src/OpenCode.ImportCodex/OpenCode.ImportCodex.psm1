Set-StrictMode -Version Latest

$privateFiles = @(
    'Private/Common.ps1'
    'Private/CodexStore.ps1'
    'Private/CodexTypedItems.ps1'
    'Private/NativeConverter.ps1'
    'Private/OpenCodeBundle.ps1'
    'Private/OpenCodeCli.ps1'
    'Private/Operations.ps1'
)
$publicFiles = @(
    'Public/Get-CodexSession.ps1'
    'Public/Select-CodexSession.ps1'
    'Public/Convert-CodexSession.ps1'
    'Public/Get-CodexSessionImportPlan.ps1'
    'Public/Import-CodexSession.ps1'
    'Public/Get-OpenCodeSession.ps1'
    'Public/Remove-OpenCodeSession.ps1'
    'Public/Test-CodexOpenCodeEnvironment.ps1'
)

foreach ($relativePath in @($privateFiles + $publicFiles)) {
    . (Join-Path $PSScriptRoot $relativePath)
}

Export-ModuleMember -Function @(
    'Get-CodexSession'
    'Select-CodexSession'
    'Convert-CodexSession'
    'Get-CodexSessionImportPlan'
    'Import-CodexSession'
    'Get-OpenCodeSession'
    'Remove-OpenCodeSession'
    'Test-CodexOpenCodeEnvironment'
)
