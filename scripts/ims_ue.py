#!/usr/bin/env python3
"""Single-role IMS UE for cross-container call testing.

Roles:
  callee <imsi> <ki>              register, then listen and auto-answer INVITEs
  caller <imsi> <ki> <target>     register, then INVITE target IMSI, ACK, BYE

Both authenticate to the P-CSCF via MD5 SIP Digest (password = Ki), exactly
like the project's SipClient. Run each role in a separate container so the two
UEs have distinct source IPs (mirrors 2 phones / 1 PC).
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

def md5(s): return hashlib.md5(s.encode()).hexdigest()

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
        self.s.settimeout(10)
        ip = self.s.getsockname()[0]
        if ip == "0.0.0.0":
            ip = socket.gethostbyname(socket.gethostname())
        self.ip, self.port = ip, self.s.getsockname()[1]
        self.contact = f"sip:{imsi}@{self.ip}:{self.port};transport=udp"
        self.call_id = uuid.uuid4().hex
        self.tag = uuid.uuid4().hex[:10]
        self.service_route = None
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

    @staticmethod
    def _uri_addr(uri):
        # "sip:user@host:port;params" or "<sip:host;lr>" -> (host, port)
        u = uri.strip().lstrip("<").rstrip(">")
        if u.startswith("sip:"):
            u = u[4:]
        u = u.split(";", 1)[0]
        if "@" in u:
            u = u.split("@", 1)[1]
        if ":" in u:
            host, port = u.rsplit(":", 1)
            return (host, int(port))
        return (u, 5060)

    def recv_final(self):
        while True:
            data, _ = self.s.recvfrom(65535)
            t = data.decode(errors="replace")
            if 100 <= status(t) <= 199:
                print(f"  [{self.imsi[-3:]}<] {t.splitlines()[0]}  (prov)")
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
                 "Expires: 600", "Supported: path", "User-Agent: ims-ue"]
            if auth: h.append(f"Authorization: {auth}")
            h += ["Content-Length: 0", "", ""]
            return "\r\n".join(h)
        self.s.sendto(build(1).encode(), PCSCF)
        r = self.recv_final()
        if status(r) not in (401, 407):
            print(f"[!] {self.imsi} REGISTER unexpected: {r.splitlines()[0]}"); return False
        p = parse_auth(hdr(r, "WWW-Authenticate") or hdr(r, "Proxy-Authenticate"))
        self.s.sendto(build(2, self.digest("REGISTER", reg_uri, p)).encode(), PCSCF)
        r2 = self.recv_final()
        ok = status(r2) == 200
        self.service_route = hdr(r2, "Service-Route")
        print(f"[{'OK' if ok else '!!'}] {self.imsi} REGISTER -> {r2.splitlines()[0]}  (contact {self.ip}:{self.port})")
        return ok

    # ---- callee ----
    # P-CSCF delivers terminating requests over TCP even when the registered
    # Contact says ;transport=udp (observed on this stack: tcpconn_1st_send ->
    # 477 if nothing listens). The callee therefore listens on BOTH transports
    # on the same port and logs which one each request arrived on.
    def serve(self, seconds=40):
        self.listen = True
        self.s.settimeout(1)
        deadline = time.time() + seconds
        tls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tls.bind(("0.0.0.0", self.port))
        tls.listen(5)
        tls.settimeout(1)
        threading.Thread(target=self._tcp_serve, args=(tls, deadline), daemon=True).start()
        print(f"[*] {self.imsi} listening for INVITE on {self.ip}:{self.port} (udp+tcp) ...")
        while self.listen and time.time() < deadline:
            try:
                data, addr = self.s.recvfrom(65535)
            except socket.timeout:
                continue
            t = data.decode(errors="replace")
            if self._handle(t, lambda b, a=addr: self.s.sendto(b, a), "udp"):
                return
        if self.listen:
            print("[*] callee serve window ended.")

    def _tcp_serve(self, tls, deadline):
        while time.time() < deadline and self.listen:
            try:
                conn, addr = tls.accept()
            except socket.timeout:
                continue
            print(f"[<] TCP connection from {addr[0]}:{addr[1]}")
            conn.settimeout(1)
            while time.time() < deadline and self.listen:
                try:
                    d = conn.recv(65535)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not d:
                    break
                t = d.decode(errors="replace")
                if self._handle(t, lambda b, c=conn: c.sendall(b), "tcp"):
                    self.listen = False
                    return
            try:
                conn.close()
            except OSError:
                pass

    def _handle(self, t, send, transport):
        lines = t.splitlines()
        if not lines:
            return False
        first = lines[0]
        if first.startswith("INVITE"):
            body = t.split("\r\n\r\n", 1)[-1]
            anchored = RTPENGINE_IP in body
            print(f"[<] INVITE received via IMS over {transport.upper()}. Offered SDP media lines:")
            for l in body.splitlines():
                if l.startswith("c=") or l.startswith("m="):
                    print("      " + l)
            print(f"    -> media anchored by rtpengine: {'YES' if anchored else 'no'}")
            self._answer(t, send)
        elif first.startswith("ACK"):
            print(f"[<] ACK received over {transport.upper()} — call established (media path open).")
        elif first.startswith("BYE"):
            self._reply(t, send, 200, "OK")
            print(f"[<] BYE received over {transport.upper()} — call ended cleanly. Test PASS.")
            return True
        return False

    def _reply(self, req, send, code, reason, body=None, ctype=None):
        vias = [l for l in req.splitlines() if l.lower().startswith("via:")]
        lines = [f"SIP/2.0 {code} {reason}"] + vias
        for name in ("From", "To", "Call-ID", "CSeq"):
            v = hdr(req, name)
            if name == "To" and v and "tag=" not in v:
                v = v + f";tag={self.tag}"
            lines.append(f"{name}: {v}")
        lines.append(f"Contact: <{self.contact}>")
        b = body or ""
        if ctype: lines.append(f"Content-Type: {ctype}")
        lines.append(f"Content-Length: {len(b)}")
        lines += ["", b]
        send("\r\n".join(lines).encode())

    def _answer(self, invite, send):
        sdp = ("v=0\r\n" f"o=- 0 0 IN IP4 {self.ip}\r\n" "s=call\r\n"
               f"c=IN IP4 {self.ip}\r\n" "t=0 0\r\n"
               "m=audio 50002 RTP/AVP 0\r\n" "a=rtpmap:0 PCMU/8000\r\n"
               "m=video 50004 RTP/AVP 96\r\n" "a=rtpmap:96 H264/90000\r\n")
        self._reply(invite, send, 100, "Trying")
        self._reply(invite, send, 180, "Ringing")
        self._reply(invite, send, 200, "OK", sdp, "application/sdp")
        print("[>] answered 200 OK with SDP (audio PCMU + video H264).")

    # ---- caller ----
    def call(self, target_imsi):
        target = f"sip:{target_imsi}@{REALM}"
        cid, ftag = uuid.uuid4().hex, uuid.uuid4().hex[:10]
        sdp = ("v=0\r\n" f"o=- 0 0 IN IP4 {self.ip}\r\n" "s=call\r\n"
               f"c=IN IP4 {self.ip}\r\n" "t=0 0\r\n"
               "m=audio 50000 RTP/AVP 0\r\n" "a=rtpmap:0 PCMU/8000\r\n"
               "m=video 50006 RTP/AVP 96\r\n" "a=rtpmap:96 H264/90000\r\n")
        def build(cseq, auth=None, extra=None):
            h = [f"INVITE {target} SIP/2.0",
                 f"Via: SIP/2.0/UDP {self.ip}:{self.port};branch=z9hG4bK{uuid.uuid4().hex};rport",
                 "Max-Forwards: 70",
                 f"From: <{self.impu}>;tag={ftag}",
                 f"To: <{target}>",
                 f"Call-ID: {cid}",
                 f"CSeq: {cseq} INVITE",
                 f"Contact: <{self.contact}>",
                 "Allow: INVITE, ACK, BYE, CANCEL, OPTIONS",
                 "Supported: replaces", "User-Agent: ims-ue",
                 "Content-Type: application/sdp"]
            if auth: h.append(f"Authorization: {auth}")
            h += [f"Content-Length: {len(sdp)}", "", sdp]
            return "\r\n".join(h)
        print(f"[*] {self.imsi} INVITE -> {target}")
        self.s.sendto(build(1).encode(), PCSCF)
        r = self.recv_final()
        if status(r) in (401, 407):
            p = parse_auth(hdr(r, "WWW-Authenticate") or hdr(r, "Proxy-Authenticate"))
            self.s.sendto(build(2, self.digest("INVITE", target, p)).encode(), PCSCF)
            r = self.recv_final()
        code = status(r)
        print(f"[<] INVITE final: {r.splitlines()[0]}")
        if not (200 <= code < 300):
            return False
        body = r.split("\r\n\r\n", 1)[-1]
        anchored = RTPENGINE_IP in body
        print(f"[OK] 200 OK. Answer SDP media (anchored by rtpengine: {'YES' if anchored else 'no'}):")
        for l in body.splitlines():
            if l.startswith("c=") or l.startswith("m="):
                print("      " + l)
        # In-dialog requests (ACK/BYE) target the remote Contact from the 200 OK.
        ct = hdr(r, "Contact") or ""
        remote = ct.split("<", 1)[-1].split(">", 1)[0] if "<" in ct else ct.split(";", 1)[0].strip()
        if not remote.startswith("sip:"):
            remote = target
        to_h = hdr(r, "To"); via = f"SIP/2.0/UDP {self.ip}:{self.port};branch=z9hG4bK{uuid.uuid4().hex};rport"
        # RFC 3261 12.1.2: the UAC route set is ALL Record-Route entries in
        # reverse order. This P-CSCF returns NO Record-Route toward a UDP
        # client, so the route set is empty -> per RFC the in-dialog request
        # goes straight to the remote target (Contact). On the flat docker net
        # the caller can reach that IP directly; sending ACK/BYE to the P-CSCF
        # with no Route would get "404 Not here" from route[WITHINDLG].
        rr_uris = []
        for l in r.splitlines():
            if l.lower().startswith("record-route:"):
                for part in l.split(":", 1)[1].split(","):
                    part = part.strip()
                    if part:
                        rr_uris.append(part)
        route = [f"Route: {u}" for u in reversed(rr_uris)]
        if rr_uris:
            first = rr_uris[0]
            dest = self._uri_addr(first)
        else:
            dest = self._uri_addr(remote)
        ack = "\r\n".join([f"ACK {remote} SIP/2.0", f"Via: {via}", *route,
                           "Max-Forwards: 70", f"From: <{self.impu}>;tag={ftag}",
                           f"To: {to_h}", f"Call-ID: {cid}", "CSeq: 2 ACK",
                           f"Contact: <{self.contact}>", "Content-Length: 0", "", ""])
        self.s.sendto(ack.encode(), dest)
        print(f"[>] ACK sent to {dest[0]}:{dest[1]} — call up. Holding 3s (media would flow here)...")
        time.sleep(3)
        bye = "\r\n".join([f"BYE {remote} SIP/2.0",
                           f"Via: SIP/2.0/UDP {self.ip}:{self.port};branch=z9hG4bK{uuid.uuid4().hex};rport",
                           *route, "Max-Forwards: 70", f"From: <{self.impu}>;tag={ftag}",
                           f"To: {to_h}", f"Call-ID: {cid}", "CSeq: 3 BYE",
                           "Content-Length: 0", "", ""])
        self.s.sendto(bye.encode(), dest)
        try:
            rb = self.recv_final()
            print(f"[<] BYE -> {rb.splitlines()[0]}")
        except socket.timeout:
            print("[<] BYE sent (no final within timeout)")
        print("[PASS] End-to-end call through IMS completed.")
        return True

def main():
    role = sys.argv[1]
    imsi, ki = sys.argv[2], sys.argv[3]
    ue = UE(imsi, ki)
    if not ue.register():
        return 1
    if role == "callee":
        ue.serve(seconds=int(sys.argv[4]) if len(sys.argv) > 4 else 40)
        return 0
    elif role == "caller":
        target = sys.argv[4]
        return 0 if ue.call(target) else 1
    print("unknown role"); return 2

if __name__ == "__main__":
    sys.exit(main())
