#!/usr/bin/env python3
"""Host(Windows LAN IP) -> WSL VM UDP relay.

IMS now runs on WSL native docker; ports are published on the WSL VM eth0
(e.g. 172.17.204.81), NOT on the Windows LAN IP (10.129.164.17) that the
SIP clients / phones must reach. This relay bridges that gap for UDP:

  10.129.164.17:5060/udp          -> 172.17.204.81:5060   (SIP signalling)
  10.129.164.17:49000-49100/udp   -> 172.17.204.81:49xxx  (rtpengine RTP)

Each listen port keeps a small NAT table {client_addr: last_seen} and a
single upstream socket, echoing return traffic back to the last client that
used the port (symmetric UDP, preserves rport semantics for SIP and the
per-port RTP pinning rtpengine relies on).

Run (after freeing 5060 from VMware NAT):
  python scripts/udp_relay_host_to_wsl.py --host 10.129.164.17 --wsl 172.17.204.81

Ctrl-C to stop.
"""
import argparse
import selectors
import socket
import sys
import threading
import time

RTP_LO = 49000
RTP_HI = 49100
SIP_PORT = 5060


class PortRelay:
    """One listen socket on host:(port) <-> one upstream socket to wsl:(port)."""

    def __init__(self, host_ip, wsl_ip, port, sel):
        self.port = port
        self.wsl = (wsl_ip, port)
        self.sel = sel
        # facing the client (host LAN IP)
        self.lsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.lsock.bind((host_ip, port))
        self.lsock.setblocking(False)
        # facing WSL (ephemeral source port); return pkts come back here
        self.usock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.usock.setblocking(False)
        self.last_client = None  # (ip, port) of most recent downstream sender
        self.last_seen = 0.0
        sel.register(self.lsock, selectors.EVENT_READ, self._on_client)
        sel.register(self.usock, selectors.EVENT_READ, self._on_upstream)

    def _on_client(self, _):
        try:
            data, addr = self.lsock.recvfrom(65535)
        except (BlockingIOError, ConnectionResetError):
            return
        self.last_client = addr
        self.last_seen = time.time()
        try:
            self.usock.sendto(data, self.wsl)
        except OSError:
            pass

    def _on_upstream(self, _):
        try:
            data, _addr = self.usock.recvfrom(65535)
        except (BlockingIOError, ConnectionResetError):
            return
        if self.last_client is None:
            return
        try:
            self.lsock.sendto(data, self.last_client)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="Windows LAN IP to listen on")
    ap.add_argument("--wsl", required=True, help="WSL VM eth0 IP to forward to")
    ap.add_argument("--rtp-lo", type=int, default=RTP_LO)
    ap.add_argument("--rtp-hi", type=int, default=RTP_HI)
    args = ap.parse_args()

    sel = selectors.DefaultSelector()
    ports = [SIP_PORT] + list(range(args.rtp_lo, args.rtp_hi + 1))
    relays = []
    failed = []
    for p in ports:
        try:
            relays.append(PortRelay(args.host, args.wsl, p, sel))
        except OSError as e:
            failed.append((p, str(e)))

    print(f"[relay] host={args.host} -> wsl={args.wsl}")
    print(f"[relay] bound {len(relays)}/{len(ports)} ports "
          f"(SIP 5060 + RTP {args.rtp_lo}-{args.rtp_hi})")
    if failed:
        head = ", ".join(f"{p}" for p, _ in failed[:6])
        print(f"[relay] WARN {len(failed)} ports failed to bind: {head}"
              f"{' ...' if len(failed) > 6 else ''}")
        if any(p == SIP_PORT for p, _ in failed):
            print("[relay] FATAL: could not bind 5060 (VMware NAT / other "
                  "process still holds it). Free it and retry.")
            sys.exit(1)
    sys.stdout.flush()

    try:
        while True:
            for key, mask in sel.select(timeout=1.0):
                key.data(key.fileobj)
    except KeyboardInterrupt:
        print("\n[relay] stopped")


if __name__ == "__main__":
    main()
