[CmdletBinding()]
param(
    [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Custom')]
    [string]$Preset = 'Medium',
    [ValidateRange(1, 100)][int]$Iterations = 3,
    [ValidateRange(0, 20)][int]$WarmupIterations = 1,
    [ValidateRange(1, 1000000)][int]$Turns = 250,
    [ValidateRange(0, 1000)][int]$ToolCallsPerTurn = 2,
    [ValidateRange(32, 100000000)][int]$TextCharacters = 2048,
    [ValidateRange(0, 1000000000)][int]$ToolPayloadCharacters = 32768,
    [switch]$IncludeUnicode,
    [switch]$IncompleteFinalToolCall,
    [switch]$IncludeOpenCodeImport,
    [switch]$AllowHuge,
    [switch]$KeepGenerated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleManifest = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1'
$Generator = Join-Path $RepoRoot 'tests/Support/New-SyntheticCodexData.ps1'
$GeneratedRoot = Join-Path $PSScriptRoot '.generated'
$DataRoot = Join-Path $GeneratedRoot 'conversion-data'
$ResultsRoot = Join-Path $GeneratedRoot 'conversion-results'
$CodexRoot = Join-Path $DataRoot 'codex'
$OutputRoot = Join-Path $DataRoot 'outputs'
$DataMarker = Join-Path $DataRoot '.synthetic-benchmark-data'

Import-Module $ModuleManifest -Force
if (Test-Path -LiteralPath $DataRoot) {
    if (-not (Test-Path -LiteralPath $DataMarker -PathType Leaf)) {
        throw "Refusing to replace an unmarked benchmark directory: $DataRoot"
    }
    Remove-Item -LiteralPath $DataRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
[System.IO.File]::WriteAllText($DataMarker, 'Generated synthetic benchmark data only.', [System.Text.UTF8Encoding]::new($false))

$generatorArguments = @{
    OutputDirectory = $CodexRoot
    Preset = $Preset
    Sessions = 1
    IncludeUnicode = $IncludeUnicode
    IncompleteFinalToolCall = $IncompleteFinalToolCall
    AllowHuge = $AllowHuge
    Force = $true
}
if ($Preset -eq 'Custom') {
    $generatorArguments.Turns = $Turns
    $generatorArguments.ToolCallsPerTurn = $ToolCallsPerTurn
    $generatorArguments.TextCharacters = $TextCharacters
    $generatorArguments.ToolPayloadCharacters = $ToolPayloadCharacters
}

$manifest = & $Generator @generatorArguments
$source = @(Get-CodexSession -CodexDataRoot $CodexRoot)[0]
$inputBytes = [int64](Get-Item -LiteralPath $source.SourcePath).Length
$openCode = if ($IncludeOpenCodeImport) {
    Get-Command opencode -CommandType Application -ErrorAction Stop | Select-Object -First 1
} else { $null }
$results = New-Object 'System.Collections.Generic.List[object]'

for ($warmup = 1; $warmup -le $WarmupIterations; $warmup++) {
    $warmupDirectory = Join-Path $OutputRoot "warmup-$warmup"
    $source | Convert-CodexSession -OutputDirectory $warmupDirectory | Out-Null
}

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $outputDirectory = Join-Path $OutputRoot "iteration-$iteration"
    $conversion = $null
    $conversionTime = Measure-Command {
        $conversion = $source | Convert-CodexSession -OutputDirectory $outputDirectory
    }
    $bundle = Get-Content -LiteralPath $conversion.BundlePath -Raw -Encoding utf8 | ConvertFrom-Json
    $parts = @($bundle.messages | ForEach-Object { @($_.parts) })
    $importSeconds = $null

    if ($IncludeOpenCodeImport) {
        $isolatedData = Join-Path $DataRoot "isolated-opencode/$iteration"
        $oldDataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')
        try {
            $env:XDG_DATA_HOME = $isolatedData
            Push-Location -LiteralPath $source.Directory
            try {
                $importTime = Measure-Command {
                    & $openCode.Path import $conversion.BundlePath --pure | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw 'Benchmark OpenCode import failed.' }
                }
                $importSeconds = $importTime.TotalSeconds
            } finally { Pop-Location }
        } finally {
            if ($null -eq $oldDataHome) { Remove-Item Env:XDG_DATA_HOME -ErrorAction SilentlyContinue }
            else { $env:XDG_DATA_HOME = $oldDataHome }
        }
    }

    $results.Add([pscustomobject]@{
        Timestamp = [datetimeoffset]::UtcNow.ToString('O')
        Preset = $Preset
        Iteration = $iteration
        InputMiB = [math]::Round($inputBytes / 1MB, 3)
        OutputMiB = [math]::Round((Get-Item -LiteralPath $conversion.BundlePath).Length / 1MB, 3)
        Messages = @($bundle.messages).Count
        Parts = $parts.Count
        ConvertSeconds = [math]::Round($conversionTime.TotalSeconds, 4)
        ConvertMiBPerSecond = if ($conversionTime.TotalSeconds) {
            [math]::Round(($inputBytes / 1MB) / $conversionTime.TotalSeconds, 3)
        } else { 0 }
        ImportSeconds = if ($null -eq $importSeconds) { '' } else { [math]::Round($importSeconds, 4) }
    })
}

New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null
$stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
$csvPath = Join-Path $ResultsRoot "conversion-$stamp.csv"
$jsonPath = Join-Path $ResultsRoot "conversion-$stamp.json"
$results | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
[System.IO.File]::WriteAllText($jsonPath, ($results | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

Write-Host "`nConversion benchmark results" -ForegroundColor Green
$results | Format-Table Iteration, InputMiB, OutputMiB, Messages, Parts, ConvertSeconds, ConvertMiBPerSecond, ImportSeconds -AutoSize | Out-Host
Write-Host "CSV:  $csvPath"
Write-Host "JSON: $jsonPath"

if (-not $KeepGenerated) {
    if (-not (Test-Path -LiteralPath $DataMarker -PathType Leaf)) {
        throw "Refusing to remove an unmarked benchmark directory: $DataRoot"
    }
    Remove-Item -LiteralPath $DataRoot -Recurse -Force
    Write-Host 'Removed generated benchmark dataset; result files were preserved.'
}
