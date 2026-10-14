"""Menu-bar app: shows the AC's state next to the clock and controls it.

It keeps one live connection to MirAIe in a background thread, so changes made
from the remote or the phone app show up here within a second or two. The
menu itself is only touched from the main thread (AppKit requires it).
"""

import asyncio
import threading

import rumps
from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
from miraie_ac import FanMode, HVACMode, PowerMode, PresetMode

from . import core

ICON = "❄︎"
RETRY_SECONDS = 30
REFRESH_SECONDS = 600


class MenuBarApp(rumps.App):
    def __init__(self):
        super().__init__("MirAIe AC", title=f"{ICON} …", quit_button=None)
        self.hub = None
        self.problem = "Connecting to MirAIe…"
        self.needs_login = False
        self.selected = core.load_config().get("default_ac")
        self.dirty = True
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self._run_loop, daemon=True).start()
        rumps.Timer(self._redraw_if_dirty, 0.5).start()

    # --- background thread ---------------------------------------------------

    def _run_loop(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_until_complete(self._stay_connected())

    async def _stay_connected(self):
        while True:
            try:
                phone, password = core.credentials()
                async with core.open_hub(phone, password, live=True) as hub:
                    for device in hub.home.devices:
                        device.register_callback(self._mark_dirty)
                    self.hub, self.problem, self.needs_login = hub, None, False
                    self._mark_dirty()
                    while True:
                        # MQTT pushes changes; this catches anything it missed.
                        await asyncio.sleep(REFRESH_SECONDS)
                        await hub.get_all_device_status()
                        self._mark_dirty()
            except core.NotLoggedIn as error:
                self.problem, self.needs_login = str(error), True
            except Exception:
                self.problem, self.needs_login = "Can't reach MirAIe. Retrying…", False
            self.hub = None
            self._mark_dirty()
            await asyncio.sleep(RETRY_SECONDS)

    def _mark_dirty(self):
        self.dirty = True

    def _send(self, *actions):
        device = self._device()
        if device:
            asyncio.run_coroutine_threadsafe(
                core.send_and_confirm(device, list(actions)), self.loop
            )

    # --- main thread ---------------------------------------------------------

    def _device(self):
        if not self.hub:
            return None
        try:
            return core.pick_device(self.hub, self.selected)
        except SystemExit:
            return self.hub.home.devices[0] if self.hub.home.devices else None

    def _redraw_if_dirty(self, _timer):
        if self.dirty:
            self.dirty = False
            self._redraw()

    def _redraw(self):
        self.menu.clear()
        device = self._device()
        if not device:
            self.title = f"{ICON} !" if self.needs_login else f"{ICON} …"
            self.menu = [rumps.MenuItem(self.problem or "No ACs found"), None, self._quit_item()]
            return

        s = device.status
        on = s.power_mode == PowerMode.ON
        if not s.is_online:
            self.title = f"{ICON} –"
        else:
            self.title = f"{ICON} {s.temperature:g}°" if on else f"{ICON} off"

        items = [rumps.MenuItem(core.describe(device)), None]
        if s.is_online:
            items.append(
                rumps.MenuItem("Turn off" if on else "Turn on",
                               callback=lambda _: self._send(core.power(not on)))
            )
            temp = s.temperature or 24
            items += [
                rumps.MenuItem(f"Warmer  ({core.clamp_temp(temp + 1):g}°)",
                               callback=lambda _: self._send(core.temperature(temp + 1))),
                rumps.MenuItem(f"Cooler  ({core.clamp_temp(temp - 1):g}°)",
                               callback=lambda _: self._send(core.temperature(temp - 1))),
                None,
                self._choices("Temperature", range(core.MIN_TEMP, core.MAX_TEMP + 1), temp,
                              lambda t: core.temperature(t), label=lambda t: f"{t}°"),
                self._choices("Mode", list(HVACMode), s.hvac_mode, core.mode),
                self._choices("Fan", list(FanMode), s.fan_mode, core.fan),
                self._choices("Preset", list(PresetMode), s.preset_mode, core.preset,
                              label=lambda p: "normal" if p == PresetMode.NONE else p.value),
            ]
        items.append(None)
        if len(self.hub.home.devices) > 1:
            pick = rumps.MenuItem("Which AC")
            for d in self.hub.home.devices:
                item = rumps.MenuItem(d.friendly_name, callback=self._select(d.friendly_name))
                item.state = int(d is device)
                pick.add(item)
            items.append(pick)
        items += [rumps.MenuItem("Refresh", callback=self._refresh), self._quit_item()]
        self.menu = items

    def _choices(self, title, values, current, build, label=None):
        label = label or (lambda v: v.value)
        parent = rumps.MenuItem(title)
        for value in values:
            item = rumps.MenuItem(label(value), callback=lambda _, v=value: self._send(build(v)))
            item.state = int(value == current)
            parent.add(item)
        return parent

    def _select(self, name):
        def choose(_):
            self.selected = name
            config = core.load_config()
            config["default_ac"] = name
            core.save_config(config)
            self._mark_dirty()
        return choose

    def _refresh(self, _):
        if self.hub:
            future = asyncio.run_coroutine_threadsafe(self.hub.get_all_device_status(), self.loop)
            future.add_done_callback(lambda _: self._mark_dirty())

    def _quit_item(self):
        return rumps.MenuItem("Quit", callback=lambda _: rumps.quit_application())


def main():
    # No Dock icon, menu bar only.
    NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    MenuBarApp().run()


if __name__ == "__main__":
    main()
