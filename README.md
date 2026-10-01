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
| `rpc.pl`              | HTTP client wrapper (`rpc/2,3`) over `/call`        |
| `websocket.pl`        | Native RFC 6455 WebSocket client/server transport   |
| `web_prolog.pl`       | Trinity-compatible version-1 actor protocol         |
| `distribution.pl`     | Persistent remote-node client and `Pid@Node` routing |
| `websocket_tests.pl`  | Unit and Trealla/SWI interoperability tests         |
| `distribution_tests.pl` | Trealla/Trealla and Trealla/SWI node tests       |
| `swi_websocket_interop.pl` | SWI side of the interoperability tests        |
| `UPSTREAM_REPORTS.md`   | Candidate Trealla feature requests and bug reports |
| `NOTICE.md`            | Source provenance and third-party attribution   |
| `parallel.pl`         | `parallel/1` and `first_solution/2` demo client     |
| `tests.pl`            | Manual test suite (no plunit on Trealla)            |

`parallel.pl` is pure client code over the actors API and runs
unchanged on Trealla, so no separate Trealla variant is needed.

## Test results

All 33 manual tests pass on Trealla v3.12.6 (the original 30 also pass on
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

The helper disables TLS in this test build; the automated matrix uses plain
loopback HTTP and WebSocket connections. Production TLS behavior must be
tested with an SSL-enabled build or, preferably for now, behind a terminating
proxy.

The runner rejects executables that report `trealla(0,0,0,[])`, applies a
hard timeout to every fresh process, and keeps actor, toplevel, parallel, and
WebSocket state isolated. Run the bidirectional Trealla/SWI WebSocket and
protocol matrix with `./tools/test.sh interop`, or everything with
`./tools/test.sh all`. Set `SWIPL`, `TEST_TIMEOUT`, or `TEST_PORT_BASE` to
override their defaults.

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

All four demos from `parallel.pl` also run unchanged. `node.pl`
and `rpc.pl` have no automated tests but are exercised manually
with `node(3060)` on one Trealla instance and
`rpc('http://localhost:3060', member(X, [a,b,c]))` from another.

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

The current protocol layer is for trusted peers.  It does not yet port
Trinity's origin/authentication policy, execution profiles and sandbox,
resource quotas, source-loading options, or Trinity's full node-controller
routing table.
Do not expose its
goal execution endpoint directly to an untrusted network.

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
`X-Web-Prolog-Capabilities`.  The defaults are intended for trusted private
node networks and can be replaced with explicit `header/2` options.

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

```prolog
?- rpc('http://localhost:3060', member(X, [a,b,c])).
X = a ; X = b ; X = c.
```

## Remaining limitations

### toplevel_actors.pl

(No outstanding limitations as of Trealla v2.99.6.  Mid-enumeration
`limit(N)` and `target(P)` changes via `toplevel_next/2` are now
fully supported.)

### node.pl

- Active detached connections are not currently tracked for graceful
  process-wide shutdown.

### web_prolog.pl

- Core version-1 wire compatibility and source-bearing actor/toplevel spawns
  are implemented; Trinity's security and resource-governance layers remain
  to be ported. `src_uri/1` is not yet supported.
- A TLS-enabled Trealla client currently lacks complete hostname-verified
  certificate validation in the underlying socket implementation.

### distribution.pl

- Node-to-node terminal endpoint inheritance, output acknowledgement, and
  prompt responses are implemented. Browser-terminal second-stage
  acknowledgement (`browser_io_reply`) and connection-scoped, one-shot prompt
  authorization are also implemented when the browser negotiates
  `io_ack:true`.

### rpc.pl

- `https://` URIs are not supported (only `http://`).

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
