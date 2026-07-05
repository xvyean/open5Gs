#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a
source "$ROOT/.env.shijian"
set +a

OPEN5GS_PATH="${OPEN5GS_DIR:-third_party/docker_open5gs}"
case "$OPEN5GS_PATH" in
  /*) ;;
  *) OPEN5GS_PATH="$ROOT/$OPEN5GS_PATH" ;;
esac

cd "$OPEN5GS_PATH"
docker compose -f 4g-volte-deploy.yaml -f "$ROOT/config/docker-compose.enb-external.override.yaml" down
