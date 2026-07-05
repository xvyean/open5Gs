#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/configure-env.sh"

set -a
source "$ROOT/.env.shijian"
set +a

CSV_PATH="$ROOT/${SUBSCRIBERS_CSV:-config/subscribers.csv}"

if ! docker ps --format '{{.Names}}' | grep -qx 'webui'; then
  echo "Container 'webui' is not running. Start the core first: bash scripts/start-core-ims.sh" >&2
  exit 1
fi

echo "[provision] Writing Open5GS HSS subscriber records..."
tail -n +2 "$CSV_PATH" | while IFS=, read -r card imsi msisdn ki opc amf sqn; do
  [[ -z "${imsi:-}" ]] && continue
  echo "  - $card IMSI=$imsi MSISDN=$msisdn"
  docker exec webui misc/db/open5gs-dbctl remove_ue "$imsi" >/dev/null 2>&1 || true
  docker exec webui misc/db/open5gs-dbctl add_ue_with_apn "$imsi" "$ki" "$opc" internet
  docker exec webui misc/db/open5gs-dbctl update_apn "$imsi" ims 0
done

cat <<EOF

Open5GS HSS records were requested.

IMS/pyHSS still needs the APN/AUC/subscriber/IMS-subscriber entries. Payloads
have been generated here:
  $ROOT/runtime/pyhss-payloads

Open Swagger UI and apply them in this order:
  http://$DOCKER_HOST_IP:8080/docs/
  1. apn: runtime/pyhss-payloads/apn-internet.json
  2. apn: runtime/pyhss-payloads/apn-ims.json
  3. auc: card*-auc.json
  4. subscriber: card*-subscriber.json, replacing APN/AUC IDs with returned IDs
  5. ims_subscriber: card*-ims-subscriber.json
EOF
