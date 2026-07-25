import { MSG, decodePingStamp, encodePing } from './Protocol';

export type NetRole = 'host' | 'guest';
export type NetStatus = 'offline' | 'connecting' | 'waiting' | 'connected' | 'error';

export interface ConnectionHooks {
  onStatus(status: NetStatus, detail: string): void;
  onRole(role: NetRole): void;
  /** Peer arrived or left. */
  onPeer(present: boolean): void;
  onPacket(view: DataView, raw: ArrayBuffer): void;
}

/** Close code the room server uses for "two players are already in here". */
const ROOM_FULL = 4001;
const ROOM_FULL_MESSAGE = 'That room is full — your friend is already in a game';

/** Unambiguous alphabet — no O/0, no I/1, so a code survives being read aloud. */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export function makeRoomCode(): string {
  let out = '';
  for (let i = 0; i < 6; i++) {
    if (i === 3) out += '-';
    out += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return out;
}

/**
 * WebSocket link to one room. Knows nothing about the game — it hands raw
 * packets to whoever is driving it, and tracks role, peer presence and ping.
 */
export class Connection {
  status: NetStatus = 'offline';
  role: NetRole | null = null;
  peerPresent = false;
  /** Round-trip time in ms, or 0 before the first pong. */
  ping = 0;
  code = '';

  private ws: WebSocket | null = null;
  private hooks: ConnectionHooks;
  private pingTimer = 0;
  private closing = false;
  /** Set when the room turned us away, so the close handler keeps that reason. */
  private rejected = false;

  constructor(hooks: ConnectionHooks) {
    this.hooks = hooks;
  }

  get open() {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  /** `server` is an http(s) or ws(s) origin; the room code is appended. */
  connect(server: string, code: string) {
    this.disconnect();
    this.closing = false;
    this.rejected = false;
    this.code = code.toUpperCase();

    let url: string;
    try {
      url = roomUrl(server, this.code);
    } catch {
      this.setStatus('error', 'That server address is not a valid URL');
      return;
    }

    this.setStatus('connecting', `Connecting to ${this.code}…`);

    let ws: WebSocket;
    try {
      ws = new WebSocket(url);
    } catch {
      this.setStatus('error', 'Could not open a connection');
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;

    ws.onopen = () => {
      this.pingTimer = window.setInterval(() => this.sendPing(), 2000);
    };

    ws.onmessage = (e) => {
      if (typeof e.data === 'string') {
        this.handleControl(e.data);
        return;
      }
      const raw = e.data as ArrayBuffer;
      if (raw.byteLength < 1) return;
      const view = new DataView(raw);
      const type = view.getUint8(0);
      if (type === MSG.ping) {
        this.send(encodePing(MSG.pong, decodePingStamp(view)));
        return;
      }
      if (type === MSG.pong) {
        this.ping = Math.max(0, Math.round(performance.now() - decodePingStamp(view)));
        return;
      }
      this.hooks.onPacket(view, raw);
    };

    ws.onerror = () => {
      if (!this.closing && !this.rejected) {
        this.setStatus('error', 'Connection failed — check the server address');
      }
    };

    ws.onclose = (e) => {
      window.clearInterval(this.pingTimer);
      this.ws = null;
      this.peerPresent = false;
      if (this.closing) {
        this.setStatus('offline', '');
      } else if (this.rejected || e.code === ROOM_FULL) {
        // Keep the reason the room gave us rather than reporting a generic drop.
        this.setStatus('error', ROOM_FULL_MESSAGE);
      } else {
        this.setStatus('error', 'Disconnected');
      }
    };
  }

  disconnect() {
    this.closing = true;
    window.clearInterval(this.pingTimer);
    this.ws?.close();
    this.ws = null;
    this.role = null;
    this.peerPresent = false;
    this.ping = 0;
    this.setStatus('offline', '');
  }

  send(data: ArrayBuffer) {
    if (this.ws?.readyState !== WebSocket.OPEN) return;
    // Never let a stalled socket queue megabytes of stale snapshots.
    if (this.ws.bufferedAmount > 262144) return;
    this.ws.send(data);
  }

  private sendPing() {
    this.send(encodePing(MSG.ping, performance.now()));
  }

  private handleControl(text: string) {
    let msg: { t?: string; role?: string; joined?: boolean; peers?: number };
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (msg.t === 'full') {
      this.rejected = true;
      this.setStatus('error', ROOM_FULL_MESSAGE);
    } else if (msg.t === 'hello' && (msg.role === 'host' || msg.role === 'guest')) {
      this.role = msg.role;
      this.hooks.onRole(msg.role);
      // Only sockets already in the room get a 'peer' message, so the one
      // joining has to learn about the other from the peer count here.
      this.peerPresent = (msg.peers ?? 1) > 1;
      if (this.peerPresent) {
        this.setStatus('connected', `Connected — room ${this.code}`);
        this.hooks.onPeer(true);
      } else {
        this.setStatus(
          'waiting',
          msg.role === 'host'
            ? `Room ${this.code} — waiting for your friend`
            : `Joined ${this.code} — waiting for the host`,
        );
      }
    } else if (msg.t === 'peer') {
      this.peerPresent = !!msg.joined;
      this.hooks.onPeer(this.peerPresent);
      if (this.peerPresent) this.setStatus('connected', `Connected — room ${this.code}`);
      else this.setStatus('waiting', 'Your friend left the room');
    }
  }

  private setStatus(status: NetStatus, detail: string) {
    this.status = status;
    this.hooks.onStatus(status, detail);
  }
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/**
 * Accepts `example.workers.dev`, `https://…` or `wss://…` and normalises it to
 * a room URL. A bare host is assumed secure unless it's a local dev server,
 * which never has a certificate.
 */
export function roomUrl(server: string, code: string): string {
  const trimmed = server.trim().replace(/\/+$/, '');
  const explicit = /^(wss?|https?):\/\//.test(trimmed);
  const url = new URL(explicit ? trimmed : `https://${trimmed}`);
  const insecure = explicit
    ? url.protocol === 'http:' || url.protocol === 'ws:'
    : LOCAL_HOSTS.has(url.hostname);
  url.protocol = insecure ? 'ws:' : 'wss:';
  url.pathname = `${url.pathname.replace(/\/+$/, '')}/r/${encodeURIComponent(code)}`;
  return url.toString();
}
