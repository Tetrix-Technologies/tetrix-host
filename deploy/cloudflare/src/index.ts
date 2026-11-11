// The relay as a Cloudflare Worker.
//
// A host dials `/v1/host?id=<host ID>` and proves it holds the key behind
// that ID. A client dials `/v1/connect/<host ID>`. The relay copies messages
// between them and holds no key that opens them: the client and the host run
// a Noise handshake through it and seal everything after.
//
// This file speaks the same bytes as the Go relay in `internal/relay`. The
// specification is `docs/reference/protocol.md`. `internal/relay/relay_test.go`
// runs against either one.
import { DurableObject } from "cloudflare:workers";

const VERSION = "0.1.0";
const SUBPROTOCOL = "tetrix-host.v1";
const SOURCE = "https://github.com/Tetrix-Technologies/tetrix-host";

// A client sends bare Noise messages. The host's copy gains a 9-byte header.
const MAX_CLIENT_MESSAGE = 65535;
const RELAY_HEADER = 9;
const MAX_HOST_MESSAGE = MAX_CLIENT_MESSAGE + RELAY_HEADER;

const REGISTER_CONTEXT = "tetrix-host/relay-register/1\0";
const HOST_ID_CONTEXT = "tetrix-host/host-id/1\0";

const FRAME_OPEN = 0x01;
const FRAME_DATA = 0x02;
const FRAME_CLOSE = 0x03;

const CLOSE = {
	badRequest: 4400,
	unauthorized: 4401,
	hostOffline: 4404,
	replaced: 4409,
	tooManySessions: 4429,
} as const;

const LIMITS = {
	sessionsPerHost: 64,
	opensPerMinute: 240,
	sessionsPerAddress: 16,
	opensPerAddress: 60,
	// Connections that asked to be a host and have not yet proved it.
	pendingHosts: 4,
} as const;

export interface Env {
	HOSTS: DurableObjectNamespace<HostRoom>;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (request.method !== "GET") return new Response("method not allowed\n", { status: 405 });

		if (url.pathname === "/healthz") {
			return Response.json({ ok: true, version: VERSION, relay: "cloudflare" });
		}
		if (url.pathname === "/") {
			return new Response(
				`Tetrix Host relay ${VERSION}\n\nThis server passes sealed messages between a host and the apps paired with it.\nIt holds no key that opens them. The source is at ${SOURCE}\n`,
				{ headers: { "content-type": "text/plain; charset=utf-8" } },
			);
		}

		let hostId: string | null;
		if (url.pathname === "/v1/host") {
			hostId = url.searchParams.get("id");
		} else {
			const match = /^\/v1\/connect\/([^/]+)$/.exec(url.pathname);
			if (!match) return new Response("not found\n", { status: 404 });
			hostId = match[1];
		}
		if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
			return new Response("expected a WebSocket\n", { status: 426 });
		}
		// A host ID is 10 bytes in lower-case base32: 16 characters.
		if (!hostId || !/^[a-z2-7]{16}$/.test(hostId)) {
			return refuse(request, CLOSE.badRequest, "bad host ID");
		}
		// One object per host ID. Everything that concerns a host meets there.
		return env.HOSTS.get(env.HOSTS.idFromName(hostId)).fetch(request);
	},
} satisfies ExportedHandler<Env>;

type HostTag = { role: "host"; hostId: string; registered: boolean; nonce: string };
type ClientTag = { role: "client"; sid: string; address: string; ended?: boolean };
type Tag = HostTag | ClientTag;

