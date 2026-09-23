#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate custom.txt for a RustDesk custom client.

custom.txt is a base64-encoded JSON that the RustDesk client (>= 1.4.x)
reads at startup from a fixed location next to the executable:
  - Windows / Linux / Android: same directory as the exe / in assets/
  - macOS: inside the .app bundle Resources

Content keys are documented in upstream src/common.rs::read_custom_client():
  - "app-name"          : display name in About / window title (keeps is_custom_client=true)
  - "default-settings"  : applied only on first run
  - "override-settings" : override any user settings every startup
  - all other keys fall into HARD_SETTINGS (cannot be changed by user)

Supported hard/override keys used by this kit (all verified in 1.4.9 source):
  custom-rendezvous-server / relay-server / key / hide-network-settings /
  hide-security-settings / hide-server-settings / hide-proxy-settings /
  hide-websocket-settings / hide-remote-printer-settings

Run:  python3 tools/gen_custom_txt.py --config config.json --out custom.txt
"""
import argparse
import base64
import json
import sys

HIDE_MAP = {
    "network": "hide-network-settings",
    "security": "hide-security-settings",
    "server": "hide-server-settings",
    "proxy": "hide-proxy-settings",
    "websocket": "hide-websocket-settings",
    "remotePrinter": "hide-remote-printer-settings",
}


def build_custom_json(cfg: dict) -> dict:
    srv = cfg.get("server", {}) or {}
    host = (srv.get("host") or "").strip()
    if not host:
        raise SystemExit("config.json: 缺少 server.host")
    rport = srv.get("rendezvousPort") or 21116
    lport = srv.get("relayPort") or 21117
    key = (srv.get("key") or "").strip()
    if not key:
        raise SystemExit("config.json: 缺少 server.key")

    override = {
        "custom-rendezvous-server": "{0}:{1}".format(host, rport),
        "relay-server": "{0}:{1}".format(host, lport),
        "key": key,
    }
    hide = cfg.get("hide", {}) or {}
    for k, opt in HIDE_MAP.items():
        if hide.get(k):
            override[opt] = "Y"

    out = {
        "app-name": cfg.get("appName") or "RustDesk",
        "override-settings": override,
    }
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True, help="path to config.json")
    ap.add_argument("--out", required=True, help="output custom.txt path")
    args = ap.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    payload = json.dumps(build_custom_json(cfg), ensure_ascii=False, separators=(",", ":"))
    b64 = base64.b64encode(payload.encode("utf-8")).decode("ascii")
    with open(args.out, "w", encoding="ascii") as f:
        f.write(b64)
    print("custom.txt written: {0} bytes ({1} json bytes)".format(len(b64), len(payload)))
    print("payload: {0}".format(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
