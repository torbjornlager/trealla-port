# Trealla private-pilot deployment

This bundle runs the native Trealla Web Prolog node as an unprivileged,
read-only, resource-limited container behind Caddy. Caddy is the only
published service: it terminates TLS, restricts routes, bounds HTTP header
handling, strips identity headers, and applies HTTP Basic authentication for
the invitation-only pilot.

The Trealla backend uses `auth(open)` only inside the isolated Docker network
so an authenticated browser can use the normal WebSocket protocol without
custom authorization headers. Starting that backend still requires the
explicit `WP_ACK_PUBLIC=yes` set in `compose.yaml`. Do not publish port 3060.

The deployment image builds Trealla with OpenSSL so actor code can use
`rpc/2-3` with HTTPS Web Prolog nodes. Caddy still terminates inbound TLS.
Trealla v3.12.6 does not verify client-side TLS hostnames completely
(UPSTREAM_REPORTS.md BUG-005), so production egress policy remains an
important independent boundary.

`WP_LOAD_URI_ORIGINS` enables exact public `src_uri/1` origins. Optional
`WP_LOAD_URI_ORIGIN_ALIASES` entries have the form
`https://public.example=http://trusted-service:port`; after validating the
public origin and resolved address, the fetch uses that explicit internal
endpoint while retaining the public Host header. This is intended for a
trusted deployment network behind its TLS terminator, not as a general proxy.

## Local smoke test

Run the complete build and proxy test:

```sh
./tools/deployment-smoke.sh
```

The test builds Trealla v3.12.6, starts both containers, checks health,
readiness, discovery metadata, JSON execution, a proxied WebSocket upgrade,
internal admin maintenance, and the post-maintenance 503 response, then
removes its containers and volumes.

## Configure a pilot

Copy the example without committing the result:

```sh
cp Deployment/.env.example Deployment/.env
docker run --rm caddy:2.8.4-alpine \
  caddy hash-password --plaintext 'choose-a-long-pilot-password'
```

Put the resulting hash in `PILOT_PASSWORD_HASH`, retaining the single quotes;
they prevent Compose from interpreting the hash's dollar signs. Generate a
separate random `WP_ADMIN_TOKEN` of at least 24 characters. For a real host
set all three URL values consistently, for example:

```dotenv
SITE_ADDRESS=https://trealla.example.org
PUBLIC_NODE_URL=https://trealla.example.org
BROWSER_ORIGIN=https://demonstrator.example.org
```

Then start and inspect it:

```sh
docker compose --env-file Deployment/.env \
  -f Deployment/compose.yaml up -d --build --wait
docker compose --env-file Deployment/.env \
  -f Deployment/compose.yaml logs -f
```

Caddy obtains and renews the public certificate when `SITE_ADDRESS` is an
HTTPS hostname whose DNS points at the host and ports 80/443 are reachable.
`PILOT_PORT`, `HTTP_PORT`, and `HTTPS_PORT` may override the host-side port
bindings without changing the container ports.

## Security boundary

- The default sandbox is `whitelist`; remote `src_uri/1` is disabled unless
  `WP_LOAD_URI_ORIGINS` is explicitly supplied.
- The node has bounded wall time, idle time, actors, results, text/frame
  sizes, request rates, and concurrency. Docker additionally bounds memory,
  CPU, and process count because Trealla has no per-thread stack or inference
  ceiling yet.
- The persistent `/state` volume contains token metadata and rotating audit
  logs. Back it up as sensitive operator data.
- Caddy Basic authentication is suitable for a small pilot, not a general
  identity system. Replace it with the demonstrator's SSO/forward-auth setup
  before broadening access.
- Public federation is disabled by design. Trusted proxy ranges cover only
  this bundle's private `/24`; Caddy strips all client-supplied Web Prolog
  identity headers.
- Administrative routes are deliberately not exposed by Caddy. Operators can
  enter maintenance mode with:

  ```sh
  docker compose --env-file Deployment/.env -f Deployment/compose.yaml \
    exec trealla /opt/trealla/tpl -g \
    "use_module('/app/Deployment/start_node.pl'),deployment_start:request_maintenance,halt"
  ```

## Graceful stop

The entrypoint catches SIGTERM/SIGINT, calls the authenticated maintenance
endpoint, waits `WP_DRAIN_GRACE_SECONDS`, and then terminates Trealla. During
the grace interval `/readyz` returns 503 and new `/call` and `/ws` work is
rejected while existing handlers may finish.
