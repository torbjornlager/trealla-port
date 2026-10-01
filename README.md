# Porting `library(actors)` (and friends) to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(currently tested on v3.12.6; earlier actor/RPC work was also tested on
v2.99.12, v2.99.6, and v2.97.13).

The port lives alongside this report:

| File                  | Role                                                |
|-----------------------|-----------------------------------------------------|
| `actors.pl`           | Actor runtime, local names, and published services  |
| `toplevel_actors.pl`  | Shell-style PTCP for paged goal execution           |
| `node.pl`             | HTTP server exposing `/call` for remote queries     |
| `auth_policy.pl`      | Authentication, authorization, and WS origin policy |
| `governance_policy.pl` | Per-principal rate and concurrency governance      |
| `observability.pl`    | Audit events, activity tracking, and metrics       |
| `node_tokens.pl`      | Hashed bearer issuance, revocation, and persistence |
| `crypto_portable.pl`  | OS randomness and portable SHA-256 fallback        |
| `source_policy.pl`    | Allowlisted, bounded `src_uri/1` fetching           |
| `ip_policy.pl`        | Client IP/CIDR, trusted-proxy, and auto-ban policy  |
| `rpc.pl`              | HTTP client wrapper (`rpc/2,3`) over `/call`        |
| `websocket.pl`        | Native RFC 6455 WebSocket client/server transport   |
| `web_prolog.pl`       | Trinity-compatible version-1 actor protocol         |
| `distribution.pl`     | Persistent remote-node client and `Pid@Node` routing |
| `websocket_tests.pl`  | Unit and Trealla/SWI interoperability tests         |
| `distribution_tests.pl` | Trealla/Trealla and Trealla/SWI node tests       |
| `swi_websocket_interop.pl` | SWI side of the interoperability tests        |
| `UPSTREAM_REPORTS.md`   | Candidate Trealla feature requests and bug reports |
| `CROSS_IMPLEMENTATION_LEDGER.md` | SWI/Trealla/GNU Prolog change tracking |
| `NOTICE.md`            | Source provenance and third-party attribution   |
| `Deployment/`          | Fail-closed Docker/Caddy private-pilot bundle   |
| `parallel.pl`         | `parallel/1` and `first_solution/2` demo client     |
| `tests.pl`            | Manual test suite (no plunit on Trealla)            |

`parallel.pl` is pure client code over the actors API and runs
unchanged on Trealla, so no separate Trealla variant is needed.

## Test results

All 97 manual tests pass on Trealla v3.12.6 (the original 30 also pass on
v2.99.6 and v2.99.12; t22 requires
`findnsols(count(N), ...)` + `nb_setarg/3`; the other 29 also
pass on v2.97.13).  Tests t23-t30 mirror behaviours from the
canonical SWI plunit suite in `simple-node/tests.pl`:

Run the isolated unit groups with:

```sh
TPL=/path/to/tpl ./tools/test.sh
```

To create a pinned repository-local Trealla v3.12.6 build without replacing a
system installation:

```sh
./tools/build-trealla.sh
TPL="$PWD/.build/trealla-v3.12.6/tpl" ./tools/test.sh all
```

The helper disables TLS by default; the automated matrix uses plain loopback
HTTP and WebSocket connections. Set `TREALLA_TLS=1` when the host OpenSSL
development files are available. Production TLS behavior must be tested with
that SSL-enabled build or, preferably for now, behind a terminating proxy.

The runner rejects executables that report `trealla(0,0,0,[])`, applies a
hard timeout to every fresh process, and keeps actor, toplevel, parallel, and
WebSocket state isolated. When the executable has a sibling `library/`
directory, the runner pins that directory too, preventing a local build from
silently loading an older system-wide Trealla library. Run the bidirectional
Trealla/SWI WebSocket and
protocol matrix with `./tools/test.sh interop`, or everything with
`./tools/test.sh all`. Set `SWIPL`, `TEST_TIMEOUT`, or `TEST_PORT_BASE` to
override their defaults.

For an invitation-only deployment, see [Deployment/README.md](Deployment/README.md).
The bundle pins Trealla v3.12.6, runs it unprivileged and read-only behind
Caddy, applies container resource limits, exposes only an authenticated route
allowlist, drains on shutdown, and has an end-to-end smoke test:

```sh
./tools/deployment-smoke.sh
```

