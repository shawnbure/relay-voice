import { DurableObject } from "cloudflare:workers";

export class RelayEvents extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ connectedAt: Date.now() });
    server.send(JSON.stringify({ type: "connected", at: new Date().toISOString() }));
    return new Response(null, { status: 101, webSocket: client });
  }

  broadcast(event: string): void {
    for (const socket of this.ctx.getWebSockets()) {
      try { socket.send(event); } catch { socket.close(1011, "Delivery failed"); }
    }
  }

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    if (message === "ping") socket.send("pong");
  }
}
