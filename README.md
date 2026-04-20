# Porting `library(actors)` to Trealla Prolog

Status report on porting the simple node from SWI-Prolog to
[Trealla Prolog](https://github.com/trealla-prolog/trealla)
(v2.92.38).

The port lives alongside this report as `actors.pl`, with
a manual test suite in `tests.pl`. `parallel.pl` is pure
client code over the actors API and runs unchanged on Trealla, so
no separate Trealla variant is needed. This document records what
changed versus the canonical `simple-node/actors.pl` and why.

## Test results

All ten manual tests pass on Trealla:

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

All four demos from `parallel.pl` also run unchanged on Trealla
against `actors.pl`.

## What is supported

- `spawn/1-3` with `monitor(Bool)` and `link(Bool)` options
- `self/1`, `send/2`, `(!)/2`
- `receive/1-2` with patterns, guards (`Pattern if Guard -> Body`),
  and `timeout(0)` polling
- `monitor/2`, `demonitor/1-2`
- `register/2`, `unregister/1`, `whereis/2`
- `exit/1`, `exit/2`
- Links (bidirectional lifecycle coupling)
- Deferred-message semantics (non-matching messages stay in the
  mailbox in arrival order)

## What is not supported

`receive/2` with `timeout(T)` where `T \== 0` and `T \== infinite`.
Trealla has no `thread_get_message/3` accepting a timeout option,
so the port throws
`error(unsupported_option(timeout(T)), 'Trealla port: only timeout(0) is supported')`.
`timeout(0)` (poll) works by way of `thread_peek_message/2`.

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

## Overall assessment

The port is essentially complete: a single feature (non-zero
`receive` timeout) is genuinely missing because the underlying
primitive is absent. Every other delta is a small, localized
workaround for a Trealla-specific quirk, and the test suite
exercises them end-to-end.
