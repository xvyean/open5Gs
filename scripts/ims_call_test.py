#!/usr/bin/env python3
"""Two-endpoint IMS call test that mimics the custom SipClient behaviour.

Registers two UEs (card5, card6) to the P-CSCF via MD5 SIP Digest (password =
Ki), then UE-A sends a naive INVITE (To/From only, no Service-Route handling,
just like the project's SipClient) toward UE-B. UE-B auto-answers 200 OK with
SDP. We report whether the INVITE routed through the IMS to UE-B and whether
rtpengine anchored the media (SDP c=/m= rewritten to the rtpengine IP).
"""
import hashlib
import socket
import sys
import threading
import time
import uuid

REALM = "ims.mnc001.mcc001.3gppnetwork.org"
PCSCF = ("172.22.0.21", 5060)
RTPENGINE_IP = "172.22.0.16"

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

def hdr(text, name):
    for l in text.splitlines():
        if l.lower().startswith(name.lower() + ":"):
            return l.split(":", 1)[1].strip()
    return None

def status(text):
    first = text.splitlines()[0] if text.splitlines() else ""
    p = first.split()
    return int(p[1]) if len(p) > 1 and p[1].isdigit() else 0

class UE:
    def __init__(self, imsi, ki):
        self.imsi, self.ki = imsi, ki
        self.impu = f"sip:{imsi}@{REALM}"
        self.impi = f"{imsi}@{REALM}"
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.bind(("0.0.0.0", 0))
        self.s.settimeout(8)
        ip = self.s.getsockname()[0]
        if ip == "0.0.0.0":
            ip = socket.gethostbyname(socket.gethostname())
        self.ip = ip
        self.port = self.s.getsockname()[1]
        self.contact = f"sip:{imsi}@{self.ip}:{self.port};transport=udp"
        self.call_id = uuid.uuid4().hex
        self.tag = uuid.uuid4().hex[:10]
        self.incoming = []
        self.answered_media = None
        self.listen = False

    def digest(self, method, uri, p):
        ha1 = md5(f"{self.impi}:{p.get('realm','')}:{self.ki}")
        ha2 = md5(f"{method}:{uri}")
        nc, cn = "00000001", uuid.uuid4().hex[:16]
        if p.get("qop"):
            r = md5(f"{ha1}:{p['nonce']}:{nc}:{cn}:auth:{ha2}")
            a = (f'Digest username="{self.impi}", realm="{p.get("realm","")}", nonce="{p["nonce"]}", '
                 f'uri="{uri}", qop=auth, nc={nc}, cnonce="{cn}", response="{r}", algorithm=MD5')
        else:
            r = md5(f"{ha1}:{p['nonce']}:{ha2}")
            a = (f'Digest username="{self.impi}", realm="{p.get("realm","")}", nonce="{p["nonce"]}", '
                 f'uri="{uri}", response="{r}", algorithm=MD5')
        if p.get("opaque"):
            a += f', opaque="{p["opaque"]}"'
        return a

    def recv_final(self):
        while True:
            data, _ = self.s.recvfrom(65535)
            t = data.decode(errors="replace")
            if 100 <= status(t) <= 199:
                print(f"    [{self.imsi[-3:]}<] {t.splitlines()[0]}  (prov)")
                continue
            return t

    def register(self):
        reg_uri = f"sip:{REALM}"
        def build(cseq, auth=None):
            h = [f"REGISTER {reg_uri} SIP/2.0",
                 f"Via: SIP/2.0/UDP {self.ip}:{self.port};branch=z9hG4bK{uuid.uuid4().hex};rport",
                 "Max-Forwards: 70",
                 f"From: <{self.impu}>;tag={self.tag}",
                 f"To: <{self.impu}>",
                 f"Call-ID: {self.call_id}",
                 f"CSeq: {cseq} REGISTER",
                 f"Contact: <{self.contact}>;expires=600",
                 "Expires: 600", "Supported: path", "User-Agent: ims-call-test"]
            if auth:
                h.append(f"Authorization: {auth}")
            h += ["Content-Length: 0", "", ""]
            return "\r\n".join(h)
        self.s.sendto(build(1).encode(), PCSCF)
        r = self.recv_final()
        if status(r) not in (401, 407):
            print(f"[!] {self.imsi} unexpected: {r.splitlines()[0]}"); return False
        www = hdr(r, "WWW-Authenticate") or hdr(r, "Proxy-Authenticate")
        p = parse_auth(www)
        self.s.sendto(build(2, self.digest("REGISTER", reg_uri, p)).encode(), PCSCF)
        r2 = self.recv_final()
        ok = status(r2) == 200
        print(f"[{'OK' if ok else '!!'}] {self.imsi} REGISTER -> {r2.splitlines()[0]}")
        self.service_route = hdr(r2, "Service-Route")
        return ok

    def start_listen(self):
        self.listen = True
        threading.Thread(target=self._listen, daemon=True).start()

    def _listen(self):
        self.s.settimeout(1)
        while self.listen:
            try:
                data, addr = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            t = data.decode(errors="replace")
            first = t.splitlines()[0]
            if first.startswith("INVITE"):
                print(f"    [{self.imsi[-3:]}<] INVITE received (IMS routed the call here)")
                self.incoming.append(t)
                self._answer(t, addr)
            elif first.startswith("ACK"):
                pass
            elif first.startswith("BYE"):
                self._reply(t, addr, 200, "OK")

    def _reply(self, req, addr, code, reason, body=None, ctype=None):
        vias = [l for l in req.splitlines() if l.lower().startswith("via:")]
        lines = [f"SIP/2.0 {code} {reason}"] + vias
        for name in ("From", "To", "Call-ID", "CSeq"):
            v = hdr(req, name)
            if name == "To" and v and "tag=" not in v:
                v = v + f";tag={self.tag}"
            lines.append(f"{name}: {v}")
        lines.append(f"Contact: <{self.contact}>")
        b = body or ""
        if ctype:
            lines.append(f"Content-Type: {ctype}")
        lines.append(f"Content-Length: {len(b)}")
        lines.append("")
        lines.append(b)
        self.s.sendto("\r\n".join(lines).encode(), addr)

    def _answer(self, invite, addr):
        # naive SDP answer (audio PCMU + video H264)
        sdp = ("v=0\r\n"
               f"o=- 0 0 IN IP4 {self.ip}\r\n"
               "s=call\r\n"
               f"c=IN IP4 {self.ip}\r\n"
               "t=0 0\r\n"
               "m=audio 50002 RTP/AVP 0\r\n"
               "a=rtpmap:0 PCMU/8000\r\n"
               "m=video 50004 RTP/AVP 96\r\n"
               "a=rtpmap:96 H264/90000\r\n")
        self._reply(invite, addr, 100, "Trying")
        self._reply(invite, addr, 180, "Ringing")
        self._reply(invite, addr, 200, "OK", sdp, "application/sdp")

    def invite(self, target_imsi):
        target = f"sip:{target_imsi}@{REALM}"
        cid = uuid.uuid4().hex
        ftag = uuid.uuid4().hex[:10]
        sdp = ("v=0\r\n"
               f"o=- 0 0 IN IP4 {self.ip}\r\n"
               "s=call\r\n"
               f"c=IN IP4 {self.ip}\r\n"
               "t=0 0\r\n"
               "m=audio 50000 RTP/AVP 0\r\n"
               "a=rtpmap:0 PCMU/8000\r\n"
               "m=video 50006 RTP/AVP 96\r\n"
               "a=rtpmap:96 H264/90000\r\n")
        use_route = "--route" in sys.argv and getattr(self, "service_route", None)
        def build(cseq, auth=None):
            h = [f"INVITE {target} SIP/2.0",
                 f"Via: SIP/2.0/UDP {self.ip}:{self.port};branch=z9hG4bK{uuid.uuid4().hex};rport",
                 "Max-Forwards: 70",
                 f"From: <{self.impu}>;tag={ftag}",
                 f"To: <{target}>",
                 f"Call-ID: {cid}",
                 f"CSeq: {cseq} INVITE",
                 f"Contact: <{self.contact}>",
                 "Allow: INVITE, ACK, BYE, CANCEL, OPTIONS",
                 "Supported: replaces",
                 "User-Agent: ims-call-test",
                 "Content-Type: application/sdp"]
            if use_route:
                h.insert(2, f"Route: {self.service_route}")
            if auth:
                h.append(f"Authorization: {auth}")
            h += [f"Content-Length: {len(sdp)}", "", sdp]
            return "\r\n".join(h)
        print(f"[*] service_route learned at REGISTER: {getattr(self,'service_route',None)}")
        print(f"[*] {self.imsi} INVITE -> {target} ({'WITH Route=Service-Route' if use_route else 'naive, no Service-Route (mimics SipClient)'})")
        self.s.sendto(build(1).encode(), PCSCF)
        try:
            r = self.recv_final()
        except socket.timeout:
            print("[!] INVITE: no response (timeout)"); return False
        if status(r) in (401, 407):
            www = hdr(r, "WWW-Authenticate") or hdr(r, "Proxy-Authenticate")
            p = parse_auth(www)
            self.s.sendto(build(2, self.digest("INVITE", target, p)).encode(), PCSCF)
            r = self.recv_final()
        code = status(r)
        print(f"[<] INVITE final: {r.splitlines()[0]}")
        if 200 <= code < 300:
            body = r.split("\r\n\r\n", 1)[-1]
            anchored = RTPENGINE_IP in body
            print("[OK] Call answered through IMS." +
                  (f" Media anchored by rtpengine ({RTPENGINE_IP})." if anchored
                   else " (SDP not rewritten to rtpengine IP)"))
            for l in body.splitlines():
                if l.startswith("c=") or l.startswith("m="):
                    print("      " + l)
            return True
        return False

def main():
    a = UE("001012345678905", "000102030405060708090A0C0B0D0E0F")
    b = UE("001012345678906", "000102030405060708090A0C0B0D0E0F")
    if not a.register():
        return 1
    if not b.register():
        return 1
    b.start_listen()
    time.sleep(1)
    ok = a.invite(b.imsi)
    time.sleep(1)
    b.listen = False
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
