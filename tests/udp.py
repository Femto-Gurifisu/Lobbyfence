"""UDP echo server / probe client for the namespace test.

  udp.py serve <port>                 echo every datagram back
  udp.py probe <port> <ip> [<ip>...]  print "<ip> ok|blocked" per server
"""
import socket
import sys

if sys.argv[1] == "serve6":
    # IPv6 echo server (replies come from the address that was asked)
    s6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s6.setsockopt(socket.IPPROTO_IPV6, getattr(socket, "IPV6_RECVPKTINFO", 49), 1)
    s6.bind(("::", int(sys.argv[2])))
    while True:
        data, anc, _, addr = s6.recvmsg(2048, socket.CMSG_SPACE(20))
        out = [(lvl, getattr(socket, "IPV6_PKTINFO", 50), d) for lvl, typ, d in anc if lvl == socket.IPPROTO_IPV6]
        s6.sendmsg([data], out, 0, addr)
elif sys.argv[1] == "serve":
    s4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s4.bind(("0.0.0.0", int(sys.argv[2])))
    while True:
        data, addr = s4.recvfrom(2048)
        s4.sendto(data, addr)
elif sys.argv[1] == "serve_from":
    # like serve, but replies come from the address the packet was sent to
    # (a real game server answers from its own address)
    import struct
    IP_PKTINFO = getattr(socket, "IP_PKTINFO", 8)
    s4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s4.setsockopt(socket.SOL_IP, IP_PKTINFO, 1)
    s4.bind(("0.0.0.0", int(sys.argv[2])))
    while True:
        data, anc, _, addr = s4.recvmsg(2048, socket.CMSG_SPACE(12))
        dst = None
        for lvl, typ, cdata in anc:
            if lvl == socket.SOL_IP and typ == IP_PKTINFO:
                dst = cdata[4:8]
        pkt = [(socket.SOL_IP, IP_PKTINFO, struct.pack("i4s4s", 0, dst, b"\0" * 4))] if dst else []
        s4.sendmsg([data], pkt, 0, addr)
elif sys.argv[1] == "tcpserve":
    # udp.py tcpserve <port>: accept connections, answer "hi" (like a game lobby on HTTPS)
    import threading
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", int(sys.argv[2])))
    srv.listen(64)
    def one(c):
        try:
            c.sendall(b"hi")
        finally:
            c.close()
    while True:
        c, _ = srv.accept()
        threading.Thread(target=one, args=(c,), daemon=True).start()
elif sys.argv[1] == "tcpprobe":
    # udp.py tcpprobe <port> <ip>...: "<ip> ok|blocked" - connect and get the answer
    port = int(sys.argv[2])
    for ip in sys.argv[3:]:
        ok = False
        try:
            c = socket.create_connection((ip, port), timeout=1.5)
            c.settimeout(1.5)
            ok = c.recv(8) == b"hi"
            c.close()
        except OSError:
            pass
        print(ip, "ok" if ok else "blocked")
elif sys.argv[1] == "rtt":
    # udp.py rtt <port> <ip> <count>: median round trip in ms ("lost" if none came back)
    import time
    port, ip, n = int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 3074))
    s.settimeout(1.5)
    rtts = []
    for i in range(n):
        t = time.time()
        s.sendto(b"rtt%d" % i, (ip, port))
        try:
            while True:
                d, _ = s.recvfrom(64)
                if d == b"rtt%d" % i:
                    rtts.append((time.time() - t) * 1000)
                    break
        except OSError:
            pass
    rtts.sort()
    print("%d" % rtts[len(rtts) // 2] if rtts else "lost")
elif sys.argv[1] == "stream":
    # udp.py stream <port> <ip> <packets per second> <seconds>
    import time
    port, ip, pps, secs = int(sys.argv[2]), sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 3074))
    end = time.time() + secs
    while time.time() < end:
        s.sendto(b"game", (ip, port))
        time.sleep(1.0 / pps)
else:
    port = int(sys.argv[2])
    for ip in sys.argv[3:]:
        v6 = ":" in ip
        s = socket.socket(socket.AF_INET6 if v6 else socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("::" if v6 else "0.0.0.0", 3074))      # the "game" uses local port 3074 too
        s.settimeout(0.7)
        ok = False
        for _ in range(2):
            try:
                s.sendto(b"ping", (ip, port))
                s.recvfrom(64)
                ok = True
                break
            except OSError:
                pass
        s.close()
        print(ip, "ok" if ok else "blocked")
