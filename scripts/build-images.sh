#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-pull}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/configure-env.sh"

DOCKER_CONFIG_DIR="$ROOT/runtime/docker-config"
mkdir -p "$DOCKER_CONFIG_DIR"
if [[ ! -f "$DOCKER_CONFIG_DIR/config.json" ]]; then
  printf '{}\n' > "$DOCKER_CONFIG_DIR/config.json"
fi
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

set -a
source "$ROOT/.env.shijian"
set +a

OPEN5GS_PATH="${OPEN5GS_DIR:-third_party/docker_open5gs}"
case "$OPEN5GS_PATH" in
  /*) ;;
  *) OPEN5GS_PATH="$ROOT/$OPEN5GS_PATH" ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "Docker engine is not reachable. Start Docker Desktop and enable WSL integration first." >&2
  exit 1
fi

cd "$OPEN5GS_PATH"

pull_and_tag() {
  local upstream="$1"
  local local_name="$2"
  echo "[pull] $upstream -> $local_name"
  docker pull "$upstream"
  docker tag "$upstream" "$local_name"
}

case "$MODE" in
  pull)
    pull_and_tag ghcr.io/herlesupreeth/docker_open5gs:master docker_open5gs
    pull_and_tag ghcr.io/herlesupreeth/docker_kamailio:master docker_kamailio
    pull_and_tag ghcr.io/herlesupreeth/docker_pyhss:master docker_pyhss
    pull_and_tag ghcr.io/herlesupreeth/docker_mysql:master docker_mysql
    pull_and_tag ghcr.io/herlesupreeth/docker_osmomsc:master docker_osmomsc
    pull_and_tag ghcr.io/herlesupreeth/docker_osmohlr:master docker_osmohlr
    pull_and_tag ghcr.io/herlesupreeth/docker_metrics:master docker_metrics
    pull_and_tag ghcr.io/herlesupreeth/docker_srslte:master docker_srslte
    pull_and_tag ghcr.io/herlesupreeth/docker_dns:master docker_dns
    pull_and_tag ghcr.io/herlesupreeth/docker_rtpengine:master docker_rtpengine
    docker pull mongo:6.0
    docker pull grafana/grafana:11.3.0
    ;;
  build)
    echo "[build] Building Open5GS base image..."
    docker build --no-cache --force-rm -t docker_open5gs ./base

    echo "[build] Building Kamailio IMS base image..."
    docker build --no-cache --force-rm -t docker_kamailio ./ims_base

    echo "[build] Building srsRAN 4G image for USRP/srsENB..."
    docker build --no-cache --force-rm -t docker_srslte ./srslte

    echo "[build] Building 4G VoLTE compose images..."
    docker compose -f 4g-volte-deploy.yaml build
    ;;
  *)
    echo "Usage: $0 [pull|build]" >&2
    exit 2
    ;;
esac

echo "[build] Images ready for mode=$MODE."
