# Porting `library(actors)` to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(v2.92.38).

The port lives alongside this report as `actors.pl` and
`toplevel_actors.pl`, with a manual test suite in `tests.pl`.
`parallel.pl` is pure client code over the actors API and runs
unchanged on Trealla, so no separate Trealla variant is needed.
This document records what changed versus the canonical
`simple-node/` sources and why.

## Test results

All 18 manual tests pass on Trealla:

| # | Test                                     | Status |
|---|------------------------------------------|--------|
| 1 | basic `receive` pattern match            | ok     |
| 2 | deferred (non-matching) message preserved| ok     |
| 3 | `timeout(0)` poll / on_timeout fires     | ok     |
| 4 | guarded receive with `if`                | ok     |
| 5 | `exit(Pid, kill)` + monitor `down` msg   | ok     |
| 6 | `exit(Pid, bye)` reason propagates       | ok     |
| 7 | `register/2` + named send                | ok     |
| 8 | `parallel/1` success case                | ok     |
| 9 | `parallel/1` failure propagates          | ok     |
|10 | `first_solution/2` picks fastest         | ok     |
|11 | `findnsols/4` non-deterministic batches  | ok     |
|12 | `offset/2` skips N solutions             | ok     |
|13 | `toplevel_spawn` + `toplevel_call`       | ok     |
|14 | `toplevel_next` delivers second batch    | ok     |
|15 | goal failure propagates as `failure/1`   | ok     |
|16 | goal exception propagates as `error/2`   | ok     |
|17 | `toplevel_stop` + session reuse          | ok     |
|18 | `session(true)` loop handles two calls   | ok     |

All four demos from `parallel.pl` also run unchanged on Trealla
against `actors.pl`.

## What is supported

### actors.pl

- `spawn/1-3` with `monitor(Bool)` and `link(Bool)` options
- `self/1`, `send/2`, `(!)/2`
- `receive/1-2` with patterns, guards (`Pattern if Guard -> Body`),
  and `timeout(0)` polling
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

## What is not supported

### actors.pl

`receive/2` with `timeout(T)` where `T \== 0` and `T \== infinite`.
Trealla has no `thread_get_message/3` accepting a timeout option,
so the port throws
`error(unsupported_option(timeout(T)), 'Trealla port: only timeout(0) is supported')`.
`timeout(0)` (poll) works by way of `thread_peek_message/2`.

### toplevel_actors.pl

- **Infinite generators**: `findnsols/4` materialises all solutions via
  `findall/3` on the first call; goals with infinitely many solutions
  will not terminate.
- **Mid-enumeration limit/target change**: the `limit(N)` and
  `target(P)` sub-options of `toplevel_next/2` are accepted for
  protocol compatibility but silently ignored, because the underlying
  mechanism (`nb_setarg/3`) is absent in Trealla.

## Portability deltas

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

### 9. `output/1-2`, `input/2-3`, `respond/2` absent from Trealla port

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


## Portability deltas for `toplevel_actors.pl`

### 1. `findnsols/4` absent

SWI's `findnsols/4` materialises at most N solutions and, crucially,
is **non-deterministic**: on backtracking it resumes from where it
left off and delivers the next N solutions.  The original
`toplevel_actors.pl` relies on this to drive the PTCP state machine
(state s3 fails deliberately to backtrack into `findnsols` for the
next slice).

Trealla port: collect all solutions up front with `findall/3`, then
deliver them in batches via `between/3`.  A cut on the last batch
makes it deterministic, so `call_cleanup/2` can set `Det = true`
immediately — which is how `answer/5` detects that no further
solutions remain.

```prolog
findnsols(N0, Template, Goal, List) :-
    (compound(N0) -> arg(1, N0, N) ; N = N0),
    findall(Template, Goal, All),
    length(All, Total),
    (   Total =:= 0
    ->  !, List = []
    ;   NumBatches is (Total + N - 1) // N,
        between(1, NumBatches, Batch),
        Start is (Batch - 1) * N,
        skip_n(Start, All, Rest),
        take_n(N, Rest, List, _),
        (Batch =:= NumBatches -> ! ; true)
    ).
```

`N0` may be an integer or a `count(N)` compound (the original code
wraps the limit in `count/1` as a mutable cell for `nb_setarg`).

### 2. `offset/2` absent

`offset(N, Goal)` skips the first N solutions of Goal.  It must work
inside `findall/3`, which requires the skip counter to survive
backtracking.  Implemented with `assertz`/`retract` keyed by thread
ID:

```prolog
offset(0, Goal) :- !, call(Goal).
offset(N, Goal) :-
    N > 0,
    thread_self(Me),
    (retract(offset_counter(Me, _)) -> true ; true),
    assertz(offset_counter(Me, N)),
    call(Goal),
    retract(offset_counter(Me, C)),
    (   C > 0
    ->  C1 is C - 1,
        assertz(offset_counter(Me, C1)),
        fail
    ;   true
    ).
```

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


## Overall assessment

Both modules are ported and fully tested.  The actors port has one
missing feature (non-zero `receive` timeout).  The toplevel_actors
port adds one further limitation (no mid-enumeration limit/target
change), and does not support infinite generators.  Every other
delta is a small, localised workaround for a Trealla-specific quirk.
