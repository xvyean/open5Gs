#!/usr/bin/env python3
"""Provision pyHSS (IMS) subscribers via REST, runnable from inside WSL against
the docker bridge IP. Mirrors scripts/provision-pyhss.ps1 (apn -> auc ->
subscriber -> ims_subscriber with id chaining)."""
import json, sys, os, urllib.request, urllib.error, csv

BASE = os.environ.get("PYHSS_BASE", "http://172.22.0.18:8080")
ROOT = os.environ.get("SHIJIAN_ROOT", "/mnt/g/study/Third/lab/shijian")
PDIR = os.path.join(ROOT, "runtime", "pyhss-payloads")
CSV = os.path.join(ROOT, "config", "subscribers.csv")


def req(method, path, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            txt = resp.read().decode()
            try:
                return resp.status, json.loads(txt)
            except Exception:
                return resp.status, txt
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try:
            return e.code, json.loads(txt)
        except Exception:
            return e.code, txt
    except Exception as e:
        return 0, str(e)


def load(name):
    with open(os.path.join(PDIR, name)) as f:
        return json.load(f)


def ensure_apn(name, payload_file):
    st, body = req("PUT", "/apn/", load(payload_file))
    if isinstance(body, dict) and body.get("apn_id") is not None:
        print(f"  APN '{name}' created apn_id={body['apn_id']}")
        return int(body["apn_id"])
    # fallback: list and find by name
    st, body = req("GET", "/apn/list")
    if isinstance(body, list):
        for a in body:
            if a.get("apn") == name:
                print(f"  APN '{name}' found apn_id={a['apn_id']}")
                return int(a["apn_id"])
    print(f"  !! APN '{name}' create failed st={st} body={body}")
    sys.exit(2)


def ensure_auc(imsi, payload_file):
    st, body = req("GET", f"/auc/imsi/{imsi}")
    if isinstance(body, dict) and body.get("auc_id") is not None:
        print(f"  AuC exists imsi={imsi} auc_id={body['auc_id']}")
        return int(body["auc_id"])
    st, body = req("PUT", "/auc/", load(payload_file))
    if isinstance(body, dict) and body.get("auc_id") is not None:
        print(f"  AuC created imsi={imsi} auc_id={body['auc_id']}")
        return int(body["auc_id"])
    st, body = req("GET", f"/auc/imsi/{imsi}")
    if isinstance(body, dict) and body.get("auc_id") is not None:
        return int(body["auc_id"])
    print(f"  !! AuC failed imsi={imsi} st={st} body={body}")
    sys.exit(2)


def ensure_subscriber(imsi, payload_file, auc_id, internet_apn, ims_apn):
    p = load(payload_file)
    p["auc_id"] = auc_id
    p["default_apn"] = internet_apn
    p["apn_list"] = f"{internet_apn},{ims_apn}"
    st, ex = req("GET", f"/subscriber/imsi/{imsi}")
    if isinstance(ex, dict) and ex.get("subscriber_id") is not None:
        req("PATCH", f"/subscriber/{ex['subscriber_id']}", p)
        print(f"  subscriber updated imsi={imsi} id={ex['subscriber_id']}")
        return int(ex["subscriber_id"])
    st, body = req("PUT", "/subscriber/", p)
    if isinstance(body, dict) and body.get("subscriber_id") is not None:
        print(f"  subscriber created imsi={imsi} id={body['subscriber_id']}")
        return int(body["subscriber_id"])
    print(f"  !! subscriber failed imsi={imsi} st={st} body={body}")
    sys.exit(2)


def ensure_ims_subscriber(imsi, payload_file):
    p = load(payload_file)
    st, ex = req("GET", f"/ims_subscriber/ims_subscriber_imsi/{imsi}")
    if isinstance(ex, dict) and ex.get("ims_subscriber_id") is not None:
        req("PATCH", f"/ims_subscriber/{ex['ims_subscriber_id']}", p)
        print(f"  ims_subscriber updated imsi={imsi} id={ex['ims_subscriber_id']}")
        return int(ex["ims_subscriber_id"])
    st, body = req("PUT", "/ims_subscriber/", p)
    if isinstance(body, dict) and body.get("ims_subscriber_id") is not None:
        print(f"  ims_subscriber created imsi={imsi} id={body['ims_subscriber_id']}")
        return int(body["ims_subscriber_id"])
    print(f"  !! ims_subscriber failed imsi={imsi} st={st} body={body}")
    sys.exit(2)


def main():
    st, _ = req("GET", "/oam/ping")
    print(f"[*] pyHSS {BASE} ping st={st}")
    if st == 0:
        print("!! pyHSS unreachable"); sys.exit(2)
    internet = ensure_apn("internet", "apn-internet.json")
    ims = ensure_apn("ims", "apn-ims.json")
    with open(CSV) as f:
        for row in csv.DictReader(f):
            label, imsi = row["card"], row["imsi"]
            if not imsi:
                continue
            print(f"[*] {label} imsi={imsi}")
            auc = ensure_auc(imsi, f"{label}-auc.json")
            ensure_subscriber(imsi, f"{label}-subscriber.json", auc, internet, ims)
            ensure_ims_subscriber(imsi, f"{label}-ims-subscriber.json")
    print("[+] pyHSS provisioning done")


if __name__ == "__main__":
    main()
