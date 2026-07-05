param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$WslDistro = 'Ubuntu',
    [switch]$SkipConfigure
)

$ErrorActionPreference = 'Stop'

function ConvertTo-WslPath {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ($resolved -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Cannot convert non-drive path to WSL path: $resolved"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2].Replace('\', '/')
    return "/mnt/$drive/$rest"
}

$composeFile = Join-Path $Root 'third_party\docker_open5gs\4g-volte-deploy.yaml'
$overrideFile = Join-Path $Root 'config\docker-compose.enb-external.override.yaml'
$envFile = Join-Path $Root 'third_party\docker_open5gs\.env'

if (-not $SkipConfigure) {
    $wslRoot = ConvertTo-WslPath -Path $Root
    Write-Host "Generating runtime config through WSL distro '$WslDistro'..."
    wsl -d $WslDistro -- bash -lc "cd '$wslRoot' && bash scripts/configure-env.sh"
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $envFile) {
            Write-Warning "configure-env.sh failed in WSL distro '$WslDistro'. Continuing with existing $envFile. Use -SkipConfigure to suppress this warning."
        } else {
            throw "configure-env.sh failed in WSL distro '$WslDistro' and $envFile does not exist."
        }
    }
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop engine is not reachable from Windows.'
}

docker compose `
    -f $composeFile `
    -f $overrideFile `
    --env-file $envFile `
    up -d

if ($LASTEXITCODE -ne 0) {
    throw 'docker compose up failed.'
}

Write-Host 'Open5GS EPC + Kamailio IMS containers are starting.'
