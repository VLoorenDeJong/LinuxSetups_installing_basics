"""Makes Uptime Kuma's monitors named "<prefix> ..." match a desired list.

    python monitor_uptimekuma.py sync <kuma-url> <prefix>   < stdin

stdin: Kuma's session token, then one `name<TAB>url<TAB>host_header<TAB>answers`
per line. A monitor that does not exist yet is added only when answers is 1.
A host header means "probe this IP as that hostname": TLS errors are ignored,
because the certificate names the hostname, not the IP.
Monitors whose name lacks the prefix are never touched.
"""
from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass

from uptime_kuma_api import MonitorType, UptimeKumaApi


@dataclass(frozen=True)
class Wanted:
    name: str
    url: str
    host: str
    answers: bool

    def fields(self) -> dict:
        return {
            "url": self.url,
            "headers": json.dumps({"Host": self.host}) if self.host else None,
            "ignoreTls": bool(self.host),
            # 4xx is the login gate answering: the proxy is up. 5xx is not.
            "accepted_statuscodes": ["200-299", "300-399", "400-499"],
            "maxredirects": 0,
        }


def read_input() -> tuple[str, list[Wanted]]:
    lines = sys.stdin.read().splitlines()
    token, rows = lines[0], lines[1:]
    wanted = []
    for row in rows:
        if not row.strip():
            continue
        name, url, host, answers = (row.split("\t") + ["", "", ""])[:4]
        wanted.append(Wanted(name, url, host, answers == "1"))
    return token, wanted


def differs(current: dict, want: dict) -> bool:
    for key, value in want.items():
        have = current.get(key)
        if key == "headers":
            have = have or None
        if have != value:
            return True
    return False


def connect(url: str, token: str) -> UptimeKumaApi:
    """Kuma answers HTTP before its socket takes commands, so the first try may time out."""
    for attempt in range(1, 4):
        api = None
        try:
            api = UptimeKumaApi(url, timeout=30)
            api.login_by_token(token)
            return api
        except Exception:
            if api is not None:
                api.disconnect()
            if attempt == 3:
                raise
            time.sleep(10)
    raise AssertionError("unreachable")


def sync(url: str, prefix: str) -> int:
    token, wanted = read_input()
    if not prefix.strip():
        print("Refusing an empty prefix: it would claim every monitor.", file=sys.stderr)
        return 2
    added = updated = deleted = same = waiting = 0
    with connect(url, token) as api:
        ours = {m["name"]: m for m in api.get_monitors() if m["name"].startswith(prefix + " ")}
        for w in wanted:
            fields = w.fields()
            if w.name not in ours and not w.answers:
                print(f"waiting  {w.name}: does not answer yet, added once it does")
                waiting += 1
            elif w.name not in ours:
                api.add_monitor(type=MonitorType.HTTP, name=w.name, interval=60, **fields)
                print(f"added    {w.name}")
                added += 1
            elif differs(ours[w.name], fields):
                api.edit_monitor(ours[w.name]["id"], **fields)
                print(f"updated  {w.name}")
                updated += 1
            else:
                same += 1
        keep = {w.name for w in wanted}
        for name, mon in ours.items():
            if name not in keep:
                api.delete_monitor(mon["id"])
                print(f"deleted  {name}")
                deleted += 1
    print(f"summary  {added} added, {updated} updated, {deleted} deleted, {same} unchanged, {waiting} waiting")
    return 0


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] != "sync":
        print(__doc__, file=sys.stderr)
        return 2
    return sync(sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    sys.exit(main())
