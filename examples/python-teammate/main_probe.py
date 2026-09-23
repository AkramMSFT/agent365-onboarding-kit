from __future__ import annotations

import _thread
import ipaddress
import os
import runpy
import site
import socket
import sys
import threading
from pathlib import Path

root = Path(__file__).parent
sys.dont_write_bytecode = True
site.addsitedir(sys.argv[1])
sys.path[:0] = [sys.argv[1], str(root / "app")]
assert sys.flags.no_site
connect = socket.socket.connect
getaddrinfo = socket.getaddrinfo
blocked = []


def check(host):
    try:
        allowed = ipaddress.ip_address(host).is_loopback
    except ValueError:
        allowed = host == "localhost"
    if not allowed:
        blocked.append(str(host))
        raise AssertionError("Main-entry fixture blocked external network activity")


def guarded_connect(sock, address):
    check(address[0])
    return connect(sock, address)


def guarded_getaddrinfo(host, *args, **kwargs):
    check(host)
    return getaddrinfo(host, *args, **kwargs)


socket.socket.connect = guarded_connect
socket.getaddrinfo = guarded_getaddrinfo


def stop_on_input():
    if sys.stdin.readline().strip() != "stop":
        return
    _thread.interrupt_main()
    try:
        with socket.create_connection(("127.0.0.1", int(os.environ["PORT"])), timeout=2) as stream:
            stream.sendall(b"GET /api/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    except OSError:
        pass


threading.Thread(target=stop_on_input, daemon=True).start()
runpy.run_path(str(root / "app" / "host_agent_server.py"), run_name="__main__")

from observability_tokens import TOKEN_STORE

assert TOKEN_STORE._loop is None and not TOKEN_STORE._pending and not TOKEN_STORE._tasks
assert not blocked
print("MAIN_ENTRYPOINT_CLEANUP_OK; NETWORK_GUARD_BLOCKS=0", flush=True)