| #  | Test                                       | Status |
|----|--------------------------------------------|--------|
|  1 | basic `receive` pattern match              | ok     |
|  2 | deferred (non-matching) message preserved  | ok     |
|  3 | `timeout(0)` poll / on_timeout fires       | ok     |
|  4 | guarded receive with `if`                  | ok     |
|  5 | `exit(Pid, kill)` + monitor `down` msg     | ok     |
|  6 | `exit(Pid, bye)` reason propagates         | ok     |
|  7 | `register/2` + named send                  | ok     |
|  8 | `parallel/1` success case                  | ok     |
|  9 | `parallel/1` failure propagates            | ok     |
| 10 | `first_solution/2` picks fastest           | ok     |
| 11 | `findnsols/4` non-deterministic batches    | ok     |
| 12 | `offset/2` skips N solutions               | ok     |
| 13 | `toplevel_spawn` + `toplevel_call`         | ok     |
| 14 | `toplevel_next` delivers second batch      | ok     |
| 15 | goal failure propagates as `failure/1`     | ok     |
| 16 | goal exception propagates as `error/2`     | ok     |
| 17 | `toplevel_stop` + session reuse            | ok     |
| 18 | `session(true)` loop handles two calls     | ok     |
| 19 | positive `timeout(T)` fires when idle      | ok     |
| 20 | message arrives before positive timeout    | ok     |
| 21 | deferred-list pruning across timed receives| ok     |
| 22 | mid-stream `limit(N)` change via toplevel_next/2 | ok |
| 23 | catch-all `_` receive clause binds default | ok |
| 24 | catch-all receive picks the only message   | ok |
| 25 | backtracking through a failed timed receive | ok |
| 26 | `whereis/2` returns `undefined` after exit | ok |
| 27 | toplevel `output/1` delivers `output/2` then success | ok |
| 28 | toplevel `input/2` + `respond/2` roundtrip | ok |
| 29 | `toplevel_abort/1` unwinds a runaway goal  | ok |
| 30 | `parallel/1` propagates an exception       | ok |
| 31 | descendants inherit their terminal target  | ok |
| 32 | stream-originated terminal output keeps its provenance | ok |
| 33 | concurrent `make_ref/1` calls are unique   | ok |
| 34–41 | private source isolation and cleanup    | ok |
| 42–46 | execution-profile enforcement           | ok |
| 47–56 | sandbox and public source policy        | ok |
| 57–62 | resource governance                     | ok |
| 63–68 | authentication and WebSocket origin policy | ok |
| 69–73 | per-principal rate and concurrency governance | ok |
| 74–79 | audit, runtime usage, and metrics observability | ok |
| 80–84 | persistent bearer-token lifecycle       | ok |
| 85–88, 93–94 | controlled source-URI and egress policy | ok |
| 89–92 | IP/CIDR and trusted-proxy policy          | ok |
| 95 | bounded node shutdown and connection cleanup   | ok |

All four demos from `parallel.pl` also run unchanged. The isolated suite and
the interoperability matrix exercise `node.pl` and `rpc.pl` automatically.

## Node lifecycle

`node/1-3` blocks while serving, as before. A control thread can now stop a
listener and its active clients with `node:stop_node/1`; the two-argument form
accepts a bounded drain timeout:

```prolog
?- node:stop_node(3060, [timeout(10)]).
```

Shutdown first prevents new work, closes every tracked client stream, wakes
the blocked accept loop, and waits for detached connection handlers to run
their normal cleanup. `node_running/1` and `node_connection_count/2` expose
the lifecycle state. If handlers have not drained before the deadline,
`stop_node/2` raises `resource_error(node_shutdown_timeout(Port, Count))`;
it does not use forced thread interruption.

## Native WebSocket transport

`websocket.pl` is a plain Trealla Prolog implementation of the RFC 6455
opening handshake and wire protocol. It has no Logtalk or foreign-code
dependency. The client and standalone server have been tested in both
directions against SWI-Prolog 10.1.3 using text (including Unicode), binary
messages, 16-bit and 64-bit payload lengths, masking, and the closing
handshake.

The API mirrors the useful subset of SWI's WebSocket library:

```prolog
http_open_websocket('ws://localhost:8080/echo', WS, []),
ws_send(WS, text(hello)),
ws_receive(WS, Reply),
ws_close(WS, 1000, done).
```

Messages are represented as `text(Atom)`, `binary(Bytes)`, `ping(Bytes)`,
`pong(Bytes)`, and `close(Code, Reason)`. Incoming ping frames are answered
automatically. Fragmented messages are reassembled. Incoming payloads default
to a 16 MiB limit, configurable with `max_payload_length(Bytes)`.

For a concurrent standalone server, define a handler that accepts a WebSocket
and the requested path:

```prolog
echo(WS, '/echo') :-
    ws_receive(WS, Message),
    ( Message = close(Code, Reason) ->
        ws_send(WS, close(Code, Reason))
    ; ws_send(WS, Message),
      echo(WS, '/echo')
    ).

?- websocket_server(8080, echo).
```

`websocket_server/2` accepts continuously in the calling thread and dispatches
each connection to a detached handler thread. For programmatic lifecycle
control, `websocket_server_start(Port, Handler, Server)` returns immediately
and `websocket_server_stop(Server)` stops and joins the listener. Existing
connection handlers are allowed to finish independently.

Run the unit tests on Trealla:

```sh
tpl -g "consult(websocket_tests),websocket_tests,halt"
```

For a Trealla client against an SWI server, start the server:

```sh
swipl -q -s swi_websocket_interop.pl -g "server(38765)"
```

Then run:

```sh
tpl -g "consult(websocket_tests),trealla_client_test(38765),halt"
```

For the reverse direction, start the one-shot Trealla server:

```sh
tpl -g "consult(websocket_tests),trealla_server_once(38766),halt"
```

Then run the SWI client:

```sh
swipl -q -s swi_websocket_interop.pl -g "client_test(38766),halt"
```

The concurrent server stress/interoperability test uses eight simultaneous SWI
clients:

```sh
tpl -g "consult(websocket_tests),trealla_concurrent_server(38767,8),halt"
```

In another terminal:

```sh
swipl -q -s swi_websocket_interop.pl \
  -g "concurrent_client_test(38767,8),halt"
```

The node can expose HTTP RPC and WebSocket traffic on one port:

```prolog
node_ws(WS, '/ws') :-
    ws_receive(WS, Message),
    ws_send(WS, Message),
    node_ws(WS, '/ws').

?- node(3060, node_ws).
```

Clients can then use `http://localhost:3060/call?...` and
`ws://localhost:3060/ws` concurrently. The handoff uses `ws_accept/3`, which
validates the already-parsed upgrade headers, sends the HTTP 101 response, and
returns the WebSocket handle without closing the stream.

