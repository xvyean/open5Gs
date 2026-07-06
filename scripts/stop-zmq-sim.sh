#!/usr/bin/env bash
# stop-zmq-sim.sh -- Stop the srsRAN 4G ZMQ simulation (srsue_zmq first, then
# srsenb_zmq). The Open5GS/IMS core keeps running; stop it separately with
# scripts/stop-core-ims.sh.
#
# WSL-native-dockerd counterpart of stop-zmq-sim.ps1. The external network
# docker_open5gs_default is owned by the core stack and left untouched here.
# NEVER add --remove-orphans: the ZMQ files share the compose project name with
# the core stack, so --remove-orphans would tear down the core containers too.
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

if ! docker info >/dev/null 2>&1; then
  echo "Docker engine is not reachable (WSL native dockerd)." >&2
  exit 1
fi

echo "[1/2] Stopping srsue_zmq..."
docker compose -f "$UE_COMPOSE" --env-file "$ENV_FILE" down

echo "[2/2] Stopping srsenb_zmq..."
docker compose -f "$ENB_COMPOSE" --env-file "$ENV_FILE" down

echo "ZMQ simulation stopped. Core (EPC + IMS) is still running."
