# Porting `library(actors)` (and friends) to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(v2.92.38).

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
This document records what changed versus the canonical
`simple-node/` sources and why.

## Test results

All 21 manual tests pass on Trealla:

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

All four demos from `parallel.pl` also run unchanged on Trealla
against `actors.pl`. `node.pl` and `rpc.pl` have no automated tests
but are exercised manually with `node(3060)` on one Trealla instance
and `rpc('http://localhost:3060', member(X, [a,b,c]))` from another.

## What is supported

### actors.pl

- `spawn/1-3` with `monitor(Bool)` and `link(Bool)` options
- `self/1`, `send/2`, `(!)/2`
- `receive/1-2` with patterns, guards (`Pattern if Guard -> Body`),
  `timeout(0)` polling, **and positive `timeout(T)` deadlines**
  (emulated via a short-lived timer actor — see delta #10 below)
- `monitor/2`, `demonitor/1-2`
- `register/2`, `unregister/1`, `whereis/2`
- `exit/1`, `exit/2`
- `output/1-2`, `input/2-3`, `respond/2`
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
- `findnsols/4` — collect at most N solutions; non-deterministic (each
  backtrack delivers the next batch)
- `offset/2` — skip the first N solutions of a goal

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

## What is not supported

### actors.pl

Everything in the original surface is supported. `receive/2` with a
positive timeout used to be unsupported on Trealla (no
`thread_get_message/3`), but is now emulated — see delta #10.

### toplevel_actors.pl

- **Mid-enumeration limit/target change**: the `limit(N)` and
  `target(P)` sub-options of `toplevel_next/2` are accepted for
  protocol compatibility but silently ignored, because the underlying
  mechanism (`nb_setarg/3`) is absent in Trealla.

### node.pl

- Only the `prolog` response format is implemented. Requests for
  `format=json` receive a brief "not yet implemented" notice.
- The server loop handles connections one at a time in the calling
  thread; for production deployment each connection should be
  dispatched to its own actor.

### rpc.pl

- `https://` URIs are not supported (only `http://`).
- The response body is read with `getline/2`, which reads exactly
  one line. The current node format (a single `term.\n` per response)
  is fine, but multi-line response terms would be truncated.

## Portability deltas — `actors.pl`

Each item below is a place where the canonical SWI source could not
be used verbatim and why.

### 1. `library(option)` absent

SWI-Prolog's `option/2-3` is not shipped with Trealla. Polyfilled
in-module:

```prolog
option(Opt, Options, _Default) :-
    memberchk(Opt, Options), !.
option(Opt, _, Default) :-
    functor(Opt, _, 1),
    arg(1, Opt, Default).

option(Opt, Options) :-
    memberchk(Opt, Options).
```

### 2. `is_thread/1` absent

Polyfilled via `thread_property/2`:

```prolog
is_thread(Id) :-
    catch(thread_property(Id, status(_)), _, fail).
```

### 3. No `thread_local/1`

The deferred-message list, previously stored in a `thread_local`
dynamic predicate, is kept on Trealla's per-thread blackboard:

```prolog
deferred_list(L) :-
    (bb_get('$actor_deferred', L) -> true ; L = []).

deferred_put(L) :-
    bb_put('$actor_deferred', L).
```

### 4. `abort/0` crashes a thread

Calling `abort/0` inside a spawned thread segfaults Trealla.
Replaced with `throw(actor_exit)`, which is caught by a wrapper
in `start/4`.

### 5. `thread_detach/1` inside `at_exit` hangs

The at-exit hook never returns if it calls `thread_detach/1`.
Threads are created with `detached(true)` up front instead, and
`thread_detach` is not called from `stop/2`.

### 6. `thread_property(Pid, status(...))` reports `running` inside `at_exit`

In SWI, the at-exit hook can read the thread's final status out of
`thread_property/2`. In Trealla the status is still `running` when
the hook runs, so the outcome cannot be recovered that way.
Instead, the `start/4` wrapper records the outcome explicitly:

```prolog
catch(
    ( call(Goal)
    ->  assertz(exit_reason(Pid, true))
    ;   assertz(exit_reason(Pid, false))
    ),
    E,
    ( E == actor_exit
    ->  true                % exit/1 already asserted the reason
    ;   assertz(exit_reason(Pid, exception(E)))
    )
).
```

`stop/2` then `retract`s `exit_reason/2` to build the `down` message.

### 7. `thread_signal` on a dead detached thread raises an uncatchable error

Once a detached thread has finished, `thread_signal/2` on its PID
throws a domain error that bypasses `catch/3`. The workaround is a
liveness table:

```prolog
:- dynamic(actor_alive/1).

% The top-level thread must be registered too, so the library can
% deliver messages to it from spawned actors.
:- initialization((thread_self(Me), assertz(actor_alive(Me)))).
```

`exit/2` and `send/2` both check `actor_alive/1` before attempting
`thread_signal`/`thread_send_message`, and `stop/2` retracts the
entry as its first action.

### 8. `thread_self/1` inside a `thread_signal`-delivered goal raises `uninstantiation_error`

This is the subtlest difference. When a goal injected via
`thread_signal/2` calls `thread_self/1`, Trealla raises
`error(uninstantiation_error('$thread'(N)), thread_self/1)` --- the
argument appears to be pre-bound in the signal delivery context.

Consequently we cannot implement `exit(Pid, Reason)` by injecting
`exit(Reason)` (whose body calls `self/1`). Instead, the PID is
bound into the injected goal at call-site:

```prolog
exit(Pid, Reason) :-
    (   actor_alive(Pid)
    ->  catch(thread_signal(Pid, actors:'$do_exit'(Pid, Reason)), _, true)
    ;   true
    ).

'$do_exit'(Pid, Reason) :-
    asserta(exit_reason(Pid, Reason)),
    throw(actor_exit).
```

### 9. `output/1-2`, `input/2-3`, `respond/2` absent from initial port

The original `simple-node/actors.pl` provides these predicates;
they were missing from the initial Trealla port. Added alongside
per-thread parent tracking via the blackboard (key includes the
thread ID to avoid cross-thread collisions, since Trealla's
`bb_put`/`bb_get` are globally shared rather than thread-local):

```prolog
set_parent(Parent) :-
    thread_self(Me),
    format(atom(Key), '$actor_parent_~w', [Me]),
    bb_put(Key, Parent).
```

### 10. `thread_get_message/3` (with timeout) absent

SWI-Prolog provides `thread_get_message(Mailbox, Msg, [timeout(T)])`,
which blocks up to T seconds for a message. Trealla's
`thread_get_message/2` only supports the unconditional blocking
form. Positive timeouts are emulated by spawning a short-lived
**timer actor** that sleeps for T seconds and then sends a unique
`'$timeout'(TimerPid)` sentinel back to the receiver:

```prolog
receive_loop_timed(Self, Patterns, T, Options) :-
    make_ref(Ref),
    spawn(timer_actor(Self, T, Ref), TimerPid, [link(false)]),
    ...
    thread_get_message(Self, Msg),
    (   Msg = '$timeout'(TimerPid)
    ->  option(on_timeout(Goal), Options, true), call(Goal)
    ;   try_match_or_defer(Msg, Patterns, ..., TimerPid)
    ).
```

On a successful match the timer actor is cancelled and any pending
sentinel drained from the mailbox. The match path uses
`cancel_timer/2`; the timeout path lets the timer exit naturally.

## Portability deltas — `toplevel_actors.pl`

### 1. `findnsols/4` absent

SWI's `findnsols/4` materialises at most N solutions and, crucially,
is **non-deterministic**: on backtracking it resumes from where it
left off and delivers the next N solutions.  The original
`toplevel_actors.pl` relies on this to drive the PTCP state machine
(state s3 fails deliberately to backtrack into `findnsols` for the
next slice).

Trealla port: implemented with an `asserta`/`catch` collector that
takes a **lazy** N+1 probe per batch — never `findall/3` over the
whole goal, so infinite generators terminate on each page.

`collect_n/5` calls Goal under a `catch/3`; each solution is
asserted into `nsols_bag/2` and a per-thread blackboard counter is
incremented. After N+1 hits the helper throws `'$nsols_limit'` to
stop backtracking; `gather_nsols/3` then harvests the bag in FIFO
order. The N+1 probe lets `findnsols_batch/6` distinguish "this is
the final batch" (cut, deterministic) from "more remain" (leave a
choicepoint to clause 2, which retracts the stored next-offset on
backtracking and continues):

