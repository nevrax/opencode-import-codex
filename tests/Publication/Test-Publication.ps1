[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $TestsRoot
$forbiddenDirectories = @(
    (Join-Path $RepoRoot '.tools'),
    (Join-Path $TestsRoot '.generated'),
    (Join-Path $RepoRoot 'tests/Benchmarks/.generated')
)
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($directory in $forbiddenDirectories) {
    if (Test-Path -LiteralPath $directory) {
        $failures.Add("Generated/private directory must be removed before publication: $directory")
    }
}

if (Test-Path -LiteralPath (Join-Path $RepoRoot '.github')) {
    $failures.Add('The repository must not contain a .github directory or hosted automation.')
}
$gitIgnore = Get-Content -LiteralPath (Join-Path $RepoRoot '.gitignore') -Raw -Encoding UTF8
if ($gitIgnore -notmatch '(?m)^\.demo/$') {
    $failures.Add('.demo/ must remain excluded from publication through .gitignore.')
}

$legacyPaths = @(
    ('Import-Codex' + 'ToOpenCode.ps1'),
    ('help' + 'ers'),
    ('bench' + 'marks')
)
foreach ($relativePath in $legacyPaths) {
    $candidate = Join-Path $RepoRoot $relativePath
    if (Test-Path -LiteralPath $candidate) {
        $failures.Add("Legacy architecture path must be removed before publication: $candidate")
    }
}

$extensions = @('.ps1', '.psm1', '.md', '.json', '.jsonl', '.yml', '.yaml', '.txt', '.gitignore', '.gitattributes')
$allFiles = @(
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepoRoot -Force | Where-Object { $_.Name -notin @('.git', '.research', '.tools', '.demo') })) {
        if (-not $entry.PSIsContainer) { $entry }
        else {
            Get-ChildItem -LiteralPath $entry.FullName -File -Recurse -Force | Where-Object {
                $_.FullName -notmatch '[\\/]tests[\\/]\.generated[\\/]' -and
                $_.FullName -notmatch '[\\/]tests[\\/]Benchmarks[\\/]\.generated[\\/]'
            }
        }
    }
)

foreach ($file in $allFiles) {
    if ($file.Name -match '(?i)^(\.env($|\.)|auth\.json$|credentials(?:\.json)?$|id_(rsa|ed25519)$)') {
        $failures.Add("Sensitive filename found: $($file.FullName)")
    }
}

$files = @($allFiles | Where-Object {
    $extensions -contains $_.Extension -or $_.Name -in @('.gitignore', '.gitattributes', 'LICENSE')
})
$patterns = [ordered]@{
    'Windows user-profile path' = '(?i)[A-Z]:\\Users\\[^\\\s"'']+'
    'Unix user-profile path' = '(?i)/(home|Users)/[^/\s"'']+'
    'OpenCode session ID' = '\bses_[A-Za-z0-9]{16,}\b'
    'Codex UUIDv7 session ID' = '(?i)\b01[0-9a-f]{6}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
    'GitHub token' = '(?i)\b(ghp|github_pat)_[A-Za-z0-9_]{20,}\b'
    'OpenAI-style secret key' = '\bsk-[A-Za-z0-9_-]{20,}\b'
    'AWS access key' = '\bAKIA[0-9A-Z]{16}\b'
    'Private key block' = '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
    'Bearer credential' = '(?i)\bAuthorization\s*:\s*Bearer\s+[A-Za-z0-9._~+/-]{12,}'
}
$currentUserName = [Environment]::UserName
$currentUserProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$currentMachineName = [Environment]::MachineName
$currentTimeZone = [TimeZoneInfo]::Local.Id
$genericAccountNames = @('root', 'runner', 'admin', 'administrator', 'user')

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($entry in $patterns.GetEnumerator()) {
        if ($content -match $entry.Value) {
            $failures.Add("$($entry.Key) found in $($file.FullName)")
        }
    }
    if ($currentUserName -and $currentUserName.Length -ge 3 -and
        $currentUserName -notin $genericAccountNames -and
        $content -match [regex]::Escape($currentUserName)) {
        $failures.Add("Current username found in $($file.FullName)")
    }
    if ($currentUserProfile -and $currentUserProfile.Length -ge 4 -and
        $content -match [regex]::Escape($currentUserProfile)) {
        $failures.Add("Current user-profile path found in $($file.FullName)")
    }
    if ($currentMachineName -and $currentMachineName.Length -ge 4 -and
        $content -match [regex]::Escape($currentMachineName)) {
        $failures.Add("Current machine name found in $($file.FullName)")
    }
    if ($currentTimeZone -and $currentTimeZone.Length -ge 4 -and
        $content -match [regex]::Escape($currentTimeZone)) {
        $failures.Add("Current time-zone identifier found in $($file.FullName)")
    }
}

foreach ($image in @($allFiles | Where-Object Extension -eq '.png')) {
    $bytes = [IO.File]::ReadAllBytes($image.FullName)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    foreach ($chunk in @('tEXt', 'zTXt', 'iTXt', 'eXIf')) {
        if ($ascii.Contains($chunk)) {
            $failures.Add("PNG metadata chunk '$chunk' found in $($image.FullName)")
        }
    }
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Publication audit failed with $($failures.Count) finding(s)."
}

Write-Host "Publication audit passed for $($files.Count) source/documentation file(s)." -ForegroundColor Green
