"""Talks to Panasonic's MirAIe cloud: sign-in, AC status, and sending commands.

Your MirAIe password lives in the macOS Keychain; the phone number and the
default AC sit in ~/.config/miraie-ac/config.json (nothing secret there).
"""

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path

import aiohttp
import keyring
import keyring.errors
import miraie_ac.device
import miraie_ac.hub
from miraie_ac.utils import parse_room_temp
from miraie_ac import (
    ConvertiMode,
    Device,
    FanMode,
    HVACMode,
    MirAIeBroker,
    MirAIeHub,
    PowerMode,
    PresetMode,
    SwingMode,
    DisplayMode,
)

KEYCHAIN_SERVICE = "miraie-ac"
CONFIG_PATH = Path.home() / ".config" / "miraie-ac" / "config.json"
MIN_TEMP, MAX_TEMP = 16, 30

# The library logs every reconnect at ERROR; keep the terminal quiet unless asked.
logging.getLogger("custom_components.miraie_in").setLevel(logging.CRITICAL)


def room_temp(value: str, firmware_version: str = "") -> float | None:
    """Room temperature from the AC's `rmtmp` field.

    It comes in two formats: a plain reading ("23.12") or, on newer firmware,
    "<fraction byte>.<whole degrees>" ("62.22" = 22.24°). The library assumes
    every 3.02+ reading is packed and garbles plain ones. Many strings fit both
    ("23.12": 23.12° or 12.09°), so readings outside 15-40° are dropped as
    impossible for a room, and if both survive the plain one wins."""
    if not value:
        return None
    candidates = []
    try:
        candidates.append(float(value))
    except ValueError:
        pass
    head, _, tail = value.partition(".")
    if head.isdigit() and tail.isdigit() and int(head) <= 255 and int(tail) > 0:
        candidates.append(round(int(tail) + int(head) / 256, 2))
    plausible = [t for t in candidates if 15 <= t <= 40]
    return plausible[0] if plausible else None


# The library calls its own parser from both modules; point them at ours.
miraie_ac.hub.parse_room_temp = room_temp
miraie_ac.device.parse_room_temp = room_temp


class NotLoggedIn(Exception):
    pass


def load_config() -> dict:
    try:
        return json.loads(CONFIG_PATH.read_text())
    except FileNotFoundError:
        return {}


def save_config(config: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(config, indent=2) + "\n")


def credentials() -> tuple[str, str]:
    phone = load_config().get("phone")
    password = keyring.get_password(KEYCHAIN_SERVICE, phone) if phone else None
    if not phone or not password:
        raise NotLoggedIn("Not signed in. Run: ac login")
    return phone, password


def store_credentials(phone: str, password: str) -> None:
    keyring.set_password(KEYCHAIN_SERVICE, phone, password)
    config = load_config()
    config["phone"] = phone
    save_config(config)


def forget_credentials() -> None:
    config = load_config()
    phone = config.pop("phone", None)
    if phone:
        try:
            keyring.delete_password(KEYCHAIN_SERVICE, phone)
        except keyring.errors.PasswordDeleteError:
            pass
    save_config(config)


class Broker(MirAIeBroker):
    """The library marks itself connected before it has subscribed to the AC's
    status topics, so a command sent straight away could miss the AC's reply.
    This adds an event that fires once the subscriptions are in place."""

    def __init__(self) -> None:
        super().__init__()
        self.subscribed = asyncio.Event()

    async def on_connect(self):
        self.subscribed.clear()
        await super().on_connect()
        self.subscribed.set()


@asynccontextmanager
async def open_hub(phone: str, password: str, live: bool):
    """Signs in and loads every AC with its current status. With live=True it
    also opens the MQTT connection, which commands and live updates need."""
    async with aiohttp.ClientSession() as session:
        hub = MirAIeHub(session)
        broker = Broker()
        hub._broker = broker
        try:
            await hub._authenticate(phone, password)
        except aiohttp.ClientError:
            raise
        except Exception:
            raise NotLoggedIn("MirAIe refused the phone number or password. Run: ac login")
        await hub._get_home_details()
        await hub.get_all_device_status()
        try:
            if live:
                await hub._init_broker(broker)
                await asyncio.wait_for(broker.subscribed.wait(), timeout=15)
            yield hub
        finally:
            await hub.close()


def pick_device(hub: MirAIeHub, name: str | None) -> Device:
    devices = hub.home.devices
    if not devices:
        raise SystemExit("No ACs found on this MirAIe account.")
    wanted = name or load_config().get("default_ac")
    if not wanted:
        return devices[0]
    for device in devices:
        if wanted.lower() in (device.name, device.friendly_name.lower(), device.id):
            return device
    names = ", ".join(d.friendly_name for d in devices)
    raise SystemExit(f'No AC called "{wanted}". Yours: {names}')


def describe(device: Device) -> str:
    s = device.status
    if not s.is_online:
        return f"{device.friendly_name}: offline (AC unplugged or off Wi-Fi)"
    room = f"room {s.room_temperature:g}°" if s.room_temperature else "room ?"
    if s.power_mode == PowerMode.OFF:
        return f"{device.friendly_name}: OFF · {room}"
    parts = [
        f"{device.friendly_name}: ON",
        s.hvac_mode.value,
        f"set {s.temperature:g}°",
        room,
        f"fan {s.fan_mode.value}",
    ]
    if s.preset_mode != PresetMode.NONE:
        parts.append(s.preset_mode.value)
    return " · ".join(parts)


async def send_and_confirm(device: Device, actions: list, timeout: float = 8.0) -> bool:
    """Sends each action, then waits for the AC to report its new state.
    Returns False when the AC never answered (it is probably offline)."""
    updated = asyncio.Event()

    def on_update():
        updated.set()

    device.register_callback(on_update)
    try:
        for action in actions:
            await action(device)
            await asyncio.sleep(0.4)
        try:
            await asyncio.wait_for(updated.wait(), timeout)
        except TimeoutError:
            return False
        # The AC sends one status per change; give the rest a moment to arrive.
        await asyncio.sleep(1.0)
        return True
    finally:
        device.remove_callback(on_update)


def clamp_temp(value: float) -> float:
    return max(MIN_TEMP, min(MAX_TEMP, value))


# Each builder returns an async function taking the device, so the CLI and the
# menu bar describe commands the same way.
def power(on: bool):
    return lambda d: d.turn_on() if on else d.turn_off()


def temperature(value: float):
    return lambda d: d.set_temperature(clamp_temp(value))


def mode(value: HVACMode):
    return lambda d: d.set_hvac_mode(value)


def fan(value: FanMode):
    return lambda d: d.set_fan_mode(value)


def preset(value: PresetMode):
    return lambda d: d.set_preset_mode(value)


def swing(value: SwingMode):
    return lambda d: d.set_v_swing_mode(value)


def display(value: DisplayMode):
    return lambda d: d.set_display_mode(value)


def converti(value: ConvertiMode):
    return lambda d: d.set_converti_mode(value)


def h_swing(value: SwingMode):
    return lambda d: d.set_h_swing_mode(value)


def sleep_setting() -> list:
    """Bedtime: on, Cool, Low fan, Converti8 50%, both swings auto."""
    return [
        power(True),
        mode(HVACMode.COOL),
        fan(FanMode.LOW),
        converti(ConvertiMode.C50),
        swing(SwingMode.AUTO),
        h_swing(SwingMode.AUTO),
    ]