```prolog
findnsols_batch(N, Me, Offset, Template, Goal, List) :-
    N1 is N + 1,
    collect_n(N1, Me, Template, offset(Offset, Goal), Probe),
    length(Probe, Got),
    (   Got =:= 0     -> !, List = []
    ;   Got =:= N1    -> NextOffset is Offset + N,
                         assertz(nsols_state(Me, NextOffset)),
                         take_n(N, Probe, List, _)
    ;   !, List = Probe
    ).
findnsols_batch(N, Me, _, Template, Goal, List) :-
    retract(nsols_state(Me, NextOffset)),
    findnsols_batch(N, Me, NextOffset, Template, Goal, List).
```

`N0` may be an integer or a `count(N)` compound (the original code
wraps the limit in `count/1` as a mutable cell for `nb_setarg`); arg 1
is unwrapped in both cases.

### 2. `offset/2` — now a Trealla built-in

Earlier versions of this port carried an `assertz`/`retract` polyfill
keyed by thread ID, because `offset(N, Goal)` had to skip N solutions
of Goal and the skip counter had to survive backtracking inside
`findall/3`.  Trealla now provides `offset/2` as a built-in, so the
polyfill has been removed.  The module declaration still lists
`offset/2` in its export list — that re-declaration is purely so
clients can `use_module(toplevel_actors)` and call `offset/2` without
an explicit `library(lists)`-style import.

