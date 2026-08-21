function Confirm-CodexSessionId {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[A-Za-z0-9_-]{1,128}$') {
        throw "Unsafe session ID rejected: '$Id'"
    }
}

function Get-NormalizedFileSystemPath {
    param([Parameter(Mandatory)][string]$Path)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $root, $comparison)) { return $root }
    $fullPath.TrimEnd([char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ))
}

function Test-FileSystemPathEqual {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    [string]::Equals(
        (Get-NormalizedFileSystemPath $Left),
        (Get-NormalizedFileSystemPath $Right),
        $comparison
    )
}

function Test-FileSystemPathInside {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $fullPath = Get-NormalizedFileSystemPath $Path
    $fullParent = Get-NormalizedFileSystemPath $Parent
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $prefix = if ($fullParent.EndsWith($separator)) { $fullParent } else { $fullParent + $separator }
    $fullPath.StartsWith($prefix, $comparison)
}

function Get-ObjectPropertyValue {
    param([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $Default
}

function Get-OpenCodeImportOutputDirectory {
    param([string]$OutputDirectory, [Parameter(Mandatory)][string]$CodexDataRoot)
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $result = [System.IO.Path]::GetFullPath($OutputDirectory)
    } else {
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if (-not [string]::IsNullOrWhiteSpace($localData)) {
            $result = [System.IO.Path]::GetFullPath((Join-Path $localData 'OpenCode.ImportCodex/exports'))
        } else {
            $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
            if ([string]::IsNullOrWhiteSpace($profile)) {
                throw 'Could not determine an output directory. Pass -OutputDirectory.'
            }
            $result = [System.IO.Path]::GetFullPath((Join-Path $profile '.opencode-import-codex/exports'))
        }
    }
    if ((Test-FileSystemPathEqual $result $CodexDataRoot) -or (Test-FileSystemPathInside $result $CodexDataRoot)) {
        throw "OutputDirectory must not be inside the Codex data root: $result"
    }
    $result
}

function Get-ApplicationCommandInfo {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return [pscustomobject]@{ Installed = $false; Path = ''; Version = '' }
    }
    try { $version = ((& $command.Path --version 2>$null) | Out-String).Trim() }
    catch { $version = 'installed (version check failed)' }
    [pscustomobject]@{ Installed = $true; Path = $command.Path; Version = $version }
}

function Get-RequiredOpenCodeCli {
    $cli = Get-ApplicationCommandInfo 'opencode'
    if (-not $cli.Installed) {
        throw 'OpenCode CLI is required for this operation. This module does not install it.'
    }
    $cli
}

function Find-DesktopApplication {
    param([Parameter(Mandatory)][string]$DisplayPattern, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CandidatePaths)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $CandidatePaths) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { $found.Add($candidate) | Out-Null } }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        foreach ($registryPath in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            Get-ItemProperty $registryPath -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match $DisplayPattern } | ForEach-Object {
                $value = if ($_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation) { $_.InstallLocation } else { $_.DisplayName }
                if ($value) { $found.Add([string]$value) | Out-Null }
            }
        }
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) { Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DisplayPattern -or $_.PackageFullName -match $DisplayPattern } | ForEach-Object { $found.Add("AppX: $($_.PackageFullName)") | Out-Null } }
        if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) { Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $DisplayPattern } | ForEach-Object { $found.Add("Start menu: $($_.Name)") | Out-Null } }
    }
    @($found | Select-Object -Unique)
}

function Invoke-CheckedApplication {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $null = @(& $FilePath @ArgumentList)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Invoke-ApplicationText {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $text = ((& $FilePath @ArgumentList) | Out-String)
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
    }
    [pscustomobject]@{
        Text = $text
        ExitCode = $exitCode
    }
}
