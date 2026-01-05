const WebSocket = require("ws");

const http = require("http");
const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Signaling server is running ok");
});

const wss = new WebSocket.Server({ server });

server.listen(8080, () => {
  console.log("Signaling server started on port 8080");
});

// Track connected clients with their roles
let clientIdCounter = 0;
const clients = new Map(); // Map<WebSocket, { id: number, role: 'polite' | 'impolite' }>

wss.on("connection", (ws) => {
  const clientId = ++clientIdCounter;
  
  // First client is polite, second is impolite
  // If there's already a client, new one is impolite; otherwise polite
  const existingClients = Array.from(clients.values());
  const role = existingClients.length === 0 ? 'polite' : 'impolite';
  
  clients.set(ws, { id: clientId, role: role });
  console.log(`Client ${clientId} connected with role: ${role} (total: ${clients.size})`);
  
  // Send role assignment to the client
  ws.send(JSON.stringify({ type: 'role', role: role, clientId: clientId }));

  ws.on("message", (message) => {
    let data;
    try {
      data = JSON.parse(message);
    } catch (e) {
      console.log("Received non-JSON message:", message);
      return;
    }

    const clientInfo = clients.get(ws);
    const clientRole = clientInfo ? clientInfo.role : 'unknown';

    switch (data.type) {
      case "offer":
        console.log(`Broadcasting offer from ${clientRole} client`);
        broadcast(ws, data);
        break;
      case "answer":
        console.log(`Broadcasting answer from ${clientRole} client`);
        broadcast(ws, data);
        break;
      case "candidate":
        console.log(`Broadcasting candidate from ${clientRole} client`);
        broadcast(ws, data);
        break;
      default:
        console.log("Unknown message type:", data.type);
        break;
    }
  });

  ws.on("close", () => {
    const clientInfo = clients.get(ws);
    console.log(`Client ${clientInfo?.id} (${clientInfo?.role}) disconnected`);
    clients.delete(ws);
    
    // When a client disconnects and there's only one left, reassign it as polite
    if (clients.size === 1) {
      const remainingClient = Array.from(clients.entries())[0];
      if (remainingClient) {
        const [remainingWs, info] = remainingClient;
        if (info.role !== 'polite') {
          info.role = 'polite';
          clients.set(remainingWs, info);
          remainingWs.send(JSON.stringify({ type: 'role', role: 'polite', clientId: info.id }));
          console.log(`Reassigned client ${info.id} to polite (only client remaining)`);
        }
      }
    }
  });
});

function broadcast(sender, data) {
  wss.clients.forEach((client) => {
    if (client !== sender && client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(data));
    }
  });
}
