[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TestsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Split-Path -Parent $TestsRoot
$ModuleManifest = Join-Path $RepoRoot 'src/OpenCode.ImportCodex/OpenCode.ImportCodex.psd1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-CodexOutputDecoder {
    param($Value)
    & $script:Module {
        param($InputValue)
        ConvertFrom-CodexCustomToolOutput $InputValue
    } $Value
}

Remove-Module OpenCode.ImportCodex -Force -ErrorAction SilentlyContinue
Import-Module $ModuleManifest -Force
$script:Module = Get-Module OpenCode.ImportCodex

$textEnvelope = '[{"type":"input_text","text":"first\n"},{"type":"output_text","text":"second"},{"type":"text","text":" third"}]'
Assert-True ((Invoke-CodexOutputDecoder $textEnvelope) -ceq "first`nsecond third") 'all supported textual envelope variants should flatten in order with exact text'

$emptyTextEnvelope = '[{"type":"input_text","text":""},{"type":"text","text":"tail"}]'
Assert-True ((Invoke-CodexOutputDecoder $emptyTextEnvelope) -ceq 'tail') 'empty textual items should remain valid and preserve following text'

foreach ($case in @(
    [pscustomobject]@{ Name = 'malformed JSON'; Raw = '[{"type":"input_text"'; Expected = '[{"type":"input_text"' },
    [pscustomobject]@{ Name = 'unknown item type'; Raw = '[{"type":"image","text":"not text"}]'; Expected = '[{"type":"image","text":"not text"}]' },
    [pscustomobject]@{ Name = 'mixed text and image'; Raw = '[{"type":"input_text","text":"visible"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]'; Expected = '[{"type":"input_text","text":"visible"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]' },
    [pscustomobject]@{ Name = 'null item'; Raw = '[null]'; Expected = '[null]' },
    [pscustomobject]@{ Name = 'missing text property'; Raw = '[{"type":"text"}]'; Expected = '[{"type":"text"}]' },
    [pscustomobject]@{ Name = 'empty array'; Raw = '[]'; Expected = '[]' }
)) {
    Assert-True ((Invoke-CodexOutputDecoder $case.Raw) -ceq $case.Expected) "$($case.Name) must be preserved byte-for-byte rather than partially decoded"
}

$objectValue = [ordered]@{ type = 'input_image'; image_url = 'data:image/png;base64,AA==' }
$objectResult = Invoke-CodexOutputDecoder $objectValue
Assert-True ($objectResult -ceq '{"type":"input_image","image_url":"data:image/png;base64,AA=="}') 'non-string mixed-content values should remain a lossless compact JSON envelope'

Write-Host 'Codex custom-tool output decoding tests passed (9 cases).' -ForegroundColor Green
