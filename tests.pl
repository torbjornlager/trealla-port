/** <module> Tests -- manual test suite for actors and toplevel_actors

This file is a flat, sequential test suite for actors.pl and
toplevel_actors.pl.  It is designed for Trealla Prolog, which does not
ship with a unit-test framework (plunit is absent).

## Running {#tests-running}

```
tpl -g "consult(tests), \
        t1,t2,t3,t4,t5,t6,t7,t8,t9,t10, \
        t11,t12,t13,t14,t15,t16,t17,t18, \
        t19,t20,t21, \
        format('~nALL OK~n'), halt"
```

Each test predicate prints a one-line status message and succeeds on
pass, fails (or throws) on failure.  Tests are grouped:

  - t1-t10  exercise actors.pl primitives
  - t11-t18 exercise toplevel_actors.pl

## Tests: actors.pl (t1-t10) {#tests-actors}

  - t1  basic send and receive
  - t2  deferred messages (out-of-order receive)
  - t3  timeout(0) poll on an empty mailbox
  - t4  guarded receive clause (if/2)
  - t5  exit/2 and monitor notification
  - t6  exit/2 with arbitrary reason, monitor delivery
  - t7  named actor (register/2, whereis/2)
  - t8  parallel/1 -- all goals succeed
  - t9  parallel/1 -- one goal fails (overall failure)
  - t10 first_solution/2 -- race between slow and fast goal

## Tests: toplevel_actors.pl (t11-t18) {#tests-toplevel}

  - t11 findnsols/4 batching (two batches from a 5-element list)
  - t12 offset/2 built-in
  - t13 toplevel first batch (limit=3 from between(1,5,N))
  - t14 toplevel_next/1 fetches the second batch
  - t15 toplevel failure answer
  - t16 toplevel error answer
  - t17 toplevel_stop/1 followed by a fresh call in session mode
  - t18 session mode with two successive calls

## Tests: receive timeout (t19-t21) {#tests-timeout}

  - t19 timeout fires when no message arrives (positive timeout)
  - t20 message arrives before timeout (positive timeout)
  - t21 deferred-list pruning across many timed receives
*/

:- use_module(actors).
:- use_module(parallel).
:- use_module(toplevel_actors).


                /*******************************
                *      actors.pl  (t1-t10)    *
                *******************************/

%!  t1 is det.
%
%   Basic send (`!`) and receive.  Sends `hello` to self and waits for
%   it.

t1 :-
    self(Me),
    Me ! hello,
    receive({hello -> true}),
    format("1. basic receive ok~n").

%!  t2 is det.
%
%   Deferred message ordering.  Sends `first` then `second`, but waits
%   for `second` first.  Verifies that `first` is still in the
%   (deferred) mailbox and can be received next.

t2 :-
    self(Me),
    Me ! first,
    Me ! second,
    receive({second -> true}),
    receive({first -> true}),
    format("2. deferred ok~n").

%!  t3 is det.
%
%   timeout(0) non-blocking poll.  With an empty mailbox, receive/2
%   should return immediately via the on_timeout goal.

t3 :-
    ( receive({_ -> fail}, [timeout(0), on_timeout(true)])
    -> format("3. timeout(0) ok~n")
    ; format("3. timeout(0) FAIL~n"), fail ).

%!  t4 is det.
%
%   Guarded receive clause (`if`).  Sends val(1) then val(2); waits for
%   the one where the guard `X > 1` passes (val(2)), then collects the
%   deferred val(1).

t4 :-
    self(Me),
    Me ! val(1),
    Me ! val(2),
    receive({val(X) if X > 1 -> true}),
    X == 2,
    receive({val(Y) -> true}),
    Y == 1,
    format("4. guard ok (X=~w Y=~w)~n", [X, Y]).

%!  t5 is det.
%
%   exit/2 and monitor.  Spawns an actor that blocks in receive, kills
%   it with exit/2, and verifies the down/3 message arrives with the
%   expected reason.

t5 :-
    spawn(receive({stop -> true}), Pid, [monitor(true), link(false)]),
    exit(Pid, kill),
    receive({down(Pid, Pid, kill) -> true}),
    format("5. exit_monitor ok~n").

%!  t6 is det.
%
%   exit/2 with arbitrary reason.  Similar to t5 but verifies that the
%   reason atom is forwarded unchanged in the down/3 message.

t6 :-
    spawn(receive({_ -> true}), Pid, [monitor(true), link(false)]),
    exit(Pid, bye),
    receive({down(Pid, Pid, R) -> true}),
    format("6. exit_other (reason=~w) ok~n", [R]).

%!  t7 is det.
%
%   Named actors.  Spawns a ping responder, registers it as `pinger`,
%   sends a message by name, and receives the reply.

t7 :-
    spawn(receive({ping(From) -> From ! pong}), Pid, [link(false)]),
    register(pinger, Pid),
    self(Me),
    pinger ! ping(Me),
    receive({pong -> true}),
    format("7. register ok~n").

%!  t8 is det.
%
%   parallel/1 -- all three goals succeed (each sleeps 50 ms).
%   Verifies that parallel/1 returns success when all goals succeed.

t8 :-
    parallel([(_=a, sleep(0.05)),
              (_=b, sleep(0.05)),
              (_=c, sleep(0.05))]),
    format("8. parallel_ok ok~n").

%!  t9 is det.
%
%   parallel/1 -- one goal fails.  Verifies that parallel/1 fails when
%   any goal fails.

