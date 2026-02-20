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

httpServer.listen(3000, () => {
  console.log('[Server] HTTP server listening on http://localhost:3000');
});

const wss = new WebSocketServer({ port: 8080 });

let streamer = null;
let activeViewer = null; // only one viewer at a time

function send(ws, obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

wss.on('connection', (ws) => {
  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }

    if (msg.type === 'register') {
      if (msg.role === 'streamer') {
        streamer = ws;
        console.log('[Signaling] Streamer registered');
        // Notify any waiting active viewer
        if (activeViewer) send(activeViewer, { type: 'streamer-ready' });
      } else {
        // Disconnect previous viewer if any
        if (activeViewer && activeViewer !== ws && activeViewer.readyState === 1) {
          console.log('[Signaling] Replacing old viewer');
          activeViewer.close();
        }
        activeViewer = ws;
        console.log('[Signaling] Viewer registered');
        if (streamer && streamer.readyState === 1) {
          send(ws, { type: 'streamer-ready' });
        } else {
          console.log('[Signaling] No streamer yet, viewer waiting');
        }
      }
      return;
    }

    // Offer from viewer → streamer
    if (msg.type === 'offer') {
      console.log('[Signaling] Routing offer to streamer');
      send(streamer, msg);
      return;
    }

    // Answer from streamer → active viewer only
    if (msg.type === 'answer') {
      console.log('[Signaling] Routing answer to viewer');
      send(activeViewer, msg);
      return;
    }

    // ICE: viewer → streamer
    if (msg.type === 'ice-candidate' && ws === activeViewer) {
      console.log('[Signaling] ICE viewer→streamer:', msg.candidate && msg.candidate.slice(0, 60));
      send(streamer, msg);
      return;
    }

    // ICE: streamer → active viewer
    if (msg.type === 'ice-candidate' && ws === streamer) {
      console.log('[Signaling] ICE streamer→viewer:', msg.candidate && msg.candidate.slice(0, 60));
      send(activeViewer, msg);
      return;
    }
  });

  ws.on('close', () => {
    if (ws === streamer) {
      streamer = null;
      console.log('[Signaling] Streamer disconnected');
      if (activeViewer) send(activeViewer, { type: 'streamer-disconnected' });
    } else if (ws === activeViewer) {
      activeViewer = null;
      console.log('[Signaling] Viewer disconnected');
    }
  });

  ws.on('error', (err) => console.error('[Signaling] Error:', err.message));
});

console.log('[Signaling] WebSocket server listening on ws://localhost:8080');