/** One host and its clients. */
export class HostRoom extends DurableObject<Env> {
	// Times of recent client connections. They live in memory only. The
	// object stays in memory while connections keep arriving, which is the
	// only time these counts matter.
	private opens: number[] = [];
	private opensByAddress = new Map<string, number[]>();

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/v1/host") return this.acceptHost(request, url.searchParams.get("id") ?? "");
		return this.acceptClient(request);
	}

	private acceptHost(request: Request, hostId: string): Response {
		// A connection that never registers costs little, but bound them.
		const pending = this.hosts().filter(({ tag }) => !tag.registered);
		if (pending.length >= LIMITS.pendingHosts) {
			closeQuietly(pending[0].socket, CLOSE.unauthorized, "register timed out");
		}
		const [client, server] = Object.values(new WebSocketPair());
		const nonce = encodeBase64(crypto.getRandomValues(new Uint8Array(32)));
		this.ctx.acceptWebSocket(server, ["host"]);
		server.serializeAttachment({ role: "host", hostId, registered: false, nonce } satisfies HostTag);
		server.send(JSON.stringify({ type: "challenge", nonce }));
		return upgraded(request, client);
	}

	private acceptClient(request: Request): Response {
		const host = this.registeredHost();
		if (!host) return refuse(request, CLOSE.hostOffline, "host offline");

		const address = clientAddress(request);
		if (!this.admit(address)) {
			return refuse(request, CLOSE.tooManySessions, "host cannot take this connection");
		}
		const sid = randomSessionId();
		const [client, server] = Object.values(new WebSocketPair());
		this.ctx.acceptWebSocket(server, ["client", `sid:${sid}`]);
		server.serializeAttachment({ role: "client", sid, address } satisfies ClientTag);
		sendQuietly(host, frame(FRAME_OPEN, sid));
		return upgraded(request, client);
	}

	/**
	 * Checks the limits for one more client. The address limits come first,
	 * so that one address runs into its own limit before it can use up the
	 * host's and lock the host's own devices out.
	 */
	private admit(address: string): boolean {
		const now = Date.now();
		const recent = (times: number[]) => times.filter((t) => now - t < 60_000);
		const clients = this.clients();

		const fromAddress = recent(this.opensByAddress.get(address) ?? []);
		const openFromAddress = clients.filter(({ tag }) => tag.address === address).length;
		if (openFromAddress >= LIMITS.sessionsPerAddress || fromAddress.length >= LIMITS.opensPerAddress) return false;

		this.opens = recent(this.opens);
		if (clients.length >= LIMITS.sessionsPerHost || this.opens.length >= LIMITS.opensPerMinute) return false;

		this.opens.push(now);
		fromAddress.push(now);
		// Forget addresses that hold nothing, so the map cannot grow forever.
		for (const [key, times] of this.opensByAddress) {
			if (recent(times).length === 0) this.opensByAddress.delete(key);
		}
		this.opensByAddress.set(address, fromAddress);
		return true;
	}

	async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
		const tag = socket.deserializeAttachment() as Tag | null;
		if (!tag) return closeQuietly(socket, CLOSE.badRequest, "bad state");

		if (tag.role === "client") {
			if (typeof message === "string") return;
			if (message.byteLength > MAX_CLIENT_MESSAGE) {
				// Never forward what the host would refuse to read. End this
				// client and nobody else.
				this.endClient(socket, tag, 1009, "message too big", true);
				return;
			}
			const host = this.registeredHost();
			if (!host) return this.endClient(socket, tag, CLOSE.hostOffline, "host offline", false);
			sendQuietly(host, frame(FRAME_DATA, tag.sid, new Uint8Array(message)));
			return;
		}

		if (!tag.registered) return this.register(socket, tag, message);
		if (typeof message === "string") return;
		if (message.byteLength < RELAY_HEADER || message.byteLength > MAX_HOST_MESSAGE) {
			this.endHost(socket, tag, CLOSE.badRequest, "bad frame");
			return;
		}
		const view = new DataView(message);
		const kind = view.getUint8(0);
		const sid = view.getBigUint64(1).toString();
		const target = this.ctx.getWebSockets(`sid:${sid}`)[0];
		if (!target) return;
		if (kind === FRAME_DATA) {
			sendQuietly(target, message.slice(RELAY_HEADER));
		} else if (kind === FRAME_CLOSE) {
			// The host may name a close code. Only the application range
			// passes, so a host cannot make the relay send a reserved code.
			let code = 1000;
			let reason = "";
			if (message.byteLength >= RELAY_HEADER + 2) {
				const asked = view.getUint16(RELAY_HEADER);
				if (asked >= 4000 && asked <= 4999) code = asked;
				reason = new TextDecoder().decode(message.slice(RELAY_HEADER + 2, RELAY_HEADER + 2 + 64));
			}
			const clientTag = target.deserializeAttachment() as ClientTag;
			this.endClient(target, clientTag, code, reason, false);
		}
	}

	/** Checks a host's answer to the challenge. */
	private async register(socket: WebSocket, tag: HostTag, message: string | ArrayBuffer): Promise<void> {
		const fail = (why: string) => {
			sendQuietly(socket, JSON.stringify({ type: "error", code: "register_failed", message: why }));
			closeQuietly(socket, CLOSE.unauthorized, "register failed");
		};
		if (typeof message !== "string") return fail("expected a register message");
		let body: { type?: string; hostId?: string; publicKey?: string; signature?: string };
		try {
			body = JSON.parse(message);
		} catch {
			return fail("expected a register message");
		}
		if (body.type !== "register") return fail("expected a register message");
		const publicKey = decodeBase64(body.publicKey ?? "");
		const signature = decodeBase64(body.signature ?? "");
		const nonce = decodeBase64(tag.nonce);
		if (!publicKey || publicKey.length !== 32) return fail("bad public key");
		if (!signature || signature.length !== 64 || !nonce) return fail("bad signature");

		let verified = false;
		try {
			const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
			verified = await crypto.subtle.verify("Ed25519", key, signature, concat(utf8(REGISTER_CONTEXT), nonce));
		} catch {
			verified = false;
		}
		if (!verified) return fail("signature does not verify");

		// The ID must be the key's own, and it must be the ID this object
		// was reached by. Otherwise a host could sit in another host's room.
		const hostId = await hostIdOf(publicKey);
		if (body.hostId !== hostId || tag.hostId !== hostId) return fail("host ID does not match the key");

		// A host that registers again replaces its old connection, which is
		// what a reconnect after a network change needs. The old connection's
		// clients go too, because their session keys lived in it.
		for (const other of this.hosts()) {
			if (other.socket === socket || !other.tag.registered) continue;
			other.socket.serializeAttachment({ ...other.tag, registered: false } satisfies HostTag);
			closeQuietly(other.socket, CLOSE.replaced, "replaced");
		}
		for (const client of this.clients()) {
			this.endClient(client.socket, client.tag, CLOSE.hostOffline, "host reconnected", false);
		}

		socket.serializeAttachment({ ...tag, registered: true } satisfies HostTag);
		sendQuietly(socket, JSON.stringify({ type: "registered", hostId }));
	}

	async webSocketClose(socket: WebSocket, code: number, reason: string): Promise<void> {
		// Finish the closing handshake. A reserved code cannot be sent back.
		closeQuietly(socket, code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000, reason);
		this.gone(socket);
	}

	async webSocketError(socket: WebSocket): Promise<void> {
		closeQuietly(socket, 1011, "error");
		this.gone(socket);
	}

	/** Cleans up after a socket the far side ended. */
	private gone(socket: WebSocket): void {
		const tag = socket.deserializeAttachment() as Tag | null;
		if (!tag) return;
		if (tag.role === "host") {
			if (!tag.registered) return;
			socket.serializeAttachment({ ...tag, registered: false } satisfies HostTag);
			for (const client of this.clients()) {
				this.endClient(client.socket, client.tag, CLOSE.hostOffline, "host offline", false);
			}
			return;
		}
		if (tag.ended) return;
		socket.serializeAttachment({ ...tag, ended: true } satisfies ClientTag);
		this.tellHost(tag.sid);
	}

	/** Ends a client's connection, and tells the host if it does not know. */
	private endClient(socket: WebSocket, tag: ClientTag, code: number, reason: string, tellHost: boolean): void {
		if (tag.ended) return;
		socket.serializeAttachment({ ...tag, ended: true } satisfies ClientTag);
		closeQuietly(socket, code, reason);
		if (tellHost) this.tellHost(tag.sid);
	}

	private endHost(socket: WebSocket, tag: HostTag, code: number, reason: string): void {
		socket.serializeAttachment({ ...tag, registered: false } satisfies HostTag);
		closeQuietly(socket, code, reason);
		for (const client of this.clients()) {
			this.endClient(client.socket, client.tag, CLOSE.hostOffline, "host offline", false);
		}
	}

	private tellHost(sid: string): void {
		const host = this.registeredHost();
		if (host) sendQuietly(host, frame(FRAME_CLOSE, sid));
	}

	private hosts(): { socket: WebSocket; tag: HostTag }[] {
		return this.ctx
			.getWebSockets("host")
			.map((socket) => ({ socket, tag: socket.deserializeAttachment() as HostTag | null }))
			.filter((entry): entry is { socket: WebSocket; tag: HostTag } => entry.tag !== null && isOpen(entry.socket));
	}

	private registeredHost(): WebSocket | undefined {
		return this.hosts().find(({ tag }) => tag.registered)?.socket;
	}

	private clients(): { socket: WebSocket; tag: ClientTag }[] {
		return this.ctx
			.getWebSockets("client")
			.map((socket) => ({ socket, tag: socket.deserializeAttachment() as ClientTag | null }))
			.filter(
				(entry): entry is { socket: WebSocket; tag: ClientTag } =>
					entry.tag !== null && !entry.tag.ended && isOpen(entry.socket),
			);
	}
}

