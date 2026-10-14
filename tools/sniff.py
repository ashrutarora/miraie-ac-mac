"""Logs every MQTT message on the AC's topics (control, status, connection),
so we can see exactly what the phone app sends for each feature."""

import asyncio
import json
import ssl
import sys
import time

import aiohttp
import certifi
from aiomqtt import Client

from miraie_ac_mac import core


async def main(log_path):
    phone, password = core.credentials()
    async with core.open_hub(phone, password, live=False) as hub:
        token, home = hub.user.access_token, hub.home.id
        bases = [d.control_topic.rsplit("/", 1)[0] for d in hub.home.devices]
    context = ssl.create_default_context(cafile=certifi.where())
    with open(log_path, "a", buffering=1) as log:
        async with Client("mqtt.miraie.in", 8883, username=home, password=token, tls_context=context) as client:
            for base in bases:
                await client.subscribe(base + "/#")
            log.write(f"{time.strftime('%H:%M:%S')} listening on {bases}\n")
            async for message in client.messages:
                try:
                    body = json.dumps(json.loads(message.payload), separators=(",", ":"))
                except Exception:
                    body = repr(message.payload)
                log.write(f"{time.strftime('%H:%M:%S')} {message.topic.value.rsplit('/', 1)[-1]:16} {body}\n")


asyncio.run(main(sys.argv[1]))
