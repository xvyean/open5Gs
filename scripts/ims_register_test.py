#!/usr/bin/env python3
"""Minimal SIP REGISTER tester for the Kamailio IMS (MD5 SIP Digest path).

Sends a REGISTER to the P-CSCF, handles the 401 challenge with MD5 Digest
using the card Ki as the password (matching pyHSS Digest-MD5 behaviour), and
reports the final status. Run from a container on docker_open5gs_default.
"""
import hashlib
import socket
import sys
import uuid

def md5(s):
    return hashlib.md5(s.encode()).hexdigest()

def parse_auth(h):
    h = h.split("Digest", 1)[-1]
    out = {}
    for part in h.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip().lower()] = v.strip().strip('"')
    return out

def main():
    pcscf_ip = sys.argv[1] if len(sys.argv) > 1 else "172.22.0.21"
    pcscf_port = int(sys.argv[2] if len(sys.argv) > 2 else 5060)
    imsi = sys.argv[3] if len(sys.argv) > 3 else "001012345678905"
    ki = sys.argv[4] if len(sys.argv) > 4 else "000102030405060708090A0C0B0D0E0F"
    realm = "ims.mnc001.mcc001.3gppnetwork.org"

    impu = f"sip:{imsi}@{realm}"
    impi = f"{imsi}@{realm}"
    reg_uri = f"sip:{realm}"

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 0))
    s.settimeout(6)
    local_ip = s.getsockname()[0]
    if local_ip == "0.0.0.0":
        local_ip = socket.gethostbyname(socket.gethostname())
    local_port = s.getsockname()[1]

    call_id = uuid.uuid4().hex
    from_tag = uuid.uuid4().hex[:10]
    contact = f"sip:{imsi}@{local_ip}:{local_port}"

    def build(cseq, auth=None):
        h = [
            f"REGISTER {reg_uri} SIP/2.0",
            f"Via: SIP/2.0/UDP {local_ip}:{local_port};branch=z9hG4bK{uuid.uuid4().hex};rport",
            "Max-Forwards: 70",
            f"From: <{impu}>;tag={from_tag}",
            f"To: <{impu}>",
            f"Call-ID: {call_id}",
            f"CSeq: {cseq} REGISTER",
            f"Contact: <{contact}>;expires=600",
            "Expires: 600",
            "Supported: path",
            "User-Agent: ims-register-test",
        ]
        if auth:
            h.append(f"Authorization: {auth}")
        h += ["Content-Length: 0", "", ""]
        return "\r\n".join(h)

    def recv():
        # Skip 1xx provisional responses (e.g. 100 Trying from P-CSCF)
        for _ in range(10):
            data, _addr = s.recvfrom(65535)
            text = data.decode(errors="replace")
            first = text.splitlines()[0] if text.splitlines() else ""
            parts = first.split()
            code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            if 100 <= code <= 199:
                print(f"[<] {first}  (provisional, waiting...)")
                continue
            return text
        return text

    print(f"[*] Target P-CSCF {pcscf_ip}:{pcscf_port}  local {local_ip}:{local_port}")
    print(f"[*] IMPU={impu}  IMPI={impi}  pw=Ki")

    # 1st REGISTER (no auth)
    s.sendto(build(1).encode(), (pcscf_ip, pcscf_port))
    resp = recv()
    line = resp.splitlines()[0]
    print(f"[<] {line}")
    if " 401 " not in line and " 407 " not in line:
        print("[!] Expected 401/407 challenge. Full response:")
        print(resp)
        return 2

    www = None
    for l in resp.splitlines():
        if l.lower().startswith("www-authenticate") or l.lower().startswith("proxy-authenticate"):
            www = l.split(":", 1)[1]
            break
    if not www:
        print("[!] No WWW-Authenticate header")
        print(resp)
        return 2
    p = parse_auth(www)
    print(f"[*] challenge realm={p.get('realm')} qop={p.get('qop')} alg={p.get('algorithm')} nonce={p.get('nonce','')[:16]}...")

    ha1 = md5(f"{impi}:{p.get('realm','')}:{ki}")
    ha2 = md5(f"REGISTER:{reg_uri}")
    nc, cnonce = "00000001", uuid.uuid4().hex[:16]
    if p.get("qop"):
        resp_digest = md5(f"{ha1}:{p['nonce']}:{nc}:{cnonce}:auth:{ha2}")
        auth = (f'Digest username="{impi}", realm="{p.get("realm","")}", nonce="{p["nonce"]}", '
                f'uri="{reg_uri}", qop=auth, nc={nc}, cnonce="{cnonce}", '
                f'response="{resp_digest}", algorithm=MD5')
    else:
        resp_digest = md5(f"{ha1}:{p['nonce']}:{ha2}")
        auth = (f'Digest username="{impi}", realm="{p.get("realm","")}", nonce="{p["nonce"]}", '
                f'uri="{reg_uri}", response="{resp_digest}", algorithm=MD5')
    if p.get("opaque"):
        auth += f', opaque="{p["opaque"]}"'

    # 2nd REGISTER (with auth)
    s.sendto(build(2, auth).encode(), (pcscf_ip, pcscf_port))
    resp2 = recv()
    line2 = resp2.splitlines()[0]
    print(f"[<] {line2}")
    if " 200 " in line2:
        print("[OK] IMS registration SUCCEEDED via MD5 SIP Digest (password = Ki)")
        return 0
    print("[!] Full second response:")
    print(resp2)
    return 1

if __name__ == "__main__":
    sys.exit(main())
