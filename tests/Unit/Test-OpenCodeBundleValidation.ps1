[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleManifest = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1'
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "OpenCode.ImportCodex-bundle-validation-$PID-$([guid]::NewGuid().ToString('N'))"
$TargetDirectory = Join-Path $TemporaryRoot 'target with spaces'
$BundlePath = Join-Path $TemporaryRoot 'bundle.json'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Copy-TestValue {
    param($Value)
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function Write-TestBundle {
    param($Bundle)
    [System.IO.File]::WriteAllText(
        $BundlePath,
        ($Bundle | ConvertTo-Json -Depth 100),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Test-BundleRejected {
    param($Bundle, [string]$ExpectedMessage, [string]$Description)
    Write-TestBundle $Bundle
    try {
        & $script:Module {
            param($Path, $Directory)
            Test-OpenCodeImportBundle -Path $Path -TargetDirectory $Directory
        } $BundlePath $TargetDirectory | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) { throw }
        return
    }
    throw "Invalid bundle was accepted: $Description"
}

try {
    New-Item -ItemType Directory -Force -Path $TargetDirectory | Out-Null
    Remove-Module OpenCode.ImportCodex -Force -ErrorAction SilentlyContinue
    Import-Module $ModuleManifest -Force
    $script:Module = Get-Module OpenCode.ImportCodex

    $sessionId = 'ses_test'
    $userMessageId = 'msg_000000000000000000000001'
    $assistantMessageId = 'msg_000000000000000000000002'
    $validBundle = [ordered]@{
        info = [ordered]@{ id = $sessionId; title = 'Synthetic validation'; directory = $TargetDirectory; time = @{ created = 1; updated = 2 } }
        messages = @(
            [ordered]@{
                info = [ordered]@{ id = $userMessageId; sessionID = $sessionId; role = 'user'; time = @{ created = 1 } }
                parts = @(
                    [ordered]@{ id = 'prt_000000000000000000000001'; sessionID = $sessionId; messageID = $userMessageId; type = 'text'; text = 'Synthetic user text.' },
                    [ordered]@{
                        id = 'prt_000000000000000000000002'; sessionID = $sessionId; messageID = $userMessageId; type = 'text'; synthetic = $true
                        text = '[Archived Codex code-mode activity: 1 opaque execution. Raw source and output are intentionally excluded from model context.]'
                        metadata = @{ codex = @{ kind = 'code_mode_archive'; executions = @(@{ callId = 'synthetic-call'; source = 'synthetic source'; outputs = @('synthetic output') }) } }
                    }
                )
            },
            [ordered]@{
                info = [ordered]@{ id = $assistantMessageId; sessionID = $sessionId; role = 'assistant'; time = @{ created = 2 } }
                parts = @(
                    [ordered]@{
                        id = 'prt_000000000000000000000003'; sessionID = $sessionId; messageID = $assistantMessageId; type = 'tool'; tool = 'apply_patch'; callID = 'call_synthetic'
                        state = @{ status = 'completed'; input = @{ patchText = 'synthetic' }; output = 'done'; time = @{ start = 2; end = 2 } }
                    }
                )
            }
        )
    }

    Write-TestBundle $validBundle
    $validation = & $script:Module {
        param($Path, $Directory)
        Test-OpenCodeImportBundle -Path $Path -TargetDirectory $Directory
    } $BundlePath $TargetDirectory
    Assert-True ($validation.MessageCount -eq 2) 'valid bundle should report its exact message count'
    Assert-True ($validation.PartCount -eq 3) 'valid bundle should report all text, archive, and tool parts'
    Assert-True ($validation.OpenCodeSessionId -eq $sessionId) 'valid bundle should retain the session ID'

    $duplicatePart = Copy-TestValue $validBundle
    $duplicatePart.messages[1].parts[0].id = $duplicatePart.messages[0].parts[0].id
    Test-BundleRejected $duplicatePart 'duplicate part IDs' 'duplicate part IDs'

    $wrongParent = Copy-TestValue $validBundle
    $wrongParent.messages[1].parts[0].messageID = $userMessageId
    Test-BundleRejected $wrongParent 'inconsistent parent IDs' 'part parent mismatch'

    $pendingTool = Copy-TestValue $validBundle
    $pendingTool.messages[1].parts[0].state.status = 'pending'
    Test-BundleRejected $pendingTool 'invalid tool state' 'nonterminal tool state'

    $unsafeImage = Copy-TestValue $validBundle
    $unsafeImage.messages[1].parts[0] = [pscustomobject]@{ id = 'prt_000000000000000000000003'; sessionID = $sessionId; messageID = $assistantMessageId; type = 'file'; mime = 'image/png'; url = 'https://example.invalid/image.png' }
    Test-BundleRejected $unsafeImage 'unsafe or unsupported image part' 'remote image URL'

    $wrongDirectory = Copy-TestValue $validBundle
    $wrongDirectory.info.directory = Join-Path $TemporaryRoot 'other-target'
    Test-BundleRejected $wrongDirectory 'Bundle directory mismatch' 'embedded target mismatch'

    $emptyBundle = Copy-TestValue $validBundle
    $emptyBundle.messages = @()
    Test-BundleRejected $emptyBundle 'no messages' 'empty message list'

    $invalidSession = Copy-TestValue $validBundle
    $invalidSession.info.id = 'invalid'
    Test-BundleRejected $invalidSession 'invalid OpenCode session ID' 'invalid session ID'

    Write-Host 'OpenCode bundle validation tests passed (1 valid and 7 rejected bundles).' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}
