# Porting `library(actors)` (and friends) to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(tested on v2.95.4).

## What v2.95.4 changes for this port

v2.95.4 renamed several stream/network built-ins by prefixing them
with `$`:

  - `server/3`     → `$server/3`
  - `accept/2`     → `$accept/2`
  - `parse_url/2`  → `$parse_url/2`
  - `client/5`, `http_location` likewise.

The bare names are now `existence_error(procedure, ...)`. Two of
our files needed the rename:

  - `node.pl` — `server/3`/`accept/2` calls in `node/1` and
    `node_loop/1` updated to `'$server'/3` / `'$accept'/2`.
  - `rpc.pl` — `parse_url/2` updated to `'$parse_url'/2`.

The test suite (t1–t21) does not exercise either file, so the
suite passed before the rename was applied — the broken behaviour
only shows up on a real `node(P)` call or `rpc/2,3` round-trip.

`thread_get_message/3`'s timeout granularity is somewhat better in
v2.95.4 (0.05 s now returns in ~0.075 s), but still bad for
mid-range values (0.1 → ~0.9 s, 0.2 → ~0.97 s). The timer-actor
emulation is still retained — see delta #7 for the updated table.

`thread_send_message/2` to a dead thread is *still* uncatchable in
v2.95.4 (verified), so the `actor_alive/1` table (delta #5) stays.

A `getlines/3` predicate was added with an `empty(+Bool)` option;
not currently needed by the port (single-line responses suffice for
`/call`'s prolog format).

## What v2.94.20 changed for this port

The `findnsols/4` polyfill is gone — Trealla v2.94.20 ships a
proper lazy, non-deterministic built-in. The `toplevel_actors.pl`
findnsols section (about 100 lines: the polyfill itself plus
`collect_n`, `gather_nsols`, `take_n`, and the `nsols_bag` /
`nsols_state` dynamic state) was deleted, and the `count(N)`
wrapper that existed only to satisfy SWI's `nb_setarg` mutability
trick was unwound at the same time. A counter probe confirmed the
new built-in is genuinely lazy: each batch consumes exactly N
solutions, not N+M.

`thread_get_message/3` also gained a working `timeout(Float)`
option in v2.94.20, but the timer-actor emulation in `actors.pl`
was retained: see delta #7 below for the granularity numbers.

## What v2.94.16 changed for this port

Trealla v2.94.16 ships fixes for almost every quirk the original port
worked around. The port has been simplified accordingly:

**Polyfills removed (built-ins now exist):**

  - `option/2-3` (former delta #1 in `actors.pl`). Polyfill and the
    `option/2,3` exports gone; `rpc.pl` no longer imports them.
  - `is_thread/1` (former delta #2 in `actors.pl`). Polyfill was dead
    code anyway. Doesn't show up in `current_predicate/1` listings,
    which is what fooled me at first.
  - `strip_module/3` (former delta in `toplevel_actors.pl`).
    Built-in via `library(loader)`; same `current_predicate`-blind
    story.

**Workarounds removed (Trealla bugs fixed upstream):**

  - `port(Port)` with a runtime-bound integer now reaches the C
    builtin correctly, so the `PortOpt =.. [port, Port]` trick is
    gone from `rpc.pl`.
  - `thread_self/1` in a `thread_signal`-delivered goal no longer
    raises `uninstantiation_error`, so the `'$do_exit'(Pid, Reason)`
    helper in `actors.pl` is gone — `exit/2` now injects
    `actors:exit(Reason)` directly. (Former delta #6.)

**Stdlib used in place of hand-written parsing:**

  - `library(http)`'s `parse_url/2` replaces the home-grown
    `parse_uri/4` in `rpc.pl`. (Former rpc delta #1.)

Other upstream fixes — `abort/0`, `thread_detach/1` in `at_exit`,
`thread_property` status in `at_exit`, `thread_signal` on a dead
thread (now `actors.pl` deltas #2–#5) — were verified with probe
scripts but the existing workarounds were left in place: they
continue to work and ripping them out would be a non-trivial
refactor of the start/at-exit machinery. The deltas below describe
the workarounds that are still in the code and note where Trealla
has caught up.

One thing is still missing:

  - `thread_get_message/3` accepts a `timeout(T)` option but appears
    to ignore it (the call still blocks forever). The timer-actor
    emulation in delta #7 therefore stays.

`thread_send_message/2` to a dead thread also still raises an
uncatchable error, which is why the `actor_alive/1` table in
`actors.pl` (delta #5) remains.

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
  (emulated via a short-lived timer actor — see delta #7 below)
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
`thread_get_message/3`), but is now emulated — see delta #7.

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
be used verbatim and why. The original port had ten such deltas;
v2.94.16 made the `option/2-3` polyfill obsolete (former #1) and the
`is_thread/1` polyfill turned out to be dead code that no caller
ever used (former #2), so the remaining items are renumbered to
eight.

### 1. No `thread_local/1`

The deferred-message list, previously stored in a `thread_local`
dynamic predicate, is kept on Trealla's per-thread blackboard.
`deferred_list/1` also drops any `'$actor_timeout'(_)` sentinels
that arrived behind a matched message (so the deferred list does
not accumulate stale timers across many timed receives — see
delta #7):

```prolog
deferred_list(L) :-
    (   bb_get('$actor_deferred', Raw) -> true ; Raw = [] ),
    prune_stale(Raw, L).

deferred_put(L) :-
    bb_put('$actor_deferred', L).
```

### 2. `abort/0` crashes a thread

Calling `abort/0` inside a spawned thread segfaults Trealla.
Replaced with `throw(actor_exit)`, which is caught by a wrapper
in `start/4`. (Fixed upstream in v2.94.16; workaround retained.)

### 3. `thread_detach/1` inside `at_exit` hangs

The at-exit hook never returns if it calls `thread_detach/1`.
Threads are created with `detached(true)` up front instead, and
`thread_detach` is not called from `stop/2`. (Fixed upstream in
v2.94.16; workaround retained.)

### 4. `thread_property(Pid, status(...))` reports `running` inside `at_exit`

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
(Fixed upstream in v2.94.16: `at_exit` now sees the final status;
workaround retained because exit_reason still carries the user's
exit reason from `exit/1,2`, which `status/1` does not.)

### 5. `thread_signal` on a dead detached thread raises an uncatchable error

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
entry as its first action. (Partially fixed upstream in v2.94.16:
`thread_signal/2` on a dead detached thread now raises a *catchable*
domain error, but `thread_send_message/2` is still uncatchable, so
the actor_alive table stays.)

### 6. `output/1-2`, `input/2-3`, `respond/2` absent from initial port

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

### 7. `thread_get_message/3` timeout granularity is too coarse

SWI-Prolog provides `thread_get_message(Mailbox, Msg, [timeout(T)])`,
which blocks up to T seconds for a message. Trealla v2.94.20 has
this predicate and the `timeout(Float)` option does fire — fixing
the unreachable-`if` bug noted in earlier releases — but the
granularity is still too coarse to use as a drop-in. Measured on
v2.95.4:

| asked     | actually returned after |
|-----------|-------------------------|
| 0.05 s    | 0.075 s                 |
| 0.1  s    | 0.91 s                  |
| 0.2  s    | 0.97 s                  |
| 0.5  s    | 0.94 s                  |
| 1.0  s    | 1.29 s                  |
| 2.0  s    | 2.01 s                  |

(0.05 s is now genuinely tight; everything between ~0.1 s and
~1 s still overshoots wildly.)

The cause is still in `src/bif_threads.c` (`do_match_message`):
the wait loop is `do { suspend_thread(t, 10); } while (... && cnt++ < 1000)`,
and the timeout check sits *outside* that loop. So the timeout
only gets re-evaluated when the inner loop exits — either a message
arrives, the cnt cap of 1000 (i.e. up to 10 s) is hit, or
`pthread_cond_timedwait` returns spuriously. For sub-second
timeouts that's far worse than useful.

A receive timeout that fires "somewhere between 5x and 10x the
requested duration" breaks too many real use cases — periodic
poll loops, supervision deadlines, bounded-wait synchronisation —
so the timer-actor emulation is retained. The timer uses `sleep/1`
which is accurate; the test suite (t19) reliably sees ~0.21 s for
a 0.2 s requested timeout.

The control flow is a `catch/3` around an inner mailbox loop. A
fresh atom `Ref` is generated with `make_ref/1`, a short-lived
timer actor sleeps T seconds and then sends `'$actor_timeout'(Ref)`
back to the receiver; the inner loop pulls messages with the
unconditional `thread_get_message/2`, throws `'$receive_timeout'(Ref)`
when it sees the sentinel, and the outer catch runs `on_timeout/1`.
`Ref` must be an atom rather than the TimerPid because Trealla
loses the identity of a compound containing `'$thread'(N)` opaque
cells across throw/catch:

The control flow is a `catch/3` around an inner mailbox loop. The
loop throws `'$receive_timeout'(Ref)` the moment it pulls the
matching sentinel out of the mailbox; the catch then runs the
`on_timeout/1` goal. On a normal match, the loop returns and the
match arm cancels the still-running timer:

```prolog
receive_loop_timed(Mailbox, Clauses, Options, Deferred, T) :-
    self(Self),
    make_ref(Ref),
    spawn(timer_actor(Self, T, Ref), TimerPid, [link(false)]),
    catch(
        ( timed_loop(Mailbox, Clauses, Options, Deferred, Ref),
          cancel_timer(TimerPid, Self, Ref) ),
        '$receive_timeout'(Ref),
        ( deferred_put(Deferred),
          option(on_timeout(Goal), Options, true),
          call(Goal) )
    ).

timed_loop(Mailbox, Clauses, Options, Deferred, Ref) :-
    thread_get_message(Mailbox, Msg),
    (   Msg == '$actor_timeout'(Ref)
    ->  throw('$receive_timeout'(Ref))
    ;   select_body(Clauses, Msg, Body)
    ->  deferred_put(Deferred), call(Body)
    ;   append(Deferred, [Msg], Deferred1),
        timed_loop(Mailbox, Clauses, Options, Deferred1, Ref)
    ).
```

The match path runs `cancel_timer/3` (TimerPid, Self, Ref), which
sends `cancelled` to the timer via `exit/2` and peels one
already-arrived sentinel off the front of the mailbox. Sentinels
that arrived *behind* other messages stay briefly in the deferred
list and are filtered by `prune_stale/2` on the next receive
(see delta #3). The timeout path leaves the timer to exit
naturally — signalling it would race with its own at_exit hook.

## Portability deltas — `toplevel_actors.pl`

### 1. `findnsols/4` — now a Trealla built-in

Earlier versions of this port carried a sizeable lazy `findnsols/4`
polyfill (an `asserta`/`catch` collector with N+1 lookahead, plus
`collect_n`, `gather_nsols`, `take_n` and the `nsols_bag` /
`nsols_state` dynamic state). Trealla v2.94.20 ships a real lazy
non-deterministic `findnsols/4`, so the polyfill was deleted.

The original SWI implementation wrapped the limit in `count(N)` so
that `nb_setarg/3` could mutate it mid-stream; without `nb_setarg`
that wrapping does nothing useful, so it has been unwound here
too — the PTCP state machine now passes the integer `Limit`
straight through.

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

### 4. No implicit re-export in Trealla's module system

SWI-Prolog re-exports a predicate when it appears in the module
declaration but is defined in an imported module.  Trealla does not:
only predicates actually defined in the module are exported.

Consequence: `toplevel_actors` cannot transparently re-export
`spawn/1-3`, `receive/1-2`, etc.  Users must load both modules:

```prolog
:- use_module(actors).
:- use_module(toplevel_actors).
```

### 5. `select_body` — unqualified `{...}` patterns

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

### 1. `http_open/3` URL-string form fails for localhost

Calling `http_open('http://localhost:3060/...', S, [])` does not
reliably connect on Trealla. Workaround: pass the components in
list form: `http_open([host(H), port(P), path(P0)], S, [])`.

### 2. `getline/2` reads only one line

The response body is read with `getline/2`, which works because the
node's response is exactly one line (`term.\n`). Multi-line response
terms would be silently truncated; if the response format ever
grows, a proper streaming reader is needed.

### 3. URL percent-encoding is hand-rolled

There is no `uri_encoded/3` or `www_form_encode/2` in Trealla, so
`url_encode/2` is implemented inline alongside `url_decode/2`,
following RFC 3986's unreserved-character set.

## Overall assessment

Four modules are ported and exercised on Trealla:

- **`actors.pl`** — feature-complete, including positive `receive`
  timeouts (emulated via a timer actor because the native
  `thread_get_message/3` timeout has ~10x granularity overshoot —
  see delta #7).
- **`toplevel_actors.pl`** — paged enumeration uses Trealla's lazy
  built-in `findnsols/4`; only the mid-enumeration `limit(N)` /
  `target(P)` change is silently ignored, because Trealla has no
  `nb_setarg/3`.
- **`node.pl`** — single-threaded server, `format=prolog` only.
  The producer-actor cache works particularly cleanly thanks to
  Trealla's stack-preserving `receive/1`.
- **`rpc.pl`** — `http://` only; relies on `getline/2` reading the
  whole one-line reply.

Every other delta is a small, localised workaround for a
Trealla-specific quirk.
