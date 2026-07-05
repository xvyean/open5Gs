# start-zmq-sim.ps1 -- Bring up the srsRAN 4G ZMQ virtual-RF simulation
# (srsenb_zmq + srsue_zmq) on top of an already running Open5GS EPC + IMS
# core (started via scripts/start-core-ims.ps1, compose file
# third_party/docker_open5gs/4g-volte-deploy.yaml).
#
# Order matters:
#   1. Core stack must already run: it owns the external docker network
#      "docker_open5gs_default" and the MME (172.22.0.9) that the eNB
#      connects to over S1AP.
#   2. srsenb_zmq starts first (binds ZMQ tx tcp://SRS_ENB_IP:2000, performs
#      S1 Setup towards MME_IP).
#   3. srsue_zmq starts last (binds ZMQ tx tcp://SRS_UE_IP:2001 and connects
#      to the eNB's port 2000). The eNB runs with fail_on_disconnect=true,
#      so if the UE is restarted alone and the radio link dies, restart the
#      eNB as well (stop-zmq-sim.ps1 then this script).
#
# UE identity comes from third_party/docker_open5gs/.env (UE1_IMSI/UE1_KI/
# UE1_OP -> card 5, IMSI 001012345678905; UE1_OP holds the card's OPc and
# srslte/ue_zmq.conf maps it to "opc =").
#
# Verification checklist (details in docs/ZMQ_SIM_NOTES.md):
#   docker logs -f srsue_zmq      -> "Found Cell ... PCI=1", "Found PLMN Id=00101",
#                                    "RRC Connected",
#                                    "Network attach successful. IP: 192.168.100.x"
#   docker logs srsenb_zmq        -> "==== eNodeB started ===", "RACH: ...", "User 0x... connected"
#   docker logs mme               -> S1 setup from 172.22.0.22 and Attach complete
#   docker exec srsue_zmq ip addr show tun_srsue
#   docker exec srsue_zmq ping -c 3 -I tun_srsue 192.168.100.1   (APN gateway)
#   docker exec srsue_zmq ping -c 3 -I tun_srsue 8.8.8.8         (internet via UPF NAT)

param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$open5gsDir = Join-Path $Root 'third_party\docker_open5gs'
$enbCompose = Join-Path $open5gsDir 'srsenb_zmq.yaml'
$ueCompose  = Join-Path $open5gsDir 'srsue_zmq.yaml'
$envFile    = Join-Path $open5gsDir '.env'

foreach ($f in @($enbCompose, $ueCompose, $envFile)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Required file not found: $f"
    }
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop engine is not reachable from Windows.'
}

# The ZMQ compose files declare the network as external -> the core stack
# must have created it already.
docker network inspect docker_open5gs_default *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker network 'docker_open5gs_default' does not exist. Start the core first: scripts\start-core-ims.ps1"
}

docker inspect --format '{{.State.Running}}' mme *> $null
if ($LASTEXITCODE -ne 0) {
    throw "MME container not found. Start the core first: scripts\start-core-ims.ps1"
}
$mmeState = docker inspect --format '{{.State.Running}}' mme
if ("$mmeState".Trim() -ne 'true') {
    throw "MME container exists but is not running. Start the core first: scripts\start-core-ims.ps1"
}

# Both ZMQ services use the prebuilt image 'docker_srslte'. It is pulled and
# tagged by scripts/build-images.sh (mode: pull). Building it locally compiles
# srsRAN 4G from source and takes a long time -- prefer the pull path.
docker image inspect docker_srslte *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Image 'docker_srslte' is missing. Fetch it with either:"
    Write-Warning "  wsl -d Ubuntu -- bash -lc 'cd <repo> && bash scripts/build-images.sh pull'"
    Write-Warning "  or: docker pull ghcr.io/herlesupreeth/docker_srslte:master; docker tag ghcr.io/herlesupreeth/docker_srslte:master docker_srslte"
    throw "Image 'docker_srslte' not found."
}

Write-Host '[1/3] Starting srsenb_zmq (S1AP -> MME, ZMQ tx on tcp://172.22.0.22:2000)...'
docker compose `
    -f $enbCompose `
    --env-file $envFile `
    up -d
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose up for srsenb_zmq failed.'
}
# Note: compose may print a "Found orphan containers" warning because the ZMQ
# files share the project name with the core stack. That warning is harmless.
# NEVER add --remove-orphans here: it would tear down the core containers.

Write-Host '[2/3] Waiting for the eNodeB to come up (max 60 s)...'
$deadline = (Get-Date).AddSeconds(60)
$enbReady = $false
while (-not $enbReady) {
    Start-Sleep -Seconds 3
    $enbLog = (docker logs --tail 200 srsenb_zmq | Out-String)
    if ($enbLog -match 'eNodeB started') {
        $enbReady = $true
    } elseif ((Get-Date) -ge $deadline) {
        break
    }
}
if ($enbReady) {
    Write-Host '      eNodeB is up.'
} else {
    Write-Warning 'Did not see "eNodeB started" within 60 s. Check: docker logs srsenb_zmq'
    Write-Warning 'Continuing anyway; the UE will keep searching for the cell.'
}

Write-Host '[3/3] Starting srsue_zmq (card 5, IMSI 001012345678905)...'
docker compose `
    -f $ueCompose `
    --env-file $envFile `
    up -d
if ($LASTEXITCODE -ne 0) {
    throw 'docker compose up for srsue_zmq failed.'
}

Write-Host ''
Write-Host 'ZMQ simulation containers are starting.'
Write-Host 'Follow the attach procedure with:'
Write-Host '    docker logs -f srsue_zmq'
Write-Host 'Expected success line:'
Write-Host '    Network attach successful. IP: 192.168.100.x'
Write-Host 'Then verify the user plane:'
Write-Host '    docker exec srsue_zmq ip addr show tun_srsue'
Write-Host '    docker exec srsue_zmq ping -c 3 -I tun_srsue 192.168.100.1'
Write-Host '    docker exec srsue_zmq ping -c 3 -I tun_srsue 8.8.8.8'
Write-Host 'More checks and troubleshooting: docs\ZMQ_SIM_NOTES.md'
