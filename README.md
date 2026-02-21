# iOS Simulator Stream

Streams the iOS Simulator screen to a browser over WebRTC. Works on Chrome and Safari.

# ⚠️ INFO

- This requires screen capture and accessibility permissions (accessibility could be removed)
- You'll need to untick Window > Show Device Bezels (or restart simulator, the swift code changes the preferences)

# Architecture

Required components:

- GRPC to send click events (idb takes 200ms to boot)
- Node as a signaling server (=websocket coordinator) and reverse proxy (so both webpage and video stream go through the same port)

# TODOs

- Don't enforce "hide bezels"

## Requirements

- macOS 14+
- Xcode / Swift toolchain
- Node.js
- Screen Recording permission granted to Terminal (System Settings → Privacy & Security → Screen Recording)

## Start

Three components must run simultaneously. Open three terminal tabs.

**1. Signaling server**

```sh
cd signaling
npm install
node server.js
```

**2. Swift streamer**

```sh
swift run
```

**3. Browser**

Open `http://localhost:3000` in any browser on the same machine, or replace `localhost` with the machine's IP address to view from another device on the network.
