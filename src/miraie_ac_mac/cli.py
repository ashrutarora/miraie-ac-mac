"""The `ac` command.

    ac                      show status
    ac on | off | toggle
    ac 24                   set temperature (16-30)
    ac up | down            one degree warmer or cooler
    ac cool | dry | heat    mode (also: ac mode auto, ac mode fan)
    ac fan auto|low|medium|high|quiet
    ac eco | boost | clean | normal
    ac swing auto|1|2|3|4|5 vertical louvre
    ac display on|off       the light on the indoor unit
    ac on 24 cool fan high  several at once, sent in order
    ac sleep                bedtime: on, cool, low fan, Converti8 50%, swing auto

    ac list                 your ACs
    ac use "Bedroom"        make one the default
    ac --ac Bedroom off     act on a specific AC
    ac login | logout
    ac autostart on|off     start the menu-bar app when you log in
"""

import argparse
import asyncio
import getpass
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

import aiohttp
from miraie_ac import DisplayMode, FanMode, HVACMode, PowerMode, PresetMode, SwingMode

from . import core

MODES = {"cool": HVACMode.COOL, "dry": HVACMode.DRY, "heat": HVACMode.HEAT}
PRESETS = {
    "eco": PresetMode.ECO,
    "boost": PresetMode.BOOST,
    "clean": PresetMode.CLEAN,
    "normal": PresetMode.NONE,
}
SWINGS = {"auto": SwingMode.AUTO, **{str(i): SwingMode(i) for i in range(1, 6)}}


def usage_error(message: str):
    raise SystemExit(f"{message}\n\nRun `ac help` for the list of commands.")


def parse_actions(words: list[str], device) -> list:
    """Turns words like `on 24 cool fan high` into actions. Needs the device
    for `toggle`, `up` and `down`, which depend on its current state."""
    actions = []
    words = [w.lower() for w in words]
    target = device.status.temperature or 24
    i = 0

    def take_value(choices: dict):
        nonlocal i
        keyword = words[i]
        i += 1
        if i >= len(words) or words[i] not in choices:
            usage_error(f"`{keyword}` needs one of: {', '.join(choices)}")
        return choices[words[i]]

    while i < len(words):
        word = words[i]
        if word == "sleep":
            actions += core.sleep_setting()
        elif word in ("on", "off"):
            actions.append(core.power(word == "on"))
        elif word == "toggle":
            actions.append(core.power(device.status.power_mode == PowerMode.OFF))
        elif word in ("up", "down"):
            target = core.clamp_temp(target + (1 if word == "up" else -1))
            actions.append(core.temperature(target))
        elif word.replace(".", "", 1).isdigit():
            target = float(word)
            if not core.MIN_TEMP <= target <= core.MAX_TEMP:
                usage_error(f"Temperature must be {core.MIN_TEMP}-{core.MAX_TEMP}.")
            actions.append(core.temperature(target))
        elif word in MODES:
            actions.append(core.mode(MODES[word]))
        elif word == "mode":
            actions.append(core.mode(take_value({m.value: m for m in HVACMode})))
        elif word == "fan":
            actions.append(core.fan(take_value({f.value: f for f in FanMode})))
        elif word in PRESETS:
            actions.append(core.preset(PRESETS[word]))
        elif word == "swing":
            actions.append(core.swing(take_value(SWINGS)))
        elif word == "display":
            actions.append(core.display(take_value({d.value: d for d in DisplayMode})))
        else:
            usage_error(f"Don't know `{word}`.")
        i += 1
    return actions


async def login() -> None:
    print("Sign in with the phone number and password you use in the MirAIe app.")
    phone = input("Phone (e.g. +919876543210): ").strip().replace(" ", "")
    if not phone.startswith("+"):
        phone = "+91" + phone.lstrip("0")
    password = getpass.getpass("Password (hidden): ")
    async with core.open_hub(phone, password, live=False) as hub:
        core.store_credentials(phone, password)
        print("Signed in. Password saved in your Keychain.")
        for device in hub.home.devices:
            print("  " + core.describe(device))


