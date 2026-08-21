[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleRoot = Join-Path $RepoRoot 'src/OpenCode.ImportCodex'
$ModuleManifest = Join-Path $ModuleRoot 'OpenCode.ImportCodex.psd1'
$PublicRoot = Join-Path $ModuleRoot 'Public'
$FixtureRoot = Join-Path $TestsRoot 'Fixtures/ComplexLegacy/Codex'
$Fixture = Join-Path $FixtureRoot 'sessions/2026/01/01/rollout-2026-01-01T00-00-00-11111111-2222-3333-4444-555555555555.jsonl'
$ExpectedCommands = @(
    'Get-CodexSession'
    'Select-CodexSession'
    'Convert-CodexSession'
    'Get-CodexSessionImportPlan'
    'Import-CodexSession'
    'Get-OpenCodeSession'
    'Remove-OpenCodeSession'
    'Test-CodexOpenCodeEnvironment'
)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Rejected {
    param([scriptblock]$Command, [string]$Description, [string]$ExpectedMessage)
    try {
        & $Command *> $null
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) { throw }
        return
    }
    throw "Invalid operation was accepted: $Description"
}

function Get-RepositoryEntries {
    @(
        foreach ($entry in @(Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object { $_.Name -notin @('.git', '.research') })) {
            $entry.FullName
            if ($entry.PSIsContainer) { Get-ChildItem -LiteralPath $entry.FullName -Recurse -Force | ForEach-Object FullName }
        }
    ) | Sort-Object
}

$parseFiles = @(
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object { $_.Name -notin @('.git', '.research') })) {
        if (-not $entry.PSIsContainer -and $entry.Extension -in @('.ps1', '.psm1', '.psd1')) { $entry }
        elseif ($entry.PSIsContainer) { Get-ChildItem -LiteralPath $entry.FullName -Recurse -File | Where-Object Extension -in @('.ps1', '.psm1', '.psd1') }
    }
)
foreach ($file in $parseFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (-not $errors.Count) "PowerShell parse errors in $($file.FullName): $($errors -join '; ')"
}
$manifestData = Test-ModuleManifest -Path $ModuleManifest -ErrorAction Stop
Assert-True ($manifestData.Name -eq 'OpenCode.ImportCodex') 'module manifest name should be OpenCode.ImportCodex'

Remove-Module OpenCode.ImportCodex -Force -ErrorAction SilentlyContinue
$entriesBeforeImport = Get-RepositoryEntries
Import-Module $ModuleManifest -Force
$entriesAfterImport = Get-RepositoryEntries
Assert-True (($entriesBeforeImport -join "`n") -ceq ($entriesAfterImport -join "`n")) 'module import must not create files or directories'

$exported = @(Get-Command -Module OpenCode.ImportCodex -CommandType Function | ForEach-Object Name | Sort-Object)
$expectedSorted = @($ExpectedCommands | Sort-Object)
Assert-True ($exported.Count -eq 8) "module should export exactly eight functions, found $($exported.Count)"
Assert-True (($exported -join "`n") -ceq ($expectedSorted -join "`n")) "module exports differ from the expected contract: $($exported -join ', ')"

$approvedVerbs = @(Get-Verb | ForEach-Object Verb)
foreach ($name in $ExpectedCommands) {
    $verb, $noun = $name -split '-', 2
    Assert-True ($approvedVerbs -contains $verb) "$name does not use an approved PowerShell verb"
    Assert-True ($noun -notmatch 'Sessions$') "$name should use a singular noun"
}

$publicFiles = @(Get-ChildItem -LiteralPath $PublicRoot -Filter '*.ps1' -File)
$publicFunctions = @{}
foreach ($file in $publicFiles) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($functionAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $publicFunctions[$functionAst.Name] = $functionAst
    }
}

foreach ($name in $ExpectedCommands) {
    Assert-True ($publicFunctions.ContainsKey($name)) "public function source is missing for $name"
    $functionAst = $publicFunctions[$name]
    $declaredParameters = @($functionAst.Body.ParamBlock.Parameters)
    foreach ($parameter in $declaredParameters) {
        $parameterName = $parameter.Name.VariablePath.UserPath
        Assert-True ($parameterName -cmatch '^[A-Z][A-Za-z0-9]*$') "$name parameter '$parameterName' must be explicitly declared in PascalCase"
        Assert-True ($parameterName -notmatch '(?i)(converter|helper|repositoryroot|reporoot)') "$name exposes an implementation-related parameter: $parameterName"
    }

    $help = Get-Help $name -Full
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$help.Synopsis)) "$name help is missing a synopsis"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$help.Description.Text)) "$name help is missing a description"
    Assert-True (@($help.Examples.Example).Count -ge 2) "$name help must contain at least two examples"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$help.ReturnValues.ReturnValue.Type.Name)) "$name help is missing outputs"
    foreach ($parameter in $declaredParameters) {
        $parameterName = $parameter.Name.VariablePath.UserPath
        $helpParameter = @($help.Parameters.Parameter | Where-Object Name -eq $parameterName)
        Assert-True ($helpParameter.Count -eq 1) "$name help is missing parameter $parameterName"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$helpParameter[0].Description.Text)) "$name parameter $parameterName is missing a help description"
    }
}

