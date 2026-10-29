[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleManifest = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1'
$Generator = Join-Path $TestsRoot 'Support/New-SyntheticCodexData.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-TestBundleJson {
    param([string]$Path)
    $bundle = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    ($bundle | ConvertTo-Json -Depth 100 -Compress)
}

Remove-Module OpenCode.ImportCodex -Force -ErrorAction SilentlyContinue
Import-Module $ModuleManifest -Force
$script:Module = Get-Module OpenCode.ImportCodex

$zstdInfo = & $script:Module { Get-ZstdCommandInfo }
Assert-True ($zstdInfo -and $zstdInfo.PSObject.Properties['Installed']) 'environment diagnostics should expose a zstd command info object'

$missingZstdError = $null
$env:CODEX_IMPORT_ZSTD = '/nonexistent/opencode-import-codex/zstd'
try {
    & $script:Module { param($Path) Open-CodexRolloutReader -Path $Path } (Join-Path ([System.IO.Path]::GetTempPath()) 'synthetic-rollout-compressed.jsonl.zst') | Out-Null
} catch {
    $missingZstdError = [string]$_.Exception.Message
} finally {
    Remove-Item Env:CODEX_IMPORT_ZSTD -ErrorAction SilentlyContinue
}
Assert-True ($missingZstdError -match 'zstd') 'a compressed rollout should fail with an actionable zstd error when no decompressor is configured'

if (-not $zstdInfo.Installed) {
    Write-Host 'Skipping compressed rollout round-trip assertions because no zstd decompressor is installed on this machine.'
} else {
    $generatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-import-codex-compressed-" + [guid]::NewGuid().ToString('N'))
    $outputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("opencode-import-codex-compressed-outputs-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $generatedRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        $generatedManifest = & $Generator -OutputDirectory $generatedRoot -Preset Tiny -Force
        $sourcePath = [string]$generatedManifest.sessions[0].file
        $sessionId = [string]$generatedManifest.sessions[0].id
        Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) 'generated synthetic rollout should exist before compression'

        $targetDirectory = Join-Path $outputRoot 'synthetic destination'
        $plainOutputDirectory = Join-Path $outputRoot 'plain'
        $compressedOutputDirectory = Join-Path $outputRoot 'compressed'
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        New-Item -ItemType Directory -Force -Path $plainOutputDirectory | Out-Null
        New-Item -ItemType Directory -Force -Path $compressedOutputDirectory | Out-Null

        $plainSession = @(Get-CodexSession -CodexDataRoot $generatedRoot)[0]
        $plainResult = $plainSession | Convert-CodexSession -DestinationDirectory $targetDirectory -OutputDirectory $plainOutputDirectory
        $plainBundlePath = Join-Path $plainOutputDirectory ($plainResult.CodexSessionId + '.json')
        Assert-True (Test-Path -LiteralPath $plainBundlePath -PathType Leaf) 'plain conversion should write a bundle file'

        $compressedSourcePath = $sourcePath + '.zst'
        & $zstdInfo.Path -q -f $sourcePath
        Assert-True ($LASTEXITCODE -eq 0) 'zstd should compress the synthetic rollout into a .jsonl.zst file'
        Assert-True (Test-Path -LiteralPath $compressedSourcePath -PathType Leaf) 'zstd should produce a .jsonl.zst rollout file'
        Remove-Item -LiteralPath $sourcePath -Force

        $compressedSession = @(Get-CodexSession -CodexDataRoot $generatedRoot -SessionId $sessionId)[0]
        Assert-True ($compressedSession.SourcePath -like '*.jsonl.zst') 'Get-CodexSession should discover a compressed rollout after compression'
        $compressedResult = Convert-CodexSession -SessionId $sessionId -CodexDataRoot $generatedRoot -DestinationDirectory $targetDirectory -OutputDirectory $compressedOutputDirectory
        $compressedBundlePath = Join-Path $compressedOutputDirectory ($compressedResult.CodexSessionId + '.json')
        Assert-True (Test-Path -LiteralPath $compressedBundlePath -PathType Leaf) 'compressed conversion should write a bundle file'
        Assert-True ($compressedResult.OpenCodeSessionId -eq $plainResult.OpenCodeSessionId) 'plain and compressed rollouts should produce the same OpenCode session id'

        $plainBundleJson = Get-TestBundleJson -Path $plainBundlePath
        $compressedBundleJson = Get-TestBundleJson -Path $compressedBundlePath
        Assert-True (-not [string]::IsNullOrWhiteSpace($plainBundleJson)) 'converted bundle should not be empty'
        Assert-True ($plainBundleJson -eq $compressedBundleJson) 'a compressed rollout should convert to the same OpenCode bundle as its plain twin'
    } finally {
        if (Test-Path -LiteralPath $generatedRoot) { Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $outputRoot) { Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host 'Compressed Codex rollout tests passed.'
