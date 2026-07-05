#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-docker}"
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

case "$MODE" in
  docker)
    if ! docker info >/dev/null 2>&1; then
      echo "Docker engine is not reachable." >&2
      exit 1
    fi
    cd "$OPEN5GS_PATH"
    docker compose -f srsenb.yaml up -d
    docker container attach srsenb
    ;;
  native)
    if ! command -v srsenb >/dev/null 2>&1; then
      echo "srsenb is not installed in this WSL distro. Use docker mode or install srsRAN_4G natively." >&2
      exit 1
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo cpupower frequency-set -g performance >/dev/null 2>&1 || true
      sudo srsenb "$ROOT/runtime/srsran4g/enb.conf"
    else
      srsenb "$ROOT/runtime/srsran4g/enb.conf"
    fi
    ;;
  *)
    echo "Usage: $0 [docker|native]" >&2
    exit 2
    ;;
esac
