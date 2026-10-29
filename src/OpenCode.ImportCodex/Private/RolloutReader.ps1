function Get-ZstdCommandPath {
    $candidate = $env:CODEX_IMPORT_ZSTD
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Path }
        return $null
    }
    foreach ($name in @('zstd', 'zstd.exe')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Path }
    }
    $codex = Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($codex) {
        $codexDirectory = [System.IO.Path]::GetDirectoryName($codex.Path)
        foreach ($name in @('zstd', 'zstd.exe')) {
            $sibling = Join-Path $codexDirectory $name
            if (Test-Path -LiteralPath $sibling -PathType Leaf) { return [System.IO.Path]::GetFullPath($sibling) }
        }
    }
    $null
}

function Get-ZstdCommandInfo {
    $path = Get-ZstdCommandPath
    if (-not $path) { return [pscustomobject]@{ Installed = $false; Path = ''; Version = '' } }
    $version = ''
    try { $version = ((& $path --version 2>$null) | Out-String).Trim() } catch { $version = 'installed (version check failed)' }
    [pscustomobject]@{ Installed = $true; Path = $path; Version = $version }
}

function Test-CodexRolloutCompressed {
    param([Parameter(Mandatory)][string]$Path)
    $Path.EndsWith('.zst', [System.StringComparison]::OrdinalIgnoreCase)
}

function Open-CodexRolloutReader {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-CodexRolloutCompressed $Path) {
        $zstd = Get-ZstdCommandPath
        if (-not $zstd) {
            throw "Compressed Codex rollout '$Path' requires the zstd command-line tool. Install zstd, or set CODEX_IMPORT_ZSTD to its executable."
        }
        if ($Path.Contains('"')) {
            throw "Compressed rollout path contains a double quote and cannot be passed to zstd: $Path"
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $zstd
        $startInfo.Arguments = '-dc -- "' + $Path + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        try {
            $process = [System.Diagnostics.Process]::Start($startInfo)
        } catch {
            throw "Could not start zstd for '$Path': $($_.Exception.Message)"
        }
        $stream = $process.StandardOutput.BaseStream
        return [pscustomobject]@{
            Path = $Path
            Reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            Stream = $stream
            Process = $process
            Length = (Get-Item -LiteralPath $Path).Length
            Compressed = $true
        }
    }
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    [pscustomobject]@{
        Path = $Path
        Reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        Stream = $stream
        Process = $null
        Length = $stream.Length
        Compressed = $false
    }
}

function Close-CodexRolloutReader {
    param(
        [Parameter(Mandatory)]$Source,
        [switch]$AllowEarlyExit,
        [switch]$IgnoreErrors
    )
    $failure = ''
    try {
        $Source.Reader.Dispose()
    } finally {
        $process = $Source.Process
        if ($null -ne $process) {
            try {
                $killed = $false
                if (-not $process.WaitForExit(5000)) {
                    $killed = $true
                    try { $process.Kill() } catch { }
                    $process.WaitForExit(5000) | Out-Null
                }
                $errorText = ''
                try { $errorText = $process.StandardError.ReadToEnd() } catch { }
                $exitCode = $process.ExitCode
                $brokenPipe = ($exitCode -eq 141) -or ($errorText -match 'Broken pipe')
                $failed = $false
                if ($killed) { $failed = -not $AllowEarlyExit }
                elseif ($exitCode -ne 0) { $failed = -not ($AllowEarlyExit -and $brokenPipe) }
                if ($failed) {
                    $detail = if ($errorText) { $errorText.Trim() } else { "exit code $exitCode" }
                    $failure = "zstd failed to decompress '$($Source.Path)': $detail"
                }
            } finally {
                $process.Dispose()
            }
        }
    }
    if ($failure -and -not $IgnoreErrors) { throw $failure }
}
