#!/usr/bin/env /opt/homebrew/opt/python@3.11/bin/python3.11
"""
Persistent bridge: reads JSON touch commands from stdin, sends them as gRPC HID
events to idb_companion. Stays alive to amortize connection setup.

Protocol (one JSON object per line on stdin):
  {"type":"tap",   "x":200, "y":400}
  {"type":"swipe", "x1":100,"y1":200,"x2":300,"y2":600, "duration":0.3}
  {"type":"down",  "x":200, "y":400}
  {"type":"move",  "x":210, "y":420}
  {"type":"up",    "x":210, "y":420}

Responds with one JSON line per command on stdout:
  {"ok":true}  or  {"ok":false,"error":"..."}
"""

import asyncio
import json
import sys
import os

async def main():
    from grpclib.client import Channel
    from idb.grpc.idb_grpc import CompanionServiceStub
    from idb.grpc.idb_pb2 import HIDEvent

    sock_path = os.environ.get("IDB_COMPANION_SOCKET")
    if not sock_path:
        respond({"ok": False, "error": "IDB_COMPANION_SOCKET not set"})
        return

    channel = Channel(path=sock_path)
    stub = CompanionServiceStub(channel)

    def make_press(x, y, direction):
        ev = HIDEvent()
        ev.press.action.touch.point.x = x
        ev.press.action.touch.point.y = y
        ev.press.direction = direction  # 0=DOWN, 1=UP
        return ev

    def make_swipe(x1, y1, x2, y2, duration=0.3):
        ev = HIDEvent()
        ev.swipe.start.x = x1
        ev.swipe.start.y = y1
        ev.swipe.end.x = x2
        ev.swipe.end.y = y2
        ev.swipe.duration = duration
        return ev

    respond({"ok": True, "status": "ready"})
    sys.stdout.flush()

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        line = await reader.readline()
        if not line:
            break
        line = line.decode().strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            respond({"ok": False, "error": f"bad json: {e}"})
            continue

        try:
            t = cmd.get("type")
            if t == "tap":
                msgs = [make_press(cmd["x"], cmd["y"], 0),
                        make_press(cmd["x"], cmd["y"], 1)]
                await stub.hid(msgs)
            elif t == "swipe":
                msgs = [make_swipe(cmd["x1"], cmd["y1"], cmd["x2"], cmd["y2"],
                                   cmd.get("duration", 0.3))]
                await stub.hid(msgs)
            elif t == "down":
                msgs = [make_press(cmd["x"], cmd["y"], 0)]
                await stub.hid(msgs)
            elif t == "move":
                msgs = [make_press(cmd["x"], cmd["y"], 0)]
                await stub.hid(msgs)
            elif t == "up":
                msgs = [make_press(cmd["x"], cmd["y"], 1)]
                await stub.hid(msgs)
            else:
                respond({"ok": False, "error": f"unknown type: {t}"})
                continue
            respond({"ok": True})
        except Exception as e:
            respond({"ok": False, "error": str(e)})

    channel.close()


def respond(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    asyncio.run(main())
