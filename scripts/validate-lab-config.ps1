param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

function Require-Path {
    param([string]$Path)
    $full = Join-Path $Root $Path
    if (-not (Test-Path -LiteralPath $full)) {
        $failures.Add("Missing required path: $Path")
    }
}

function Require-Content {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )
    $full = Join-Path $Root $Path
    if (-not (Test-Path -LiteralPath $full)) {
        $failures.Add("Cannot inspect missing file: $Path")
        return
    }
    $text = Get-Content -Raw -LiteralPath $full
    if ($text -notmatch $Pattern) {
        $failures.Add($Message)
    }
}

$requiredPaths = @(
    '.env.shijian',
    'README.md',
    'config\subscribers.csv',
    'config\docker-compose.enb-external.override.yaml',
    'scripts\check-prereqs.ps1',
    'scripts\bootstrap-wsl.sh',
    'scripts\build-images.sh',
    'scripts\configure-env.sh',
    'scripts\start-core-ims.ps1',
    'scripts\start-core-ims.sh',
    'scripts\stop-core-ims.ps1',
    'scripts\stop-core-ims.sh',
    'scripts\provision-subscribers.sh',
    'scripts\provision-subscribers.ps1',
    'scripts\provision-pyhss.ps1',
    'scripts\start-srsenb.sh',
    'scripts\print-ue-settings.ps1',
    'third_party\docker_open5gs\4g-volte-deploy.yaml',
    'third_party\docker_open5gs\srsenb.yaml'
)

foreach ($path in $requiredPaths) {
    Require-Path $path
}

Require-Content '.env.shijian' '(?m)^MCC=001$' 'Expected MCC=001 in .env.shijian'
Require-Content '.env.shijian' '(?m)^MNC=01$' 'Expected MNC=01 in .env.shijian'
Require-Content '.env.shijian' '(?m)^TAC=1$' 'Expected TAC=1 in .env.shijian'
Require-Content 'config\subscribers.csv' '001012345678905,12345678905,000102030405060708090A0C0B0D0E0F,C6413837878F5B826F4F8162A1C8D879' 'Card 5 subscriber row is missing or incorrect'
Require-Content 'config\subscribers.csv' '001012345678906,12345678906,000102030405060708090A0C0B0D0E0F,C6413837878F5B826F4F8162A1C8D879' 'Card 6 subscriber row is missing or incorrect'
Require-Content 'config\docker-compose.enb-external.override.yaml' '36412:36412/sctp' 'S1AP SCTP port is not exposed for external srsENB'
Require-Content 'config\docker-compose.enb-external.override.yaml' '2152:2152/udp' 'S1-U GTP-U port is not exposed for external srsENB'

$readme = Join-Path $Root 'README.md'
if (Test-Path -LiteralPath $readme) {
    $text = Get-Content -Raw -LiteralPath $readme
    if ($text -match 'sip0|G:\\study\\Third\\lab\\sip') {
        $failures.Add('README.md must describe the shijian mobile-network lab, not the separate sip experiment.')
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'Lab config validation failed:'
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host 'Lab config validation passed.'
