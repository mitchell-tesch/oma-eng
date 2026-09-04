"""
hello_spacegass.py — smallest possible SPACE GASS 14.5+ automation.

Purpose: prove that Python inside the guest (or on Omarchy, given the
port is reachable) can drive SPACE GASS's REST API end-to-end (connect
→ open sample → read structure → close) from source that lives on
the Omarchy host via the virtiofs share.

The SPACE GASS API is a headless local HTTP service at
`http://localhost:34560` by default. Start it in the guest before
running this script by double-clicking the "SPACE GASS API" shortcut
under the SPACE GASS Windows application folder, or by running:

    "C:\\Program Files\\SPACE GASS 14.5\\SpaceGassApi.exe"

Modelled on the vendor Quick Start sample —
https://github.com/SpaceGass/space-gass-api/blob/main/sdks/python/examples/quick_start/quick_start.py

Prereqs (in the guest):
    - SPACE GASS 14.5 or later, opened at least once
    - `py -m pip install --user -r requirements.txt`
    - SpaceGassApi.exe running

Run:
    py hello_spacegass.py
    py hello_spacegass.py http://192.168.122.42:34560   # optional: custom URL
"""

from __future__ import annotations

import asyncio
import sys

from space_gass_api import SpaceGassApiClient
import space_gass_api.models as models


async def main() -> int:
    base_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:34560"

    client = SpaceGassApiClient.create_client(base_url)

    try:
        print(f"Connecting to SPACE GASS API at {base_url}")
        print("Opening built-in sample 'Portal Frame.SG'...")
        await client.job.open_sample.post(
            models.OpenSampleRequest(file_name="Portal Frame.SG"),
        )

        nodes = await client.job.structure.nodes.get()
        print(f"Found {len(nodes)} node(s):")
        for node in nodes:
            print(f"  Node {node.id}: ({node.x}, {node.y}, {node.z})")

        print("Hello from SPACE GASS on Omarchy.")

    except models.ErrorResponse as err:
        print(f"API error {err.status}: {err.title}", file=sys.stderr)
        if err.detail:
            print(f"  {err.detail}", file=sys.stderr)
        return 1
    finally:
        print("Closing project...")
        await client.job.close.post()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