`wss://` is supported natively when Trealla was built with OpenSSL.  A secure
node uses the same handler and adds socket options:

```prolog
?- web_prolog_node(3060,
       [ssl(true), keyfile('key.pem'), certfile('cert.pem')]).
```

The client selects TLS from the URL automatically.  Trealla 3.12.6 encrypts a
connection opened without `certfile/1`, but its socket layer does not verify
the peer in that mode.  Passing `certfile/1` enables the verification path but
the current Trealla implementation does not perform hostname verification.
Production deployments should terminate TLS in a well-configured proxy until
Trealla's client verification is complete.

The transport also implements optional RFC 6455 subprotocol negotiation.
Web Prolog does **not** request a WebSocket subprotocol: Trinity version 1 is
announced with `X-Web-Prolog-Protocol: 1` and its JSON command vocabulary.
Extensions such as `permessage-deflate` remain unsupported.

## Native Web Prolog protocol

`web_prolog.pl` implements the protocol specified by the Trinity demonstrator
in `prolog/web_prolog/node_ws.pl`, `remote_protocol.pl`, and
`docs/CROSS_NODE_ARCHITECTURE.md`.  It is native Trealla code and uses no
Logtalk.  Start an HTTP `/call` endpoint and Web Prolog `/ws` endpoint on one
port with:

```prolog
?- use_module(web_prolog), web_prolog_node(3060).
```

The node accepts the same profile names as Trinity: `relation`, `isobase`,
`isotope`, `actor`, and the unrestricted development profile `workbench`
(the default). Historical `stateless` and `session` names are accepted as
aliases for `isobase` and `isotope`:

```prolog
?- web_prolog_node(3060, [profile(actor)]).
```

Profiles are enforced at the request boundary. `/call` has an ISObase ceiling
and `/ws` has an ACTOR ceiling; consequently an ISObase node returns HTTP 403
for `/ws`, while ACTOR-only goals submitted to `/call` are rejected even on a
workbench node. RELATION nodes additionally require an explicit allowlist of
advertised query patterns. A conjunction is accepted only when every conjunct
matches one of those patterns:

```prolog
?- web_prolog_node(3060,
        [profile(relation), relations([edge/2, status(ok)])]).
```

The node also accepts `sandbox(off|blacklist|whitelist)`. The default is
`blacklist`; historical `on`, `demo`, and `strict` values select the more
conservative whitelist:

```prolog
?- web_prolog_node(3060,
       [profile(actor), sandbox(blacklist)]).
```

Blacklist mode rejects ambient stream/filesystem access, process execution,
network creation, module/native-code loading, thread primitives, runtime
reflection, parser mutation, and foreign module qualification. Opaque
meta-calls and dynamically asserted clause bodies are rewritten through
runtime guards, so constructing a forbidden goal in a variable does not evade
the initial walk. Whitelist mode additionally admits only a conservative
catalog of pure predicates, actor operations, and predicates defined in the
submitted source. `sandbox(off)` is intended only for trusted development.

Public `src_text/1` and `src_list/1` inputs are parsed, checked, rewritten, and
then loaded as actor-private terms. Unsafe directives, qualified/reserved
clause heads, and source-level expansion hooks are rejected. Direct public
`src_predicates/1` must be materialized by the sending node, as the Trealla
distribution layer does. `src_uri/1` is denied by default and becomes
available only when the operator configures an exact origin allowlist. Nested
remote spawn is currently restricted to loopback node URLs in sandbox mode.

Remote source uses the same profile and sandbox validation as inline source:
the response is fetched first, parsed into terms, checked and rewritten, and
only then installed in the actor-private namespace. Every redirect target is
checked before connecting, response bodies are streamed under
`max_source_text_bytes/1`, and URI, response-header, redirect-count, and
wall-time limits are independent of the remote server. Only absolute HTTP(S)
source URIs are accepted; local files and credentials in URI authorities are
not.

```prolog
?- web_prolog_node(3060,
       [ load_uri_allowed_origins(
             ['http://127.0.0.1:8080']),
         load_uri_allowed_ip_ranges(['127.0.0.0/8']),
         source_fetch_timeout(10),
         max_source_redirects(5)
       ]).
```

Every source host is resolved once, checked, and then contacted at that same
numeric address, closing the DNS-rebinding interval between authorization and
connection. Without `load_uri_allowed_ip_ranges/1`, only public IPv4 and IPv6
global-unicast destinations are accepted. Supplying the option replaces that
default with an explicit exact-address/IPv4-CIDR allowlist; the example
therefore deliberately permits its loopback source server. Redirect targets
go through the same resolution and address policy.

Trealla v3.12.6 does not verify TLS host names. For that reason HTTPS source
fetching fails even for an allowlisted origin unless the operator also sets
`allow_unverified_https(true)`. That switch acknowledges the limitation; it
does not provide server authentication. A hostname-verifying reverse proxy is
the recommended deployment boundary. Because Trealla cannot yet separate a
socket's numeric connection address from its TLS server name, the pinned
address is also used as SNI; HTTPS sites requiring name-based SNI may need that
proxy (FR-009 in `UPSTREAM_REPORTS.md`). The operating system or container
should still enforce an independent egress boundary as defense in depth.

Public nodes also install resource ceilings. They are configured with these
startup options (defaults shown):

```prolog
?- web_prolog_node(3060,
       [ time_limit(300), idle_limit(300),
         max_actors(256), max_solutions(1000),
         max_term_text_bytes(32768),
         max_source_text_bytes(262144),
         max_ws_frame_bytes(262144)
       ]).
```

