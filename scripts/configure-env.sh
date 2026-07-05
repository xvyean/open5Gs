#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_ENV="$ROOT/.env.shijian"

if [[ ! -f "$LAB_ENV" ]]; then
  echo "Missing $LAB_ENV" >&2
  exit 1
fi

set -a
source "$LAB_ENV"
set +a

OPEN5GS_PATH="${OPEN5GS_DIR:-third_party/docker_open5gs}"
case "$OPEN5GS_PATH" in
  /*) ;;
  *) OPEN5GS_PATH="$ROOT/$OPEN5GS_PATH" ;;
esac

if [[ ! -d "$OPEN5GS_PATH" ]]; then
  echo "Missing docker_open5gs at $OPEN5GS_PATH" >&2
  echo "Clone it with: git clone --depth 1 https://github.com/herlesupreeth/docker_open5gs \"$OPEN5GS_PATH\"" >&2
  exit 1
fi

DOCKER_ENV="$OPEN5GS_PATH/.env"
if [[ ! -f "$DOCKER_ENV" ]]; then
  echo "Missing upstream .env at $DOCKER_ENV" >&2
  exit 1
fi

if [[ ! -f "$DOCKER_ENV.upstream.bak" ]]; then
  cp "$DOCKER_ENV" "$DOCKER_ENV.upstream.bak"
fi

find "$OPEN5GS_PATH" -type f \( -name '*.sh' -o -name '*_init.sh' -o -name 'start' \) -exec sed -i 's/\r$//' {} +

set_kv() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$DOCKER_ENV"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$DOCKER_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$DOCKER_ENV"
  fi
}

set_kv MCC "$MCC"
set_kv MNC "$MNC"
set_kv TAC "$TAC"
set_kv DOCKER_HOST_IP "$DOCKER_HOST_IP"
set_kv SGWU_ADVERTISE_IP "$DOCKER_HOST_IP"
set_kv UE_IPV4_INTERNET "$UE_IPV4_INTERNET"
set_kv UE_IPV4_IMS "$UE_IPV4_IMS"

mkdir -p "$ROOT/runtime/srsran4g" "$ROOT/runtime/pyhss-payloads"

export ROOT OPEN5GS_PATH MCC MNC TAC DOCKER_HOST_IP RAN_BIND_IP LTE_DL_EARFCN LTE_N_PRB SRSRAN_DEVICE_ARGS
export SUBSCRIBERS_CSV="${SUBSCRIBERS_CSV:-config/subscribers.csv}"

python3 - <<'PY'
import csv
import json
import os
import pathlib
import re

root = pathlib.Path(os.environ["ROOT"])
open5gs = pathlib.Path(os.environ["OPEN5GS_PATH"])
runtime = root / "runtime" / "srsran4g"
pyhss = root / "runtime" / "pyhss-payloads"
runtime.mkdir(parents=True, exist_ok=True)
pyhss.mkdir(parents=True, exist_ok=True)

values = {
    "MCC": os.environ["MCC"],
    "MNC": os.environ["MNC"],
    "TAC": os.environ["TAC"],
    "MME_IP": os.environ["DOCKER_HOST_IP"],
    "SRS_ENB_IP": os.environ["RAN_BIND_IP"],
}

def render(src_name, dst_name):
    text = (open5gs / "srslte" / src_name).read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace(key, value)
    if dst_name == "enb.conf":
        text = re.sub(r"(?m)^n_prb\s*=.*$", f"n_prb = {os.environ['LTE_N_PRB']}", text)
        device_args = os.environ.get("SRSRAN_DEVICE_ARGS", "").strip()
        if device_args:
            if "#device_args = clock=external" in text:
                text = text.replace("#device_args = clock=external", f"device_args = {device_args}")
            elif "device_args =" not in text:
                text = re.sub(r"(?m)^rx_gain\s*=.*$", lambda m: m.group(0) + f"\ndevice_args = {device_args}", text, count=1)
    if dst_name == "rr.conf":
        text = re.sub(r"(?m)^(\s*)dl_earfcn\s*=.*$", rf"\1dl_earfcn = {os.environ['LTE_DL_EARFCN']};", text, count=1)
    (runtime / dst_name).write_text(text, encoding="utf-8", newline="\n")

render("enb.conf", "enb.conf")
render("rr_enb.conf", "rr.conf")
render("rb_enb.conf", "rb.conf")
render("sib_enb.conf", "sib.conf")

mcc = os.environ["MCC"].zfill(3)
mnc = os.environ["MNC"].zfill(3)
realm = f"ims.mnc{mnc}.mcc{mcc}.3gppnetwork.org"

(pyhss / "apn-internet.json").write_text(json.dumps({
    "apn": "internet",
    "apn_ambr_dl": 0,
    "apn_ambr_ul": 0
}, indent=2) + "\n", encoding="utf-8")

(pyhss / "apn-ims.json").write_text(json.dumps({
    "apn": "ims",
    "apn_ambr_dl": 0,
    "apn_ambr_ul": 0
}, indent=2) + "\n", encoding="utf-8")

csv_path = root / os.environ["SUBSCRIBERS_CSV"]
with csv_path.open(newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        label = row["card"]
        imsi = row["imsi"]
        msisdn = row["msisdn"]
        (pyhss / f"{label}-auc.json").write_text(json.dumps({
            "ki": row["ki"],
            "opc": row["opc"],
            "amf": row["amf"],
            "sqn": int(row["sqn"]),
            "imsi": imsi
        }, indent=2) + "\n", encoding="utf-8")
        (pyhss / f"{label}-subscriber.json").write_text(json.dumps({
            "imsi": imsi,
            "enabled": True,
            "auc_id": "REPLACE_WITH_AUC_ID",
            "default_apn": "REPLACE_WITH_INTERNET_APN_ID",
            "apn_list": "REPLACE_WITH_INTERNET_APN_ID,REPLACE_WITH_IMS_APN_ID",
            "msisdn": msisdn,
            "ue_ambr_dl": 0,
            "ue_ambr_ul": 0
        }, indent=2) + "\n", encoding="utf-8")
        (pyhss / f"{label}-ims-subscriber.json").write_text(json.dumps({
            "imsi": imsi,
            "msisdn": msisdn,
            "sh_profile": "string",
            "scscf_peer": f"scscf.{realm}",
            "msisdn_list": f"[{msisdn}]",
            "ifc_path": "default_ifc.xml",
            "scscf": f"sip:scscf.{realm}:6060",
            "scscf_realm": realm
        }, indent=2) + "\n", encoding="utf-8")
PY

echo "Configured $DOCKER_ENV"
echo "Generated runtime srsRAN 4G configs under $ROOT/runtime/srsran4g"
echo "Generated pyHSS payloads under $ROOT/runtime/pyhss-payloads"
