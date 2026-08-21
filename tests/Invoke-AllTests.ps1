[CmdletBinding()]
param(
    [ValidateSet('Tiny', 'Small', 'Medium')]
    [string]$Preset = 'Tiny',
    [switch]$TestOpenCodeImport,
    [switch]$KeepGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$steps = @(
    [pscustomobject]@{ Name = 'Publication'; Path = Join-Path $PSScriptRoot 'Publication/Test-Publication.ps1'; Arguments = @{} },
    [pscustomobject]@{ Name = 'Module contract'; Path = Join-Path $PSScriptRoot 'Contract/Test-ModuleContract.ps1'; Arguments = @{} },
    [pscustomobject]@{ Name = 'Custom-tool output unit'; Path = Join-Path $PSScriptRoot 'Unit/Test-CodexCustomToolOutput.ps1'; Arguments = @{} },
    [pscustomobject]@{ Name = 'Bundle validation unit'; Path = Join-Path $PSScriptRoot 'Unit/Test-OpenCodeBundleValidation.ps1'; Arguments = @{} },
    [pscustomobject]@{ Name = 'Documentation'; Path = Join-Path $PSScriptRoot 'Documentation/Test-Documentation.ps1'; Arguments = @{} },
    [pscustomobject]@{ Name = 'Synthetic conversion integration'; Path = Join-Path $PSScriptRoot 'Integration/Test-SyntheticConversion.ps1'; Arguments = @{ Preset = $Preset; TestOpenCodeImport = $TestOpenCodeImport; KeepGenerated = $KeepGenerated } }
)

$results = New-Object 'System.Collections.Generic.List[object]'
$suiteClock = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($step in $steps) {
    Write-Host "`n==> $($step.Name)" -ForegroundColor Cyan
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $arguments = $step.Arguments
        & $step.Path @arguments
        $clock.Stop()
        $results.Add([pscustomobject]@{ Test = $step.Name; Result = 'Passed'; Seconds = [math]::Round($clock.Elapsed.TotalSeconds, 2) }) | Out-Null
    } catch {
        $clock.Stop()
        $results.Add([pscustomobject]@{ Test = $step.Name; Result = 'Failed'; Seconds = [math]::Round($clock.Elapsed.TotalSeconds, 2) }) | Out-Null
        $results | Format-Table -AutoSize | Out-Host
        throw
    }
}
$suiteClock.Stop()

Write-Host "`nAll repository tests passed in $([math]::Round($suiteClock.Elapsed.TotalSeconds, 2)) seconds." -ForegroundColor Green
$results | Format-Table -AutoSize | Out-Host