`time_limit/1` bounds one HTTP producer or PTCP call; `idle_limit/1` reclaims
an inactive PTCP in either waiting state. Client-supplied PTCP limits and page
sizes may make the owner limits tighter but cannot raise them. The actor limit
is admitted atomically and its slot is reclaimed in actor cleanup. Textual
goals/templates, source options, and WebSocket payloads are checked before
parsing or loading, and the node clamps the WebSocket transport's own payload
limit as well.

Trealla's reusable timer currently spans a PTCP call including time suspended
between result pages; the separate idle ceiling can be lower. Trealla v3.12.6
does not expose SWI-equivalent inference or per-thread stack ceilings, so
process memory/CPU containment remains the deployment boundary for those
resources.

Authentication is configured independently of profiles and sandboxing.  Open
mode remains the compatibility default; private mode requires an authenticated
principal for both `/call` and `/ws`; development mode grants its development
principal only to a direct loopback TCP peer:

```prolog
?- web_prolog_node(3060,
       [ auth(private),
         bearer_token(alice, 'replace-with-a-secret', [execute]),
         ws_allowed_origins(['https://portal.example.org'])
       ]).
```

The static `bearer_token(Id, Token, Capabilities)` form remains useful as a
bootstrap credential, but is kept as plaintext in process memory. The managed
token store provides the Trinity lifecycle: 64-bit public ids, one-time
192-bit secrets, salted SHA-256 hashes at rest, expiry, revocation,
last-used timestamps, secret-free listings, and atomic persistence. Enable
persistence with `tokens_file/1` (also accepted as `token_store_file/1`):

```prolog
?- web_prolog_node(3060,
       [ auth(private),
         bearer_token(bootstrap, 'replace-with-a-secret', [admin]),
         tokens_file('state/tokens.pl')
       ]).
```

The parent directory must exist. The store uses the same portable `token/8`
terms as the SWI implementation and never contains the presented secret.
Managed tokens are tried before static credentials. Administrative operations
require an authenticated `admin` principal:

- `GET /admin/tokens` lists metadata without hashes or secrets.
- `POST /admin/tokens` accepts JSON containing `principal`, optional
  `capabilities` (default `["execute"]`), `expires_in`, and `label`. The full
  bearer token appears once in this response.
- `DELETE /admin/tokens?id=<public-id>` revokes a token while retaining its
  audit metadata.

Trealla's current `crypto_n_random_bytes/2` is not cryptographically secure,
so this layer deliberately reads the macOS/Linux OS CSPRNG and fails closed if
it is unavailable. SHA-256 uses Trealla's OpenSSL primitive when present and a
portable implementation otherwise. Tokens must still be transported only over
TLS and kept out of shell history and logs. A bearer can be used by the
explicit distribution API:

```prolog
?- remote_node_open('wss://node.example.org/ws', Node,
       [header('Authorization', 'Bearer replace-with-a-secret')]).
```

For reverse-proxy and node-to-node deployments, `principal(Id, Capabilities)`
and `authenticated_default_capabilities(Capabilities)` configure trusted
identity-header policy. `X-Web-Prolog-User` and
`X-Web-Prolog-Capabilities` are honoured only when the immediate TCP peer is
listed explicitly in `trusted_proxy_ranges/1`. Operators must ensure each
listed peer is a header-stripping authenticating proxy or trusted node. The
distribution client's existing `node:trealla`/`internal_transport` headers
work without changing the wire protocol once the receiving node trusts the
sending node's address range.

Incoming execution routes also have an independent IP policy. Both lists are
empty by default, which preserves open behavior. The blocklist takes
precedence; when the allowlist is non-empty, every address outside it is
denied. CIDR matching is available for IPv4, while IPv4 and IPv6 may both be
matched exactly:

```prolog
?- web_prolog_node(3060,
       [ ip_allowlist(['10.0.0.0/8', '192.168.0.0/16']),
         ip_blocklist(['10.23.4.9']),
         trusted_proxy_ranges(['127.0.0.0/8']),
         auto_ban_threshold(5),
         auto_ban_window_seconds(60),
         auto_ban_seconds(900)
       ]).
```

`X-Forwarded-For` and `X-Forwarded-Proto` are ignored unless the immediate
peer matches `trusted_proxy_ranges/1`; the rightmost forwarded address is
used. Repeated HTTP or WebSocket rate-limit violations can trigger a temporary
ban. Explicitly allowlisted clients are exempt from automatic bans. Metrics
remain public, but the IP gate covers `/call` and the `/ws` upgrade.

The node binds to the IPv4 wildcard `0.0.0.0` by default. This avoids a
Trealla v3.12.6 peer-address bug on dual-stack IPv6 wildcard listeners
(BUG-013 in `UPSTREAM_REPORTS.md`). Use `bind_address(Address)` to restrict
the listener to a specific IPv4 interface.

WebSocket requests without an `Origin` header remain available to native
clients. Browser requests must be same-origin with the request `Host`, or
their normalized origin must appear in `ws_allowed_origins/1`. This prevents
an unrelated web page from driving the actor endpoint even when the node is
otherwise open.

Per-principal abuse controls are configured independently. Defaults match the
initial Trinity policy:

```prolog
?- web_prolog_node(3060,
       [ rate_window_seconds(60),
         max_call_requests_per_window(500),
         max_session_spawns_per_window(100),
         max_ws_commands_per_window(1000),
         max_inflight_calls(4),
         max_ws_actors_per_principal(16)
       ]).
```

