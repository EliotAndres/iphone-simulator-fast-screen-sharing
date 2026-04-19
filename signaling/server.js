const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

// HTTP server for browser client
const httpServer = http.createServer((req, res) => {
  const indexPath = path.join(__dirname, '..', 'browser', 'index.html');
  fs.readFile(indexPath, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(data);
  });
});

// WebSocket server attached to HTTP server (same port for tunnel compatibility).
// perMessageDeflate: false avoids occasional framing issues behind reverse proxies
// and, more importantly, would waste CPU on already-compressed H.264 payloads.
const wss = new WebSocketServer({
  server: httpServer,
  path: '/ws',
  perMessageDeflate: false,
  maxPayload: 16 * 1024 * 1024,
});

// Cloudflare quick tunnels and similar proxies often close idle WebSockets; ping keeps them up.
const WS_PING_MS = 20000;
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.readyState === 1) ws.ping();
  });
}, WS_PING_MS);

httpServer.listen(3000, () => {
  console.log('[Server] HTTP server listening on http://localhost:3000');
  console.log('[Stream] WebSocket server on ws://localhost:3000/ws');
});

let streamer = null;
let activeViewer = null; // only one viewer at a time

function sendJSON(ws, obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function sendBinary(ws, buf) {
  if (ws && ws.readyState === 1) ws.send(buf, { binary: true });
}

wss.on('connection', (ws, req) => {
  const ip = req.socket?.remoteAddress ?? req.headers['x-forwarded-for'] ?? '?';
  const ua = (req.headers['user-agent'] || '').slice(0, 100);
  console.log('[Stream] WS client connected from', ip, 'path=', req.url, 'ua=', ua);

  ws.on('message', (data, isBinary) => {
    // Binary: H.264 frames from streamer → forward to active viewer as-is.
    if (isBinary) {
      if (ws === streamer) sendBinary(activeViewer, data);
      return;
    }

    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }

    if (msg.type === 'register') {
      if (msg.role === 'streamer') {
        streamer = ws;
        console.log('[Stream] Streamer registered');
        if (activeViewer) {
          sendJSON(streamer, { type: 'viewer-joined' });
          sendJSON(activeViewer, { type: 'streamer-ready' });
        }
      } else {
        if (activeViewer && activeViewer !== ws && activeViewer.readyState === 1) {
          console.log('[Stream] Replacing old viewer');
          activeViewer.close();
        }
        activeViewer = ws;
        console.log('[Stream] Viewer registered');
        if (streamer && streamer.readyState === 1) {
          sendJSON(streamer, { type: 'viewer-joined' });
          sendJSON(ws, { type: 'streamer-ready' });
        } else {
          console.log('[Stream] No streamer yet, viewer waiting');
        }
      }
      return;
    }

    // Streamer → viewer: video-init config
    if (msg.type === 'video-init' && ws === streamer) {
      sendJSON(activeViewer, msg);
      return;
    }

    // Viewer → streamer: touch events, commands, and keyframe requests
    if (ws === activeViewer) {
      if (msg.type === 'down' || msg.type === 'move' || msg.type === 'up' ||
          msg.type === 'home' || msg.type === 'request-keyframe') {
        sendJSON(streamer, msg);
        return;
      }
    }
  });

  ws.on('close', () => {
    if (ws === streamer) {
      streamer = null;
      console.log('[Stream] Streamer disconnected');
      if (activeViewer) sendJSON(activeViewer, { type: 'streamer-disconnected' });
    } else if (ws === activeViewer) {
      activeViewer = null;
      console.log('[Stream] Viewer disconnected');
      if (streamer) sendJSON(streamer, { type: 'viewer-left' });
    }
  });

  ws.on('error', (err) => console.error('[Stream] Error:', err.message));
});
