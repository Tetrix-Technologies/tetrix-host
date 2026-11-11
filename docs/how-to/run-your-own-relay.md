# How to run your own relay

A relay passes sealed messages between a host and its paired devices. It holds no key that opens them. Run your own if you want no third party on the path, or if your network does not allow connections to Tetrix's relay.

A relay comes in two forms that speak the same protocol and pass the same tests. Use either.

| Form | Runs on | Choose it when |
|------|---------|----------------|
| `tetrix-host relay serve` | Any machine with a public address | You have a server and want everything on it |
| The Worker in `deploy/cloudflare` | Cloudflare Workers | You want no server to look after. Tetrix's own relay runs this way |

## Run the relay on Cloudflare

You need a Cloudflare account that holds a domain, and Node.js.

1. In `deploy/cloudflare/wrangler.jsonc`, change the route's `pattern` to a name in your own zone, such as `relay.example.com`.
2. Make an API token from the **Edit Cloudflare Workers** template, limited to your account and that zone.
3. Deploy.

	```sh
	cd deploy/cloudflare
	npm ci
	export CLOUDFLARE_API_TOKEN=<the token>
	export CLOUDFLARE_ACCOUNT_ID=<your account ID>
	npx wrangler deploy
	```

	The first deploy of a new Worker can stop with "This Worker does not exist on your account". Run the command again.

The deploy adds the name to your zone and issues its certificate. Then [check the relay](#check-the-relay) and [point a host at it](#point-a-host-at-the-relay).

The Worker keeps one Durable Object for each host ID, which holds that host's connection and its clients'. It limits how many connections one network address can open to a host, as the other form does. Its request logs are turned off in `wrangler.jsonc`, so that it keeps no record of which host a request named. Cloudflare, as the network, still sees addresses and sizes.

To test a change to the Worker before you deploy it, run it locally and aim the test suites at it:

```sh
cd deploy/cloudflare && npm run dev
TETRIX_HOST_TEST_RELAY=ws://127.0.0.1:18950 go test ./internal/relay
RELAY_URL=ws://127.0.0.1:18950 scripts/interop.sh
```

## Run the relay on your own server

You need a machine with a public address and a domain name that points at it.

### Start the relay

On the machine, [install the command](install.md) and start the relay.

```sh
tetrix-host relay serve --listen 127.0.0.1:8787
```

To limit how many hosts the relay serves, add `--max-hosts`.

```sh
tetrix-host relay serve --listen 127.0.0.1:8787 --max-hosts 10
```

The relay limits how many connections one network address can open to a host. Behind a reverse proxy, every client appears to come from the proxy's address, so tell the relay to read the address the proxy reports.

```sh
tetrix-host relay serve --listen 127.0.0.1:8787 --behind-proxy
```

Use `--behind-proxy` only when your own proxy is the only way to reach the relay's port. Without a proxy in front, a client could write any address it liked into the header.

To run the relay in a container, build the image from the repository root.

```sh
docker build -f deploy/relay/Dockerfile -t tetrix-host-relay .
docker run -d --restart unless-stopped -p 127.0.0.1:8787:8787 tetrix-host-relay
```

### Put TLS in front

The relay speaks plain WebSocket. The sealed channel does not depend on TLS for secrecy, but apps on iOS and macOS refuse a `ws://` address that is not on the local machine, and TLS hides the host ID from the network.

With [Caddy](https://caddyserver.com), this `Caddyfile` is enough. Caddy gets the certificate and passes WebSockets through.

```
relay.example.com {
	reverse_proxy 127.0.0.1:8787
}
```

Caddy adds each client's address to `X-Forwarded-For`, so start the relay with `--behind-proxy`.

If you use another proxy, make sure that it passes the `Upgrade` and `Connection` headers and that its idle timeout is longer than 30 seconds. The relay sends a ping every 25 seconds.

## Check the relay

```sh
curl https://relay.example.com/healthz
```

The answer is JSON with `"ok": true`. The server form also reports how many hosts are connected.

## Point a host at the relay

On each host, set the relay and check the tunnel.

```sh
tetrix-host tunnel relay wss://relay.example.com
tetrix-host doctor
```

`doctor` pairs a throwaway device through your relay and sends one request, so a pass means the whole path works.

A pairing link names its relay. A device that paired through the old relay still looks for the host there, so pair each device again.

To go back to the default relay:

```sh
tetrix-host tunnel relay default
```

## What the relay logs

The server form writes one line when a host connects and one when it disconnects, each with the host ID. It does not log client addresses or message contents, and it writes nothing to disk. Your proxy may log addresses. Check its settings.

The Worker writes nothing.
