from __future__ import annotations

import argparse
import importlib.metadata
import ipaddress
import json
import socket
import site
import sys
import sysconfig
import unittest
from pathlib import Path
from unittest.mock import patch


def main() -> int:
    if not sys.flags.no_site:
        raise SystemExit("Use python -I -S run_offline.py to exclude global site packages")
    parser = argparse.ArgumentParser()
    parser.add_argument("--deps", type=Path, default=Path(__file__).parent / "deps")
    parser.add_argument("--pattern", default="test_*.py")
    args = parser.parse_args()
    root = Path(__file__).parent
    sys.dont_write_bytecode = True
    site.addsitedir(str(args.deps.absolute()))
    sys.path[:0] = [str(args.deps.absolute()), str(root / "app"), str(root / "tests")]
    required = {
        "microsoft-agents-hosting-core": "1.6.0",
        "microsoft-agents-hosting-aiohttp": "1.6.0",
        "microsoft-agents-authentication-msal": "1.6.0",
        "microsoft-agents-a365-notifications": "1.0.0",
        "microsoft-agents-a365-tooling": "1.0.0",
        "agent-framework-core": "1.17.0",
        "agent-framework-openai": "1.14.2",
        "microsoft-opentelemetry": "1.2.0",
        "openai": "3.8.0",
        "mcp": "1.29.1",
    }
    installed = {
        distribution.metadata["Name"].lower().replace("_", "-"): distribution.version
        for distribution in importlib.metadata.distributions(path=[str(args.deps)])
    }
    for name, version in required.items():
        if installed.get(name) != version:
            raise RuntimeError(f"Restore the isolated manifest: {name}=={version} is required")
    print(
        json.dumps(
            {"python": sys.version.split()[0], "platform": sysconfig.get_platform(), "sdk_matrix": required}
        ),
        flush=True,
    )
    connect = socket.socket.connect
    connect_ex = socket.socket.connect_ex
    getaddrinfo = socket.getaddrinfo
    blocked = []

    def reject(address):
        blocked.append(str(address))
        raise AssertionError(f"Offline fixture blocked external networking: {address}")

    def allowed(address) -> bool:
        if not isinstance(address, tuple):
            return False
        try:
            return ipaddress.ip_address(address[0]).is_loopback
        except ValueError:
            return address[0] == "localhost"

    def guarded_connect(sock, address):
        if not allowed(address):
            reject(address[0])
        return connect(sock, address)

    def guarded_connect_ex(sock, address):
        if not allowed(address):
            reject(address[0])
        return connect_ex(sock, address)

    def guarded_getaddrinfo(host, *positional, **keywords):
        if host is not None and not allowed((host, 0)):
            reject(host)
        return getaddrinfo(host, *positional, **keywords)

    with (
        patch.object(socket.socket, "connect", guarded_connect),
        patch.object(socket.socket, "connect_ex", guarded_connect_ex),
        patch.object(socket, "getaddrinfo", guarded_getaddrinfo),
    ):
        suite = unittest.defaultTestLoader.discover(str(root / "tests"), pattern=args.pattern)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    print("NETWORK_GUARD_BLOCKS=" + str(len(blocked)), flush=True)
    return 0 if result.wasSuccessful() and not blocked else 1


if __name__ == "__main__":
    raise SystemExit(main())
