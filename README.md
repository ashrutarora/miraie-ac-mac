# miraie-ac-mac

Control a Panasonic MirAIe air conditioner from a Mac: a menu-bar panel and an `ac` command for the terminal.
It talks to the same MirAIe cloud the phone app uses (sign-in over HTTPS, commands and live status over MQTT),
so the AC needs Wi-Fi and the Mac needs internet. MirAIe has no public API; this is built on the community
[`miraie-ac-in`](https://pypi.org/project/miraie-ac-in/) library and on watching what the official app sends.

Panasonic ACs that use the global Comfort Cloud app instead of MirAIe are not supported.

## The menu-bar panel

Click the snowflake in the menu bar (it shows the set temperature while the AC is on):

- Power, a temperature dial (drag, scroll, or ↑/↓), mode and fan speed.
- **Sleep**: one click for on, Cool, Low fan, Converti8 50% and both swings on auto (⌘S).
- Rows that open in place: airflow (each louvre position drawn), features (Display, Eco, Powerful, nanoe, Clean,
  Converti8 40–110%), switch-on/off timers and the app's Default profile, and energy use by day, week or month.
- A warning with Retry when the AC doesn't confirm a change.

## Install

Needs macOS 14+, [uv](https://docs.astral.sh/uv/), and the Xcode command-line tools (full Xcode is not needed).

```bash
uv tool install --editable .     # puts `ac` in ~/.local/bin
ac login                         # MirAIe phone number + password; the password goes to the Keychain
mac/build.sh                     # builds ~/Applications/MirAIe AC.app
ac autostart on                  # starts the panel now and at every login
```

The first time the panel starts, macOS asks whether it may read the `miraie-ac` Keychain item: choose
**Always Allow**. The app is signed ad hoc, so a rebuild asks once more.

`~/.local/bin/ac` shadows macOS's own `/usr/sbin/ac` (an old login-time report); run that one by its full path.

## The `ac` command

```text
ac                      status
ac on | off | toggle
ac 24                   temperature, 16-30
ac up | down            one degree warmer or cooler
ac cool | dry | heat    mode (also: ac mode auto, ac mode fan)
ac fan auto|low|medium|high|quiet
ac eco | boost | clean | normal
ac swing auto|1-5       vertical louvre
ac display on|off       the light on the indoor unit
ac sleep                on, cool, low fan, Converti8 50%, swing auto
ac on 24 cool fan high  several at once, in order
ac list / ac use "Bedroom" / ac --ac Bedroom off
ac logout / ac autostart on|off
```

Each command signs in, sends, and waits for the AC to report its new state, so it takes 2-4 seconds.

## How the AC is driven

Commands are JSON on `<device topic>/control`; the AC answers with its full state on `<device topic>/status`.
Field names and `ki` values below are what the official iPhone app sends:

| What | Field | `ki` | Values |
|---|---|---|---|
| Power | `ps` | 1 | `on`, `off` |
| Temperature | `actmp` | 2 | `"24.0"` |
| Mode | `acmd` | 0 | `cool`, `dry`, `fan`, `auto` (`heat` on models that have it) |
| Fan | `acfs` | 4 | `auto`, `quiet`, `low`, `medium`, `high` |
| Up–down louvre | `acvs` | 5 | 0 = swing, 1-5 |
| Left–right louvre | `achs` | 6 | 0 = swing, 1-5 |
| Display light | `acdc` | 8 | `on`, `off` |
| Eco | `acem` | 10 | `on`, `off` (the app also sets 26°) |
| Powerful | `acpm` | 3 | `on`, `off` |
| Clean | `acec` | 1 | `on`, `off`; only while the AC is off |
| nanoe | `acng` | 60 | `on`, `off` |
| Converti8 | `cnv` | 191 | 0, 40, 50, 60, 70, 80, 90, 100, 110 |
| Default profile | `acsp`, `pid`, `temps` | 12 | `on`/`off`, `"default"`, nine values: 8 hourly temperatures and `"0.0"` |
| Timers | `actm` | none | `[switch off, switch on]` in seconds from now, `-1` cancels |

The status reports each timer as the Unix time it fires. The room temperature (`rmtmp`) comes either plain
(`"23.12"`) or packed as `"<fraction byte>.<whole degrees>"` (`"62.22"` = 22.24°); see `room_temp` in
`src/miraie_ac_mac/core.py`.

`tools/sniff.py` logs every message on the AC's topics, which is how the table above was filled in.

## Where things live

- Password: Keychain, service `miraie-ac`. Phone number and default AC: `~/.config/miraie-ac/config.json`.
- Login item: `~/Library/LaunchAgents/com.ashrutarora.miraie-ac.plist` (`ac autostart off` removes it).
- Panel source: `mac/` (SwiftUI, no dependencies). CLI: `src/miraie_ac_mac/`. Tests: `uv run pytest`.
