/**
 * Rocket Arena room server.
 *
 * One Durable Object per room code, holding at most two WebSockets. It never
 * looks inside a game packet — whatever one player sends, the other receives.
 * All match logic stays in the browser (the room creator is the authority).
 *
 * Runs on the Workers free plan: inbound WebSocket messages bill at 20:1, so a
 * five-minute match costs roughly 750 of the 100,000 daily requests.
 */

import { DurableObject } from 'cloudflare:workers';

export interface Env {
  ROOM: DurableObjectNamespace<Room>;
}

const CODE = /^[A-Z0-9-]{3,12}$/;

/**
 * Application close code for "this room already has two players".
 * Deliberately not exported: workerd treats every named export of the entry
 * module as a handler or Durable Object class, and refuses to start on a
 * number.
 */
const ROOM_FULL = 4001;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/r\/([^/]+)$/);
    if (!match) {
      return new Response('Rocket Arena room server', {
        status: 200,
        headers: { 'content-type': 'text/plain' },
      });
    }

    const code = decodeURIComponent(match[1]).toUpperCase();
    if (!CODE.test(code)) return new Response('Bad room code', { status: 400 });
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected WebSocket', { status: 426 });
    }

    return env.ROOM.getByName(code).fetch(request);
  },
} satisfies ExportedHandler<Env>;

export class Room extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keepalives are answered without waking the object.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  async fetch(_request: Request): Promise<Response> {
    const existing = this.ctx.getWebSockets();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (existing.length >= 2) {
      // Turning the upgrade down with an HTTP status tells the browser nothing
      // — it just sees a failed connection, indistinguishable from a bad
      // address. So accept, say why, and close with a code the client can read.
      // Plain accept() rather than acceptWebSocket(), so this socket is never
      // counted as a member of the room.
      server.accept();
      server.send(JSON.stringify({ t: 'full' }));
      server.close(ROOM_FULL, 'room full');
      return new Response(null, { status: 101, webSocket: client });
    }

    // Whoever gets there first is the host, and stays the host — a reconnecting
    // player must not steal authority from the one still in the match.
    const role = this.ctx.getWebSockets('host').length === 0 ? 'host' : 'guest';

    this.ctx.acceptWebSocket(server, [role]);

    server.send(JSON.stringify({ t: 'hello', role, peers: existing.length + 1 }));
    for (const other of existing) {
      try {
        other.send(JSON.stringify({ t: 'peer', joined: true }));
      } catch {
        // Socket already gone; webSocketClose will tidy up.
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  /** Pure relay — game packets are opaque here. */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      try {
        other.send(message);
      } catch {
        // Dropped mid-send; the close handler deals with it.
      }
    }
  }

  async webSocketClose(ws: WebSocket) {
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      try {
        other.send(JSON.stringify({ t: 'peer', joined: false }));
      } catch {
        // Nothing left to tell.
      }
    }
  }

  async webSocketError(ws: WebSocket) {
    await this.webSocketClose(ws);
  }
}