AGENT_LABEL = "com.ashrutarora.miraie-ac"
AGENT_PATH = Path.home() / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"


def autostart(enable: bool) -> None:
    """Adds or removes a LaunchAgent that starts `ac-menubar` at login."""
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{AGENT_LABEL}"], capture_output=True)
    if not enable:
        AGENT_PATH.unlink(missing_ok=True)
        print("The menu-bar app no longer starts at login (and is stopped now).")
        return
    # Prefer the SwiftUI panel (mac/build.sh); fall back to the simple Python menu.
    panel = Path.home() / "Applications" / "MirAIe AC.app" / "Contents" / "MacOS" / "MirAIeAC"
    program = str(panel) if panel.exists() else shutil.which("ac-menubar")
    if not program:
        raise SystemExit("Can't find the menu-bar app. Build it with mac/build.sh.")
    AGENT_PATH.parent.mkdir(parents=True, exist_ok=True)
    AGENT_PATH.write_bytes(plistlib.dumps({
        "Label": AGENT_LABEL,
        "ProgramArguments": [program],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Interactive",
    }))
    # bootout finishes in the background; bootstrap fails until it has.
    for _ in range(10):
        if subprocess.run(["launchctl", "bootstrap", domain, str(AGENT_PATH)], capture_output=True).returncode == 0:
            break
        time.sleep(0.5)
    else:
        raise SystemExit("launchctl wouldn't start the menu-bar app. Try `ac autostart on` again.")
    print("The menu-bar app is running and will start every time you log in.")


async def run(args) -> None:
    command = args.words[0].lower() if args.words else "status"

    if command == "help":
        print(__doc__)
        return
    if command == "login":
        await login()
        return
    if command == "autostart":
        if len(args.words) < 2 or args.words[1] not in ("on", "off"):
            usage_error("Say: ac autostart on   or   ac autostart off")
        autostart(args.words[1] == "on")
        return
    if command == "logout":
        core.forget_credentials()
        print("Signed out; password removed from the Keychain.")
        return

    phone, password = core.credentials()

    if command in ("status", "list", "use"):
        async with core.open_hub(phone, password, live=False) as hub:
            if command == "list":
                default = core.pick_device(hub, None)
                for device in hub.home.devices:
                    mark = "*" if device is default else " "
                    print(f"{mark} {core.describe(device)}")
            elif command == "use":
                if len(args.words) < 2:
                    usage_error('Say which AC: ac use "Bedroom"')
                device = core.pick_device(hub, " ".join(args.words[1:]))
                config = core.load_config()
                config["default_ac"] = device.friendly_name
                core.save_config(config)
                print(f"Default AC is now {device.friendly_name}.")
            else:
                print(core.describe(core.pick_device(hub, args.ac)))
        return

    async with core.open_hub(phone, password, live=True) as hub:
        device = core.pick_device(hub, args.ac)
        if not device.status.is_online:
            raise SystemExit(core.describe(device))
        actions = parse_actions(args.words, device)
        confirmed = await core.send_and_confirm(device, actions)
        if confirmed:
            print(core.describe(device))
        else:
            print("Sent, but the AC didn't confirm. Check it with: ac status")


def main() -> None:
    parser = argparse.ArgumentParser(prog="ac", add_help=False)
    parser.add_argument("--ac", help="which AC, by name")
    parser.add_argument("-h", "--help", action="store_true")
    parser.add_argument("words", nargs="*")
    args = parser.parse_args()
    if args.help:
        args.words = ["help"]
    try:
        asyncio.run(run(args))
    except core.NotLoggedIn as error:
        sys.exit(str(error))
    except (aiohttp.ClientError, TimeoutError):
        sys.exit("Can't reach MirAIe's servers. Check your internet and try again.")
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
