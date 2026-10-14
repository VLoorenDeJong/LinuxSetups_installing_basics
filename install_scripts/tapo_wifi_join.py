"""Move Tapo plugs to another Wi-Fi network without a reset.

    python3 tapo_wifi_join.py <ssid> <plug-ip> [<plug-ip> ...]

Needs python-kasa, so run it inside the Home Assistant container:
    docker cp tapo_wifi_join.py homeassistant:/tmp/
    docker exec -it homeassistant python3 /tmp/tapo_wifi_join.py <ssid> <ip> ...

Before running:
  - This machine must reach the plugs (a guest Wi-Fi needs local access on for it).
  - Disable each plug's TP-Link entry in Home Assistant: a plug being polled
    refuses the move with a 403.
  - Tapo app, Third-Party Compatibility on: off, the plugs only speak TPAP,
    which python-kasa cannot.

Plugs are moved in the order given. Nothing is stored; every secret is typed
at a hidden prompt. A plug that cannot join returns to its old network.
"""
import asyncio
import getpass
import logging
import sys

from kasa import Credentials, Discover

# kasa's error log prints the request, and the request carries the logins.
logging.disable(logging.CRITICAL)


def ask_twice(label: str) -> str:
    while True:
        first = getpass.getpass(f"{label}: ")
        if first and first == getpass.getpass(f"{label} again: "):
            return first
        print("Empty or not the same, try again.")


async def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ssid, hosts = sys.argv[1], sys.argv[2:]

    email = input("Tapo account e-mail: ").strip()
    creds = Credentials(email, getpass.getpass("Tapo account password: "))

    plugs = []
    for host in hosts:
        try:
            plug = await Discover.discover_single(host, credentials=creds)
            await plug.update()
        except Exception as exc:
            print(f"  {host}: skipped, {type(exc).__name__}")
            continue
        print(f"  {host}: {plug.alias} ({plug.model}, {plug.mac})")
        plugs.append(plug)
    if not plugs:
        return 1
    if input(f"\nMove these {len(plugs)} to '{ssid}', in this order? y/N: ").strip().lower() != "y":
        for plug in plugs:
            await plug.disconnect()
        return 1

    wifi_pw = ask_twice(f"Password of '{ssid}'")
    for plug in plugs:
        try:
            await plug.wifi_join(ssid, wifi_pw)
        except Exception as exc:  # the plug drops the connection as it switches
            print(f"  {plug.alias}: went away while switching ({type(exc).__name__})")
        try:
            await plug.disconnect()
        except Exception:
            pass
        print(f"  {plug.alias}: sent")
    print("Done. A plug that cannot join returns to its old network by itself.")
    return 0


sys.exit(asyncio.run(main()))
