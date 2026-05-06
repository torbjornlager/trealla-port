# Porting `library(actors)` (and friends) to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(tested on v2.95.12).

The port lives alongside this report:

| File                  | Role                                                |
|-----------------------|-----------------------------------------------------|
| `actors.pl`           | Erlang-style actor runtime (`spawn`, `receive`, …)  |
| `toplevel_actors.pl`  | Shell-style PTCP for paged goal execution           |
| `node.pl`             | HTTP server exposing `/call` for remote queries     |
| `rpc.pl`              | HTTP client wrapper (`rpc/2,3`) over `/call`        |
| `parallel.pl`         | `parallel/1` and `first_solution/2` demo client     |
| `tests.pl`            | Manual test suite (no plunit on Trealla)            |

`parallel.pl` is pure client code over the actors API and runs
unchanged on Trealla, so no separate Trealla variant is needed.

## Test results

All 21 manual tests pass on Trealla v2.95.12:

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

All four demos from `parallel.pl` also run unchanged. `node.pl`
and `rpc.pl` have no automated tests but are exercised manually
with `node(3060)` on one Trealla instance and
`rpc('http://localhost:3060', member(X, [a,b,c]))` from another.

## What is supported

### actors.pl

- `spawn/1-3` with `monitor(Bool)` and `link(Bool)` options
- `self/1`, `send/2`, `(!)/2`
- `receive/1-2` with patterns, guards (`Pattern if Guard -> Body`),
  `timeout(0)` polling, and positive `timeout(T)` deadlines
- `monitor/2`, `demonitor/1-2`
- `register/2`, `unregister/1`, `whereis/2`
- `exit/1`, `exit/2`
- `output/1-2`, `input/2-3`, `respond/2`
- `make_ref/1`, `flush/0`
- Links (bidirectional lifecycle coupling)
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

### node.pl

- `node/1` — start an HTTP server on a port
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

- **Mid-enumeration limit/target change**: the `limit(N)` and
  `target(P)` sub-options of `toplevel_next/2` are accepted for
  protocol compatibility but silently ignored. Implementing them
  would require `nb_setarg/3` to mutate the in-flight `count(N)`
  cell; Trealla has no `nb_setarg/3`.

### node.pl

- Only the `prolog` response format is implemented. Requests for
  `format=json` receive a brief "not yet implemented" notice.
- The server loop handles connections one at a time in the calling
  thread; for production deployment each connection should be
  dispatched to its own actor.

### rpc.pl

- `https://` URIs are not supported (only `http://`).

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

Because `bb_put`/`bb_get` are global rather than thread-local, the
parent-pointer key includes the thread ID so distinct actors don't
collide:

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

### `toplevel_actors.pl`

#### 1. `nb_setarg/3` absent

The canonical SWI implementation wraps the per-call `Limit` in a
`count(N)` cell so that `nb_setarg/3` can mutate it between
batches when `toplevel_next(Pid, [limit(NewN)])` arrives. Without
`nb_setarg/3` the cell is read-only, so the wrapping is unwound
and mid-stream `limit(N)` / `target(P)` changes are silently
ignored (see "Remaining limitations" above).

#### 2. No implicit re-export across modules

SWI re-exports an imported predicate when it appears in the
importer's module declaration. Trealla does not — only predicates
actually defined in the module are exported. Consequently
`toplevel_actors` cannot transparently re-export `spawn/1-3`,
`receive/1-2`, etc. Users must load both modules:

```prolog
:- use_module(actors).
:- use_module(toplevel_actors).
```

### `node.pl`

#### 1. No higher-level HTTP framework

Trealla ships only a low-level HTTP layer in `library(http)`
(`http_server/2` is a thin wrapper that forks per connection,
which would break the producer-actor cache). The server is built
directly on `'$server'/3` + `'$accept'/2`, and query parameters
are parsed manually with a small percent-decoder (`url_decode/2`)
and a `split/4` driver.

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

#### 1. `http_open/3` URL-string form is unreliable for localhost

Calling `http_open('http://localhost:3060/...', S, [])` does not
reliably connect on Trealla. The list form is used instead:
`http_open([host(H), port(P), path(P0)], S, [])`. URI
decomposition is delegated to `library(http)`'s `'$parse_url'/2`.

#### 2. URL percent-encoding is hand-rolled

There is no `uri_encoded/3` or `www_form_encode/2` in Trealla's
stdlib, so `url_encode/2` is implemented inline alongside
`url_decode/2`, following RFC 3986's unreserved-character set.

## Overall assessment

Four modules are ported and exercised on Trealla v2.95.12:

- **`actors.pl`** — feature-complete, including positive `receive`
  timeouts via the native `thread_get_message/3` `timeout(Float)`
  option.
- **`toplevel_actors.pl`** — paged enumeration uses Trealla's
  built-in lazy `findnsols/4`; only the mid-enumeration `limit(N)`
  / `target(P)` change is silently ignored, because Trealla has no
  `nb_setarg/3`.
- **`node.pl`** — single-threaded server, `format=prolog` only.
  The producer-actor cache works particularly cleanly thanks to
  Trealla's stack-preserving `receive/1`.
- **`rpc.pl`** — `http://` only.

Every other delta is a small, localised workaround for a
Trealla-specific quirk.
