[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '.generated/codex'),
    [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Custom')]
    [string]$Preset = 'Small',
    [ValidateRange(1, 10000)][int]$Sessions = 1,
    [ValidateRange(1, 1000000)][int]$Turns = 20,
    [ValidateRange(0, 1000)][int]$ToolCallsPerTurn = 1,
    [ValidateRange(32, 100000000)][int]$TextCharacters = 512,
    [ValidateRange(0, 1000000000)][int]$ToolPayloadCharacters = 4096,
    [int]$Seed = 424242,
    [switch]$IncludeUnicode,
    [switch]$IncompleteFinalToolCall,
    [switch]$AllowHuge,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$presets = @{
    Tiny = @{ Sessions = 1; Turns = 3; ToolCallsPerTurn = 1; TextCharacters = 128; ToolPayloadCharacters = 256 }
    Small = @{ Sessions = 1; Turns = 20; ToolCallsPerTurn = 1; TextCharacters = 512; ToolPayloadCharacters = 4096 }
    Medium = @{ Sessions = 1; Turns = 250; ToolCallsPerTurn = 2; TextCharacters = 2048; ToolPayloadCharacters = 32768 }
    Large = @{ Sessions = 2; Turns = 1000; ToolCallsPerTurn = 3; TextCharacters = 4096; ToolPayloadCharacters = 131072 }
    Huge = @{ Sessions = 2; Turns = 2000; ToolCallsPerTurn = 4; TextCharacters = 8192; ToolPayloadCharacters = 1048576 }
}

if ($Preset -ne 'Custom') {
    $settings = $presets[$Preset]
    foreach ($name in $settings.Keys) {
        if (-not $PSBoundParameters.ContainsKey($name)) {
            Set-Variable -Name $name -Value $settings[$name]
        }
    }
}

$estimatedCharacters = [int64]$Sessions * [int64]$Turns * (
    ([int64]$TextCharacters * 3) +
    ([int64]$ToolCallsPerTurn * ([int64]$ToolPayloadCharacters + 768)) +
    1024
)
$estimatedGiB = $estimatedCharacters / 1GB
if ($estimatedGiB -ge 1 -and -not $AllowHuge) {
    throw ("Estimated output is {0:N2} GiB. Pass -AllowHuge to generate datasets of 1 GiB or larger." -f $estimatedGiB)
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$markerPath = Join-Path $OutputDirectory '.synthetic-codex-fixture'
if (Test-Path -LiteralPath $OutputDirectory) {
    $existing = @(Get-ChildItem -LiteralPath $OutputDirectory -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -and -not (Test-Path -LiteralPath $markerPath)) {
        throw "Refusing to modify an unmarked directory: $OutputDirectory"
    }
    if ($existing.Count -and -not $Force) {
        throw "Synthetic output already exists. Pass -Force to regenerate: $OutputDirectory"
    }
    if ($Force) {
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
[System.IO.File]::WriteAllText($markerPath, 'Generated synthetic Codex data only.', [System.Text.UTF8Encoding]::new($false))
$projectsRoot = Join-Path $OutputDirectory 'projects'
$sessionIndexPath = Join-Path $OutputDirectory 'session_index.jsonl'
New-Item -ItemType Directory -Force -Path $projectsRoot | Out-Null

function New-DeterministicGuid {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
        $bytes = [byte[]]::new(16)
        [System.Array]::Copy($hash, $bytes, 16)
        [guid]::new($bytes).ToString()
    }
    finally {
        $sha.Dispose()
    }
}

function New-SyntheticText {
    param(
        [Parameter(Mandatory)][int]$Length,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Ordinal
    )
    if ($Length -le 0) { return '' }
    $vocabulary = if ($IncludeUnicode) {
        $unicodeWords = 'caf{0} na{1}ve {2}{3} {4}{5}{6}{7}{8}{9}' -f @(
            [char]0x00e9,
            [char]0x00ef,
            [char]0x6771,
            [char]0x4eac,
            [char]0x03b4,
            [char]0x03bf,
            [char]0x03ba,
            [char]0x03b9,
            [char]0x03bc,
            [char]0x03ae
        )
        "synthetic alpha beta gamma delta generated fixture unicode $unicodeWords "
    }
    else {
        'synthetic alpha beta gamma delta epsilon generated fixture payload deterministic '
    }
    $prefix = "$Label-$Ordinal "
    $builder = [System.Text.StringBuilder]::new($Length + $vocabulary.Length)
    $null = $builder.Append($prefix)
    while ($builder.Length -lt $Length) {
        $null = $builder.Append($vocabulary)
    }
    $builder.ToString(0, $Length)
}

function Write-JsonLine {
    param(
        [Parameter(Mandatory)][System.IO.StreamWriter]$Writer,
        [Parameter(Mandatory)]$Value
    )
    $Writer.WriteLine(($Value | ConvertTo-Json -Depth 30 -Compress))
}

$manifestSessions = [System.Collections.Generic.List[object]]::new()
$indexWriter = [System.IO.StreamWriter]::new($sessionIndexPath, $false, [System.Text.UTF8Encoding]::new($false))
$baseTime = [datetimeoffset]::Parse('2026-01-01T00:00:00Z')
try {
    for ($sessionNumber = 1; $sessionNumber -le $Sessions; $sessionNumber++) {
        $sessionId = New-DeterministicGuid "$Seed/session/$sessionNumber"
        $started = $baseTime.AddDays($sessionNumber - 1)
        $dateDirectory = Join-Path $OutputDirectory 'sessions'
        $dateDirectory = Join-Path $dateDirectory $started.ToString('yyyy')
        $dateDirectory = Join-Path $dateDirectory $started.ToString('MM')
        $dateDirectory = Join-Path $dateDirectory $started.ToString('dd')
        New-Item -ItemType Directory -Force -Path $dateDirectory | Out-Null
        $projectDirectory = Join-Path $projectsRoot "synthetic-project-$sessionNumber"
        New-Item -ItemType Directory -Force -Path $projectDirectory | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $projectDirectory 'SYNTHETIC-DATA-ONLY.txt'),
            'This project exists only as a target directory for generated tests.',
            [System.Text.UTF8Encoding]::new($false)
        )

        $fileName = "rollout-{0:yyyy-MM-ddTHH-mm-ss}-$sessionId.jsonl" -f $started
        $rolloutPath = Join-Path $dateDirectory $fileName
        $writer = [System.IO.StreamWriter]::new($rolloutPath, $false, [System.Text.UTF8Encoding]::new($false), 1048576)
        $recordNumber = 0
        try {
            Write-JsonLine $writer @{
                timestamp = $started.ToString('O')
                type = 'session_meta'
                payload = @{
                    id = $sessionId
                    timestamp = $started.ToString('O')
                    cwd = $projectDirectory
                    originator = 'synthetic-test-generator'
                    cli_version = '0.0.0-synthetic'
                    source = 'synthetic'
                }
            }

            for ($turn = 1; $turn -le $Turns; $turn++) {
                $recordNumber++
                $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                Write-JsonLine $writer @{
                    timestamp = $timestamp; type = 'response_item'
                    payload = @{
                        type = 'message'; role = 'user'
                        content = @(@{
                            type = 'input_text'
                            text = New-SyntheticText $TextCharacters 'synthetic-user' $turn
                        })
                    }
                }

                $recordNumber++
                $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                Write-JsonLine $writer @{
                    timestamp = $timestamp; type = 'response_item'
                    payload = @{
                        type = 'message'; role = 'assistant'
                        content = @(@{
                            type = 'output_text'
                            text = New-SyntheticText $TextCharacters 'synthetic-assistant-start' $turn
                        })
                    }
                }

                for ($tool = 1; $tool -le $ToolCallsPerTurn; $tool++) {
                    $callId = "call_synthetic_${sessionNumber}_${turn}_${tool}"
                    $arguments = @{
                        command = "synthetic-command --session $sessionNumber --turn $turn --tool $tool"
                        synthetic = $true
                        ordinal = $tool
                    } | ConvertTo-Json -Compress
                    $recordNumber++
                    $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                    Write-JsonLine $writer @{
                        timestamp = $timestamp; type = 'response_item'
                        payload = @{
                            type = 'function_call'; name = 'exec_command'
                            call_id = $callId; arguments = $arguments
                        }
                    }

                    $isIncomplete = $IncompleteFinalToolCall -and
                        $sessionNumber -eq $Sessions -and $turn -eq $Turns -and $tool -eq $ToolCallsPerTurn
                    if (-not $isIncomplete) {
                        $recordNumber++
                        $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                        Write-JsonLine $writer @{
                            timestamp = $timestamp; type = 'response_item'
                            payload = @{
                                type = 'function_call_output'; call_id = $callId
                                output = New-SyntheticText $ToolPayloadCharacters 'synthetic-tool-output' (($turn * 1000) + $tool)
                            }
                        }
                    }
                }

                $recordNumber++
                $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                Write-JsonLine $writer @{
                    timestamp = $timestamp; type = 'response_item'
                    payload = @{
                        type = 'message'; role = 'assistant'
                        content = @(@{
                            type = 'output_text'
                            text = New-SyntheticText $TextCharacters 'synthetic-assistant-end' $turn
                        })
                    }
                }

                $recordNumber++
                $timestamp = $started.AddMilliseconds($recordNumber * 10).ToString('O')
                Write-JsonLine $writer @{
                    timestamp = $timestamp; type = 'event_msg'
                    payload = @{
                        type = 'token_count'
                        info = @{
                            total_token_usage = @{ input_tokens = 110; cached_input_tokens = 40; cache_write_input_tokens = 10; output_tokens = 30; reasoning_output_tokens = 5; total_tokens = 140 }
                            last_token_usage = @{ input_tokens = 110; cached_input_tokens = 40; cache_write_input_tokens = 10; output_tokens = 30; reasoning_output_tokens = 5; total_tokens = 140 }
                            model_context_window = 258400
                        }
                        rate_limits = $null
                    }
                }
            }
        }
        finally {
            $writer.Dispose()
        }

        $title = "Synthetic Codex session $sessionNumber"
        Write-JsonLine $indexWriter @{
            id = $sessionId; thread_name = $title
            updated_at = $started.AddMilliseconds($recordNumber * 10).ToString('O')
        }
        $manifestSessions.Add([pscustomobject]@{
            id = $sessionId
            title = $title
            file = $rolloutPath
            projectDirectory = $projectDirectory
            bytes = (Get-Item -LiteralPath $rolloutPath).Length
        })
    }
}
finally {
    $indexWriter.Dispose()
}

$manifest = [pscustomobject]@{
    generatedAt = [datetimeoffset]::UtcNow.ToString('O')
    syntheticOnly = $true
    seed = $Seed
    preset = $Preset
    settings = [pscustomobject]@{
        sessions = $Sessions
        turns = $Turns
        toolCallsPerTurn = $ToolCallsPerTurn
        textCharacters = $TextCharacters
        toolPayloadCharacters = $ToolPayloadCharacters
        includeUnicode = [bool]$IncludeUnicode
        incompleteFinalToolCall = [bool]$IncompleteFinalToolCall
    }
    codexDataRoot = $OutputDirectory
    estimatedCharacters = $estimatedCharacters
    sessions = $manifestSessions
}
$manifestPath = Join-Path $OutputDirectory 'generated-manifest.json'
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)

$actualBytes = ($manifestSessions | Measure-Object bytes -Sum).Sum
Write-Host ("Created {0} synthetic Codex session(s), {1:N2} MiB at {2}" -f $Sessions, ($actualBytes / 1MB), $OutputDirectory) -ForegroundColor Green
$manifest