### 3. `nb_setarg/3` absent

State s3 uses `nb_setarg` to mutate the `count(N)` and `target(T)`
cells in place before failing back into `findnsols`.  Without it, the
limit and target cannot change between batches.  The `limit(N)` and
`target(P)` sub-options of `'$next'(Options)` are therefore accepted
but ignored.

### 4. `strip_module/3` absent

Two-clause polyfill:

```prolog
strip_module(_M:Goal, _M, Goal) :- !.
strip_module(Goal, _, Goal).
```

### 5. No implicit re-export in Trealla's module system

SWI-Prolog re-exports a predicate when it appears in the module
declaration but is defined in an imported module.  Trealla does not:
only predicates actually defined in the module are exported.

Consequence: `toplevel_actors` cannot transparently re-export
`spawn/1-3`, `receive/1-2`, etc.  Users must load both modules:

```prolog
:- use_module(actors).
:- use_module(toplevel_actors).
```

### 6. `select_body` — unqualified `{...}` patterns

Because `meta_predicate` semantics are not propagated through
Trealla's module boundaries, `receive({...})` called from outside
the `actors` module may arrive without a module qualifier.  Added a
second clause to handle the unqualified form:

```prolog
select_body({Clauses}, Message, Body) :-
    select_body_aux(Clauses, Message, Body).
```

## Portability deltas — `node.pl`

### 1. `library(http/thread_httpd)`, `http_dispatch`, `http_parameters` absent

Trealla ships only a low-level HTTP layer. The server is built
directly on `server/3` + `accept/2`, and query parameters are parsed
manually from the request path with a small percent-decoder
(`url_decode/2`) and `split/4` driver.

### 2. `library(settings)` absent

Defaults that would be `setting/1` declarations in SWI are plain
facts (e.g. `cache_size(100).`).

### 3. `predicate_property(_, number_of_clauses(N))` absent

The cache size check uses `findall/3` over the cache facts and a
`length/2` instead of querying clause count directly.

### 4. Producer-actor caching exploits a Trealla-specific guarantee

Trealla's `receive/1` blocks the OS thread while preserving the
**complete WAM stack**, including every open choicepoint. That is
exactly what makes the suspended-producer cache work across HTTP
requests: the producer actor pauses inside `receive({...})` after
each solution, and on resume backtracks naturally for the next page.
The same pattern would need extra machinery in implementations
where a paused thread does not own a stack snapshot.

### 5. No `receive/2` timeout needed for producer replies

`compute_answer/5` uses unconditional `receive/1` rather than a
timed receive: the producer is a local actor we just spawned (or
just resumed via `'$request'`), so a reply is guaranteed and a
timeout would only obscure real bugs.

## Portability deltas — `rpc.pl`

### 1. `library(url)` absent

URIs are decomposed with a small `parse_uri/4` predicate and the
query path is assembled with `format/2`. Only `http://` is handled.

### 2. `http_open/3` URL-string form fails for localhost

Calling `http_open('http://localhost:3060/...', S, [])` does not
reliably connect on Trealla. Workaround: pass the components in
list form: `http_open([host(H), port(P), path(P0)], S, [])`.

### 3. `port(Port)` cannot be constructed directly with a runtime integer

Trealla's `bif_client_5` does not dereference the port argument
before calling `is_integer`, so

```prolog
http_open([host(H), port(Port), path(...)], S, [])
```

fails when `Port` is bound at runtime. The fix is to build the
option through `=..`, which produces a fresh compound cell that
Trealla recognises correctly:

```prolog
PortOpt =.. [port, Port],
http_open([host(H), PortOpt, path(...)], S, []).
```

### 4. `getline/2` reads only one line

The response body is read with `getline/2`, which works because the
node's response is exactly one line (`term.\n`). Multi-line response
terms would be silently truncated; if the response format ever
grows, a proper streaming reader is needed.

### 5. URL percent-encoding is hand-rolled

There is no `uri_encoded/3` or `www_form_encode/2` in Trealla, so
`url_encode/2` is implemented inline alongside `url_decode/2`,
following RFC 3986's unreserved-character set.

## Overall assessment

Four modules are ported and exercised on Trealla:

- **`actors.pl`** — feature-complete, including positive `receive`
  timeouts (emulated via a timer actor).
- **`toplevel_actors.pl`** — paged enumeration works for both finite
  and infinite generators (lazy N+1 probe per batch, no upfront
  `findall`); only the mid-enumeration `limit(N)` / `target(P)`
  change is silently ignored, because Trealla has no `nb_setarg/3`.
- **`node.pl`** — single-threaded server, `format=prolog` only.
  The producer-actor cache works particularly cleanly thanks to
  Trealla's stack-preserving `receive/1`.
- **`rpc.pl`** — `http://` only; relies on `=..` to dodge a Trealla
  `bif_client_5` bug and on `getline/2` reading the whole one-line
  reply.

Every other delta is a small, localised workaround for a
Trealla-specific quirk.
