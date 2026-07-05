# stop-zmq-sim.ps1 -- Stop the srsRAN 4G ZMQ simulation containers
# (srsue_zmq first, then srsenb_zmq). The Open5GS/IMS core stack keeps
# running; stop it separately with scripts/stop-core-ims.ps1.
#
# The external network 'docker_open5gs_default' is owned by the core stack
# and is intentionally left untouched by these 'down' commands.
# NEVER add --remove-orphans to the compose commands below: the ZMQ files
# share the compose project name with the core stack, and --remove-orphans
# would tear down the core containers as well.

param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$open5gsDir = Join-Path $Root 'third_party\docker_open5gs'
$enbCompose = Join-Path $open5gsDir 'srsenb_zmq.yaml'
$ueCompose  = Join-Path $open5gsDir 'srsue_zmq.yaml'
$envFile    = Join-Path $open5gsDir '.env'

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop engine is not reachable from Windows.'
}

Write-Host '[1/2] Stopping srsue_zmq...'
docker compose `
    -f $ueCompose `
    --env-file $envFile `
    down
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose down for srsue_zmq failed.'
}

Write-Host '[2/2] Stopping srsenb_zmq...'
docker compose `
    -f $enbCompose `
    --env-file $envFile `
    down
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose down for srsenb_zmq failed.'
}

Write-Host 'ZMQ simulation stopped. Core (EPC + IMS) is still running.'
