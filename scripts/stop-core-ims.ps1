param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$composeFile = Join-Path $Root 'third_party\docker_open5gs\4g-volte-deploy.yaml'
$overrideFile = Join-Path $Root 'config\docker-compose.enb-external.override.yaml'
$envFile = Join-Path $Root 'third_party\docker_open5gs\.env'

docker compose `
    -f $composeFile `
    -f $overrideFile `
    --env-file $envFile `
    down

if ($LASTEXITCODE -ne 0) {
    throw 'docker compose down failed.'
}

Write-Host 'Open5GS EPC + Kamailio IMS containers stopped.'