Counts are shared by all connections authenticated as the same principal.
`admin` and `internal_transport` principals are exempt from these
per-principal limits, but remain subject to the node's absolute resource
ceilings. Anonymous HTTP callers are bucketed by their resolved client address;
anonymous WebSockets get separate connection identities. Consequently a
reverse proxy should be explicitly trusted so forwarded client addresses are
available, and should authenticate callers when stable principal quotas are
required. Limits accept `unlimited` as an explicit opt-out. Rate violations
return HTTP 429 (or a WebSocket `error` event), while actor capacity is
reclaimed when the actor exits or its owning connection closes.

Operational observability is available on two additional HTTP routes:

- `GET /metrics` returns aggregate Prometheus text exposition without
  authentication. It deliberately excludes principal identities and event
  contents.
- `GET /admin/runtime` returns JSON containing current counters, detailed
  per-principal rate/capacity usage, active connection and actor counts, and
  the bounded recent audit-event window. It also reports the active resource,
  source-egress, IP, and governance policies. It requires an authenticated
  principal with the `admin` capability.

The in-memory audit window defaults to 500 events. An optional append-only,
rotating JSONL audit file can be enabled at startup:

```prolog
?- web_prolog_node(3060,
       [ log_capacity(500),
         audit_log_file('logs/node-audit.jsonl'),
         max_audit_log_bytes(10485760),
         max_audit_log_backups(5)
       ]).
```

The audit file's parent directory must already exist. Set
`max_audit_log_bytes(unlimited)` to disable rotation or leave
`audit_log_file/1` unset to disable durable logging. Audit records contain
principal identity, transport, operation, outcome, duration, and normalized
errors; goals, source text, headers, tokens, and actor-message payloads are
not recorded.

For startup-option portability, the SWI names `interaction_log_file/1`,
`max_interaction_log_bytes/1`, and `max_interaction_log_backups/1` are accepted
as aliases for the corresponding `audit_*` options.

The optional `transport_welcome` event advertises the configured profile and
sandbox in additive `profile` and `sandbox` fields. Authentication is enforced
before an HTTP call or WebSocket upgrade. These Prolog-level checks are defense
in depth, not a host security boundary: public deployment still requires TLS,
careful identity configuration, and OS/container isolation.

Protocol version 1 uses one JSON object per text frame.  The port accepts the
core actor commands `spawn`, `send`, `monitor`, `demonitor`, and `exit`, plus
`toplevel_spawn`, `toplevel_call`, `toplevel_next`, `toplevel_stop`,
`toplevel_abort`, `toplevel_halt`, `toplevel_respond`, and the private
node-to-node `io_request` command.  It emits Trinity's
`spawned`, `success`, `failure`, `error`, `output`, `prompt`, `down`, `stop`,
`abort`, `responded`, and `halted` events.  The optional version-1
`transport_hello` / `transport_welcome` exchange is also implemented,
including connection-scoped browser/local PID capabilities and
`actor_message` return traffic, plus acknowledged `io_reply` terminal traffic.

A browser that sends `"io_ack":true` in `transport_hello` receives each
terminal write in an `io_request` envelope.  It accepts the nested `output`
event into its terminal before replying on the same connection:

```json
{"type":"io_request", "request_id":"browser-42",
 "event":{"type":"output", "pid":1, "data":"hello"}}
{"command":"browser_io_reply", "request_id":"browser-42", "status":"ok"}
```

The writer remains blocked until that reply.  Prompts retain their ordinary
`prompt` event shape; the receiving connection gets one authorization to send
`toplevel_respond` for a remote prompt source.  Closing the connection wakes
blocked writers with an I/O error and revokes its pending prompt and
distributed terminal capabilities.

The canonical toplevel call keeps terms in strings and shares variables by
parsing `goal` and `options` together:

```json
{"command":"toplevel_call", "pid":1,
 "goal":"member(X,[a,b,c])", "options":"[template(X),limit(2)]"}
```

Trealla allocates integer wire PIDs, matching the Trinity
protocol even though current Trealla thread handles are opaque terms.  A
dedicated relay actor is the only WebSocket writer, while the connection
reader remains free to accept `next`, `stop`, and `abort` during execution.
Actors and sessions owned by a connection are terminated when it closes.
Every PID-bearing control command also resolves the PID through that
connection's relay, so a second authenticated connection cannot send to,
monitor, exit, stop, abort, respond to, or halt another connection's actors or
sessions. Published services are the deliberate exception: their names form a
separate explicitly published routing surface.

The native layer now has profile, sandbox, resource, authentication, origin,
per-principal rate/concurrency, connection-ownership enforcement, aggregate
metrics, bounded audit logging, JSON `/call` replies, and the core operational
routes (`/healthz`, `/readyz`, `/version`, `/node_info`, and
`/admin/maintenance`). The
larger SWI administration and browser UI surface remains outside this native
core. Do not expose goal
execution directly to an untrusted network without TLS and OS-level
containment.

### Persistent remote nodes

`distribution.pl` adds the client-side distribution layer.  Each
remote node uses one persistent WebSocket with separate reader and writer
actors.  A node-manager thread caches connections and maps canonical
`Pid@Node` values to their writer.  The writer serializes frames and spawn
replies; the reader routes events to the local actors that own monitors.

Loading `distribution.pl` installs transparent routing hooks in `actors.pl`.
Ordinary actor syntax can therefore target a remote node:

```prolog
?- use_module(distribution),
   spawn(receive({hello -> true}), Pid,
         [node('http://other-node:3060'), monitor(true)]),
   Pid ! hello,
   receive({down(Pid, Pid, true) -> true}).
```

