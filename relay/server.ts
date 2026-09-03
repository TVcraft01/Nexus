// Nexus Relay Server — lightweight WebSocket relay for cross-network pairing.
//
// Deploy to Deno Deploy (free tier) or run locally with: deno run --allow-net relay/server.ts
//
// The relay only forwards encrypted bytes between two paired devices.
// It never reads, stores, or logs the TCP payload — it's just a pipe.

interface Device {
  id: string;
  token: string;
  socket: WebSocket;
  pairedWith?: string;
}

const devices = new Map<string, Device>();

function handleUpgrade(request: Request): Response {
  const { socket, response } = Deno.upgradeWebSocket(request);

  socket.onopen = () => {
    console.log(`[relay] connection opened`);
  };

  socket.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data as string);
      handleMessage(socket, msg);
    } catch (e) {
      console.error(`[relay] bad message: ${e}`);
    }
  };

  socket.onclose = () => {
    // Remove any device associated with this socket
    for (const [id, device] of devices) {
      if (device.socket === socket) {
        // Notify paired device
        if (device.pairedWith) {
          const peer = devices.get(device.pairedWith);
          if (peer && peer.socket.readyState === WebSocket.OPEN) {
            peer.socket.send(JSON.stringify({ type: 'error', message: 'Peer disconnected' }));
            peer.pairedWith = undefined;
          }
        }
        devices.delete(id);
        console.log(`[relay] device ${id} disconnected`);
      }
    }
  };

  socket.onerror = (e) => {
    console.error(`[relay] error: ${e}`);
  };

  return response;
}

function handleMessage(sender: WebSocket, msg: Record<string, unknown>) {
  const type = msg.type as string;

  switch (type) {
    case 'register': {
      const deviceId = msg.deviceId as string;
      const token = msg.token as string;
      if (!deviceId || !token) return;

      devices.set(deviceId, { id: deviceId, token, socket: sender });
      console.log(`[relay] device registered: ${deviceId}`);
      break;
    }

    case 'connect': {
      const fromId = msg.from as string;
      const toId = msg.to as string;
      if (!fromId || !toId) return;

      const from = devices.get(fromId);
      const to = devices.get(toId);

      if (!from || !to) {
        sender.send(JSON.stringify({ type: 'error', message: 'Target device not found' }));
        return;
      }

      // Pair them
      from.pairedWith = toId;
      to.pairedWith = fromId;

      // Notify both
      from.socket.send(JSON.stringify({ type: 'paired' }));
      to.socket.send(JSON.stringify({ type: 'paired' }));
      console.log(`[relay] paired: ${fromId} <-> ${toId}`);
      break;
    }

    case 'data': {
      // Forward encrypted data to the paired peer
      const fromDevice = findDeviceBySocket(sender);
      if (!fromDevice || !fromDevice.pairedWith) {
        sender.send(JSON.stringify({ type: 'error', message: 'Not paired' }));
        return;
      }
      const peer = devices.get(fromDevice.pairedWith);
      if (peer && peer.socket.readyState === WebSocket.OPEN) {
        peer.socket.send(event.data);
      }
      break;
    }

    case 'ping': {
      sender.send(JSON.stringify({ type: 'pong' }));
      break;
    }
  }
}

function findDeviceBySocket(socket: WebSocket): Device | undefined {
  for (const device of devices.values()) {
    if (device.socket === socket) return device;
  }
  return undefined;
}

Deno.serve({ port: parseInt(Deno.env.get('PORT') ?? '8080') }, (request) => {
  const url = new URL(request.url);

  if (url.pathname === '/ws' && request.headers.get('upgrade') === 'websocket') {
    return handleUpgrade(request);
  }

  if (url.pathname === '/health') {
    return new Response(JSON.stringify({
      status: 'ok',
      devices: devices.size,
      uptime: Date.now(),
    }), {
      headers: { 'content-type': 'application/json' },
    });
  }

  return new Response('Nexus Relay Server', { status: 200 });
});
