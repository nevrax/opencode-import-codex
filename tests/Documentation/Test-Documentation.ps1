[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $TestsRoot
$ArchitecturePath = Join-Path $RepoRoot 'docs/Architecture.md'
$CommandsPath = Join-Path $RepoRoot 'docs/Commands.md'
$ConversionPath = Join-Path $RepoRoot 'docs/Conversion.md'
$SecurityPath = Join-Path $RepoRoot 'SECURITY.md'
$LoaderPath = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psm1'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-Documentation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$documentationFiles = @(
    Get-Item -LiteralPath (Join-Path $RepoRoot 'README.md'), (Join-Path $RepoRoot 'CONTRIBUTING.md'), $SecurityPath, (Join-Path $TestsRoot 'README.md')
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs') -Filter '*.md' -File
)

foreach ($file in $documentationFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach ($match in [regex]::Matches($content, '(?m)!?\[[^\]]*\]\((?<target>[^)]+)\)')) {
        $target = $match.Groups['target'].Value.Trim()
        if ($target.StartsWith('<') -and $target.EndsWith('>')) { $target = $target.Substring(1, $target.Length - 2) }
        if ($target -match '^(?i)(https?://|mailto:|#)') { continue }
        $pathOnly = ($target -split '#', 2)[0]
        if ([string]::IsNullOrWhiteSpace($pathOnly)) { continue }
        $candidate = Join-Path $file.DirectoryName ([uri]::UnescapeDataString($pathOnly.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
        Assert-Documentation (Test-Path -LiteralPath $candidate) "Broken relative Markdown link '$target' in $($file.FullName)"
    }
}

$expectedCommands = @(
    'Get-CodexSession', 'Select-CodexSession', 'Convert-CodexSession', 'Get-CodexSessionImportPlan',
    'Import-CodexSession', 'Get-OpenCodeSession', 'Remove-OpenCodeSession', 'Test-CodexOpenCodeEnvironment'
)
$commandsDocument = Get-Content -LiteralPath $CommandsPath -Raw -Encoding UTF8
$architectureDocument = Get-Content -LiteralPath $ArchitecturePath -Raw -Encoding UTF8
foreach ($command in $expectedCommands) {
    Assert-Documentation ($commandsDocument -cmatch [regex]::Escape("## $command")) "Commands.md is missing the $command command section"
    Assert-Documentation ($architectureDocument -cmatch [regex]::Escape($command)) "Architecture.md is missing public command $command"
}

$loader = Get-Content -LiteralPath $LoaderPath -Raw -Encoding UTF8
$privateFiles = @([regex]::Matches($loader, "'Private/(?<name>[^']+\.ps1)'") | ForEach-Object { $_.Groups['name'].Value })
$publicFiles = @([regex]::Matches($loader, "'Public/(?<name>[^']+\.ps1)'") | ForEach-Object { $_.Groups['name'].Value })
Assert-Documentation ($privateFiles.Count -eq 7) "loader should contain seven private files, found $($privateFiles.Count)"
Assert-Documentation ($publicFiles.Count -eq 8) "loader should contain eight public files, found $($publicFiles.Count)"
foreach ($fileName in @($privateFiles + $publicFiles)) {
    Assert-Documentation ($architectureDocument -cmatch [regex]::Escape($fileName)) "Architecture.md repository tree or responsibility table is missing $fileName"
}
Assert-Documentation ($architectureDocument -match 'Seven private files are dot-sourced') 'Architecture.md must state the correct private-file load count'
Assert-Documentation ($architectureDocument -match 'opencode db') 'Architecture.md must distinguish global inventory through opencode db'
Assert-Documentation ($architectureDocument -match 'project-scoped.*opencode session list') 'Architecture.md must identify project-scoped import verification'

$requiredTestPaths = @(
    'tests/Invoke-AllTests.ps1',
    'tests/Benchmarks/Measure-CodexSessionConversion.ps1',
    'tests/Contract/Test-ModuleContract.ps1',
    'tests/Documentation/Test-Documentation.ps1',
    'tests/Integration/Test-SyntheticConversion.ps1',
    'tests/Publication/Test-Publication.ps1',
    'tests/Unit/Test-CodexCustomToolOutput.ps1',
    'tests/Unit/Test-OpenCodeBundleValidation.ps1',
    'tests/Support/New-SyntheticCodexData.ps1',
    'tests/Fixtures/ComplexLegacy/Codex'
)
foreach ($relativePath in $requiredTestPaths) {
    Assert-Documentation (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath)) "Documented test path does not exist: $relativePath"
}

$powerShellDirectories = @(
    Get-ChildItem -LiteralPath $TestsRoot -Directory | Where-Object Name -ne '.generated'
    Get-Item -LiteralPath (Join-Path $TestsRoot 'Fixtures/ComplexLegacy'), (Join-Path $TestsRoot 'Fixtures/ComplexLegacy/Codex')
)
foreach ($directory in $powerShellDirectories) {
    Assert-Documentation ($directory.Name -cmatch '^[A-Z][A-Za-z0-9]*$') "PowerShell project directory does not use PascalCase: $($directory.FullName)"
}
$approvedVerbs = @(Get-Verb | ForEach-Object Verb)
foreach ($scriptFile in @(Get-ChildItem -LiteralPath $TestsRoot -Filter '*.ps1' -File -Recurse)) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile.Name)
    $verb = ($baseName -split '-', 2)[0]
    Assert-Documentation ($baseName -cmatch '^[A-Z][A-Za-z0-9]+-[A-Z][A-Za-z0-9]+$') "Test script does not use Verb-Noun PascalCase: $($scriptFile.FullName)"
    Assert-Documentation ($approvedVerbs -contains $verb) "Test script uses unapproved PowerShell verb '$verb': $($scriptFile.FullName)"
}