The same `Pid@Node` value works with `!/2`, `exit/2`, `monitor/2`, and
`demonitor/1-2`. Cross-node links default to `true`, so termination of a
local parent propagates an exit to its remote children. Multiple local
actors may independently monitor one remote PID; the connection-owned
wire notification is fanned out as one `down/3` per local monitor.

Node-wide services use a separate publication registry.  The server publishes
a live local actor with `register_service/2`; clients address it as
`Name@Node`:

```prolog
echo_service :-
    receive({echo(From, Msg) -> From ! echo(Msg), echo_service}).

?- spawn(echo_service, Echo, [link(false)]),
   register_service(echo, Echo).

?- self(Self),
   Service = echo@'http://other-node:3060',
   Service ! echo(Self, hello),
   receive({echo(hello) -> true}).
```

`unregister_service/1` withdraws a publication and `whereis_service/2`
inspects the local service registry.  Service publication is independent of
ordinary `register/2` names and of individual WebSocket connections.

Local actor PIDs embedded in remote goals or messages are exported as
connection-scoped `Id@localhost` capabilities.  A remote Trealla or SWI actor
can therefore reply with ordinary actor syntax over the same WebSocket:

```prolog
?- self(Self),
   spawn(receive({ping(From) -> From ! pong}), Pid,
         [node('http://other-node:3060'), monitor(true)]),
   Pid ! ping(Self),
   receive({pong -> true}).
```

The numeric capability is meaningful only on the connection that issued it;
the remote peer never sees Trealla's opaque native thread handle.

Actors spawned from a terminal lineage also inherit an opaque
`'$io_endpoint'(Token)@HomeNode` capability.  `terminal_output/1-2` and
`input/2-3` use this endpoint across nodes.  Each remote terminal message has
a UUID request ID; the sending actor waits for `io_reply` before continuing,
so a later actor message cannot overtake output already accepted by the home
terminal mailbox.  Prompt source PIDs are exported as connection-scoped return
capabilities, allowing `respond/2` to reach the prompting actor.

The home node URL defaults to `http://127.0.0.1:Port`.  Set the externally
reachable address when starting a node that other machines must call back:

```prolog
?- use_module(distribution),
   web_prolog:web_prolog_node(3060,
       [node_url('https://prolog.example.org')]).
```

The explicit connection API remains available when connection lifetime must
be controlled directly:

```prolog
?- use_module(distribution),
   remote_node_open('ws://other-node:3060/ws', Node),
   remote_toplevel_spawn(Node, Pid, [session(true)]),
   remote_toplevel_call(Node, Pid, member(X,[a,b,c]),
                        [template(X),limit(2)]),
   receive({success(Pid, Rows, More) -> true}).
Pid = 1@'ws://other-node:3060/ws',
Rows = [a,b],
More = true.
```

The API provides `remote_spawn/4`, `remote_send/3`, `remote_exit/3`, remote
monitor operations, and the complete remote `toplevel_*` control family.
Goal and template variables are numbered together before transmission, so
variable sharing survives the two JSON string fields.  Events that race with
spawn registration are buffered and replayed after the remote PID is known.
Connection loss generates `down(Pid,Pid,connection_closed)` for live remote
targets.

Manager-cached transparent connections reconnect lazily on the next remote
spawn or `Name@Node` send.  Connection retirement is generation-aware: a late
close from an old socket cannot remove its replacement.  Published services
therefore remain reachable after reconnection.  Spawned remote actors are
connection-owned on both Trealla and Trinity, so their `down/3` notification
is terminal and reconnection deliberately does not resurrect their old PIDs.
`remote_drop_connection/1` is provided for controlled failover and testing.

The outbound connection identifies itself with protocol version 1 plus the
Trinity node headers `X-Web-Prolog-User` and
`X-Web-Prolog-Capabilities`. The receiving node must explicitly include the
sending peer in `trusted_proxy_ranges/1` before those headers grant authority;
the defaults can be replaced with explicit `header/2` options.

## What is supported

### actors.pl

- `spawn/1-3` with `monitor(Bool)` and `link(Bool)` options
- Per-actor source namespaces with `src_text(Text)`, `src_list(Terms)`, and
  `src_predicates(PIs)`; the same options work across Trealla distribution
- `self/1`, `(!)/2`
- `receive/1-2` with patterns, guards (`Pattern if Guard -> Body`),
  `timeout(0)` polling, and positive `timeout(T)` deadlines
- `monitor/2`, `demonitor/1-2`
- `register/2`, `unregister/1`, `whereis/2`
- `exit/1`, `exit/2`
- `output/1-2`, `input/2-3`, `respond/2`
- `terminal_output/1-2` with local descendant inheritance
- `input/2-3` inherits the same terminal target
- `make_ref/1` with process-lifetime uniqueness, `flush/0`
- Links 
- Deferred-message semantics (non-matching messages stay in the
  mailbox in arrival order)

### toplevel_actors.pl

- `toplevel_spawn/1-2` — create a PTCP (Prolog Toplevel Control Process)
- `toplevel_call/2-3` — run a goal inside the PTCP; answer arrives as
  `success(Pid,Slice,More)`, `failure(Pid)`, or `error(Pid,Error)`