/** Accepts a WebSocket only to close it with a code the caller can read. */
function refuse(request: Request, code: number, reason: string): Response {
	const [client, server] = Object.values(new WebSocketPair());
	server.accept();
	server.close(code, reason);
	return upgraded(request, client);
}

function upgraded(request: Request, client: WebSocket): Response {
	const headers = new Headers();
	const offered = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((p) => p.trim());
	if (offered.includes(SUBPROTOCOL)) headers.set("Sec-WebSocket-Protocol", SUBPROTOCOL);
	return new Response(null, { status: 101, webSocket: client, headers });
}

// The ready state of a socket that can still send.
const OPEN = 1;

function isOpen(socket: WebSocket): boolean {
	return socket.readyState === OPEN;
}

function sendQuietly(socket: WebSocket, data: string | ArrayBuffer | Uint8Array): void {
	try {
		socket.send(data);
	} catch {
		// The socket closed under us. Its close handler cleans up.
	}
}

function closeQuietly(socket: WebSocket, code: number, reason: string): void {
	try {
		socket.close(code, reason.slice(0, 64));
	} catch {
		// Already closed.
	}
}

/** A relay frame: one type byte, an 8-byte session ID, then the payload. */
function frame(kind: number, sid: string, payload?: Uint8Array): Uint8Array {
	const out = new Uint8Array(RELAY_HEADER + (payload?.length ?? 0));
	const view = new DataView(out.buffer);
	view.setUint8(0, kind);
	view.setBigUint64(1, BigInt(sid));
	if (payload) out.set(payload, RELAY_HEADER);
	return out;
}