$allAuditedText = @(
    $documentationFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
    Get-Content -LiteralPath (Join-Path $RepoRoot 'tests/Benchmarks/Measure-CodexSessionConversion.ps1') -Raw -Encoding UTF8
) -join "`n"
Assert-Documentation (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.github'))) 'The repository must remain independent of .github automation.'
foreach ($staleText in @('benchmarks/', 'tests/contract/', 'tests/documentation/', 'tests/integration/', 'tests/publication/', 'tests/support/', 'tests/unit/', 'tests/fixtures/', '.github/workflows/', 'tests/Invoke-SyntheticTests.ps1', 'tests/Test-ModuleContract.ps1', 'tests/Test-Publication.ps1', 'Full JavaScript remains model-visible')) {
    Assert-Documentation ($allAuditedText -cnotmatch [regex]::Escape($staleText)) "Stale documentation or automation reference remains: $staleText"
}
Assert-Documentation ($allAuditedText -notmatch '(?i)\bCI\b|checked-in workflow|GitHub Actions') 'Documentation must describe local verification only.'

$readme = Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw -Encoding UTF8
$conversion = Get-Content -LiteralPath $ConversionPath -Raw -Encoding UTF8
$security = Get-Content -LiteralPath $SecurityPath -Raw -Encoding UTF8
Assert-Documentation ($readme -match 'insert-only') 'README.md must warn that matching deterministic IDs are effectively insert-only'
Assert-Documentation ($conversion -match 'metadata\.codex\.executions') 'Conversion.md must document the exact code-mode archive field'
Assert-Documentation ($conversion -match 'explicitly\s+approved delete and reimport') 'Conversion.md must document migration replacement safety'
Assert-Documentation ($security -match 'metadata\.codex\.executions') 'SECURITY.md must disclose that exact code-mode source and output remain plaintext metadata'

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Documentation audit failed with $($failures.Count) finding(s)."
}

Write-Host "Documentation audit passed for $($documentationFiles.Count) Markdown files, $($expectedCommands.Count) commands, and $($privateFiles.Count + $publicFiles.Count) module source files." -ForegroundColor Green
