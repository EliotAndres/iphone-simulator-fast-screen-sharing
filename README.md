# iOS Simulator Stream

Streams the iOS Simulator screen to a browser as H.264 over WebSocket (WebCodecs). Low-latency, single viewer, tap/drag/home input forwarded to the simulator.

## Dependencies

**Host**
- macOS 14+
- Xcode / Swift 5.9 toolchain
- [`uv`](https://docs.astral.sh/uv/) (for the Python touch bridge)
- Python 3.12 (installed by `uv`)
- `idb_companion` (`brew install facebook/fb/idb-companion`)
- Screen Recording permission granted to Terminal (System Settings → Privacy & Security → Screen Recording)
- Optional: `cloudflared` (`brew install cloudflared`) for `--tunnel`

**Python (installed by `install.sh` into `scripts/.venv`)**
- `fb-idb`
- `grpclib`

**Swift**
- Apple frameworks only: ScreenCaptureKit, VideoToolbox, Network, AppKit (no external packages)

**Browser**
- Chrome 94+ or Safari 16.4+ (needs `VideoDecoder`)

## Install

```sh
./install.sh
```

## Run

```sh
./start.sh            # serves http://localhost:3738
./start.sh --tunnel   # also exposes it via cloudflared
```

Open `http://localhost:3738` locally, or use the machine's IP / tunnel URL from another device.

## Notes

- The Swift process disables `Window → Show Device Bezels` on launch (cleaner capture).
- A single Swift binary handles capture, H.264 encoding (hardware with software fallback), HTTP, and WebSocket — no separate signaling server.
- Touch events are forwarded to `idb_companion` over a persistent gRPC bridge (`scripts/touch_bridge.py`).
- Override the port with `PORT=xxxx swift run SimulatorStream`.
- **macOS VMs / Tart guests:** VideoToolbox often creates an H.264 session but never delivers frames (`kVTVideoEncoderNotAvailableNowErr`). The encoder falls back to software H.264 after a few failed output callbacks. To skip hardware from the first frame, set `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1` (e.g. `SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 ./start.sh`).
