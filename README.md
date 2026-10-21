# Porting `library(actors)` (and friends) to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(currently tested on v3.13.10; earlier actor/RPC work was also tested on
v2.99.12, v2.99.6, and v2.97.13).

The [Web Prolog language manual](https://github.com/torbjornlager/trinity-demonstrator/blob/main/web/manual.html)
is the single shared API reference for all nodes. This README is the Trealla
implementation guide: setup, supported implementation paths, transport adapters,
regression coverage and remaining gaps. Its portability notes do not establish
a separate language contract. The shared manual records observable differences,
including HTTP options, naming scope, startup timing and supervisor reply formats.

The [draft interoperability baseline](https://github.com/torbjornlager/trinity-conformance/blob/main/baselines/0.1.md)
and [coverage matrix](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-10-21-baseline-0.1/COVERAGE.md)
record selected public-interface checks across the existing runtimes. HTTP and
ACTOR surfaces are reported separately; passing ACTOR checks does not waive an
HTTP-path failure. Runtime repairs are separate from this specification/test
consolidation.

The port lives alongside this report:

| File                  | Role                                                |
|-----------------------|-----------------------------------------------------|
| `actors.pl`           | Actor runtime, local names, and published services  |
| `actor_api.pl`        | Precompiled API facade imported by private actors   |
| `toplevel_actors.pl`  | Shell-style PTCP for paged goal execution           |
| `node.pl`             | HTTP server exposing `/call` for remote queries     |
| `auth_policy.pl`      | Authentication, authorization, and WS origin policy |
| `governance_policy.pl` | Per-principal rate and concurrency governance      |
| `observability.pl`    | Audit events, activity tracking, and metrics       |
| `node_tokens.pl`      | Hashed bearer issuance, revocation, and persistence |
| `crypto_portable.pl`  | Native secure randomness and portable SHA-256 fallback |
| `source_policy.pl`    | Allowlisted, bounded `src_uri/1` fetching           |
| `ip_policy.pl`        | Client IP/CIDR, trusted-proxy, and auto-ban policy  |
| `rpc.pl`              | HTTP `rpc/2,3` and asynchronous `promise/yield`     |
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
| `parallel.pl`         | `parallel/1` and `first_solution/2-3` actor generics |
| `server_actor.pl`     | Generic stateful server actor behaviour             |
| `server_actor_tests.pl` | SWI-parity and private-namespace behaviour tests  |
| `supervisor_actor.pl` | Restart strategies and supervised actor trees       |
| `supervisor_actor_tests.pl` | SWI-parity supervisor behaviour tests        |
| `sxml_parser.pl`      | SWI-shaped XML reader and SXML 0.2 validator         |
| `statechart_model.pl` | Pure SXML statechart model compiler                  |
| `sxml_parser_tests.pl` | XML, validation, and model compiler regressions     |
| `tests.pl`            | Manual test suite (no plunit on Trealla)            |

`parallel.pl` is the native Trealla implementation of the shared actor
generics. Workers exchange compact variable templates, validate correlated
worker replies, and use monitor barriers for race-free cleanup.

If a worker terminates without a result, ordinary failure and exceptions keep
their existing behavior; any other reason, including `exit(true)`, becomes
`worker_exit(Pid,Reason)`. `parallel/1` cleans up its workers and throws that
error. `first_solution/2-3` uses its existing `on_error(stop|continue)` policy
(default `stop`): `continue` removes that worker and waits for another result,
failing if no workers remain. Later parallel workers may finish first; their
normal down notifications stay deferred until their results are collected.
Once a result is accepted, its down notification confirms termination regardless
of reason. Only the combinator's own monitor references are selected or drained;
application monitors, including additional monitors on the same worker, remain
available.

Both generics now own their local workers in a private scope spanning startup
and collection. Each pid is recorded before its thread is created, closing the
interruption gap during startup. Partial startup failure, exceptions, query
interruption and cuts reclaim workers already reserved/started. Ordinary
unwinding waits for private termination barriers and removes worker replies
before propagating the original exception. A caller already committed to actor
termination instead withdraws its monitors and requests worker termination,
without waiting on its dying mailbox. Only the scope's own parent-to-worker
links are retired when stopping workers, avoiding duplicate signals from parent
teardown. Nested invocations have independent nonbacktrackable ownership records,
removed after cleanup. No remote cancellation or broader actor-lifecycle
hardening is added.

Source-less persistent toplevels route `parallel/1` and `first_solution/2-3`
through small local wrappers that select the current actor's private module
explicitly. This avoids missing public predicates and loss of worker built-ins
under meta-calls such as `catch/3`; private-source execution keeps its existing
routing. `public_worker_routing_tests.pl` covers ordinary and compound calls,
worker exits, the continue policy, actor operations inside workers, variable
sharing and supplied predicates. Continue-policy pid removal uses `selectchk/3`:
worker pids are unique, so searching for a second occurrence with `select/3`
would leave an empty alternative and delay scope cleanup. The deterministic
removal lets successful `first_solution/2-3` calls close their scope immediately
and report a final page. `first_solution_determinism_tests.pl` uses monitor
barriers to force failure, exception and explicit exit before a winner, checks
successful-call determinism before any cut, and preserves unrelated notifications.
This does not change paging offsets or HTTP page-length calculations.

The focused regressions are in `parallel_exit_tests.pl` and
`worker_scope_tests.pl`, included by `./tools/test.sh unit` alongside the
existing parallel tests.

`server_actor.pl` ports the SWI generic server behaviour. A callback of the
form `Callback(Request, OldState, Response, NewState)` is copied into the
server's private actor namespace. The API includes synchronous requests,
asynchronous promise/yield pairs, fail-fast monitoring, named servers,
graceful halt, and state-preserving callback upgrades. It is an ACTOR-profile
facility and is available both in submitted source and directly at a private
toplevel. The dedicated suite mirrors the 27 SWI semantic cases and adds
callback-closure, private-namespace, and sandbox/profile integration checks
(37 tests total). Reply selection in `server_yield/2-3` uses the reference
before unifying the caller's output. A mismatch consumes that reply and fails
without invoking the timeout callback; replies with other references stay
available. The unification is confined to the reply branch, preserving default
timeout results and callback bindings, failure, exceptions and alternatives.
Focused regressions also check prebound matching outputs and reply variable
sharing. The monitored `/4` implementation and reference handling are unchanged.

`runtime_property/1` exposes the same six host-capability properties as native
SWI, with `implementation(trealla_native)` as its identity. It enumerates facts
without side effects; unsupported properties and non-matching values fail.
The remaining values are `persistent(true)`, `inbound_addressable(true)`,
`dom(false)`, `actor_isolation(native_thread)` and `hard_termination(true)`.
Forced termination does not guarantee that Prolog cleanup handlers run.
The facts live in `rpc.pl`, are re-exported through `actor_api.pl`, and are
imported/routed in private actor and toplevel query environments. The HTTP
node also imports it for source-free stateless execution. The sandbox
admits this read-only predicate through the ordinary safe-predicate list.
`runtime_property_tests.pl` covers enumeration, partial and failed matching,
both sandbox modes, source-free/private-source toplevels and a spawned actor.
The interop runner also applies identical public HTTP assertions to SWI and
Trealla, allowing only their implementation identities to differ.

`server_promise/4` removes and flushes its newly installed monitor when
subsequent reference setup or sending fails or throws, preserving the original
outcome. A successful send leaves the monitor for `server_yield/4`.
`server_promise_cleanup_tests.pl` covers these paths and unrelated monitors
and replies; the unit runner includes this focused suite.

The native statechart runtime now executes SXML 0.2 charts using the existing
pure-Prolog parser/model compiler and a port of SWI's transition engine.
Thread-local model, configuration, history and event queues isolate concurrent
charts. It supports hierarchy, shallow/deep history, parallel regions,
eventless and timed transitions, internal/completion events, entry/exit actions,
guards, snapshot re-offering of deferred events, and private embedded Prolog
datamodels. Local `<spawn>` invocation supports actors, toplevels, servers, supervisors and nested
statecharts. Remote actor/toplevel/server/supervisor/statechart invocation is also supported,
including text and URI remote statechart creation.
See the statechart execution contract below; parsing a document does not imply
that all of its features can execute.

`supervisor_actor.pl` ports the SWI supervisor behaviour on top of actors and
generic servers. It supports `one_for_one`, `one_for_all`, and `rest_for_one`;
per-child permanent, transient, and temporary restart policies; bounded,
infinite, and brutal shutdown; restart intensity limits; dynamic child
management; supervised server actors; and nested supervision trees. Child
source is materialized explicitly at each Trealla actor boundary. The 20-case
suite covers the 18 SWI semantics plus private-source and policy integration.

## Test results

The complete manual and interoperability suites pass on Trealla v3.13.10
(the original 30 tests also pass on v2.99.6 and v2.99.12). Tests t23-t30 mirror behaviours from the
canonical SWI plunit suite in `simple-node/tests.pl`:

Run the isolated unit groups with:

```sh
TPL=/path/to/tpl ./tools/test.sh
```

To create a pinned repository-local Trealla v3.13.10 build without replacing a
system installation:

```sh
./tools/build-trealla.sh
TPL="$PWD/.build/trealla-v3.13.10/tpl" ./tools/test.sh all
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
Trealla/SWI WebSocket and protocol matrix with `./tools/test.sh interop`, or
everything with `./tools/test.sh all`. Set `SWIPL`, `TEST_TIMEOUT`, or
`TEST_PORT_BASE` to override their defaults. If the Trinity demonstrator is
checked out beside this repository, the matrix also starts its real SWI actor
node and checks the shared receive, exit, monitor, demonitor, link, and
qualified-PID reply contracts in both directions. Otherwise that section is
reported as skipped; set `TRINITY_NODE_FILE` to the canonical SWI `node.pl` to
enable it from a different checkout layout.

For an invitation-only deployment, see [Deployment/README.md](Deployment/README.md).
The bundle pins Trealla v3.13.10, runs it unprivileged and read-only behind
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
| 96–97 | operational routes and RPC paging           | ok |
| 98 | deterministic ten-digit logical `self/1` and spawn identity | ok |
| 99 | deterministic exact page (`limit(1)` without false continuation) | ok |
| 100 | paging suspends before next-solution side effects | ok |
| 101 | `flush/0` routes drained messages to the inherited terminal | ok |
| 102 | `receive/1` bodies retain their private source module | ok |
| 103 | submitted guarded receives and timeout callbacks retain actor syntax/module | ok |
| 113 | live `actors/1` snapshots exclude non-actor runtime threads | ok |
| 114 | shared database visibility and actor-local shadowing | ok |
| 115 | connection-scoped `actors/1` hides relays and other shells | ok |
| 116 | private actor modules expose the toplevel actor API | ok |
| 120 | `between/3` supports SWI's `infinite` upper bound | ok |
| 104 | sandboxed nested spawn retains its runtime module in source sessions | ok |
| 105 | nested `src_predicates/1` copies source from its private parent session | ok |
| 127–130 | one-sided receive, correlation safety, and guard control semantics | ok |
| 131 | stale deferred commands do not consume a new call's continuation | ok |
| 132–135 | first-exit-wins, reserved controls, and monitor lifecycle | ok |
| 136–139 | parallel templates, worker isolation, policies, and private goals | ok |
| 140–143 | delayed send delivery, cancellation, and actor-scoped IDs | ok |
| 144 | actor sandbox exposure of `send/3` and `cancel/1` | ok |
| 145 | nested link tutorial source copying and termination cascade | ok |
| 146 | copied sandbox terminal output through `src_predicates/1` | ok |
| 147 | actor-aware `time/1` reporting and `sleep/1` wall timing | ok |
| 148 | concurrent sleeps in the tutorial parallel combinator | ok |
| 149 | copied hand-built toplevel session and paging protocol | ok |
| 150 | variable-bearing reflective clause bodies and proof trees | ok |
| 151 | SWI-compatible `random_member/2` in submitted programs | ok |
| 152 | toplevel `once(true)` commits the first answer | ok |
| 153 | SWI-compatible `atom_string/2` and string-valued `src_text/1` | ok |

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

The client selects TLS from the URL automatically. Trealla v3.13.2 verifies
the certificate chain and host name by default and supports a separate
`server_name(Host)` when connecting to a pinned numeric address.

The transport also implements optional RFC 6455 subprotocol negotiation.
The Web Prolog server prefers `web-prolog-sync-spawn-v1` when offered,
advertising correlated toplevel replies and request IDs on every spawn success
and failure. It also accepts `web-prolog-sync-v1` for toplevel correlation alone.
Connections without an offer (or without a matching optional offer) retain the ordinary handshake. Explicitly
configured required subprotocols keep their existing policy. The Trealla
outbound client offers both, in that order, and records the actual selection.
Each outbound spawn now carries a fresh request ID. On the combined subprotocol,
only matching replies complete the wait; untagged errors are delivered to the
multifile diagnostic hook `distribution:hook_transport_error(NodeURL,Error)`.
Mismatched request IDs cannot satisfy another spawn. Legacy connections retain
serialized spawning and accept untagged replies, whose errors remain ambiguous.
Connection-loss notifications, monitor delivery and actor messages are unchanged.
Trinity version 1 is also announced with `X-Web-Prolog-Protocol: 1` and its JSON vocabulary.
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

The stateless HTTP execution context explicitly provides the RPC client:
`rpc/2-3`, `promise/3-4`, `yield/2-3` and `promise_cleanup/1`. Load `rpc.pl`
before extending `rpc:hook_promise_owner/1`; on the tested Trealla build,
creating that hook first can leave a hook-only module that subsequent imports
do not complete. Source-free sandbox runtime guards use an internal HTTP
context: execution resolves through `node`, while database guards retain their existing `user`
scope. Client calls inside `catch/3` and guarded meta-calls therefore resolve
the same implementation as direct calls without exposing node bookkeeping. Private-source guards retain their actor
context. Profile/sandbox admission, request-local promise ownership, callbacks
and the client implementations are unchanged.

All HTTP page producers now park after a final/error reply until their existing
request scope stops them, matching the private-source producer rule. This
avoids a natural actor exit racing monitored request cleanup during nested HTTP
calls. Cached continuations, whole-page deadlines and public replies retain
their existing semantics.

Run the fresh-process regression matrix with
`python3 tools/test-http-client-context.py --tpl /path/to/tpl`.
It starts disposable loopback nodes through `node.pl` and `distribution.pl`,
in blacklist and whitelist modes, without preloading the client in the fixture.
Its 80 checks cover direct/nested calls, sharing, default and explicit promise
templates, timeout callbacks/retry, invalid references, disposal, cross-request
ownership, private sources and sandbox rejection. The
[client-context follow-up](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-10-21-http-client-context/COVERAGE.md)
records the shared conformance rerun; remaining GNU-to-Trealla and bare-operator
framing differences are separate diagnostics/failures.

HTTP `/call` now consumes the existing `src_text` parameter instead of ignoring
it. Source-bearing requests reuse the actor source admission and private-module
loader, including size, profile and sandbox checks. The internal page producer
owns the private source environment; it survives while a continuation is cached
and is destroyed when that producer is reclaimed. After a terminal reply the
producer waits for its owning scope to stop it, avoiding concurrent
natural module destruction and monitored termination. Source text and admission
policy are part of the cache identity, preventing reuse across different source
programs or policies. Goal/template variables remain shared, including JSON
binding projection. Source-free HTTP execution is unchanged.
The [follow-up coverage report](https://github.com/torbjornlager/trinity-conformance/blob/main/reports/2026-10-21-http-source-loading/COVERAGE.md)
records 10/10 Trealla HTTP baseline cases before the client-context repair
described above; that earlier matrix remains historical evidence.

`http_source_tests.pl` exercises private loading, both sandbox modes, ISOBASE
admission, source size/syntax rejection, runtime guards, private mutation,
variable sharing, source/policy cache separation, continuation reuse and cleanup.
Run it with `tpl -g "use_module(http_source_tests),http_source_tests:run(3097),halt"`
on an unused loopback port. RPC source options are still materialised by the
caller into inline text; this repair adds no destination-side URI fetch path.

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

Every address returned for a source host is checked before the first approved
numeric address is contacted, closing the DNS-rebinding interval between
authorization and connection. Without `load_uri_allowed_ip_ranges/1`, only public IPv4 and IPv6
global-unicast destinations are accepted. Supplying the option replaces that
default with an explicit exact-address/IPv4-CIDR allowlist; the example
therefore deliberately permits its loopback source server. Redirect targets
go through the same resolution and address policy.

HTTPS source fetching verifies the origin host while connecting to the pinned
address. `allow_unverified_https(true)` is now an explicit unsafe opt-out,
retained only for deployments with a separately authenticated transport. The
operating system or container should still enforce an independent egress
boundary as defense in depth.

Public nodes also install resource ceilings. They are configured with these
startup options (defaults shown):

```prolog
?- web_prolog_node(3060,
       [ time_limit(300), idle_limit(300),
         inference_limit(unlimited), stack_limit(unlimited),
         max_actors(256),
         max_term_text_bytes(32768),
         max_source_text_bytes(262144),
         max_ws_frame_bytes(262144)
       ]).
```

`time_limit/1` bounds a complete HTTP page computation and an active PTCP
computation slice; `idle_limit/1` reclaims
an inactive PTCP in either waiting state. Client-supplied execution and idle
limits may tighten the owner limits but cannot raise them. Page sizes are
caller-controlled: HTTP requests, PTCP calls and `next` honour `limit(N)`
without an owner solution-count cap. A finite goal that ends earlier returns
a shorter final page. Requests without an explicit limit are no longer split
at the former owner count cap; execution and configured stack/inference
limits still apply. The actor limit
is admitted atomically and its slot is reclaimed in actor cleanup. Textual
goals/templates, source options, and WebSocket payloads are checked before
parsing or loading, and the node clamps the WebSocket transport's own payload
limit as well.

The former `max_solutions/1` owner option is retired. Supplying it now raises
`error(domain_error(retired_resource_option,max_solutions),_)` before changing
policy. Remove it from startup options. The deployment launcher likewise
rejects the retired `WP_MAX_SOLUTIONS` environment variable; remove it from
custom launchers and container environments. Updated Compose and example
configuration omit it. `page_size_tests.pl` checks HTTP and PTCP call/next sizes,
omitted limits and obsolete-option rejection. The development stack limit
still defaults to `unlimited`: removing the count cap does not create a memory
ceiling or response-byte budget.

The HTTP request timer spans producer startup/cache checkout, offset skipping,
collection and lookahead, without restarting between answers. Every HTTP page
request receives a fresh budget; cached idle time does not consume it. It is
cancelled before request-scope failure cleanup and before response serialization
or socket writing. Expiry reports `error(resource_error(time),_)` and reclaims
the request-owned producer. Already-published cache continuations retain their
ownership. `infinite` disables the page deadline.

The separate PTCP and HTTP-producer execution timers are disarmed while a result
waits for its continuation and rearmed when computation resumes; the separate PTCP
idle ceiling governs that suspended state. `inference_limit/1` bounds each
query using `call_with_inference_limit/3`, while `stack_limit/1` is passed to
every actor and accepted HTTP/WebSocket connection thread. Both default to
`unlimited`; container limits remain an independent boundary.

Each producer and connection worker has its own stack allowance. The connection
ceiling covers parsing, page accumulation and response formatting, including
WebSocket handling after upgrade. Collector exhaustion unwinds the existing page
scope, reclaiming its owned producer and preserving cached handoffs. Recoverable
HTTP stack errors are reported as `error(resource_error(space),_)` in the existing
Prolog/JSON response format. Errors before a usable request context or while
reporting an error may instead close the connection; the stream and connection
registration still have their normal cleanup and `at_exit` fallback.

The runtime ceiling covers Prolog execution areas, not every atom, message queue,
socket buffer or foreign allocation. It is neither an aggregate process-memory
budget nor a response-byte limit. Response buffering is unchanged. `connection_stack_tests.pl` in the unit runner exercises collector
exhaustion with individually small answers and an unlimited producer, live Prolog
and JSON errors, successful paging after exhaustion, lifecycle-option retention,
and finite-limit WebSocket Unicode/binary traffic and connection teardown.

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

Trealla v3.13.2 supplies cryptographically secure random bytes. SHA-256 uses
Trealla's OpenSSL primitive when present and a portable implementation
otherwise. Tokens must still be transported only over TLS and kept out of
shell history and logs. A bearer can be used by the
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

The node binds to the IPv4 wildcard `0.0.0.0` by default. Use
`bind_address(Address)` to restrict the listener to a specific interface.

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

PID conversion preserves variable sharing across goals and answer templates,
and recursively converts nested pids without changing their existing mappings.
The converter builds compounds with `=../2`: on Trealla v3.13.10, equivalent
`functor/3` constructions can fail built-in or arithmetic lookup (BUG-023).
Asynchronous calls support unification, arithmetic, control constructs, and
paging both with and without private source. Replies use the connection relay
selected when the toplevel was created unless `target/1` overrides it. An
explicit target must be routable from the remote node; a client's process-local
pid alone does not establish a return route for ordinary actor traffic.

The server accepts correlated synchronous calls from existing SWI and browser
clients. Each private `'$request_ref'/1` on a toplevel call or next request
tags success, failure, and exception replies with that complete reference.
A next request replaces the current reference; an untagged call or next clears
it and produces ordinary asynchronous replies. Native connection replies carry
`toplevel_correlation` metadata and canonical payloads; browser caller endpoints
receive the equivalent `'$toplevel_reply'(Ref,Answer)` envelope with a global pid.
The adapter for these private requests uses the connection relay for native
callers and the browser's caller endpoint for browser traffic. Ordinary actor
name/pid routing is unchanged.

These tags let the existing synchronous wrappers discard a late reply from a
timed-out request without confusing it with the next request. Timeout does not
cancel execution. Browser target updates are kept in actor-local nonbacktrackable
state because Trealla's `nb_setarg/3` cannot store compound endpoints.

The public `toplevel_call_synch/3-4` and `toplevel_next_synch/2-3` wrappers now
support local toplevel pids and registered remote toplevel pids. Ordinary aliases
resolve through the existing registry. Registered remote routes reuse the
explicit correlated client below; unknown remote routes fail explicitly rather
than falling back to an uncorrelated asynchronous wait. Local requests select
the caller as target, use a fresh private reference, and remove/flush only their
own monitor on success, failure, exception or interruption. An old correlated
reply for the same toplevel is discarded without restarting the original wait
deadline. Replies for other toplevels and ordinary asynchronous messages remain
available. The reply is selected before output unification, so an output
mismatch consumes it and fails.

The wrappers separate query options (`template/1`, `offset/1`, `limit/1`,
`once/1`) from local receive options (`timeout/1`, `on_timeout/1`). Next accepts
only `limit/1` among query options. All occurrences are validated before sending;
`target/1` must equal the caller, and `io_target/1` is unsupported here. They are
exported through `actor_api.pl` and private actor bootstraps, with ACTOR-profile
and sandbox checks on query goals and computed timeout callbacks. Private actor
callback context and sharing are retained. In standalone modules, explicitly
qualify next-call options (`Module:Options`) when a callback needs that module;
the existing list-valued meta-argument qualification gap can otherwise lose it.
`synchronous_toplevel_tests.pl` checks the public local API and remote calls
against both native peers. The explicit remote constructor now registers its
returned pid/connection route; no links or monitors are added by that registration.
The wrapper's remote path explicitly selects its caller, and the existing writer
waiter accepts either typed correlated replies or endpoint-delivered private
reply envelopes. Only live waiters claim replies, and tagged public-wrapper
replies arriving after release are discarded. The peer's advertised URL may be
an alias of the connection URL; replies retain the caller's registered pid form.
Existing asynchronous and explicit remote APIs retain their reply formats and
option behaviour.

The local sandbox adapter nests prepared query goals inside `call/1`, keeping
qualified private helpers below the wrapper's outer caller qualification.
The source-less worker preparer traverses this call while retaining its control
boundary. Synchronous calls retain the original unqualified goal as the default
template before this protection is added, so public sandboxed calls return the
same answer rows as direct calls. Explicit templates retain their sharing and
option precedence. The worker-query test helper uses the same protection. Remote queries
still send portable goals without sender-private rewrites; general outer-module
qualification semantics are unchanged. Regression checks cover both sandbox
policies, source-less and private-source toplevels, sharing, paging, and remote
calls against SWI and Trealla.

The synchronous sandbox adapter commits its completed preparation before
sending a request, so returned answers leave no preparation choicepoint and
output mismatch cannot backtrack into another send.

Public demonstrator checks also found a native SWI-to-Trealla remote-query
qualification problem, now repaired in native SWI, and unrelated peer errors
entering a later spawn wait. The results and remaining repair boundaries are recorded in
[`reproducers/port-synchronous-ui-interop.md`](reproducers/port-synchronous-ui-interop.md).
They do not prevent the local synchronous tutorial example, or the verified
Trealla-to-SWI and browser-to-SWI paging paths. Native spawn-error selection
now uses explicit capability negotiation. Receiver-side delegated-lineage cleanup
is described below; downstream delegation remains separate.

### Receiving delegated lifetimes from native SWI

An authenticated node transport with `internal_transport` authority may supply
SWI's existing `lineage` and optional `account` fields. Both identifiers must be
32 hexadecimal characters. The default open endpoint does not grant this
authority: configure peer bearer credentials or the existing trusted-header
boundary explicitly. No deployment credentials or trust policy are changed by
this repair. Lineage identity is scoped to the accepted connection;
reusing a token on another connection does not share ownership. The account field
is validated, but Trealla retains its existing resource accounting rather than
claiming SWI's aggregate delegated-account implementation.

The receiver carries the lineage with queued commands and installs it during
actor creation. Local descendants inherit that namespace, including children
created with `link(false)`. Ordinary name lookup and uniqueness remain node-wide;
registration ownership and promise access distinguish the delegated namespaces.
Actor control and monitor removal through the relay respect those boundaries.

`lineage_close` closes admission, removes that namespace's registrations and name
reservations, disposes of its promises, and requests termination of all its local
actors. Closing admission and reserving local actors share the registry mutex,
so a racing creation is either included in cleanup or rejected. Children still
preparing source reach a closed-namespace startup error before entering their
goal; preparation retains the existing loader limits. Repeated closure
is harmless; later requests for the closed lineage are rejected. Closing the
connection closes every delegated namespace on it. Other lineages, connections,
legacy actors and unrelated monitor references are preserved by explicit lineage
closure. Toplevels in the lineage terminate too, whether they are executing a
query or waiting between pages; termination is reported by the normal `down`
notification rather than as a query error. The command carries no new
completion acknowledgement: termination notifications remain the way to observe
actor termination.

This is **receiver-side support**. Trealla does not yet propagate this ownership
to further remote nodes or forward lineage closure through them. It provides no
blanket remote cancellation or no-orphan guarantee. Commands without lineage
metadata retain the existing connection behaviour; public browser clients cannot
assert transport lineage authority.

`receiver_lineage_tests.pl` covers validation, sandbox boundaries, context
restoration, detached descendants, names, promises, repeated closure, queued and
concurrent creation, and connection teardown. `swi_lineage_compat.pl` exercises
multiplexed wire commands, legacy traffic, monitor preservation and native SWI's
actual distribution encoder against a disposable Trealla node. Both are included
in `tools/test.sh` (`unit` and `interop`, respectively); live tests use a fixture-only
bearer token and do not alter a running deployment.

General `toplevel_spawn/2` with a remote `node/1` now uses a constructor hook,
matching SWI's dispatch pattern. It delegates to the existing transparent
`toplevel_spawn` transport command so the peer creates its own PTCP, rather
than receiving Trealla's private `session/5`. Local creation and ordinary remote
actor spawning are unchanged. The existing handshake retains caller-owned
links and monitors, pid routes and explicit answer targets. Source options are
materialised in order under the sender's existing policy and source-module
context. Requested session/time/idle options reach the destination, which
applies its own owner ceilings; sender-side PTCP ceilings are not substituted.
The explicit remote API remains available. `remote_toplevel_creation_tests.pl`
covers validation and local creation, plus general creation against both native
peers with source text, lists, copied predicates and URI source, paging, variable
sharing, target changes, duplicate-option precedence, monitors and cleanup.

The WebSocket relay sends the ordinary lifecycle down event alongside all
registered explicit monitor references. A temporary synchronous monitor no longer
suppresses the spawn-time notification when a one-shot query finishes before
private monitor cleanup. References are deduplicated by strict identity; removing
one explicit reference leaves the default event and other actors' monitors
unchanged. The actor is retired once, so repeated termination events do not
repeat notifications. `termination_notification_tests.pl` checks actual WebSocket
frames and public calls against SWI and Trealla, including private filtering,
explicit demonitoring and independent application monitors. Private wait cleanup
and the wire format are unchanged.

The transparent and explicit notification checks run in separate client
processes. On the pinned Trealla v3.13.10 engine,
`termination_notification_tests:combined_connections_diagnostic(URL)` can
SIGSEGV in `match_head` when opening an explicit connection while the cached
transparent connection remains alive after its checks. The sequence also crashes with the pre-repair demonitor implementation;
its runtime cause remains unresolved. Both paths pass independently. This
combined sequence remains a diagnostic, not a passing conformance assertion.
The follow-up reduction, stress runner, candidate engine patch and upstream
report are in `reproducers/bug-025-module-map-growth.*`. They isolate concurrent
module-table growth and lookup without Web Prolog or network code. The installed
runtime has not been patched.

Actor bootstrap generation avoids `with_output_to/2`: the pinned Trealla
engine captures the shared current-output stream across threads, allowing
concurrent captures to mix generated source. Full bootstraps now use individually
formatted atom fragments, concatenated in their original order; minimal
bootstraps use direct atom formatting. HTTP and WebSocket display-term
serializers use `write_term_to_atom/3` with the existing quoting and variable-name
options. Source text, source ordering, private namespaces, sandbox checks and
canonical answer sharing are unchanged. This workaround does not repair the
engine's public output-capture predicate.

`source_capture_tests.pl` checks concurrent full/minimal bootstrap generation,
reply serialization, quoting, variable naming/sharing and surrounding captured
output. It runs in `tools/test.sh unit`. The separate standalone reproducer and
upstream report (submitted as [#1174](https://github.com/trealla-prolog/trealla-prolog/issues/1174)) are in
[`reproducers/bug-026-concurrent-output-capture.md`](reproducers/bug-026-concurrent-output-capture.md).
The [ACTOR conformance rerun](https://github.com/torbjornlager/trinity-conformance/tree/main/reports/2026-10-21-trealla-source-capture)
records the public-interface checks separately from diagnostics. The original
intermittent source-parsing failure is retained in the earlier GNU framing
report; the independently reproduced capture corruption strongly supports,
but does not conclusively establish, its cause.

The remaining isolation/sandbox parser diagnostics have a separate standalone
reduction in [`reproducers/bug-027-assert-goal-expansion.md`](reproducers/bug-027-assert-goal-expansion.md).
Rebased runtime variables can be misprinted in an internal goal-expansion query;
the failing path can leave later expansion disabled while assertion still
succeeds. A separate experimental engine build fixes the recorded cases and
passes the bounded regression comparison. The patch and raw results accompany
the report submitted as [#1175](https://github.com/trealla-prolog/trealla-prolog/issues/1175). The installed engine and port runtime sources
remain unchanged by that investigation; its results do not claim a production
engine upgrade or eliminate the original capture report's causal qualification.

Public remote `demonitor/1-2` now checks caller ownership under the actor
registry mutex, performs distribution work without that mutex held, then retires
the caller's record under the mutex. Previously the manager's route reply could
wait on the same registry while the caller held it, making lookup time out and
leaving the writer's watcher active after local retirement. The distribution
hook and writer both restrict removal to the caller's reference. A fresh internal
acknowledgement ticket confirms writer removal before `flush` drains all queued
notifications for that exact reference. Other messages, application monitors and
private wait monitors remain independent; repeat/unknown removals are idempotent.
The private monitor on the writer is removed on every exit path. A stopped writer
completes local withdrawal; a live writer that does not acknowledge within two
seconds raises `error(remote_demonitor_timeout(Pid),demonitor/2)` and retains the
caller's target-monitor record for retry. Wire protocols and the explicit remote
API are unchanged. `remote_demonitor_tests.pl` covers the lock interaction,
acknowledgement ordering, multiple queued notifications, ownership boundaries,
repeat removal, writer loss/timeouts and public calls against both native peers.


The remaining wide-atom observation is kept separately in
`remote_toplevel_creation_diagnostics.pl`, not counted as a passing conformance
assertion. Native SWI's current portability check rejects wide-character atoms
(`ucs_text` blobs), so an asynchronous answer containing such an atom can lack
the negotiated canonical `term` field; the Trealla client reports
`remote_answer_protocol_error(missing_term)`. Unicode URI source is still fetched
and loaded in the creation tests, with an ASCII result payload.


The native client exports `remote_toplevel_call_synch(Node,Pid,Goal,Answer)`
and its five-argument form with options, plus
`remote_toplevel_next_synch(Node,Pid,Answer)` and its four-argument form.
They return the ordinary `success(Pid,Rows,More)`, `failure(Pid)`, or
`error(Pid,Exception)` answer. Each request has a fresh reference and a private
remote monitor. A writer-side waiter is registered before sending, so a fast
reply cannot precede registration. Replies are routed to that request's caller,
including callers sharing a connection, without changing asynchronous targets.

Call options are `template/1`, positive `limit/1`, nonnegative `offset/1`, and
boolean `once/1`; next accepts `limit/1`. Both accept nonnegative numeric
`timeout/1` and callable `on_timeout/1`, which stay local. `target/1`, if supplied,
must denote the calling actor. On timeout, the callback runs once (default
`true`) without binding `Answer`; callback bindings, failure, or exceptions
are preserved. An explicitly module-qualified options list supplies callback
context; otherwise the current actor source context or call's goal module is
used (the default next context outside an actor source module is `user`).

Observed termination throws `toplevel_down(Reason)`; ordinary peer loss throws
`toplevel_down(connection_closed)`. Every exit path removes the waiter,
best-effort demonitors its remote reference, flushes its private local messages,
and removes the monitor on the writer actor. Unrelated monitors and mailbox
messages remain available. Late replies for released references are discarded.
Private remote monitor references use `'$sync_monitor'(RequestRef)` so a late
private down notification can also be discarded without retaining tombstones;
ordinary monitor references keep their existing routing.
An unsupported peer raises `permission_error(use,toplevel_correlation,NodeURL)`
before sending a private monitor or query; asynchronous access remains available.
Cancellation and the general local/remote wrapper API remain separate.

Explicit `remote_node_close/1` requests reader cancellation, then waits for
its actor registry entry to be removed by the exit hook before asking the
writer to close the shared stream. This prevents a close racing the reader's
`get_byte/2`. The writer retains the existing pending-call notification and
monitor cleanup: synchronous callers receive `toplevel_down(connection_closed)`;
unrelated monitors remain available. Repeated close after completed teardown
is harmless. Each termination wait allows 100 polling intervals of 0.01 seconds;
if the actor has not stopped, close raises
`error(resource_error(remote_node_close_timeout(Pid)),remote_node_close/1)`.
A reader timeout does not authorize closing its stream; a later close can retry.

A previous concurrent-close stress run crashed natively on v3.13.10; the
crash report shows a reader failing in `get_byte/2` / C `clearerr()` during
shutdown. Explicit close now confirms reader termination first, with regression
coverage against SWI and Trealla peers. A standalone runtime reproducer is still
needed before filing upstream; see `UPSTREAM_OUTSTANDING.md`.
Existing PTCP handling can also turn an active-computation cancellation
interrupt into an error answer; the synchronous API preserves that answer
rather than inventing a down event.

Clients may request `answer_terms:true` in `transport_hello`; the server
acknowledges it in `transport_welcome` for that connection. Negotiated success
events include `term`, a Prolog text representation of the entire solution
list; negotiated actor errors include the exception term in the same field.
Parse it once to preserve sharing across the payload. Failure needs no extra
payload. Existing display fields remain available, and connections that omit
the capability or request `false` retain legacy answers.

For explicit answer templates, use `format(prolog)` in the call options (or
the JSON command's `format:"prolog"` field). This preserves the first explicit
`template/1`, defaulting to the goal. The default JSON format continues to
return named display bindings. In Prolog format, an outer caller module tag
such as `user:Goal` is stripped before the ordinary profile and sandbox checks;
it does not grant access to a server module. Execution uses the actor context.

The canonical writer names actual variables without `numbervars/3`, preserving
distinct variables, repeated variables, and literal `'$VAR'/1` terms. This
uses Trealla's existing term semantics, including character-list strings; it
does not introduce a portable string contract.

The native outbound client also requests this capability. It completes the
existing welcome exchange before sending requests, and selects Prolog-format
call options only when the peer acknowledges `answer_terms:true`. Negotiated
success payloads are parsed once as a complete solution list; negotiated
exceptions are delivered as `error(Pid,Exception)`, preserving their structure
and variables. Missing or malformed negotiated payloads are delivered as
`error(Pid,remote_answer_protocol_error(missing_term))` or
`error(Pid,remote_answer_protocol_error(invalid_term))`, including a success
payload that is not a proper list. There is no silent display-data fallback
after acknowledgement. A welcome that omits the capability or sets it to
`false` retains the original request format and legacy decoding, including
the `remote_error(Data)` wrapper for legacy actor errors.

`remote_toplevel_call/4` serializes its goal and options with one shared
variable-name map, retaining goal/template sharing and literal `'$VAR'/1`
terms without binding caller variables. This is confined to toplevel call
requests; other actor-message and routing protocols are unchanged.

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

At this boundary, physical newlines inside quoted atoms and strings are
translated to equivalent `\n` escapes before Trealla reads the term. This
preserves SWI-compatible multiline `src_text/1` examples without changing
newlines used merely to lay out a query.

Trealla allocates stable ten-digit logical actor PIDs and keeps a private
logical-PID-to-thread registry. The same PID is returned by `spawn/2`, by
the child actor's `self/1`, and on the WebSocket wire; opaque Trealla thread
handles never enter the public actor API. A dedicated relay actor is the only WebSocket writer, while the connection
reader remains free to accept `next`, `stop`, and `abort` during execution.
Like the SWI implementation, an active browser shell therefore uses three
threads: one connection reader, one relay, and one shell actor. `actors/1`
returns only public actors in the calling shell's connection namespace, so a
fresh shell reports itself rather than its internal relay or actors belonging
to other browser connections. Actors and sessions owned by a connection are
terminated before connection cleanup completes; this applies to close frames,
abrupt socket loss, and browser reloads.
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
- `self/1`, `send/2`, and the `(!)/2` operator alias
- `send/3` with `delay(Seconds)` and optional actor-scoped `id(Id)`, plus
  `cancel/1` to withdraw all of the caller's pending sends with that ID
- `receive/1-2` with one-sided `subsumes_term/2` matching, guards
  (`Pattern if Guard -> Body`), `timeout(0)` polling, positive relative
  `timeout(T)` values, and absolute `deadline(D)` values in the `get_time/1`
  time scale. `on_timeout(Goal)` handles expiry for either form; `timeout/1`
  takes precedence if both are supplied. Patterns cannot instantiate variables
  inside a message; ordinary guard exceptions reject a candidate, while
  lifecycle and resource-control exceptions propagate without losing the
  message.
- `monitor/2`, `demonitor/1-2`
- `register/2`, `unregister/1`, `whereis/2`
- `exit/1`, `exit/2`
- `output/1-2`, `input/2-3`, `respond/2`
- `terminal_output/1-2` with local descendant inheritance
- `input/2-3` inherits the same terminal target
- `make_ref/1` backed by Trealla's atomic `flag/3`, with process-lifetime-unique
  ten-digit integer references,
  `actors/1` for a live-actor snapshot, and `flush/0`
- Links 
- Deferred-message semantics (non-matching messages stay in the
  mailbox in arrival order)

`spawn/3` validates its complete options list before routing, source loading,
or actor allocation. Direct `remote_spawn/4` calls use the same checks before
source materialization or sending a request. Supported public options are
boolean `link/1` and `monitor/1`, a node address in `node/1`, instantiated
`target/1` and `io_target/1`, and `src_text/1`, `src_list/1`,
`src_predicates/1`, and `src_uri/1`. Node addresses retain their atom or
character-list forms. Source text and URIs retain their existing text formats;
predicate indicators are atom/nonnegative-integer `Name/Arity` pairs.
Source fetching remains subject to the existing source policy.

Malformed lists, uninstantiated option names, unknown options, and invalid
values raise errors with the relevant API context and `'invalid spawn option'`.
Every occurrence is checked, including invalid later duplicates. Existing
scalar precedence, source ordering, routing, PID sharing and spawn-time monitor
semantics are preserved. Direct `spawn/3` does not implement `name/1`;
server/supervisor naming remains with those wrappers.

Framework `'$entry_context'(caller)` metadata goes through the internal
`actors:spawn_runtime/3` or scoped entry point. Public `spawn/3` and
`remote_spawn/4` reject that internal option. Wrappers remove options they have
already consumed before invoking base spawn; in particular, the toplevel's
`session/1` stays local to the wrapper. Specialized wrappers and supervisor child specifications add their own early checks below. `spawn_option_tests.pl` covers local checks,
source loading, PID sharing and metadata; its live driver checks explicit and
transparent remote spawning. Both are included in the corresponding test
runner modes.

The specialized constructors validate all options before callback copying,
source materialization, child normalization/startup, or actor allocation. Their
wrapper-specific options are:

| Constructor | Additional options |
|---|---|
| `toplevel_spawn/2` | Boolean `session/1`; positive numeric seconds or `infinite` in `time_limit/1` and `idle_limit/1` |
| `server_spawn/4` | Atom `name/1` |
| `supervisor_spawn/3` | Atom `name/1`; `strategy(one_for_one|one_for_all|rest_for_one)`; nonnegative integer `intensity/1`; positive numeric `period/1` |

Other options use the shared spawn validator. Defaults, first-occurrence
precedence, resource-policy limit clamping, variable sharing, and valid runtime
metadata are unchanged. Invalid later duplicates are rejected even when the
first occurrence is valid. Wrapper errors carry the constructor context and
`'invalid wrapper option'`. Toplevel `name/1` is unsupported and rejected.
Direct `remote_toplevel_spawn/3` and incoming WebSocket toplevel creation use
the same checks before loading source or sending/starting work.

These checks validate option shapes and values. Local named creation additionally
uses the reservation and startup publication described below; other lifecycle behavior is unchanged. Statechart constructors now apply the same wrapper
validation, plus their XML source and feature checks. Focused regressions
are in `wrapper_option_tests.pl`, run by `./tools/test.sh unit`; the live
remote-toplevel check is also included in the interoperability runner.

Supervisor child specifications are validated before source materialization or
actor creation. The initial specification list must be proper and acyclic,
contain `child(Id, Options)` terms with ground, unique IDs, and use proper option
lists. Dynamic `supervisor_spawn_child/3` applies the same single-child checks
before sending the request. A valid addition with an existing ID still returns
`error(already_present)`.

Supported child options are required callable `start/1`,
`restart(permanent|transient|temporary)`, `type(worker|supervisor)`, and
`shutdown(brutal_kill|infinity|Seconds)` with nonnegative numeric seconds.
Every occurrence is checked, including later duplicates; the first occurrence
still supplies the effective value. Defaults remain `restart(permanent)`,
`type(worker)`, and shutdown of 5 seconds for workers or `infinity` for
supervisors. Module qualifiers must be atoms; predicate availability and goal
arguments are not checked.

Server starts `server(Callback, Options)` require an atom child ID, a callable
callback, and valid server/spawn options plus unrestricted `initial_state/1`.
Nested `start_sub_supervisor(Specs, Options)` starts recursively validate their
specifications and supervisor options before any child starts. Validation does
not copy terms or ground goal arguments or initial states, preserving shared
variables. Errors carry the calling API context and
`'invalid child specification'`. These checks do not change startup rollback or other lifecycle behavior. Regressions are in
`child_spec_tests.pl`, included in `./tools/test.sh unit`.

Local `server_spawn/4` and `supervisor_spawn/3` with `name(Name)` reserve the
ordinary name under the actor-registry mutex before callback/source preparation
or actor creation. Competing creation or `register/2` gets the existing
`name_is_in_use(Name)` exception. A pending reservation is not returned by
`whereis/2`, and `unregister/1` does not cancel it. After the child's source is
prepared, startup publishes its PID under that name before acknowledging
startup and running the child's goal. Failure or exception during creation
releases an unpublished reservation; normal termination removes a published
registration, including when the child exits immediately after startup.
Successful creation does not promise that the child remains alive afterward.

First-occurrence `name/1` precedence and Trealla's existing node-wide ordinary
name namespace remain unchanged. The separate service-name registry is
unchanged. Ordinary `register/2` check-and-insert and `unregister/1` now use the
same mutex. Public
`spawn/3` still rejects `name/1` and private reservation metadata. Remote named
creation uses caller-side reservation and publication as described below. This does not
add general cancellation or parent-death cleanup machinery. Focused concurrent,
startup-failure, first-goal visibility and immediate-exit regressions are in
`named_creation_tests.pl`, included in `./tools/test.sh unit`.

`register/2` checks local PID liveness under that same registry mutex,
immediately before insertion. Missing local PIDs, retired native threads, and
actors that have committed an exit reason raise
`error(existence_error(process, Pid), context(actors:register/2, _))`.
Live actor PIDs and live shell/native-thread PIDs obtained through `self/1`
remain registerable. Existing duplicate-PID and occupied-name errors retain
precedence over the liveness check.

With the distribution layer loaded, integer PIDs qualified by `localhost` or
the configured current node URL receive the same local check. Their stored
alias terms remain unchanged, and ordinary actor termination cleanup removes
these qualified local aliases as well as bare local PID registrations.
Addresses of other nodes retain remote-alias semantics: registration performs
no network liveness probe, and an unrelated local actor with the same numeric
PID cannot remove their aliases. The ordinary node-wide namespace and separate
service-name registry are unchanged. A successful registration does not promise
continued liveness. For spawned actors using ordinary termination cleanup, the
registry mutex ensures that termination either removes a registration or
precedes its rejection. This does not add native-thread exit cleanup or general
namespace teardown. Focused tests in
`registration_tests.pl`, included in `./tools/test.sh unit`, cover termination
races, committed exits, native-thread mappings, and local/remote aliases.

Remote ordinary aliases are removed when the outbound connection observes a
`down` event for their exact remote PID, before delivering the event. This
includes explicit and transparent event routing, owner fallback, and private
synchronous-call monitor notifications. Explicit close or connection loss also
removes aliases for that connection's known PIDs, snapshotted from spawned
targets (including targets already marked dead), active monitors, and pending
synchronous waits before their bookkeeping is cleared. Existing monitor and
pending-call notifications are unchanged.

Cleanup runs under the actor-registry mutex and preserves local names, service
registrations, and aliases for other exact PIDs, including other PIDs on the
same node URL. It does not sweep every alias for a node: another connection may
still be active. Registration does not implicitly monitor or probe a remote
actor. An alias without an associated known PID or observed termination still
requires explicit `unregister/1`; registration after an observation is not
prevented by a persistent tombstone. Focused regressions in
`remote_alias_tests.pl` cover all event paths, explicit close and simulated
connection loss, plus preservation of unrelated names/services/monitors. Its
live driver checks termination and two-connection isolation against SWI and
Trealla in `./tools/test.sh interop`.

WebSocket namespace teardown removes ordinary registrations and unpublished
local-name reservations created by that client. Ownership follows the caller
that registers/reserves the name, not the target actor: remote aliases and
names assigned to other local actors are included. This ownership metadata
does not partition naming; lookup, name uniqueness and PID-name uniqueness
remain node-wide. Names owned by other clients or trusted standalone code and
the separate service registry are preserved.

On WebSocket disconnect, the namespace is marked closed and its names and
reservations are retired under the registry mutex before existing connection
shutdown runs. Surviving actors keep their namespace identity and lifetimes;
late `register/2`, local named creation, and startup publication are rejected
with `error(permission_error(register, closed_namespace, Namespace), _)`.
Source preparation already in progress cannot publish a name after closure.
Repeated teardown cannot remove a replacement subsequently registered by
another client. Closed namespace markers are retained to reject late activity;
this batch adds no general marker reclamation policy.

Existing connection-owned actor shutdown is unchanged; removing registrations
does not itself terminate actors. This applies to WebSocket scopes only: HTTP
and cached-producer namespace lifetimes, ownership transfer, and other lifecycle
policies remain separate. WebSocket-owned promise disposal is described below.
`namespace_tests.pl` covers
creator ownership, surviving actors, admission/teardown races and in-flight
startup publication; its live interoperability driver verifies disconnect
cleanup and node-wide visibility/isolation using two WebSocket clients.

Remote named creation through the server/supervisor constructors reserves the
caller's ordinary node-wide name before callback/source preparation, connection
setup, or the spawn request. The reservation token is private local metadata
and is stripped from wire options. Once the remote PID is known, the caller
publishes its alias during the existing transparent-spawn handshake, before
acknowledging readiness to the writer. Buffered termination notifications are
then processed against the published alias. Namespace closure rejects late
publication, and a failed handshake explicitly releases the writer rather than
leaving it waiting for readiness.

Startup or publication errors release the reservation and roll back the
attempt's alias, route, link and spawn-time monitor bookkeeping, preserving
unrelated names and monitors. When the PID and connection are usable, rollback
requests remote termination with the existing exit command; a cleanup failure
does not replace the original startup/publication error. Unnamed spawning and
successful monitor delivery retain their behavior. No wire protocol extension
is required.

Supervisor initial startup and dynamic additions now use a private startup
journal. Each local child is recorded before thread creation and remains
provisional until monitoring and child bookkeeping succeed. The journal is
committed only when the whole initial child list, or one dynamic addition,
succeeds. Failure or exception rolls back that attempt in reverse startup order,
using each child's existing shutdown policy: graceful server stop with the
configured timeout or `infinity`, immediate `shutdown` for ordinary goals, and
`kill` for `brutal_kill`. Cleanup uses private termination monitors and withdraws
only the attempt's lifecycle monitors, preserving unrelated application
monitors, including additional monitors on the same child. Parent links for
children being rolled back are retired before explicit stops to avoid duplicate
signals from supervisor teardown. If shutdown itself throws, rollback still
attempts to stop that child and continues through the rest; a primary startup
exception remains the reported error.

Initial ordinary failure still exits with `init_failed`; an initial startup
exception retains its original term. Supervisor creation still acknowledges
actor creation before its children finish starting, so callers use a monitor
to observe later initialization failure. A dynamic startup exception now returns
`error(Error)` while preserving the supervisor's previous children/state;
ordinary startup failure retains `error(start_failed)`, duplicate ids retain
`error(already_present)`, and successful additions retain `ok`. Failed attempts
release their child names, so the id/name can be retried. Reserved actor/PTCP
control exceptions are rethrown rather than returned as addition errors.
Committed actor termination retains normal parent-link containment without
waiting on its dying mailbox. Restart-failure handling is described below;
restart strategies and general supervisor-exit cleanup are unchanged.
`supervisor_startup_tests.pl` covers rollback order, provisional children, source
setup errors, name reuse, shutdown policies, cleanup errors and monitor isolation.

Explicit respawn and automatic replacement now reuse the startup journal.
`supervisor_respawn_child/3` rolls back a failed replacement, retains the
inactive specification and existing siblings, and returns `error(start_failed)`
for ordinary failure or `error(Error)` for a startup exception. Success still
returns Trealla's `ok(NewPid)`; `error(running)` and `error(not_found)` are
unchanged. The failed id/name can be retried.

All replacements for one automatic restart event share a journal. If one fails,
new actors and monitors are rolled back, then remaining recorded children are
stopped in reverse order using their declared shutdown policies. The supervisor
exits with `restart_failed(Id,Reason)`, where `Id` identifies the failed
replacement, which can differ from the child that triggered the restart.
`Reason` is `start_failed` for ordinary failure or the original exception term.
Cleanup errors do not replace that reason. No additional retry loop is added.
Successful group stopping and replacement order, restart policies and public
reply formats are retained. Restart shutdown waits use private monitor
references; unrelated application monitors and messages are not consumed by
cleanup. Runtime exit/abort controls propagate instead of becoming restart
errors. `shutdown(infinity)` can delay failure cleanup indefinitely. Intensity
exhaustion cleanup is described below; broader supervisor-exit handling remains
unchanged.
`supervisor_restart_tests.pl` covers explicit retry, all three strategies,
partial replacement success, failure identity, shutdown policies, cleanup errors
and application monitors.

Restart-intensity exhaustion now stops remaining recorded children before the
supervisor exits with its existing `shutdown` reason. The triggering child is
marked inactive, and no replacement is started once the allowance is exhausted.
Cleanup runs in reverse startup order using each child's configured shutdown
policy and private termination monitors, preserving unrelated application
monitors and messages. Cleanup errors do not replace `shutdown` or prevent
attempts to stop the remaining children; runtime exit/abort controls propagate.
An `infinity` shutdown policy can delay the exit indefinitely. The restart
count, time-window pruning (strictly newer than the cutoff), threshold rule,
strategy behavior below the limit, and public reply formats are unchanged.
`supervisor_intensity_tests.pl` covers zero intensity for all three strategies,
exhaustion after permitted restarts, period pruning, shutdown order/policies,
cleanup errors and same-mailbox monitor/message isolation. General cleanup
after arbitrary supervisor exits remains separate.

The Trealla receiver recognizes the existing unqualified
`sup_init(Specs, sup(Strategy, Intensity, Period, [], []))` spawn entry used by
supervisor constructors. It validates the normalized child specifications and
settings, rejects pre-populated children or restart history, and constructs
fresh runtime bookkeeping. Private module-qualified entry calls remain blocked;
ordinary remote goals still use the existing spawn/sandbox path. The sender
and wire protocol are unchanged.

The adapter treats sender module qualifiers as source context rather than
permission to call peer-private modules. Child goals, nested sources and server
callbacks pass through profile and sandbox checks; opaque calls retain runtime
guards in blacklist mode and existing admission restrictions in whitelist mode.
Checked application sources load into each receiving child's own database.
Framework code executes precompiled instead of being copied into child source.
Nested supervisors receive the same policy, and subsequent child additions are
checked too. Invalid additions return an error reply while leaving the
supervisor running. Existing defaults, naming, counts/info reply shapes,
restart/shutdown policies, monitor delivery and alias cleanup are retained.

`remote_supervisor_tests.pl` covers malformed/forged state, source validation,
private-module rejection, variable sharing, opaque calls, server callbacks,
dynamic additions, and ordinary spawning. Live tests cover named/unnamed,
source-backed and nested supervisors. `swi_supervisor_compat.pl` additionally
runs native SWI named/unnamed constructors (empty and `src_text/1`-backed)
against a disposable Trealla peer. WebSocket `spawn` and `toplevel_spawn`
accept an optional string `request_id` and echo it on the corresponding
`spawned` or protocol `error` reply, including admission, sandbox, option and
startup failures. Correlation is carried with each request; ordinary actor
messages and monitor `down` events retain their existing format. Requests
without an ID retain the legacy reply format. Invalid non-string IDs are
rejected with an uncorrelated error. This supports native SWI's caller-side
named-startup reservation even with older peers that already echo IDs. The new
combined subprotocol explicitly guarantees error correlation as well. Tests cover
duplicate-name rejection, failed-start name reuse, monitor delivery and legacy
replies; `spawn_reply_tests.pl` also checks reply decoding, mismatched IDs,
unrelated errors before/during waits, matching startup errors, legacy fallback
and connection loss. Its `live/1` check runs unchanged against SWI and Trealla.
Native SWI halt acknowledgement and normal `down` may arrive
out of order over different connections. Native SWI and Trealla halt waits now
require the matching acknowledgement while tolerating an earlier normal
`down(..., true)`. They retain the original ten-second deadline, starting after
sending the stop request; a normal down does not restart it. If no acknowledgement
arrives before that deadline, an observed normal down produces
`supervisor_down(true)`; otherwise expiry produces
`supervisor_call_timeout(Sup, stop)`. Abnormal termination still raises
`supervisor_down(Reason)` immediately. Only the wait's private monitor is
withdrawn and flushed; application monitors and unrelated messages remain.
Success acknowledges acceptance, not completed child shutdown. Shutdown policies
and other supervisor request waits are unchanged. `supervisor_halt_tests.pl`
checks both event orders, delayed/missing acknowledgements, the deadline and
monitor cleanup. The native compatibility smoke test now requires actual
acknowledgement and separately observes termination, including repeated cycles. Adapter-created
child source preparation is serialized to avoid concurrent bootstrap generation
on this runtime; child execution remains concurrent. HTTP promise
ownership and broader lifecycle machinery are unchanged; current deployments
need the updated receiver code for this entry to be available.

The guarantee is atomic caller-side alias ownership. The remote actor may
already have begun its goal before the alias is published. Connection loss
before its PID is returned limits cleanup; this does not provide guaranteed
remote cancellation, cancellation when the caller itself disappears during
startup, or a distributed transaction. Focused tests in
`remote_named_tests.pl` cover publication/rollback, namespace closure, failure
acknowledgements and monitor preservation. Live interoperability tests against
SWI and Trealla cover competing creators (only one enters creation), failed
source preparation/name reuse, immediate termination, and monitor delivery.

### toplevel_actors.pl

- `toplevel_spawn/1-2` — create a PTCP (Prolog Toplevel Control Process)
- `toplevel_call/2-3` — run a goal inside the PTCP; answer arrives as
  `success(Pid,Slice,More)`, `failure(Pid)`, or `error(Pid,Error)`
- `toplevel_next/1-2` — request the next batch of solutions
- `toplevel_halt/1-2` — terminate a PTCP, optionally waiting for termination
- `toplevel_stop/1` — discard remaining solutions; return PTCP to idle
- `toplevel_abort/1` — abort a running goal; restart PTCP in idle state
- `offset/2` — skip the first N solutions of a goal (re-exported from
  Trealla's built-in for convenience)
- `toplevel_next/2` with `limit(NewLimit)` — mid-stream limit change
  is honoured via a mutable `count/1` cell driven by `nb_setarg/3`
- Exact-page exhaustion uses `call_cleanup/2` determinism on the original
  goal, matching SWI without an N+1 lookahead or premature side effects
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
- Continuation-cache and RPC client offsets advance by the number of answers
  actually returned, including when a peer returns a short non-final page;
  short pages do not authorize silent page-size clamping

### rpc.pl

- `rpc/2,3` — call a goal on a remote node; solutions are yielded one
  by one on backtracking, with automatic page fetching when the node
  reports `More=true`
- `promise/3,4` and `yield/2,3` — start a remote HTTP call immediately and
  collect its complete `success/2`, `failure`, or `error/1` answer later;
  timed-out yields retain the promise for a later collection
- `promise_cleanup/1` — explicitly dispose of a promise's local resources
  (otherwise it expires automatically after five minutes)
- `limit(N)` option to control page size
- `src_text/1`, `src_list/1`, `src_predicates/1`, and `src_uri/1` options
  are materialized into the remote call's source payload
- The documented HTTP option subset below is passed through to the transport

Client options are validated before source fetching, network requests, promise
resource creation, or collection. Each list must be proper, each option name
instantiated, and every occurrence valid, including duplicates. Scalar option
lookup retains first-occurrence precedence. Repeated request headers and source
options keep their existing behavior and order. Validation preserves template
and callback variables.

| API | Supported options |
|---|---|
| `rpc/3` | `limit/1`, boolean `once/1`, the four `src_*` options above, and the HTTP subset below |
| `promise/4` | The same options, plus arbitrary `template/1` and nonnegative integer `offset/1` |
| `yield/3` | `timeout/1` and callable `on_timeout/1` |

`rpc/3` defaults to `once(false)`. With `once(true)`, it still yields every
answer in the first slice through backtracking, but never requests a later page,
even if the peer reports `More=true`. The first `once/1` setting wins; every
occurrence must be boolean. The client forwards that value as the HTTP `once`
query parameter rather than passing it to `http_open/3`. Both native SWI and
Trealla destinations honour it by stopping the computation after the slice.
This does not add remote cancellation after disconnects. Failure, errors,
source loading, variable sharing and ordinary paging retain their semantics.
`rpc_once_tests.pl` checks request counts using a peer that deliberately ignores
`once`, plus first-slice enumeration, duplicate validation/precedence, non-ground
sharing and failure/error delivery. Its `live/1` checks run against both native
destinations; the fixture suite is included in `./tools/test.sh unit`.

`promise/4` also accepts boolean `once/1`, defaulting to `false`. It always
fetches just one slice; `once(true)` tells the destination to finish that
computation rather than retain a continuation. The first setting wins and every
occurrence is validated before source fetching or resource creation. The value
is passed through the worker into the HTTP query, never into `http_open/3`.
Collection preserves the complete peer answer, including its `More` flag;
clients do not rewrite a legacy peer's `success(Slice,true)` response.
`rpc_once_tests.pl` also checks promise request counts, default/duplicate
settings, validation without resource creation, offsets and non-ground sharing,
failure/error delivery, and timeout/callback/retry using a gated HTTP reply.
The same public promise assertions run against native SWI and Trealla through
the interoperability runner. Ownership, expiry and disposal are unchanged.

The HTTP subset is `http_timeout/1`, legacy `timeout/1`, `request_header(Name=Value)`,
`authorization(basic(User,Password))`, `user_agent/1`, `redirect/1`,
`max_redirect/1`, and `cacert_file/1`. Limits are positive integers; redirect
counts are nonnegative integers; `redirect/1` is boolean. Explicit
`http_timeout/1` requires a number and normalises negatives to zero, matching
SWI's option validation. It overrides legacy `timeout/1` regardless of list
order; the first occurrence of each name wins, and every occurrence is checked
before source fetching or resource creation. Only one normalised `timeout/1`
is forwarded when the explicit option is present. Without it, legacy transport
`timeout/1` handling (nonnegative numbers or `infinite`) is unchanged. Yield
timeouts govern the local wait. No remote execution timeout option is added.
CA certificate configuration requires a TLS-enabled Trealla build.

**Dependency limitation:** Trealla v3.13.10's `http_open/3` sets the stream's
read timeout, but the runtime stores that value without consulting it in its
read path. A delayed response can therefore succeed after either transport
option's interval has elapsed. This batch adds the explicit spelling and
precedence, not enforcement machinery. `rpc_http_timeout_tests.pl:run/1` checks
validation, transport mapping, successful requests and promise wait/callback/retry.
Its separate `diagnose_expiry/1` reproduces the unresolved transport expiry
problem for both spellings and asynchronous promise collection.

Source text, source URIs and CA filenames accept the existing text formats
(atoms, strings, or valid character/code lists); `src_list/1` takes a proper
term list and `src_predicates/1` takes a list of atom/nonnegative-integer
`Name/Arity` indicators. HTTP text values keep the library's text and numeric
forms. Only Basic authorization is accepted through `authorization/1`; an
explicit Authorization request header remains available for bearer tokens.

Unknown options, HTTP response-output options, and ineffective options are
rejected. In particular, `rpc/3` rejects `template/1` and `offset/1`.
Errors include the relevant API context and
`'invalid client option'`. An invalid `yield/3` option does not claim or consume
the promise, even when its answer is already ready. The focused tests are in
`rpc_option_tests.pl`; `./tools/test.sh unit` runs them, and the interoperability
runner exercises validated paging and promise collection over HTTP.

`yield/2` delegates to `yield/3`. A wait timeout returns `timeout` without
consuming the promise, so a later yield can collect its answer. `on_timeout/1`
runs once and may supply a different answer; if the answer is still unbound
after the callback, it becomes `timeout`. Callback exceptions propagate; a
callback that fails raises `error(timeout_callback_failed(Ref),Context)`.
Explicitly qualified options supply callback context; otherwise callbacks use
the current actor source module, or `user` outside a private actor source.

Both yield forms raise `error(existence_error(promise,Ref),Context)` for unknown,
consumed, expired, or explicitly cleaned-up integer references. Reference type
and instantiation errors keep their existing checks. A ready message is selected
and its reference consumed before unifying the caller's answer; an incompatible
output pattern therefore fails without leaving a reference to an empty queue.
The worker delivers remote `failure` unchanged, caught exceptions as
`error(Exception)`, and local request failure without an exception as
`error(error(promise_worker_failed,Context))`.

Promise collection, five-minute expiry, explicit cleanup, and partial startup
failure now share a mutex-protected lifecycle record. Successful collection
(including a subsequent output mismatch) disposes of the queue and requests
termination of the remaining local worker/expiry threads. A wait timeout keeps
the promise intact for retry; it does not restart the expiry period. Repeated
`promise_cleanup/1` is harmless.

Only one collector may wait for a reference at a time. A concurrent collector
gets `error(permission_error(collect,promise,Ref),Context)`. Answers are stored
before the queue wakeup, so interrupting a collector does not lose a ready
answer. Expiry or cleanup during a wait wakes that collector with the same
missing-reference error as other invalid references. Its queue remains alive
until the collector releases its claim or its thread has terminated. Disposal
waits outside the mutex for up to 200 intervals of 0.005 seconds for this
release; an unresponsive collector raises
`error(resource_error(promise_cleanup_timeout(Ref)),promise_cleanup/1)` and
leaves the retired queue safe for later release or a cleanup retry.

Local workers stop through a private exception, allowing their own HTTP cleanup
to close their streams. Trealla's raw `thread_cancel/1` does not wake an
indefinite queue read and bypasses Prolog cleanup on v3.13.10. Promise waits use
short reads against the caller's original deadline; stale collector claims can
be recovered after the thread has retired. A standalone observation is recorded
in `UPSTREAM_OUTSTANDING.md`; no upstream issue has been sent for it.

Promise ownership follows client execution namespaces. A WebSocket connection
and its actors share an owner; separate connections remain isolated even when
they authenticate as the same user. HTTP requests receive fresh identities,
which their execution producers and descendant actors inherit. Cached producers
retain the identity of the request that created them. Private source-module
names do not determine ownership. Trusted local threads and actors outside
public client scopes retain their shared `trusted_local` owner; this does not
give them implicit access to client-owned promises.

Foreign `yield/2-3` calls receive the same missing-reference error as unknown
references. `promise_cleanup/1` is harmless for foreign or missing references
and cannot dispose of another owner's promise. Owner checks and lifecycle
changes serialize under the promise mutex; the caller's identity is resolved
before taking that mutex. Public creation without a ground client identity
raises `permission_error(create,promise,client_context)` before allocating
resources. Internal expiry and delivery operate on the recorded promise,
independently of the framework thread's own execution context.

WebSocket disconnect closes promise admission for that client namespace and
retires all of its promises, including pending requests, stored ready answers,
and promises retained after a wait timeout. Admission and retirement share the
promise lifecycle mutex: a racing creation either belongs to the retired
snapshot or raises
`error(permission_error(create,promise,client_namespace(Namespace)), _)` before
queue/worker allocation. Closed-owner markers are retained to reject late
activity from surviving actors.

Retirement wakes waiting collectors with the existing
`existence_error(promise, Ref)` error, requests termination of local request and
expiry threads, and reclaims queues after collector release. Worker stopping
and disposal waits run outside the mutex. Cleanup attempts every retired
promise and reports the first cleanup error; an unresponsive collector retains
its safely retired queue for later release/retry under the existing timeout
policy. Connection actor shutdown still runs if promise cleanup reports an
error. Repeated namespace disposal is harmless.

Surviving actors retain their namespace identity and are not killed by promise
disposal. They may continue other work and catch invalid-reference errors, but
cannot create new promises under the closed namespace. Other WebSocket
clients, trusted-local sharing, and HTTP/cached-producer ownership lifetimes are
unchanged. Timeout-and-retry behavior and callbacks remain unchanged while a
namespace is open. Ownership transfer remains separate work. Local disposal
does not guarantee cancellation of a goal already running on the remote node.
`rpc_namespace_tests.pl` covers pending/ready resources, active collectors,
creation races, late admission, cleanup errors, surviving actors and owner
isolation; it runs in the unit suite, with a live disconnect/client-isolation
check in the interoperability suite. The correctness, lifecycle, and
ownership regressions in `rpc_promise_tests.pl`, `rpc_lifecycle_tests.pl`, and
`rpc_ownership_tests.pl` run with `./tools/test.sh unit`.
`rpc_promise_live_test(Port)`, `rpc_lifecycle_live_test(Port)`, and
`rpc_ownership_live_test(Port)` check HTTP delivery, local stream cleanup, and
client isolation against an existing local node. The interoperability runner
also runs the ownership check against its disposable Trealla node.

```prolog
?- rpc('http://localhost:3060', member(X, [a,b,c])).
X = a ; X = b ; X = c.

?- promise('http://localhost:3060', (sleep(1), X=a), Ref,
           [template(X)]),
   yield(Ref, Answer, [timeout(0.3), on_timeout(Answer=timeout)]).
Answer = timeout.
```

## Remaining limitations

### toplevel_actors.pl

- Mid-enumeration `limit(N)` and `target(P)` changes are supported. Because
  Trealla's public `call_with_time_limit/2` commits to the first solution, the
  port uses reusable runtime timers for each active computation slice and
  suspends them while a result page waits for `next`.

### web_prolog.pl

- Core version-1 wire compatibility and source-bearing actor/toplevel spawns
  now include execution-profile enforcement and native Trealla blacklist and
  whitelist sandbox modes plus wall-time, idle, actor-count, and
  textual-input ceilings, authentication, WebSocket origin checks, and
  connection ownership, plus per-principal rate/concurrency and IP/CIDR
  access limits with explicit trusted-proxy handling.
  A Docker/Caddy boundary for an invitation-only pilot is provided under
  `Deployment/`. `src_uri/1` has an exact-origin, redirect-aware, size- and
  time-bounded fetch policy plus resolve-check-connect IP pinning.
  OS/container egress policy remains recommended as an independent boundary.
- HTTPS source loading pins every resolver result through the address policy
  while retaining the URI host through `server_name/1` for SNI and certificate
  verification.

### distribution.pl

- Node-to-node terminal endpoint inheritance, output acknowledgement, and
  prompt responses are implemented. Browser-terminal second-stage
  acknowledgement (`browser_io_reply`) and connection-scoped, one-shot prompt
  authorization are also implemented when the browser negotiates
  `io_ack:true`.

### rpc.pl

- Trealla's HTTP library recognizes `https://` when the runtime is built with
  OpenSSL. The repository's convenience build uses `NOSSL=1`, so use an
  SSL-enabled runtime or terminate TLS at a reverse proxy. SSL-enabled
  v3.13.2 clients verify certificate chains and host names by default.

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

#### 1. Mutable per-thread actor state

Trealla v3.13.2 provides `thread_local/1` and per-thread non-backtrackable
globals. The actor runtime uses `nb_setval/2` and `nb_current/2` for mutable
mailbox, parent, terminal, paging, and connection state. A clean retest also
passed with a repeatedly replaced `thread_local/1` mailbox value; the existing
representation remains because it directly models one mutable value and is
already covered by the full suite:

```prolog
deferred_list(L) :-
    (nb_current('$actor_deferred', L) -> true ; L = []).

deferred_put(L) :-
    nb_setval('$actor_deferred', L).
```

This directly matches the state lifetime instead of encoding thread IDs into
process-wide blackboard keys.

#### 2. Actor threads are detached at creation

Trealla v3.13.10 refuses `thread_detach/1` when a terminating thread calls it
from its own `at_exit` hook. Actor threads are therefore created with
`detached(true)` up front, and the hook does not attempt self-detach.

#### 3. Final thread status is native

Trealla v3.13.10 exposes the final success, failure, or exception through
`thread_property(Me, status(Status))` inside `at_exit`. The port now uses that
native status for ordinary monitor notifications. Only an explicit `exit/1`
reason is recorded separately, because first-exit-wins is actor semantics and
the internal unwind exception is not the public termination reason.

#### 4. `output/1-2`, `input/2-3`, `respond/2` are added explicitly

These predicates exist in the canonical `simple-node/actors.pl`
but were missing from the very first Trealla port. They are now
implemented here on top of the per-thread parent pointer described
in delta #1.

#### 5. Private modules use the native lifecycle

`isolation.pl` runs the complete child-side actor lifecycle inside Trealla
v3.13.2's `in_temporary_module/3`. Module records can therefore be reused
without accumulating empty actor modules, and cleanup follows success, failure,
exceptions, and actor-exit unwinds. Source-free actors import a small
precompiled API facade; source-bearing actors load their private source support
from an in-memory bootstrap.

### `toplevel_actors.pl`

#### 1. Exact paging uses goal determinism, not `findnsols/4` lookahead

Trealla's `findnsols/4` retains a choicepoint for an exact-size final batch,
so its own determinism cannot distinguish that batch from one with more
answers. The PTCP instead wraps the original goal in `call_cleanup/2`, whose
cleanup marker is bound before a deterministic final solution is returned.
This matches the SWI implementation's observable semantics: the actor pauses
at a full non-final page without executing the next solution or its side
effects. A thread-local reversed accumulator holds copied page values, while
mutable integer cells support mid-stream limit and target changes.

### `node.pl`

#### 1. Direct socket server retains node lifecycle control

Trealla v3.13.2 now provides `http_switch_protocol/2`. The node continues to
use `library(sockets)` directly because its connection registry, bounded
shutdown, maintenance gate, authentication, and per-principal governance all
own the handler lifecycle. Query parameters use the native URI form codec.

#### 2. `library(settings)` absent

Defaults that would be `setting/1` declarations in SWI are plain
facts (e.g. `cache_size(100).`).

#### 3. Native clause-count reflection

Trealla v3.13.4 added the `number_of_clauses(N)` property to
`predicate_property/2`.  The port uses it when discovering locally defined
actor predicates.  The node cache size check continues to use `findall/3`
over the cache facts and `length/2` to count its entries directly.

#### 4. Producer-actor caching exploits a Trealla guarantee

Trealla's `receive/1` blocks the OS thread while preserving the
**complete WAM stack**, including every open choicepoint. That is
exactly what makes the suspended-producer cache work across HTTP
requests: the producer actor pauses inside `receive({...})` after
each solution, and on resume backtracks naturally for the next
page. The same pattern would need extra machinery on
implementations where a paused thread does not own a stack
snapshot.

#### 5. HTTP paging request ownership

Each HTTP page request owns a fresh producer before its thread is created, or
an existing producer as it is checked out of the continuation cache. Failure,
exceptions and interruption reaching the request handler reclaim that producer;
terminal success/failure and query errors also close the request scope. Ordinary
unwinding waits for termination using a private monitor, preserving unrelated
messages and application monitors. A caller already committed to actor exit
requests termination without waiting on its dying mailbox. Producer cancellation
controls propagate rather than waiting to be delivered as query errors;
execution-limit errors retain their existing error replies.

Publishing the next page in the cache transfers ownership before the HTTP
response is written. A later socket-write failure therefore preserves the
cached continuation, including one already checked out by another request.
Paging order, lookahead, offsets and retained suspended
continuations are unchanged. Cache overflow now reclaims the oldest producers
in FIFO order. Eviction journals ownership before removing each entry under the
same mutex as checkout, then stops the victims outside that mutex using private
termination monitors. Another request can keep using the cache during cleanup;
a producer already checked out belongs to that request and is not evicted.
The existing request-scope unwind protection also reclaims eviction victims if
trimming is interrupted. Application monitors and unrelated messages are retained.
This does not add immediate disconnect detection during query execution,
remote cancellation, or cache expiry. Forced runtime thread cancellation that
bypasses Prolog cleanup remains outside this
scope. Producer waits still use `receive/1`, now inside the whole-page deadline.
Private replies carry the producer pid in a `$http_page_reply/2` envelope.
Skipping, collection and lookahead select that pid; cleanup waits for its
termination before draining only its queued replies. This prevents late replies
from contaminating another page and preserves unrelated messages/monitors.
Public HTTP responses and node-to-node protocols are unchanged.

HTTP `/call` also validates `once=true|false` (default `false`). A `true`
request uses a fresh producer, skips the requested offset, collects at most the
requested limit and returns `success(Slice,false)` without lookahead. It neither
checks out nor publishes an ordinary cached continuation. The producer counts
its delivered answers in actor-local non-backtrackable state and stops
enumeration at `offset + limit`, before evaluating another alternative. It then
waits for its owning request scope to retire it. The existing
request scope retires it before the response is written, draining only its own
private replies and preserving application monitors. End-of-stream during
skipping returns failure without another request to the exhausted producer.
The whole-page deadline and existing error/cleanup paths remain in force.
`http_once_tests.pl` covers slice boundaries, sharing, cache isolation, monitors,
output mismatch, failure/error and timeout cleanup, plus public Prolog/JSON
requests and boolean validation. It is included in the unit runner; its live
checks are also used against native SWI and Trealla. Ordinary paging, cache
policy, promise options and public wire envelopes are unchanged.

`http_paging_cleanup_tests.pl`, run by `./tools/test.sh unit`, covers startup
failure, interruption during skipping/collection/lookahead, abandoned cache
checkout, publication and overlapping ownership handoffs, terminal results,
output mismatch, query errors, execution timeouts and monitor/message isolation.
`http_cache_eviction_tests.pl`, also in the unit runner, covers real page overflow,
FIFO order, multiple victims, both checkout/eviction orderings, an exception
after removal, continued paging and application-monitor preservation.
`http_page_deadline_tests.pl` covers startup, collection of individually fast
answers, skipping, lookahead, cached fresh budgets, publication handoff, timer
cancellation, infinite limits, private reply selection and selective draining.

### `rpc.pl`

#### 1. `http_open/3` uses the public API directly

Trealla v3.13.2 commits socket opening correctly, so the old `once/1`
compatibility wrapper is gone. URLs are passed directly to the public API.

#### 2. URL encoding uses the native URI library

RPC request values and node query decoding use v3.13.2's
`www_form_encode/2`, including correct UTF-8 percent encoding.

## Overall assessment

The actor/RPC modules are ported and exercised through Trealla v3.13.10:

- **`actors.pl`** — feature-complete, including positive `receive`
  timeouts via the native `thread_get_message/3`
  `deadline(AbsoluteTime)` option.
- **`toplevel_actors.pl`** — paged enumeration uses `call_cleanup/2` around
  the original goal to detect its deterministic final solution without an
  N+1 probe. Mid-enumeration `limit(N)` / `target(P)` changes use mutable
  cells and match the SWI observable semantics.
- **`node.pl`** — concurrent HTTP/WebSocket server, `format=prolog` only for
  the legacy `/call` route.
  The producer-actor cache works particularly cleanly thanks to
  Trealla's stack-preserving `receive/1`.
- **`rpc.pl`** — native `http://` and hostname-verified `https://` transport.
- **`websocket.pl` / `web_prolog.pl`** — native `ws://` and `wss://`
  transport with the Trinity version-1 actor vocabulary, tested in both
  Trealla-to-SWI and SWI-to-Trealla directions.
- **`distribution.pl`** — persistent remote-node connections and asynchronous
  routing to local actor mailboxes using Trinity-compatible `Pid@NodeURL`
  identifiers.

Submitted programs also receive narrow SWI-compatibility mappings for
`atom_string/2` and `between/3`. Trealla's double-quoted text is represented
as character lists, so `atom_string/2` delegates to `atom_chars/2`;
source-loading internals do the same when browser-originated `src_text/1`
values are strings. For `between/3`, both `infinite` and SWI's `inf` alias are
accepted as an unbounded upper limit while finite bounds continue to use
Trealla's native predicate.

The remaining runtime-specific adaptations are recorded in
`UPSTREAM_REPORTS.md`; compatibility paths are kept only where the documented
regressions still require them or where Web Prolog needs stricter application
policy.

### Benchmark stability

Older v2.x builds crashed intermittently in the high-volume threading
benchmarks (`bm-ping-pong.pl`, `bm-spawning.pl`). On v3.13.10, ten fresh
10,000-message ping-pong runs and five fresh 10,000-generation recursive
spawning runs all completed on macOS arm64. The spawning workload takes about
79 seconds and roughly 232 MB maximum RSS at that depth in the pre-optimization
implementation. After adopting native temporary modules and a precompiled API
facade, a fresh 10,000-generation validation completed in 13.32 seconds with
134 MB maximum RSS. These are stability and implementation measurements rather
than claims about Trealla's raw thread cost.

### Comparative performance

A reproducible same-host comparison with the composed SWI implementation is in
[`Benchmarking/SWI_TREALLA_COMPARISON.md`](Benchmarking/SWI_TREALLA_COMPARISON.md).
On the recorded SWI 10.1.3 and Trealla 3.13.10 revisions, Trealla actor creation
is substantially more expensive, while its warmed local ping-pong path is about
20% faster. The raw samples and runner are retained with the report so the
comparison can be repeated after either implementation changes.

## Native statechart execution

`statechart_spawn(Pid, Options)` starts a local chart actor. Supply exactly one
XML source, `src_text(Text)` or `src_uri(URI)`, plus optional supplemental Prolog
`src_list/1` or `src_predicates/1` sources. `trace(true)` is the default;
`trace(false)` suppresses trace events, and duplicate trace options are rejected.
Ordinary local spawn options, monitors, links, I/O targets and atomic `name/1`
creation use the existing actor machinery. Remote `node(URL)` creation is also
supported, as described below.

The caller fetches URI sources through the existing origin/IP allowlists,
redirect checks, fetch deadline and source-size limit. A root-relative URI uses
the configured node URL. URI loading remains disabled until the operator
configures an allowlist; the constructor does not weaken that policy. XML is
parsed, its supported features validated, supplemental sources checked, and
embedded guards/actions checked before actor creation. Dynamic calls in chart
code retain runtime sandbox guards. The calling public request's sandbox mode
and execution profile are retained; direct trusted Prolog calls default to
`blacklist`/`actor`. Application code runs against the chart actor's own private
sources and the configured shared database, not the interpreter's module.
Blacklist mode retains its existing qualifications and is not a proof that
arbitrary code is safe.

The transition engine supports the pause/resume example and the execution
features listed above. History default transitions are attached to the history
node rather than its parent, correcting an existing model-compiler bug.
Embedded `<datamodel>` code is loaded after supplemental sources, in document
order. Its local clauses append to supplemental clauses and shadow shared
predicates only in that chart. Facts, rules, DCGs and `dynamic/1`/`discontiguous/1` declarations
use the existing private actor source loader; separate charts do not share
mutable datamodel facts. Empty `dynamic/1` and `discontiguous/1` declarations
create existing predicates with no clauses, as required by ISO: calls fail
normally, negation succeeds and `current_predicate/1` succeeds. Declared
predicates and both declaration types survive `src_predicates/1` copying,
including when the same predicate carries both declarations. Clause order and
variable sharing are retained; no persistent placeholder clause is added.
The same source sandbox applies before startup: in
blacklist/whitelist modes only the existing permitted declarations are accepted,
and arbitrary directives are rejected. An empty `dynamic/1` declaration also
admits that predicate in the chart’s whitelist application vocabulary;
`discontiguous/1` declarations also admit their predicates in checked source.
Malformed or reserved declaration targets are rejected. The source policies
still reject `multifile/1` in both blacklist and whitelist modes; this repair
does not change that policy. `source_declaration_tests.pl` covers text/list
sources, empty predicates, declaration copying and these sandbox boundaries.
Trealla’s private actor namespace supplies isolation; the XML code need not
declare `thread_local/1`. Sandbox-off retains trusted source-loading semantics.

Local `<spawn type="actor">`, `<spawn type="toplevel">` and
`<spawn type="statechart">` reuse the existing constructors. Local server and
supervisor invocation use the existing policy-aware behaviour preparation. As in SWI, invocation
waits until immediate transitions and queued internal events have settled;
transient states exited before that point create no children. Each successful
invocation emits `invoked(Type,Pid,State)` and queues the internal event
`spawned(Pid)`. Ordinary output/answer messages and optional `monitor(true)`
notifications report child results and termination; there is no automatic
child-completion `done(State)` event.

Child operands/options and local destinations are validated before the parent
starts. Source predicates are copied from the parent chart's private database
at invocation time, after its datamodel is installed. Child source preparation
and execution preserve the chart's sandbox mode/profile and existing fetch
restrictions. Inline source belongs to the child, not the parent datamodel.
Nested chart XML is compiled/checked by its constructor at invocation time.

Exiting an owning state sends `exit(Child,stop)` to its recorded children,
including those created with `link(false)`, and retires those records. The
chart-to-child link is removed at that handoff, preventing a second exit signal
from parent cleanup from interrupting the child’s own cleanup. Links remain
active throughout the owning state’s lifetime. Re-entry
creates fresh children. Chart cleanup also stops outstanding recorded children
on failure, exception or abort, including partial invocation startup failure.
Like SWI's state-exit handling, this requests termination without waiting for
completed child shutdown. It does not change general actor shutdown policies.

Server invocation requires `callback/1` and `state/1`; supervisor invocation
requires `children/1`. Inline source stays private to the behaviour. Callback
predicates and supervisor child entry predicates defined in the parent are
copied at invocation, alongside explicit `src_predicates/1` sources. Callback
closures, child specifications, supplied code and runtime callbacks retain the
chart’s sandbox/profile checks. Supervisor requests use the existing guarded
child-admission path, including dynamic additions. Names, reply formats and
restart policies retain their existing behaviour semantics.

`node(URL)` also invokes an actor, toplevel, server or supervisor remotely.
Copied parent predicates are materialized when the stable state is invoked.
The calling Trealla node resolves supplemental Prolog `src_uri/1` sources under
its fetch policy before sending their contents; the peer independently checks
the received source and entry under its own profile/sandbox. Sender-private
guard closures are not used as remote behaviour entries. Actor spawning uses
the existing transport; toplevel startup uses the `toplevel_spawn` command;
servers use `server_loop/2` and supervisors use `sup_init/2`, as in SWI.
Trealla's narrow server receiver adapter checks callbacks and source and retains
runtime callback guards. A user-defined `server_loop/2` supplied as source
continues through ordinary actor spawning instead of the behaviour adapter.

Remote names remain caller-side aliases, monitors retain their complete
references, and remote toplevel calls retain templates, answer terms and target
routing through the existing checked query command. State exit and partial
invocation rollback request remote termination through the existing connection;
they do not wait for completed remote shutdown or guarantee reclamation after
connection loss. The native SWI and Trealla interoperability tests cover all
four types, copied/inline sources, replies, monitors, name conflicts, sender and
receiver sandbox rejection, rollback and unrelated monitors.

Remote `statechart_spawn/2` and `<spawn type="statechart">` use the same
constructor and the SWI-compatible `interpret/1`, `interpret_text/1`,
`interpret_trace/2` and `interpret_text_trace/2` wire entries. A narrow Trealla
receiver adapter shares local chart preparation and runs the resulting model
in the transport-created actor: its returned pid is the actual chart, without
an extra wrapper actor. Caller-supplied definitions of those entry predicates
retain ordinary source treatment; qualified private runtime calls are not
made public.

For remote charts, the destination fetches URI XML and resolves root-relative
XML URIs against its configured public URL, applying its own fetch limits.
The sender copies supplemental `src_predicates/1` at invocation and resolves
supplemental Prolog URI sources under its own policy, as above. Supplemental
Prolog precedes the embedded datamodel. The destination independently applies
its profile/sandbox to those sources, guards and actions; sender module names
and compiled private guard closures grant no authority there. Text charts are
also validated under the sending Trealla chart's policy. Private mutable data,
trace settings, naming, complete monitor references and state-exit cleanup are
preserved.

Trealla validates/fetches the chart before returning the successful spawn
reply, so a preparation error releases the caller's name reservation without
publishing a pid. SWI may acknowledge creation before XML loading fails and
report failure through `down/3`; its embedded action checks also occur at
execution time. Callers must therefore handle both setup errors and later
termination when using different peers. Remote halt retains each runtime's
existing acknowledgement and timeout behavior.

The outbound client decodes acknowledged terminal/trace envelopes and sends
`browser_io_reply` after accepting them. Spawn waits service these
acknowledgements too, preventing trace-enabled charts from blocking later
startup. Trace terms use the transport's actor operators when decoded.
Native SWI's distributed terminal sink remains in effect when no inherited
terminal endpoint is supplied.

`node(localhost)` remains accepted for every type. Remote destinations inside
supervisor child specifications, dynamic trace toggling and connection-loss
reclamation remain separate work. `remote_chart_tests.pl` covers preparation,
source fetching, private data, trace envelopes, invocation, halt and monitors;
`swi_remote_chart_interop.pl` exercises SWI's public constructor against Trealla.

`statechart_halt(Pid, Reply)` waits for the legacy `reply(true)` stop
acknowledgement or observed termination. The three-argument form adds a
nonnegative seconds timeout; on expiry it kills the chart and waits for its
private down notification. Acknowledgement yields `true`, while termination
without acknowledgement or forced termination yields `killed`. Replies are
selected before unifying the output, and only the wait's private monitor is
withdrawn/flushed. This retains the legacy untagged acknowledgement protocol;
it does not add stale-reply correlation. Interpreter cleanup releases internal
queues and cancels outstanding transition timers, including graceful halt.

Trace events retain the SWI `statechart_trace` WebSocket event with a textual
Prolog payload; the portal's existing trace display handles them. The runtime
itself serves execution APIs, not portal assets. `statechart_actor_tests.pl`
checks hierarchy/history, isolation, event/guard/action variable sharing,
parallel completion, timers, deferred events, private sources, mutable datamodel
isolation, GCD/closure computations, shared-predicate shadowing and sandbox
admission. `swi_statechart_interop.pl` checks public text/URI startup, traces,
halt, monitor delivery and fetch restrictions. These run in the ordinary unit
and interoperability suites. `statechart_invocation_tests.pl` additionally
checks actor/toplevel/server/supervisor/nested-chart invocation, parent datamodel source copying,
paging, invocation timing, state re-entry, partial startup rollback, abort
cleanup and unrelated monitors. `remote_statechart_invocation_tests.pl` adds
server receiver/sandbox boundaries and live four-behaviour checks against SWI
and Trealla, including reply targets, aliases and rollback. The local invocation examples 13–17
are supported; this does not claim every demonstrator example is supported.


## Runtime ownership and remote adapters

The actor registration, promise lifecycle, worker-scope, supervisor cleanup,
HTTP producer and native statechart sections above describe local ownership.
The following notes connect those mechanisms to the remote invocation adapters.

Remote chart creation and invocation use SWI-compatible interpreter entry forms;
the receiver prepares and runs the chart in the transport-created actor, so the
returned pid is the chart rather than a second actor. Its checks independently
cover XML, supplemental source, embedded datamodel, guards and actions. Sender
module qualifications and guard closures confer no authority. Supplemental Prolog
source is materialised by the sender; the destination fetches URI XML using its
configured public URL and fetch restrictions.

Remote servers use `server_loop/2` through the narrow callback-checking receiver
adapter; supervisors use the `sup_init/2` adapter with child validation and source
context. Toplevel invocation uses checked startup/query commands. Chart state
exit retires invocation records and chart-to-child links before requesting
`exit(Child,stop)`, avoiding a second parent-cleanup signal during child cleanup.
Failure/abort cleanup also stops recorded children. Neither path waits for
completed remote shutdown or establishes cancellation after connection loss.

The outbound client acknowledges decoded terminal/trace envelopes even while
waiting for another spawn reply; otherwise a trace-enabled chart could block
later startup. Canonical answer-term and correlation wire conventions are shared
with the [native transport guide](https://github.com/torbjornlager/trinity-demonstrator/blob/main/prolog/web_prolog/README.md#node-transport-implementation).
The existing protocol sections here retain Trealla's receiver/outbound-specific
details and legacy compatibility paths.

Native Trealla `statechart_halt/2-3` uses a private monitor and the legacy untagged
`reply(true)` acknowledgement. Cleanup retires interpreter queues, transition
timers and its own monitor; the shared manual retains its observable timeout and
stale-reply qualifications. Declaration loading for empty `dynamic/1` and
`discontiguous/1` predicates uses real empty predicate definitions rather than
placeholder clauses; copied sources retain declarations. Checked loading still
rejects malformed/reserved indicators and sandboxed `multifile/1`.

Supervisor startup/replacement journals record ownership before thread creation
and retain it through monitor installation and state admission. Cleanup attempts
run in reverse order using declared shutdown policies, preserving the original
startup/restart reason when ordinary cleanup fails. Private termination monitors
provide the ordinary-unwind barrier; a caller already committed to actor exit
cannot wait on its dying mailbox. This differs from raw runtime thread
cancellation, which can bypass Prolog cleanup. The dedicated regression files
and unit runner document those boundaries without adding language guarantees.


## Relation to the research agenda

The book’s [research and engineering agenda](https://github.com/torbjornlager/boken/blob/main/author/appendix-research-agenda.tex)
is maintained separately from this runtime guide.

The supported-feature, portability-delta, lifecycle and regression sections of
this README record Trealla implementation evidence. The book agenda identifies
portable contracts and production requirements; it does not assume that native
SWI implementation status applies to Trealla. Remaining differences are also
explicit in the shared language manual.
