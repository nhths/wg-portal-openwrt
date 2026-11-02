#!/usr/bin/env python3
"""Drive the wg-portal API: log in, create a server interface and a peer and
print the peer's wg-quick configuration.

Only the standard library is used. The API is the one the web UI talks to:
POST /api/v0/auth/login, GET /api/v0/csrf, GET /api/v0/interface/prepare,
POST /api/v0/interface/new, GET /api/v0/peer/iface/<iface>/prepare,
POST /api/v0/peer/iface/<iface>/new and GET /api/v0/peer/config/<id>.
"""

import argparse
import base64
import http.cookiejar
import json
import sys
import urllib.error
import urllib.request


class Portal:
    def __init__(self, base, user, password):
        self.base = base.rstrip("/")
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar)
        )
        self.csrf = ""
        self.login(user, password)

    def request(self, method, path, payload=None, raw=False):
        url = f"{self.base}{path}"
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        if method != "GET" and self.csrf:
            headers["X-CSRF-Token"] = self.csrf
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=30) as resp:
                body = resp.read().decode()
        except urllib.error.HTTPError as exc:
            raise SystemExit(
                f"{method} {path} failed: HTTP {exc.code}: {exc.read().decode()[:400]}"
            )
        if raw:
            return body
        return json.loads(body) if body else None

    def login(self, user, password):
        self.request(
            "POST",
            "/api/v0/auth/login",
            {"username": user, "password": password},
        )
        self.csrf = self.request("GET", "/api/v0/csrf")
        if isinstance(self.csrf, str):
            self.csrf = self.csrf.strip('"')


def encode_id(identifier):
    """The API expects the id base64url encoded: '=' -> '-', '/' -> '_', '+' -> '.'."""
    raw = base64.b64encode(identifier.encode()).decode()
    return raw.replace("=", "-").replace("/", "_").replace("+", ".")


def option(value):
    """The peer model wraps its configurable values into an option object."""
    return {"Value": value, "Overridable": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:8888")
    parser.add_argument("--user", default="admin@wgportal.local")
    parser.add_argument("--password", default="wg-portal-check-password")
    parser.add_argument("--interface", default="wg0")
    parser.add_argument("--listen-port", type=int, default=51820)
    parser.add_argument("--address", default="10.99.0.1/24")
    parser.add_argument("--peer-address", default="10.99.0.2/32")
    parser.add_argument("--peer-allowed-ips", default="10.99.0.2/32")
    parser.add_argument(
        "--peer-endpoint",
        default="",
        help="the address the server uses to reach the peer; empty means the "
        "endpoint is learned from the handshake (the usual case for a client "
        "behind NAT)",
    )
    parser.add_argument("--peer-display-name", default="check-client")
    args = parser.parse_args()

    portal = Portal(args.base, args.user, args.password)

    # The interface may exist already (the guest keeps its database on the
    # flash), remove it so the check can be repeated.
    for existing in portal.request("GET", "/api/v0/interface/all") or []:
        if existing.get("Identifier") == args.interface:
            print(f"removing the existing interface {args.interface}", file=sys.stderr)
            portal.request("DELETE", f"/api/v0/interface/{encode_id(args.interface)}")

    iface = portal.request("GET", "/api/v0/interface/prepare")
    iface["Identifier"] = args.interface
    iface["DisplayName"] = "wireguard check"
    iface["Mode"] = "server"
    iface["ListenPort"] = args.listen_port
    iface["Addresses"] = [args.address]
    iface["Dns"] = []
    iface["DnsSearch"] = []
    iface["Disabled"] = False
    iface["SaveConfig"] = False
    iface["CreateDefaultPeer"] = False
    iface["PeerDefAllowedIPs"] = [args.peer_allowed_ips]
    iface["PeerDefEndpoint"] = args.peer_endpoint
    iface["PeerDefPersistentKeepalive"] = 25
    created_iface = portal.request("POST", "/api/v0/interface/new", iface)
    print(
        f"interface: {created_iface['Identifier']} ({created_iface['PublicKey']})",
        file=sys.stderr,
    )

    peer = portal.request("GET", f"/api/v0/peer/iface/{encode_id(args.interface)}/prepare")
    peer["DisplayName"] = args.peer_display_name
    peer["InterfaceIdentifier"] = args.interface
    peer["Endpoint"] = option(args.peer_endpoint)
    peer["AllowedIPs"] = option([args.peer_allowed_ips])
    peer["Addresses"] = [args.peer_address]
    peer["Dns"] = option([])
    peer["DnsSearch"] = option([])
    peer["Disabled"] = False
    peer["PersistentKeepalive"] = option(25)
    created_peer = portal.request(
        "POST", f"/api/v0/peer/iface/{encode_id(args.interface)}/new", peer
    )
    print(f"peer: {created_peer['Identifier']}", file=sys.stderr)

    config = portal.request(
        "GET", f"/api/v0/peer/config/{encode_id(created_peer['Identifier'])}"
    )
    print(config)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