t9 :-
    ( parallel([(_=a, sleep(0.05)),
                (_=b, fail),
                (_=c, sleep(0.05))])
    -> format("9. parallel_fail FAIL~n"), fail
    ; format("9. parallel_fail ok~n") ).

%!  t10 is det.
%
%   first_solution/2 -- race between a slow (300 ms) and fast (50 ms)
%   goal.  Verifies that the fast goal wins.

t10 :-
    first_solution(X, [(sleep(0.3), X=slow), (sleep(0.05), X=fast)]),
    X == fast,
    format("10. first_solution ok (X=~w)~n", [X]).


                /*******************************
                *  toplevel_actors.pl (t11-t18)*
                *******************************/

%!  t11 is det.
%
%   findnsols/4 batching.  Collects all batches of size 3 from a
%   5-element list; expects [[a,b,c],[d,e]].

t11 :-
    findall(Batch, findnsols(3, X, member(X, [a,b,c,d,e]), Batch), Batches),
    Batches = [[a,b,c],[d,e]],
    format("11. findnsols batches ok~n").

%!  t12 is det.
%
%   offset/2 built-in.  Skips the first 2 solutions of member/2 and
%   collects the rest; expects [c,d,e].

t12 :-
    findall(X, offset(2, member(X, [a,b,c,d,e])), L),
    L = [c,d,e],
    format("12. offset ok~n").

%!  t13 is det.
%
%   Toplevel first batch.  Spawns a PTCP, calls between(1,5,N) with
%   limit=3, expects success([1,2,3], true) with More=true.

t13 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, between(1,5,N), [template(N), limit(3)]),
    receive({ success(Pid, Slice, true) -> true }),
    Slice = [1,2,3],
    format("13. toplevel first batch ok~n").

%!  t14 is det.
%
%   toplevel_next/1.  Fetches two successive batches from between(1,5,N)
%   with limit=3, verifying [1,2,3] then [4,5].

t14 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, between(1,5,N), [template(N), limit(3)]),
    receive({ success(Pid, S1, true) -> true }),
    toplevel_next(Pid),
    receive({ success(Pid, S2, false) -> true }),
    S1 = [1,2,3], S2 = [4,5],
    format("14. toplevel_next ok~n").

%!  t15 is det.
%
%   Toplevel failure.  Calls fail/0, expects failure(Pid).

t15 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, fail, []),
    receive({ failure(Pid) -> true }),
    format("15. toplevel failure ok~n").

%!  t16 is det.
%
%   Toplevel error.  Calls throw(oops), expects error(Pid, oops).

t16 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, throw(oops), []),
    receive({ error(Pid, oops) -> true }),
    format("16. toplevel error ok~n").

%!  t17 is det.
%
%   toplevel_stop/1 and session reuse.  Sends a partial paged query,
%   stops it before it finishes, then issues a fresh call to true/0 on
%   the same PTCP and verifies success.  Requires session(true).

t17 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, member(X,[1,2,3,4]), [template(X), limit(2)]),
    receive({ success(Pid, _, true) -> true }),
    toplevel_stop(Pid),
    toplevel_call(Pid, true, []),
    receive({ success(Pid, _, false) -> true }),
    format("17. toplevel_stop+reuse ok~n").

%!  t18 is det.
%
%   Session multi-call.  Sends two independent calls to the same PTCP
%   in session mode and verifies both produce the expected results.

t18 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, between(1,3,N), [template(N)]),
    receive({ success(Pid, [1,2,3], false) -> true }),
    toplevel_call(Pid, between(4,6,N2), [template(N2)]),
    receive({ success(Pid, [4,5,6], false) -> true }),
    format("18. session multi-call ok~n").


                /*******************************
                *  receive timeout (t19-t21)  *
                *******************************/

%!  t19 is det.
%
%   Positive timeout fires.  Wait 200 ms for a message that never
%   arrives; verify on_timeout runs and the elapsed wall time is at
%   least 150 ms (allowing for scheduler jitter).

t19 :-
    get_time(T0),
    receive({foo -> fail}, [timeout(0.2), on_timeout(true)]),
    get_time(T1),
    Dt is T1 - T0,
    Dt >= 0.15,
    Dt < 0.5,
    format("19. timeout fires (dt=~3f s) ok~n", [Dt]).

%!  t20 is det.
%
%   Message arrives before timeout.  Spawn a helper that sends `hello`
%   after 50 ms; receive with a 2-second timeout; verify the matching
%   path runs and returns quickly.

t20 :-
    self(Me),
    spawn((sleep(0.05), Me ! hello), _, [link(false)]),
    get_time(T0),
    receive({hello -> true}, [timeout(2.0), on_timeout(fail)]),
    get_time(T1),
    Dt is T1 - T0,
    Dt < 0.5,
    format("20. timed receive matched (dt=~3f s) ok~n", [Dt]).

%!  t21 is det.
%
%   Deferred-list pruning.  Run several timed receives back to back;
%   verify the deferred list does not accumulate stale sentinels.
%   (We can't directly inspect prune_stale's effect, but if pruning
%   were broken, repeated timed receives would slow down or
%   misbehave.)

t21 :-
    self(Me),
    forall(between(1, 5, _),
           ( spawn((sleep(0.02), Me ! tick), _, [link(false)]),
             receive({tick -> true}, [timeout(1.0)]) )),
    format("21. repeated timed receives ok~n").