/**
 * A session ID. It is random, not a counter, because a counter would start
 * again after the object leaves memory while sessions are still open.
 */
function randomSessionId(): string {
	return new DataView(crypto.getRandomValues(new Uint8Array(8)).buffer).getBigUint64(0).toString();
}

/**
 * The key the address limits use. An IPv6 client is keyed by its /64,
 * because one subscriber holds the whole of it.
 */
function clientAddress(request: Request): string {
	const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
	if (!address.includes(":")) return address;
	const [head, tail = ""] = address.split("::");
	const left = head ? head.split(":") : [];
	const right = tail ? tail.split(":") : [];
	const groups = address.includes("::")
		? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right]
		: left;
	return (
		groups
			.slice(0, 4)
			.map((group) => (parseInt(group, 16) || 0).toString(16))
			.join(":") + "::/64"
	);
}

/** The host ID of a signing key, as `internal/identity` derives it. */
async function hostIdOf(publicKey: Uint8Array): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(utf8(HOST_ID_CONTEXT), publicKey)));
	return encodeBase32(digest.slice(0, 10));
}

function encodeBase32(bytes: Uint8Array): string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
	let out = "";
	let buffer = 0;
	let bits = 0;
	for (const byte of bytes) {
		buffer = (buffer << 8) | byte;
		bits += 8;
		while (bits >= 5) {
			bits -= 5;
			out += alphabet[(buffer >>> bits) & 31];
		}
	}
	if (bits > 0) out += alphabet[(buffer << (5 - bits)) & 31];
	return out;
}

function utf8(text: string): Uint8Array {
	return new TextEncoder().encode(text);
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
	const out = new Uint8Array(a.length + b.length);
	out.set(a);
	out.set(b, a.length);
	return out;
}

function encodeBase64(bytes: Uint8Array): string {
	return btoa(String.fromCharCode(...bytes));
}

function decodeBase64(text: string): Uint8Array | null {
	try {
		return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
	} catch {
		return null;
	}
}