$importCommand = Get-Command Import-CodexSession
Assert-True ($importCommand.Parameters.ContainsKey('WhatIf')) 'Import-CodexSession must support WhatIf'
Assert-True ($importCommand.Parameters.ContainsKey('Confirm')) 'Import-CodexSession must support Confirm'
$importAstText = $publicFunctions['Import-CodexSession'].Extent.Text
Assert-True ($importAstText -match '(?i)SupportsShouldProcess') 'Import-CodexSession must explicitly declare SupportsShouldProcess'

$fixtureHash = (Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash
Assert-Rejected -Command {
    Get-CodexSession -SessionId 'codex://wrong/synthetic' -CodexDataRoot $FixtureRoot
} -Description 'malformed Codex deeplink' -ExpectedMessage 'Invalid Codex deeplink'

$unsafeInput = [pscustomobject]@{
    Id = '../unsafe-output'
    SourcePath = $Fixture
    Directory = $RepoRoot
    Title = 'Unsafe synthetic source ID'
}
Assert-Rejected -Command {
    $unsafeInput | Convert-CodexSession -OutputDirectory (Join-Path $TestsRoot '.generated/unsafe')
} -Description 'unsafe pipeline source ID' -ExpectedMessage 'Unsafe session ID'

$fixtureSession = @(Get-CodexSession -CodexDataRoot $FixtureRoot)[0]
Assert-Rejected -Command {
    $fixtureSession | Convert-CodexSession -DestinationDirectory $RepoRoot -OutputDirectory (Join-Path $FixtureRoot 'generated-output')
} -Description 'output beneath the Codex root' -ExpectedMessage 'must not be inside the Codex data root'

$whatIfOutput = Join-Path $TestsRoot '.generated/contract-whatif'
$openCode = Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($openCode) {
    $fixtureSession | Import-CodexSession -DestinationDirectory $RepoRoot -OutputDirectory $whatIfOutput -WhatIf -Confirm:$false | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $whatIfOutput)) 'Import-CodexSession -WhatIf must not perform conversion'
}

Assert-True ((Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash -eq $fixtureHash) 'source fixture hash changed during contract validation'

$assistantFirstRoot = Join-Path ([System.IO.Path]::GetTempPath()) "OpenCode.ImportCodex-assistant-first-$PID-$([guid]::NewGuid().ToString('N'))"
try {
    $assistantFirstCodexRoot = Join-Path $assistantFirstRoot 'codex'
    $assistantFirstSessions = Join-Path $assistantFirstCodexRoot 'sessions/2026/01/01'
    $assistantFirstProject = Join-Path $assistantFirstRoot 'project'
    $assistantFirstOutput = Join-Path $assistantFirstRoot 'output'
    New-Item -ItemType Directory -Force -Path $assistantFirstSessions | Out-Null
    New-Item -ItemType Directory -Force -Path $assistantFirstProject | Out-Null
    $assistantFirstPath = Join-Path $assistantFirstSessions 'rollout-assistant-first-synthetic.jsonl'
    $assistantFirstRows = @(
        (@{
            timestamp = '2026-01-01T00:00:00Z'
            type = 'session_meta'
            payload = @{
                id = 'assistant-first-synthetic'
                timestamp = '2026-01-01T00:00:00Z'
                cwd = $assistantFirstProject
            }
        } | ConvertTo-Json -Depth 10 -Compress),
        (@{
            timestamp = '2026-01-01T00:00:01Z'
            type = 'response_item'
            payload = @{
                type = 'message'
                role = 'assistant'
                content = @(@{ type = 'output_text'; text = 'Synthetic assistant-first response.' })
            }
        } | ConvertTo-Json -Depth 10 -Compress)
    )
    [System.IO.File]::WriteAllLines(
        $assistantFirstPath,
        [string[]]$assistantFirstRows,
        [System.Text.UTF8Encoding]::new($false)
    )
    $assistantFirstSession = @(Get-CodexSession -CodexDataRoot $assistantFirstCodexRoot)[0]
    Assert-Rejected -Command {
        $assistantFirstSession | Convert-CodexSession -OutputDirectory $assistantFirstOutput
    } -Description 'assistant-first history' -ExpectedMessage 'first importable message is an assistant response'
}
finally {
    if (Test-Path -LiteralPath $assistantFirstRoot) {
        Remove-Item -LiteralPath $assistantFirstRoot -Recurse -Force
    }
}

Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestsRoot '.generated'))) 'module contract tests must not leave generated artifacts'

Write-Host "Module contract passed for $($ExpectedCommands.Count) exported commands and $($parseFiles.Count) PowerShell files." -ForegroundColor Green
