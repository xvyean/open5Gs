#!/usr/bin/env bash
# start-zmq-sim.sh -- Bring up the srsRAN 4G ZMQ virtual-RF simulation
# (srsenb_zmq + srsue_zmq) on top of an already running Open5GS EPC + IMS core.
#
# WSL-native-dockerd counterpart of start-zmq-sim.ps1. Since 2026-07-05 the core
# runs on WSL's native dockerd (docker context = default), NOT Docker Desktop,
# so the .ps1 (Windows Docker) targets the wrong engine. Use THIS on the box
# that runs the core -- same engine, same docker_open5gs_default network.
#
# Order matters:
#   1. Core stack must already run (it owns the external network
#      docker_open5gs_default and the MME the eNB connects to over S1AP).
#      Start it first:  bash scripts/start-core-ims.sh
#   2. srsenb_zmq starts first (S1 Setup -> MME, ZMQ tx tcp://172.22.0.22:2000),
#      then srsue_zmq (card 5, IMSI from docker_open5gs/.env UE1_*).
#
# NEVER add --remove-orphans: the ZMQ compose files share the compose project
# name with the core stack; --remove-orphans would tear the core down too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OPEN5GS_PATH="${OPEN5GS_DIR:-$ROOT/third_party/docker_open5gs}"
case "$OPEN5GS_PATH" in
  /*) ;;
  *) OPEN5GS_PATH="$ROOT/$OPEN5GS_PATH" ;;
esac

ENB_COMPOSE="$OPEN5GS_PATH/srsenb_zmq.yaml"
UE_COMPOSE="$OPEN5GS_PATH/srsue_zmq.yaml"
ENV_FILE="$OPEN5GS_PATH/.env"

for f in "$ENB_COMPOSE" "$UE_COMPOSE" "$ENV_FILE"; do
  [ -f "$f" ] || { echo "Required file not found: $f" >&2; exit 1; }
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker engine is not reachable (WSL native dockerd). Is the daemon up?" >&2
  exit 1
fi

# The ZMQ compose files declare docker_open5gs_default as external -> the core
# stack must have created it already.
if ! docker network inspect docker_open5gs_default >/dev/null 2>&1; then
  echo "Docker network 'docker_open5gs_default' not found." >&2
  echo "Start the core first: bash scripts/start-core-ims.sh" >&2
  exit 1
fi

if [ "$(docker inspect --format '{{.State.Running}}' mme 2>/dev/null)" != "true" ]; then
  echo "MME container is not running." >&2
  echo "Start the core first: bash scripts/start-core-ims.sh" >&2
  exit 1
fi

# Both ZMQ services use the prebuilt image 'docker_srslte' (pulled+tagged by
# scripts/build-images.sh pull). Building it from source is slow; prefer pull.
if ! docker image inspect docker_srslte >/dev/null 2>&1; then
  echo "Image 'docker_srslte' not found. Fetch it: bash scripts/build-images.sh pull" >&2
  exit 1
fi

echo "[1/3] Starting srsenb_zmq (S1AP -> MME, ZMQ tx on tcp://172.22.0.22:2000)..."
docker compose -f "$ENB_COMPOSE" --env-file "$ENV_FILE" up -d

echo "[2/3] Waiting for the eNodeB to come up (max 60s)..."
enb_ready=no
for _ in $(seq 1 20); do
  if docker logs --tail 200 srsenb_zmq 2>&1 | grep -q "eNodeB started"; then
    enb_ready=yes; break
  fi
  sleep 3
done
if [ "$enb_ready" = yes ]; then
  echo "      eNodeB is up."
else
  echo "      WARNING: did not see 'eNodeB started' within 60s. Check: docker logs srsenb_zmq" >&2
  echo "      Continuing anyway; the UE will keep searching for the cell."
fi

echo "[3/3] Starting srsue_zmq (card 5, IMSI 001012345678905)..."
docker compose -f "$UE_COMPOSE" --env-file "$ENV_FILE" up -d

echo "      Waiting for attach (max ~60s)..."
attach_ok=no
for _ in $(seq 1 30); do
  if docker logs --tail 100 srsue_zmq 2>&1 | grep -q "Network attach successful"; then
    attach_ok=yes; break
  fi
  sleep 2
done

echo ""
if [ "$attach_ok" = yes ]; then
  echo "ATTACH OK:"
  docker logs --tail 100 srsue_zmq 2>&1 | grep -E "Found PLMN|RRC Connected|Network attach successful" | tail -3
else
  echo "Did not see 'Network attach successful' yet. Follow live: docker logs -f srsue_zmq" >&2
fi

cat <<EOF

ZMQ simulation is up (eNB + UE). Verify the user plane:
  docker exec srsue_zmq ip addr show tun_srsue
  docker exec srsue_zmq ping -c3 -I tun_srsue 192.168.100.1     # APN gateway
  docker exec srsue_zmq ping -c3 -I tun_srsue 8.8.8.8           # internet via UPF NAT
Stop it (core stays up):
  bash scripts/stop-zmq-sim.sh
More checks / troubleshooting: docs/ZMQ_SIM_NOTES.md
EOF
