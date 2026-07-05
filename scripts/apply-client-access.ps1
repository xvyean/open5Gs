# Applies config\docker-compose.client-access.override.yaml on top of the
# running 4G VoLTE stack: publishes pcscf 5060/udp+tcp and rtpengine
# 49000-49100/udp to the Windows host, and makes rtpengine advertise
# DOCKER_HOST_IP (from third_party\docker_open5gs\.env) in SDP.
#
# Only pcscf and rtpengine are (re)created; the other 19 containers are left
# untouched. After this runs, soft clients must (re)REGISTER.
#
# PowerShell 5.1 compatible (no && / || chains).

param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$composeFile    = Join-Path $Root 'third_party\docker_open5gs\4g-volte-deploy.yaml'
$enbOverride    = Join-Path $Root 'config\docker-compose.enb-external.override.yaml'
$clientOverride = Join-Path $Root 'config\docker-compose.client-access.override.yaml'
$envFile        = Join-Path $Root 'third_party\docker_open5gs\.env'

foreach ($f in @($composeFile, $enbOverride, $clientOverride, $envFile)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Required file not found: $f"
    }
}

# Warn if the host IP baked into .env no longer matches this machine.
$hostIpLine = Select-String -LiteralPath $envFile -Pattern '^DOCKER_HOST_IP=(.+)$' | Select-Object -First 1
if ($null -ne $hostIpLine) {
    $advertisedIp = $hostIpLine.Matches[0].Groups[1].Value.Trim()
    $localIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    if ($localIps -notcontains $advertisedIp) {
        Write-Warning "DOCKER_HOST_IP=$advertisedIp (from .env) is not an IPv4 address of this machine. Re-run scripts\configure-env.sh (WSL) or fix .env, otherwise rtpengine will advertise an unreachable media IP."
    } else {
        Write-Host "rtpengine will advertise $advertisedIp for RTP."
    }
} else {
    Write-Warning 'DOCKER_HOST_IP not found in .env; the override cannot interpolate the advertised IP.'
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop engine is not reachable from Windows.'
}

# Fail early if something on the host already occupies 5060.
$udp5060 = Get-NetUDPEndpoint -LocalPort 5060 -ErrorAction SilentlyContinue
if ($null -ne $udp5060) {
    Write-Warning 'UDP port 5060 already has a listener on this host; publishing pcscf may fail. Check with: netstat -ano | findstr :5060'
}

docker compose `
    -f $composeFile `
    -f $enbOverride `
    -f $clientOverride `
    --env-file $envFile `
    up -d pcscf rtpengine

if ($LASTEXITCODE -ne 0) {
    throw 'docker compose up failed while applying the client-access override.'
}

Write-Host ''
Write-Host 'client-access override applied:'
Write-Host '  - pcscf     : host 5060/udp + 5060/tcp -> 172.22.0.21:5060'
Write-Host '  - rtpengine : host 49000-49100/udp     -> 172.22.0.16, SDP advertises DOCKER_HOST_IP'
Write-Host 'Soft clients can now REGISTER against <host-ip>:5060. See docs\CLIENT_IMS_ONBOARDING.md.'
Write-Host 'To revert: re-run scripts\start-core-ims.ps1 (without the client-access override).'
