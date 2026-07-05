#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/configure-env.sh"

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

if command -v timeout >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
  timeout 5s sudo -n sysctl -w net.ipv4.ip_forward=1 || echo "Warning: could not set net.ipv4.ip_forward from WSL. Continue and verify UE routing after attach."
else
  sysctl -w net.ipv4.ip_forward=1 || echo "Warning: could not set net.ipv4.ip_forward. Continue and verify UE routing after attach."
fi

cd "$OPEN5GS_PATH"
docker compose -f 4g-volte-deploy.yaml -f "$ROOT/config/docker-compose.enb-external.override.yaml" up -d
docker compose -f 4g-volte-deploy.yaml -f "$ROOT/config/docker-compose.enb-external.override.yaml" ps

cat <<EOF

Core + IMS requested.
Open5GS WebUI: http://$DOCKER_HOST_IP:9999  (admin / 1423)
pyHSS Swagger: http://$DOCKER_HOST_IP:8080/docs/
Grafana:       http://$DOCKER_HOST_IP:3000  (open5gs / open5gs)

Next:
  bash scripts/provision-subscribers.sh
  bash scripts/start-srsenb.sh docker
EOF