- `toplevel_next/1-2` — request the next batch of solutions
- `toplevel_stop/1` — discard remaining solutions; return PTCP to idle
- `toplevel_abort/1` — abort a running goal; restart PTCP in idle state
- `offset/2` — skip the first N solutions of a goal (re-exported from
  Trealla's built-in for convenience)
- `toplevel_next/2` with `limit(NewLimit)` — mid-stream limit change
  is now honoured (Trealla v2.99.6+), via a mutable `count/1` cell
  driven by `nb_setarg/3`
- Spawn-time private sources through the same `src_text/1`, `src_list/1`, and
  `src_predicates/1` options as ordinary actors

### node.pl

- `node/1` — start an HTTP server on a port
- `node/2` — serve `/call` and a `/ws` WebSocket endpoint on the same port;
  each connection runs in its own detached thread
- `GET /call?goal=…&template=…&offset=…&limit=…&format=prolog`
  with URL percent-encoded Prolog terms; returns one of
  `success(Slice, More).`, `failure.`, or `error(E).`
- `format=json` with Trinity-compatible named binding objects; as in the SWI
  implementation, JSON mode derives visible names from the goal and ignores
  the explicit template
- Unauthenticated `/healthz`, `/readyz`, `/version`, and `/node_info`
  operational routes
- Admin-protected `GET|POST /admin/maintenance`; maintenance makes readiness
  return 503 and refuses new `/call` and `/ws` work without aborting in-flight
  handlers
- Producer-actor caching: a paused actor preserves its WAM stack
  (including all open choicepoints) across HTTP requests, so paged
  queries resume from where the previous request left off
- Bounded FIFO cache (`cache_size/1`, default 100); oldest entry
  evicted on overflow
- N+1 lookahead probe to compute `More=true|false` without wasting
  a solution

### rpc.pl

- `rpc/2,3` — call a goal on a remote node; solutions are yielded one
  by one on backtracking, with automatic page fetching when the node
  reports `More=true`
- `limit(N)` option to control page size
- Remaining `http_open/3` options such as `timeout/1` and
  `request_header/1` are passed through to the transport

```prolog
?- rpc('http://localhost:3060', member(X, [a,b,c])).
X = a ; X = b ; X = c.
```

## Remaining limitations

### toplevel_actors.pl

- Mid-enumeration `limit(N)` and `target(P)` changes are supported. Because
  Trealla's public `call_with_time_limit/2` commits to the first solution, the
  port uses a reusable runtime timer around the complete pageable call;
  `time_limit/1` therefore includes time suspended between pages.

### web_prolog.pl

- Core version-1 wire compatibility and source-bearing actor/toplevel spawns
  now include execution-profile enforcement and native Trealla blacklist and
  whitelist sandbox modes plus wall-time, idle, actor-count, page-size, and
  textual-input ceilings, authentication, WebSocket origin checks, and
  connection ownership, plus per-principal rate/concurrency and IP/CIDR
  access limits with explicit trusted-proxy handling.
  A Docker/Caddy boundary for an invitation-only pilot is provided under
  `Deployment/`. `src_uri/1` has an exact-origin, redirect-aware, size- and
  time-bounded fetch policy plus resolve-check-connect IP pinning.
  OS/container egress policy remains recommended as an independent boundary.
- A TLS-enabled Trealla client currently lacks complete hostname-verified
  certificate validation in the underlying socket implementation.

### distribution.pl

- Node-to-node terminal endpoint inheritance, output acknowledgement, and
  prompt responses are implemented. Browser-terminal second-stage
  acknowledgement (`browser_io_reply`) and connection-scoped, one-shot prompt
  authorization are also implemented when the browser negotiates
  `io_ack:true`.

### rpc.pl

- Trealla's HTTP library recognizes `https://` when the runtime is built with
  OpenSSL. The repository's convenience build uses `NOSSL=1`, so use an
  SSL-enabled runtime or terminate TLS at a reverse proxy. TLS-disabled builds
  currently report the missing feature as `resource_error(memory)` (BUG-015),
  while SSL-enabled clients still lack hostname verification (BUG-005).

## License and attribution

This project is distributed under the [MIT License](LICENSE). Source
provenance, runtime licenses, and development acknowledgements are recorded in
[NOTICE.md](NOTICE.md). Trealla Prolog and SWI-Prolog are external dependencies
and are not vendored in this repository.

## Portability deltas

These are the places where the port deviates from the canonical
`simple-node/` SWI sources, with one entry per surviving deviation
in the code today.

### `actors.pl`

#### 1. No `thread_local/1`

Trealla has no `thread_local/1` directive. Per-thread state (the
deferred message list and the parent PID) is stored on the
thread-local blackboard via `bb_put/2` and `bb_get/2`:

```prolog
deferred_list(L) :-
    (bb_get('$actor_deferred', L) -> true ; L = []).

deferred_put(L) :-
    bb_put('$actor_deferred', L).
```

The blackboard values used here are thread-scoped.  The parent-pointer code
also retains an explicit thread ID in its key, making that ownership visible
and keeping compatibility with older implementations:

```prolog
set_parent(Parent) :-
    thread_self(Me),
    format(atom(Key), '$actor_parent_~w', [Me]),
    bb_put(Key, Parent).
```

#### 2. `thread_detach/1` in `at_exit` hangs

Calling `thread_detach/1` inside the `at_exit` hook never returns
on Trealla. Threads are therefore created with `detached(true)` up
front, and the `at_exit` hook does not call `thread_detach/1`.

#### 3. `thread_property` status is `running` inside `at_exit`

In SWI, the `at_exit` hook can read the thread's final outcome
from `thread_property(Me, status(...))`. On Trealla the status is
still `running` when the hook fires. The `start/4` wrapper records
the outcome explicitly into a `exit_reason/2` fact, which the
`stop/2` hook then retracts to build the `down/3` message:

```prolog
catch(
    ( call(Goal)
    ->  assertz(exit_reason(Pid, true))
    ;   assertz(exit_reason(Pid, false))
    ),
    E,
    ( E == actor_exit
    ->  true
    ;   assertz(exit_reason(Pid, exception(E)))
    )
).
```

#### 4. `output/1-2`, `input/2-3`, `respond/2` are added explicitly

These predicates exist in the canonical `simple-node/actors.pl`
but were missing from the very first Trealla port. They are now
implemented here on top of the per-thread parent pointer described
in delta #1.

#### 5. Private modules are emptied rather than destroyed

Trealla has no public temporary-module destruction operation. `isolation.pl`
creates a unique module for each actor, dynamically installs source clauses,
and retracts those clauses when the actor terminates. The empty bootstrap
module remains in Trealla's module table until process exit. `src_predicates/1`
also needs a serialized `listing/1` workaround because module-qualified
listing does not currently inspect the requested module (tracked in
[UPSTREAM_REPORTS.md](UPSTREAM_REPORTS.md)).

### `toplevel_actors.pl`

#### 1. Mutable `count(N)` cell must share a catch frame with `findnsols/4`

The SWI implementation can build the `count/1` cell at the top of
the state machine and mutate it from any nested predicate.  In
Trealla v2.99.6, `findnsols(count(N), ...)` and `nb_setarg(1, count, ...)`
work together only when the `count/1` cell is constructed in the
*same* catch frame as the `findnsols/4` call (a heap-context
quirk).  The port therefore consolidates the entire paged
enumeration into a single `run_call/6` predicate that allocates
`Count`, runs `findnsols/4`, and performs `nb_setarg/3` (in
`page/2`) all inside one `catch/3`.

### `node.pl`

#### 1. Direct socket server enables protocol handoff

The node uses `library(sockets)` directly. It parses the HTTP request once,
serves `/call` normally, or passes the same open stream to `ws_accept/3` for
`/ws`. This avoids the standard HTTP server's unconditional
`Content-Length`, `Connection: close`, and socket close behavior. Query
parameters are parsed with a small percent-decoder (`url_decode/2`).

#### 2. `library(settings)` absent

Defaults that would be `setting/1` declarations in SWI are plain
facts (e.g. `cache_size(100).`).

#### 3. `predicate_property(_, number_of_clauses(N))` absent

The cache size check uses `findall/3` over the cache facts and
`length/2` instead of querying the clause count directly.

#### 4. Producer-actor caching exploits a Trealla guarantee

Trealla's `receive/1` blocks the OS thread while preserving the
**complete WAM stack**, including every open choicepoint. That is
exactly what makes the suspended-producer cache work across HTTP
requests: the producer actor pauses inside `receive({...})` after
each solution, and on resume backtracks naturally for the next
page. The same pattern would need extra machinery on
implementations where a paused thread does not own a stack
snapshot.

#### 5. No `receive/2` timeout needed for producer replies

`compute_answer/5` uses unconditional `receive/1` rather than a
timed receive: the producer is a local actor we just spawned (or
just resumed via `'$request'`), so a reply is guaranteed and a
timeout would only obscure real bugs.

### `rpc.pl`

#### 1. `http_open/3` is committed with `once/1`

Trealla v3.12.6's `http_open/3` leaves internal socket-opening choicepoints.
The RPC client commits to the successful connection with `once/1`, preventing
those internals from being revisited when RPC answers are yielded on
backtracking. URLs are passed directly to the public API; the removed private
`'$parse_url'/2` predicate is no longer used.

#### 2. URL percent-encoding is hand-rolled

There is no `uri_encoded/3` or `www_form_encode/2` in Trealla's
stdlib, so `url_encode/2` is implemented inline alongside
`url_decode/2`, following RFC 3986's unreserved-character set.

## Overall assessment

The actor/RPC modules are ported and exercised through Trealla v3.12.6
(all 30 actor tests pass on the current version):

- **`actors.pl`** — feature-complete, including positive `receive`
  timeouts via the native `thread_get_message/3` `timeout(Float)`
  option.
- **`toplevel_actors.pl`** — paged enumeration uses Trealla's
  built-in lazy `findnsols/4`.  As of v2.99.6 the mid-enumeration
  `limit(N)` / `target(P)` change is supported via a mutable
  `count/1` cell driven by `nb_setarg/3`, matching the SWI
  semantics.  v2.99.12 revised how `findnsols/4` embeds the
  `count(N)` cells into its instruction sequence (issue #1026), but
  the port requires no code changes: the same-catch-frame
  arrangement in `run_call/6` continues to work correctly.
- **`node.pl`** — concurrent HTTP/WebSocket server, `format=prolog` only for
  the legacy `/call` route.
  The producer-actor cache works particularly cleanly thanks to
  Trealla's stack-preserving `receive/1`.
- **`rpc.pl`** — `http://` only.
- **`websocket.pl` / `web_prolog.pl`** — native `ws://` and `wss://`
  transport with the Trinity version-1 actor vocabulary, tested in both
  Trealla-to-SWI and SWI-to-Trealla directions.
- **`distribution.pl`** — persistent remote-node connections and asynchronous
  routing to local actor mailboxes using Trinity-compatible `Pid@NodeURL`
  identifiers.

Every other delta is a small, localised workaround for a
Trealla-specific quirk.

### Benchmark stability

The threading benchmarks (`bm-ping-pong.pl`, `bm-spawning.pl`) are
stable at low iteration counts (≤ 1 000) but crash roughly 30 % of
the time at 10 000+ iterations under both v2.98.10 and v2.99.12.
This is an upstream Trealla issue (tracked as issue #1026); the
application-level tests are unaffected because they use far fewer
actor round-trips.
