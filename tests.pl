% SPDX-License-Identifier: MIT

/** <module> Tests -- manual test suite for actors and toplevel_actors

This file is a flat, sequential test suite for actors.pl and
toplevel_actors.pl.  It is designed for Trealla Prolog, which does not
ship with a unit-test framework (plunit is absent).

## Running {#tests-running}

Run `TPL=/path/to/tpl ./tools/test.sh` from the repository root.  The
runner executes every unit-test group through `run_test_group/1` in fresh
Trealla processes, then runs the WebSocket vector
tests in another process. Fresh processes are intentional: detached-thread
cleanup and mailbox state must not leak between layers.

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
  - t22 mid-stream limit change via toplevel_next/2

## Tests: receive timeout (t19-t21) {#tests-timeout}

  - t19 timeout fires when no message arrives (positive timeout)
  - t20 message arrives before timeout (positive timeout)
  - t21 deferred-list pruning across many timed receives

## Tests: SWI parity (t23-t30) {#tests-parity}

  - t23 catch-all `_` receive clause binds default
  - t24 catch-all receive picks the deferred message
  - t25 backtracking through a failed timed receive
  - t26 whereis/2 returns undefined after exit
  - t27 toplevel output/1 delivers output/2 then success
  - t28 toplevel input/respond roundtrip
  - t29 toplevel_abort/1 unwinds a runaway goal
  - t30 parallel/1 propagates an exception

## Tests: terminal inheritance and references (t31-t33)

  - t31 descendants inherit a terminal target
  - t32 stream-originated terminal output keeps its provenance
  - t33 concurrent make_ref/1 calls produce distinct references

## Tests: private source namespaces (t34-t41)

  - t34 `src_text/1` loads an actor-private predicate
  - t35 `src_list/1` loads actor-private terms
  - t36 operator directives affect following source text
  - t37 `src_predicates/1` copies predicates from the caller
  - t38 conflicting private definitions do not cross-talk
  - t39 a toplevel evaluates calls in its private namespace
  - t40 actor termination removes loaded clauses and namespace bookkeeping
  - t41 source-preparation errors propagate without retaining a namespace

## Tests: execution profiles (t42-t46)

  - t42 profile names, aliases, ordering, and route ceilings
  - t43 unavailable routes and protocol commands are rejected
  - t44 nested goals cannot smuggle stronger-profile operations
  - t45 RELATION permits only advertised patterns and conjunctions
  - t46 source-bearing spawn options obey profile policy

## Tests: sandbox and public source policy (t47-t56)

  - t47 sandbox modes and compatibility aliases normalize
  - t48 dangerous direct, nested, qualified, and receive-body goals are denied
  - t49 unsafe source options, directives, and clause heads are denied
  - t50 checked source still loads and executes in a private actor namespace
  - t51 runtime-constructed meta-calls are guarded
  - t52 whitelist mode admits safe source-local calls and rejects unknown calls
  - t53 sandbox(off) preserves trusted-node behavior
  - t54 runtime-constructed asserted clauses are checked before mutation
  - t55 producer exceptions return to the HTTP worker instead of deadlocking
  - t56 the portable abolish/2 form stays scoped to the actor module

## Tests: resource governance (t57-t62)

  - t57 node resource options normalize and client limits are clamped
  - t58 term, source, and WebSocket size ceilings reject oversized input
  - t59 the live-actor cap rejects excess work and reclaims the slot
  - t60 the HTTP solution producer reports execution-time exhaustion
  - t61 PTCP execution timeout returns an error and preserves the session
  - t62 PTCP idle timeout reclaims an inactive session normally

## Tests: authentication and origin policy (t63-t68)

  - t63 authentication modes and compatibility aliases normalize
  - t64 private mode rejects an anonymous execution request
  - t65 a configured bearer token authenticates its principal
  - t66 trusted node headers work only across the private-network boundary
  - t67 development mode grants execution only to direct loopback peers
  - t68 WebSocket origins allow native, same-origin, and configured clients

## Tests: controlled source URI policy (t85-t88)

  - t85 remote source loading is denied by default
  - t86 source origins are normalized and validated exactly
  - t87 relative redirects are resolved without weakening origin checks
  - t88 unverified HTTPS requires an explicit operator opt-in

## Tests: per-principal governance (t69-t73)

  - t69 rate and concurrency options normalize
  - t70 rate buckets are principal-scoped and privileged transports are exempt
  - t71 anonymous HTTP and WebSocket identities do not share one global bucket
  - t72 in-flight call capacity is atomic and released by cleanup
  - t73 WebSocket actor capacity is released when ownership ends

## Tests: observability (t74-t79)

  - t74 observability options normalize
  - t75 request counters and bounded event retention work
  - t76 policy rejections are classified
  - t77 activity start/end state is reclaimed
  - t78 governance usage and the protected runtime payload are renderable
  - t79 Prometheus output and rotating JSONL audit logging work

## Tests: bearer-token lifecycle (t80-t84)

  - t80 portable SHA-256 and OS random bytes work
  - t81 issued secrets authenticate but are absent from token listings
  - t82 expiry and revocation invalidate credentials
  - t83 hashed token records survive an atomic save/load cycle
  - t84 managed tokens participate in normal request authentication
*/

:- use_module(toplevel_actors).
:- use_module(actors, [live_actor_count/1]).
:- use_module(parallel).
:- use_module(profile_policy).
:- use_module(sandbox_policy).
:- use_module(resource_policy).
:- use_module(auth_policy).
:- use_module(governance_policy).
:- use_module(observability).
:- use_module(crypto_portable).
:- use_module(node_tokens).
:- use_module(node).
:- use_module(source_policy).


                /*******************************
                *        TEST GROUPS           *
                *******************************/

%!  run_test_group(+Group) is det.
%
%   Run one isolation-safe group.  tools/test.sh invokes each group in a
%   fresh Trealla process so completed detached actors, delayed messages, or
%   protocol state from one layer cannot affect another layer's tests.

run_test_group(actors) :-
    t1, t2, t3, t4, t5, t6, t7,
    t19, t20, t21, t23, t24, t25, t26,
    t31, t32, t33.
run_test_group(toplevel) :-
    t11, t12, t13, t14, t15, t16, t17, t18,
    t22, t27, t28, t29.
run_test_group(parallel) :-
    t8, t9, t10, t30.
run_test_group(isolation) :-
    t34, t35, t36, t37, t38, t39, t40, t41.
run_test_group(profiles) :-
    t42, t43, t44, t45, t46.
run_test_group(sandbox) :-
    t47, t48, t49, t50, t51, t52, t53, t54, t55, t56.
run_test_group(resources) :-
    t57, t58, t59, t60, t61, t62,
    reset_resource_policy.
run_test_group(auth) :-
    t63, t64, t65, t66, t67, t68,
    reset_auth_policy.
run_test_group(governance) :-
    t69, t70, t71, t72, t73,
    reset_governance_policy.
run_test_group(observability) :-
    t74, t75, t76, t77, t78, t79,
    reset_observability,
    reset_governance_policy.
run_test_group(tokens) :-
    t80, t81, t82, t83, t84,
    clear_all_tokens,
    clear_tokens_file,
    reset_auth_policy.
run_test_group(source_policy) :-
    t85, t86, t87, t88,
    reset_source_policy.


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


                /*******************************
                *  mid-stream limit (t22)     *
                *******************************/

%!  t22 is det.
%
%   Mid-stream limit change.  Issues a goal with limit=2 on a
%   7-element list, then on the second page asks for limit=4.
%   Expects [a,b] then [c,d,e,f] then [g].  Exercises the
%   count(N) + nb_setarg/3 path through findnsols/4.

t22 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, member(X, [a,b,c,d,e,f,g]),
                  [template(X), limit(2)]),
    receive({ success(Pid, S1, true) -> true }),
    toplevel_next(Pid, [limit(4)]),
    receive({ success(Pid, S2, true) -> true }),
    toplevel_next(Pid),
    receive({ success(Pid, S3, false) -> true }),
    S1 = [a,b], S2 = [c,d,e,f], S3 = [g],
    format("22. mid-stream limit change ok~n").


                /*******************************
                *      SWI parity (t23-t30)   *
                *******************************/

%!  t23 is det.
%
%   Catch-all clause in receive.  Sends a message that does not
%   match `foo(_)`; verifies the `_ -> X = baz` branch fires and
%   binds X to baz, then drains the genuinely matching message.
%   Mirrors SWI plunit `receive:receive2`.

t23 :-
    self(Me),
    Me ! not_matching,
    Me ! foo(bar),
    receive({ foo(X) -> true
            ; _       -> X = baz
            }),
    X == baz,
    receive({ foo(_) -> true }),
    format("23. catch-all receive ok~n").

%!  t24 is det.
%
%   Catch-all clause picks the only message available.
%   Mirrors SWI plunit `receive:receive10`.

t24 :-
    self(Me),
    Me ! done,
    receive({ Result -> true
            ; unreachable -> Result = wrong
            }),
    Result == done,
    format("24. catch-all picks message ok~n").

%!  t25 is det.
%
%   Backtracking through a failed timed receive.  The disjunction
%   first takes `true`; the outer receive with `on_timeout(fail)`
%   then fails (no `stop` queued), forcing backtrack into the
%   second disjunct which sends and receives `foo(stop)` and feeds
%   `stop` back to self.  The outer receive now succeeds.
%   Mirrors SWI plunit `receive:receive11`.

t25 :-
    self(Me),
    (   true
    ;   Me ! foo(stop),
        receive({ foo(X) -> Me ! X })
    ),
    receive({ stop -> true },
            [ timeout(0), on_timeout(fail) ]),
    format("25. backtracking receive ok~n").

%!  t26 is det.
%
%   whereis/2 returns `undefined` after the registered actor exits.
%   Mirrors SWI plunit `actors:actors3_register_2`.

t26 :-
    % This test is about registration cleanup, not asynchronous interruption
    % of a CPU-bound goal.  A mailbox wait gives the actor an unambiguous
    % blocking point for exit/2.  The separate t29 test covers interruption
    % of a runaway goal through toplevel_abort/1.
    spawn(receive({never -> true}), Pid, [monitor(true), link(false)]),
    register(test_w, Pid),
    whereis(test_w, Pid2),
    Pid2 == Pid,
    exit(Pid2, reason),
    receive({ down(Pid2, _Ref, reason) -> true }),
    whereis(test_w, undefined),
    unregister(test_w),
    format("26. whereis after exit ok~n").

%!  t27 is det.
%
%   Toplevel output/1.  Calling output(hello) inside the toplevel
%   actor sends an `output(Pid, hello)` message to the target, then
%   the goal succeeds and the success answer follows.
%   Mirrors SWI plunit `toplevels:shell_output_message`.

t27 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, output(hello)),
    receive({ output(Pid, hello) -> true },
            [ timeout(1), on_timeout(fail) ]),
    receive({ success(Pid, [output(hello)], false) -> true },
            [ timeout(1), on_timeout(fail) ]),
    format("27. toplevel output ok~n").

%!  t28 is det.
%
%   Toplevel input/respond roundtrip.  The actor's input/2 sends a
%   `prompt(Pid, 'Input')` message and blocks; the test replies
%   with respond(Pid, hello); the goal succeeds with X = hello.
%   Mirrors SWI plunit `toplevels:shell_input_roundtrip`.

t28 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, input('Input', _X)),
    receive({ prompt(Pid, 'Input') -> respond(Pid, hello) },
            [ timeout(1), on_timeout(fail) ]),
    receive({ success(Pid, [input('Input', hello)], false) -> true },
            [ timeout(1), on_timeout(fail) ]),
    format("28. toplevel input/respond ok~n").

%!  t29 is det.
%
%   toplevel_abort/1 unwinds a runaway goal.  Asserts a recursive
%   clause, starts an infinite loop on the toplevel, aborts, then
%   issues a fresh `true` call on the same (session-mode) actor and
%   verifies it succeeds.  Mirrors SWI plunit
%   `toplevels:shell_abort_nonterminating_goal`.

:- dynamic(t29_loop/0).

t29 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    %% SWI uses assert/1; Trealla's actor module only sees the
    %% ISO assertz/1 -- behaviour under test is the same.
    toplevel_call(Pid, assertz((t29_loop :- t29_loop))),
    receive({ success(Pid, _, false) -> true },
            [ timeout(1), on_timeout(fail) ]),
    toplevel_call(Pid, t29_loop),
    sleep(0.05),
    toplevel_abort(Pid),
    toplevel_call(Pid, true),
    receive({ success(Pid, [true], false) -> true },
            [ timeout(2), on_timeout(fail) ]),
    retractall(t29_loop),
    format("29. toplevel_abort ok~n").

%!  t30 is det.
%
%   parallel/1 propagates an exception.  One of the goals raises
%   a type error (sleep(a)); parallel/1 should re-throw it.
%   Mirrors SWI plunit `parallel:parallel_error`.

t30 :-
    catch(parallel([sleep(0.05), sleep(a), sleep(0.05)]),
          Error, true),
    nonvar(Error),
    format("30. parallel error ok~n").

%!  t31 is det.
%
%   A child inherits its parent's terminal target independently of its
%   immediate actor parent.

t31 :-
    self(Me),
    spawn(spawn(terminal_output(inherited), _, [link(false)]), Outer,
          [target(Me), monitor(true), link(false)]),
    receive({ terminal_output(_Child, inherited) -> true },
            [timeout(1), on_timeout(fail)]),
    receive({ down(Outer, Outer, true) -> true },
            [timeout(1), on_timeout(fail)]),
    format("31. inherited terminal target ok~n").

%!  t32 is det.
%
%   source(io) preserves the distinction between emulated stream output and
%   explicit terminal events.

t32 :-
    self(Me),
    spawn(terminal_output(text, [source(io)]), Pid,
          [target(Me), monitor(true), link(false)]),
    receive({ terminal_io_output(Pid, text) -> true },
            [timeout(1), on_timeout(fail)]),
    receive({ down(Pid, Pid, true) -> true },
            [timeout(1), on_timeout(fail)]),
    format("32. terminal I/O provenance ok~n").

%!  t33 is det.
%
%   make_ref/1 remains unique when called concurrently by many actors.

t33 :-
    self(Me),
    spawn_ref_makers(50, Me),
    collect_refs(50, Refs),
    sort(Refs, Unique),
    length(Unique, 50),
    format("33. concurrent unique refs ok~n").


                /*******************************
                *    SOURCE ISOLATION (34-41) *
                *******************************/

copied_source_value(copied).

t34 :-
    self(Me),
    spawn((private_value(X), Me ! isolated_text(X)), _,
          [src_text('private_value(text).'), link(false)]),
    receive({isolated_text(Value) -> true}),
    Value == text,
    format("34. src_text private predicate ok~n").

t35 :-
    self(Me),
    spawn((listed_value(X), phrase(private_word, [hello]),
           Me ! isolated_list(X)), _,
          [src_list([listed_value(list), (private_word --> [hello])]),
           link(false)]),
    receive({isolated_list(Value) -> true}),
    Value == list,
    format("35. src_list private predicate ok~n").

t36 :-
    self(Me),
    Source = ':- op(500, xfx, joins). joined(X) :- X = left joins right.',
    spawn((joined(X), Me ! isolated_operator(X)), _,
          [src_text(Source), link(false)]),
    receive({isolated_operator(Value) -> true}),
    Value == joins(left, right),
    format("36. source operator directive ok~n").

t37 :-
    self(Me),
    spawn((copied_source_value(X), Me ! isolated_copy(X)), _,
          [src_predicates([copied_source_value/1]), link(false)]),
    receive({isolated_copy(Value) -> true}),
    Value == copied,
    format("37. src_predicates copy ok~n").

t38 :-
    self(Me),
    spawn((private_value(X), Me ! isolated_peer(one, X)), _,
          [src_text('private_value(first).'), link(false)]),
    spawn((private_value(X), Me ! isolated_peer(two, X)), _,
          [src_text('private_value(second).'), link(false)]),
    receive({isolated_peer(one, First) -> true}),
    receive({isolated_peer(two, Second) -> true}),
    First == first,
    Second == second,
    format("38. private namespaces do not cross-talk ok~n").

t39 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), src_text('top_value(private).')]),
    toplevel_call(Pid, top_value(X), [template(X)]),
    receive({success(Pid, Values, false) -> true}),
    Values == [private],
    format("39. toplevel private source ok~n").

t40 :-
    self(Me),
    spawn((cleanup_value(_), Me ! cleanup_ready, receive({stop -> true})),
          Pid,
          [src_text('cleanup_value(present).'), monitor(true), link(false)]),
    receive({cleanup_ready -> true}),
    isolation:actor_module(Pid, Module),
    Pid ! stop,
    receive({down(Pid, Pid, true) -> true}),
    \+ isolation:actor_module(Pid, _),
    Goal = Module:cleanup_value(_),
    catch((call(Goal) -> Loaded = true ; Loaded = false), _, Loaded = false),
    Loaded == false,
    format("40. source namespace cleanup ok~n").

t41 :-
    findall(P-M, isolation:actor_module(P, M), Before),
    catch(spawn(true, _Pid,
                [src_list([(:- module(forbidden_source_module, []))]),
                 link(false)]),
          Error, true),
    nonvar(Error),
    findall(P-M, isolation:actor_module(P, M), After),
    Before == After,
    format("41. source preparation error cleanup ok~n").


                /*******************************
                *    PROFILES (t42-t46)       *
                *******************************/

t42 :-
    normalize_profile(stateless, isobase),
    normalize_profile(session, isotope),
    min_profile(actor, isotope, isotope),
    effective_profile_for_route(workbench, call, isobase),
    effective_profile_for_route(workbench, ws, workbench),
    profile_allows_route(relation, call),
    format("42. profile ordering and ceilings ok~n").

t43 :-
    caught_profile_violation(profile_check_route(isobase, ws),
                             isobase, route(ws)),
    caught_profile_violation(profile_check_command(isotope, spawn),
                             isotope, command(spawn)),
    profile_check_route(actor, ws),
    profile_check_command(actor, spawn),
    format("43. profile route and command rejection ok~n").

t44 :-
    profile_check_goal(isobase, member(_, [a,b])),
    caught_profile_violation(profile_check_goal(isobase,
                                                once(send(target, message))),
                             isobase, goal(send(target, message))),
    caught_profile_violation(profile_check_goal(isobase,
                                                (true, assertz(tmp_fact))),
                             isobase, goal(assertz(tmp_fact))),
    profile_check_goal(isotope, assertz(tmp_fact)),
    format("44. nested goal profile enforcement ok~n").

t45 :-
    normalize_relation_patterns([edge/2, status(ok)], Patterns),
    profile_check_goal(relation, (edge(a, X), status(ok)), Patterns),
    var(X),
    caught_procedure_error(profile_check_goal(relation, status(no), Patterns),
                           status/1),
    caught_procedure_error(profile_check_goal(relation, member(_, []), Patterns),
                           member/2),
    format("45. advertised relation allowlist ok~n").

t46 :-
    caught_profile_violation(
        profile_check_spawn_options(relation, [src_text('p.')]),
        relation, option(src_text('p.'))),
    caught_profile_violation(
        profile_check_spawn_options(isobase,
                                    [src_list([(p :- assertz(q))])]),
        isobase, goal(assertz(q))),
    profile_check_spawn_options(actor,
                                [src_list([(p :- send(target, message))])]),
    format("46. source option profile enforcement ok~n").


                /*******************************
                *     SANDBOX (t47-t56)       *
                *******************************/

t47 :-
    normalize_sandbox_mode(off, off),
    normalize_sandbox_mode(blacklist, blacklist),
    normalize_sandbox_mode(whitelist, whitelist),
    normalize_sandbox_mode(on, whitelist),
    normalize_sandbox_mode(demo, whitelist),
    normalize_sandbox_mode(strict, whitelist),
    format("47. sandbox mode normalization ok~n").

t48 :-
    caught_sandbox(sandbox_prepare_goal(blacklist, actor, user,
                                        open(secret, read, _), _)),
    caught_sandbox(sandbox_prepare_goal(blacklist, actor, user,
                                        catch(true, _, shell(command)), _)),
    caught_sandbox(sandbox_prepare_goal(blacklist, actor, user,
                                        user:member(_, []), _)),
    caught_sandbox(sandbox_prepare_goal(
        blacklist, actor, user,
        receive({go -> current_prolog_flag(version_data, _)}), _)),
    caught_sandbox(sandbox_prepare_goal(
        blacklist, actor, user, _Module:open(secret, read, _), _)),
    format("48. sandbox goal walker denial ok~n").

t49 :-
    caught_permission(sandbox_prepare_options(
        blacklist, actor, actor_context,
        [src_text(':- initialization(shell(command)).')], _)),
    caught_sandbox(sandbox_prepare_options(
        blacklist, actor, actor_context,
        [src_list([(user:p :- true)])], _)),
    caught_permission(sandbox_prepare_options(
        blacklist, actor, actor_context, [src_uri('file:///etc/passwd')], _)),
    caught_permission(sandbox_prepare_options(
        blacklist, actor, actor_context, [src_predicates([secret/1])], _)),
    format("49. public source policy denial ok~n").

t50 :-
    self(Me),
    Goal0 = (sandbox_value(X), Me ! sandbox_source_value(X)),
    sandbox_prepare_spawn(blacklist, actor, actor_context, Goal0,
                          [src_text('sandbox_value(checked).')],
                          Goal, Options0),
    append(Options0, [link(false)], Options),
    spawn(Goal, _, Options),
    receive({sandbox_source_value(Value) -> true}),
    Value == checked,
    format("50. checked private source execution ok~n").

t51 :-
    Goal0 = (RuntimeGoal = current_prolog_flag(version_data, _),
             call(RuntimeGoal)),
    sandbox_prepare_goal(blacklist, isobase, user, Goal0, Goal),
    caught_sandbox(call(Goal)),
    format("51. runtime meta-call guard ok~n").

t52 :-
    self(Me),
    Goal0 = (whitelist_value(X), Me ! whitelist_source_value(X)),
    sandbox_prepare_spawn(
        whitelist, actor, actor_context, Goal0,
        [src_text('whitelist_value(X) :- member(X, [safe]).')],
        Goal, Options0),
    append(Options0, [link(false)], Options),
    spawn(Goal, _, Options),
    receive({whitelist_source_value(Value) -> true}),
    Value == safe,
    caught_sandbox(sandbox_prepare_goal(whitelist, actor, user,
                                        unknown_host_predicate, _)),
    format("52. conservative whitelist ok~n").

t53 :-
    Unsafe = open(trusted_file, read, _),
    sandbox_prepare_goal(off, actor, user, Unsafe, Same),
    Same = Unsafe,
    format("53. sandbox off compatibility ok~n").

t54 :-
    Goal0 = (Clause = (sandbox_asserted :-
                         current_prolog_flag(version_data, _)),
             assertz(Clause)),
    sandbox_prepare_goal(blacklist, isotope, user, Goal0, Goal),
    caught_sandbox(call(Goal)),
    \+ current_predicate(sandbox_asserted/0),
    format("54. runtime asserted-clause guard ok~n").

t55 :-
    catch((node:compute_answer(throw(producer_runtime_error), value,
                               0, 1, _), fail),
          producer_runtime_error,
          true),
    format("55. producer exception propagation ok~n").

t56 :-
    sandbox_prepare_goal(blacklist, isotope, user,
                         (assertz(sandbox_abolish_probe),
                          abolish(sandbox_abolish_probe, 0)),
                         Goal),
    call(Goal),
    \+ current_predicate(sandbox_abolish_probe/0),
    caught_sandbox(sandbox_prepare_goal(
        blacklist, isotope, user, abolish('$actor_call', 1), _)),
    format("56. scoped portable abolish/2 ok~n").


                /*******************************
                *    RESOURCES (t57-t62)       *
                *******************************/

t57 :-
    configure_resource_policy(
        [time_limit(2),idle_limit(3),max_actors(4),max_solutions(5)],
        Policy),
    policy_time_limit(Policy, 2),
    policy_idle_limit(Policy, 3),
    effective_time_limit(10, 2),
    effective_time_limit(1, 1),
    effective_solution_limit(20, 5),
    effective_solution_limit(2, 2),
    format("57. resource policy normalization and clamping ok~n").

t58 :-
    configure_resource_policy(
        [max_term_text_bytes(4),max_source_text_bytes(8),
         max_ws_frame_bytes(6)], _),
    check_term_text_size(goal, 'abcd'),
    caught_resource(check_term_text_size(goal, 'abcde'), input_size),
    caught_resource(check_source_options_size([src_text('123456789')]),
                    input_size),
    caught_resource(check_ws_frame_size('1234567'), input_size),
    resource_websocket_options([max_payload_length(99)], WSOptions),
    memberchk(max_payload_length(6), WSOptions),
    format("58. textual input ceilings ok~n").

t59 :-
    configure_resource_policy([max_actors(1)], _),
    spawn(receive({resource_stop -> true}), Pid,
          [monitor(true),link(false)]),
    caught_resource(spawn(true, _, [link(false)]), actors),
    Pid ! resource_stop,
    receive({down(Pid, Pid, true) -> true},
            [timeout(2),on_timeout(fail)]),
    live_actor_count(0),
    spawn(true, _, [link(false)]),
    format("59. live actor capacity and reclamation ok~n").

t60 :-
    configure_resource_policy([time_limit(0.05)], _),
    catch((node:compute_answer((repeat,fail), value, 0, 1, _), fail),
          error(resource_error(time), _),
          true),
    format("60. HTTP producer execution timeout ok~n").

t61 :-
    configure_resource_policy([time_limit(0.05),idle_limit(2)], _),
    self(Me),
    toplevel_spawn(Pid, [target(Me),session(true),link(false)]),
    toplevel_call(Pid, (repeat,fail), []),
    receive({TimeMessage ->
                TimeMessage = error(Pid, error(resource_error(time), _))},
            [timeout(2),on_timeout(fail)]),
    toplevel_call(Pid, true, [template(ok)]),
    receive({success(Pid, [ok], false) -> true},
            [timeout(2),on_timeout(fail)]),
    exit(Pid, resource_test_done),
    format("61. PTCP time limit preserves session ok~n").

t62 :-
    configure_resource_policy([time_limit(2),idle_limit(0.05)], _),
    self(Me),
    toplevel_spawn(Pid, [target(Me),session(true),monitor(true),link(false)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(2),on_timeout(fail)]),
    format("62. PTCP idle reclamation ok~n").


                /*******************************
                * AUTHENTICATION (t63-t68)     *
                *******************************/

t63 :-
    normalize_auth_mode(off, open),
    normalize_auth_mode(public, open),
    normalize_auth_mode(development, dev),
    normalize_auth_mode(private, private),
    configure_auth_policy([], _),
    current_auth_mode(open),
    format("63. authentication mode normalization ok~n").

t64 :-
    configure_auth_policy([auth(private)], _),
    request_principal('203.0.113.8':42000, [], Principal),
    Principal = anonymous([public_read]),
    caught_authentication(require_route_access(Principal, call), call),
    format("64. private anonymous execution denied ok~n").

t65 :-
    configure_auth_policy(
        [auth(private), bearer_token(alice, 'correct horse', [execute])], _),
    request_principal('203.0.113.8':42000,
                      [authorization-'Bearer correct horse'], Principal),
    principal_id(Principal, alice),
    principal_has_capability(Principal, execute),
    require_route_access(Principal, ws),
    request_principal('203.0.113.8':42000,
                      [authorization-'Bearer wrong'], Anonymous),
    caught_authentication(require_route_access(Anonymous, ws), ws),
    format("65. bearer principal authentication ok~n").

t66 :-
    Headers = ['x-web-prolog-user'-'node:trealla',
               'x-web-prolog-capabilities'-'execute,internal_transport'],
    configure_auth_policy([auth(private)], _),
    request_principal('192.168.1.20':42000, Headers, Trusted),
    principal_id(Trusted, 'node:trealla'),
    principal_has_capability(Trusted, internal_transport),
    require_route_access(Trusted, ws),
    request_principal('203.0.113.8':42000, Headers, Untrusted),
    caught_authentication(require_route_access(Untrusted, ws), ws),
    format("66. trusted transport header boundary ok~n").

t67 :-
    configure_auth_policy([auth(dev)], _),
    request_principal('127.0.0.1':42000, [], Local),
    principal_id(Local, dev),
    require_route_access(Local, call),
    request_principal('203.0.113.8':42000, [], Remote),
    caught_authentication(require_route_access(Remote, call), call),
    format("67. loopback-only development authentication ok~n").

t68 :-
    configure_auth_policy(
        [ws_allowed_origins(['https://portal.example'])], _),
    ws_require_allowed_origin('203.0.113.8':42000, []),
    ws_require_allowed_origin('203.0.113.8':42000,
                              [origin-'http://node.example:3060',
                               host-'node.example:3060']),
    ws_require_allowed_origin('203.0.113.8':42000,
                              [origin-'HTTPS://PORTAL.EXAMPLE/']),
    caught_origin(ws_require_allowed_origin(
        '203.0.113.8':42000,
        [origin-'https://evil.example',host-'node.example:3060'])),
    format("68. WebSocket origin policy ok~n").


                /*******************************
                * GOVERNANCE (t69-t73)         *
                *******************************/

t69 :-
    configure_governance_policy(
        [rate_window_seconds(10),max_call_requests_per_window(2),
         max_session_spawns_per_window(3),max_ws_commands_per_window(4),
         max_inflight_calls(5),max_ws_actors_per_principal(unlimited)],
        governance_policy(10,2,3,4,5,unlimited)),
    format("69. governance option normalization ok~n").

t70 :-
    configure_governance_policy([max_call_requests_per_window(1)], _),
    User = principal(alice, [execute]),
    enforce_call_request_rate_limit(User, alice),
    caught_rate_limit(enforce_call_request_rate_limit(User, alice),
                      alice, call_requests),
    enforce_call_request_rate_limit(User, bob),
    Admin = principal(root, [admin]),
    enforce_call_request_rate_limit(Admin, root),
    enforce_call_request_rate_limit(Admin, root),
    format("70. principal rate buckets and exemption ok~n").

t71 :-
    Anonymous = anonymous([public_read,execute]),
    quota_identity(Anonymous, '192.0.2.1':1000, http, HTTP1),
    quota_identity(Anonymous, '192.0.2.1':2000, http, HTTP1),
    quota_identity(Anonymous, '192.0.2.2':1000, http, HTTP2),
    HTTP1 \== HTTP2,
    quota_identity(Anonymous, ignored, websocket, WS1),
    quota_identity(Anonymous, ignored, websocket, WS2),
    WS1 \== WS2,
    format("71. anonymous quota identities ok~n").

t72 :-
    configure_governance_policy([max_inflight_calls(1)], _),
    User = principal(alice, [execute]),
    caught_capacity(
        with_inflight_call_limit(
            User, alice,
            with_inflight_call_limit(User, alice, true)),
        alice, inflight_calls),
    with_inflight_call_limit(User, alice, true),
    format("72. in-flight capacity cleanup ok~n").

t73 :-
    configure_governance_policy([max_ws_actors_per_principal(1)], _),
    User = principal(alice, [execute]),
    reserve_ws_actor_capacity(User, alice, First),
    commit_ws_actor_capacity(First, fake_pid_1),
    caught_capacity(reserve_ws_actor_capacity(User, alice, _),
                    alice, ws_actors),
    forget_ws_actor_owner(fake_pid_1),
    reserve_ws_actor_capacity(User, alice, Second),
    release_capacity_reservation(Second),
    format("73. WebSocket actor capacity cleanup ok~n").


                /*******************************
                * OBSERVABILITY (t74-t79)      *
                *******************************/

t74 :-
    configure_observability(
        [log_capacity(7),audit_log_file(off),max_audit_log_bytes(unlimited),
         max_audit_log_backups(2)],
        observability_config(7,off,unlimited,2)),
    configure_observability(
        [interaction_log_file(off),max_interaction_log_bytes(99),
         max_interaction_log_backups(3)],
        observability_config(500,off,99,3)),
    format("74. observability option normalization ok~n").

t75 :-
    configure_observability([log_capacity(2)], _),
    User = principal(alice, [execute]),
    observe_request(User, http, call, true),
    ( observe_request(User, http, call, fail) -> fail ; true ),
    catch(observe_request(User, http, call,
                          throw(error(test_error, observability_test))),
          error(test_error, observability_test), true),
    current_observability_snapshot(
        observability_snapshot(_, Counters, _, Events)),
    memberchk(requests_total-3, Counters),
    memberchk(errors_total-1, Counters),
    length(Events, 2),
    format("75. request counters and bounded retention ok~n").

t76 :-
    configure_observability([], _),
    User = principal(alice, [execute]),
    Error = error(rate_limit_exceeded(alice,call_requests,1,60), test),
    observe_rejection(User, http, call, Error),
    current_observability_snapshot(
        observability_snapshot(_, Counters, _, [Event])),
    memberchk(rejections_total-1, Counters),
    memberchk(rejection(rate_limit)-1, Counters),
    Event = event(_,_,rejection,denied,alice,http,call,0,_),
    format("76. rejection classification ok~n").

t77 :-
    configure_observability([], _),
    User = principal(alice, [execute]),
    observe_activity_start(ws_connection, fake_connection, User, websocket),
    current_observability_snapshot(
        observability_snapshot(_,_,[activity(ws_connection,fake_connection,
                                              alice,websocket,_)],_)),
    observe_activity_end(ws_connection, fake_connection, normal),
    current_observability_snapshot(observability_snapshot(_,_,[],_)),
    format("77. activity lifecycle observability ok~n").

t78 :-
    configure_governance_policy([max_call_requests_per_window(2)], _),
    configure_observability([], _),
    User = principal(alice, [execute]),
    enforce_call_request_rate_limit(User, alice),
    current_governance_usage(governance_usage(Rates, _)),
    memberchk(rate(call_request,alice,1,2), Rates),
    node_runtime_json(JSON),
    atom_chars(JSON, JSONChars), phrase(json:json_chars(_), JSONChars),
    sub_atom(JSON, _, _, _, '"governance"'),
    sub_atom(JSON, _, _, _, '"activity_summary"'),
    sub_atom(JSON, _, _, _, '"rate_limits"'),
    format("78. governance runtime payload ok~n").

t79 :-
    actors:make_ref(Ref),
    format(atom(File), '/tmp/trealla-port-audit-~w.jsonl', [Ref]),
    format(atom(Backup), '~w.1', [File]),
    setup_call_cleanup(
        configure_observability(
            [audit_log_file(File),max_audit_log_bytes(1),
             max_audit_log_backups(1)], _),
        ( User = principal(alice, [execute]),
          observe_request(User, http, call, true),
          observe_request(User, http, call, true),
          exists_file(File), exists_file(Backup),
          node_metrics_text(Metrics),
          sub_atom(Metrics, _, _, _, 'web_prolog_requests_total 2') ),
        ( ( exists_file(File) -> delete_file(File) ; true ),
          ( exists_file(Backup) -> delete_file(Backup) ; true ) )),
    format("79. metrics and rotating JSONL audit log ok~n").


                /*******************************
                * TOKENS (t80-t84)             *
                *******************************/

t80 :-
    sha256_hex('',
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855),
    sha256_hex(abc,
        ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad),
    sha256_hex(abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq,
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1'),
    secure_random_bytes(24, Bytes), length(Bytes, 24),
    bytes_hex(Bytes, Hex), atom_length(Hex, 48),
    format("80. portable SHA-256 and OS CSPRNG ok~n").

t81 :-
    clear_all_tokens, clear_tokens_file,
    issue_token(alice, [execute], [label(cli)], Token),
    atom_length(Token, 68),
    verify_bearer_token(Token, principal(alice,[execute])),
    current_tokens([token_info(Id,alice,[execute],_,0,Used,false,cli)]),
    Used > 0,
    atomic_list_concat([wp,Id,_], '_', Token),
    format("81. token issue and secret-free listing ok~n").

t82 :-
    clear_all_tokens,
    issue_token(alice, [execute], [expires_in(0.001)], Expiring),
    sleep(0.01),
    \+ verify_bearer_token(Expiring, _),
    issue_token(alice, [execute], [], Revocable),
    atomic_list_concat([wp,Id,_], '_', Revocable),
    revoke_token(Id),
    \+ verify_bearer_token(Revocable, _),
    format("82. token expiry and revocation ok~n").

t83 :-
    actors:make_ref(Ref),
    format(atom(File), '/tmp/trealla-port-tokens-~w.pl', [Ref]),
    atom_concat(File, '.tmp', Temporary),
    setup_call_cleanup(
        ( clear_all_tokens, set_tokens_file(File) ),
        ( issue_token(bob, [execute], [label(persistent)], Token),
          read_test_file(File, StoreText),
          \+ sub_atom(StoreText, _, _, _, Token),
          atomic_list_concat([wp,_,Secret], '_', Token),
          \+ sub_atom(StoreText, _, _, _, Secret),
          clear_all_tokens, load_tokens,
          verify_bearer_token(Token, principal(bob,[execute])),
          atomic_list_concat([wp,Id,_], '_', Token),
          revoke_token(Id), clear_all_tokens, load_tokens,
          \+ verify_bearer_token(Token, _) ),
        ( clear_all_tokens, clear_tokens_file,
          ( exists_file(File) -> delete_file(File) ; true ),
          ( exists_file(Temporary) -> delete_file(Temporary) ; true ) )),
    format("83. hashed token persistence ok~n").

t84 :-
    clear_all_tokens, clear_tokens_file,
    configure_auth_policy([auth(private)], _),
    issue_token(carol, [execute], [], Token),
    format(atom(Header), 'Bearer ~w', [Token]),
    request_principal('203.0.113.8':42000, [authorization-Header], Principal),
    Principal = principal(carol,[execute]),
    require_route_access(Principal, call),
    format("84. managed bearer authentication ok~n").


                /*******************************
                *   SOURCE URI POLICY (85-88) *
                *******************************/

t85 :-
    reset_source_policy,
    caught_source_permission(
        fetch_source_uri('http://127.0.0.1:9/source.pl', _), source_uri),
    format("85. remote source loading defaults to denied ok~n").

t86 :-
    normalize_source_origin('HTTP://Example.COM',
                            origin(http,'example.com',80)),
    normalize_source_origin('https://Example.COM:8443/',
                            origin(https,'example.com',8443)),
    caught_source_domain(
        normalize_source_origin('http://example.com/not-an-origin', _),
        source_origin),
    caught_source_domain(
        normalize_source_origin('http://example.com?query=not-origin', _),
        source_origin),
    configure_source_policy(
        [load_uri_allowed_origins(['http://example.com'])],
        source_policy([origin(http,'example.com',80)],10,5,false)),
    format("86. source origin normalization ok~n").

t87 :-
    resolve_redirect_uri('http://example.com/a/b/source.pl', '../next.pl',
                         'http://example.com/a/b/../next.pl'),
    resolve_redirect_uri('http://example.com/a/source.pl', '/safe.pl',
                         'http://example.com/safe.pl'),
    resolve_redirect_uri('https://example.com/a', '//cdn.example/x.pl',
                         'https://cdn.example/x.pl'),
    resolve_redirect_uri('http://example.com/a/source.pl?old=1', '?new=2',
                         'http://example.com/a/source.pl?new=2'),
    format("87. source redirect resolution ok~n").

t88 :-
    configure_source_policy(
        [load_uri_allowed_origins(['https://example.com'])], _),
    caught_source_permission(
        fetch_source_uri('https://example.com/source.pl', _),
        unverified_https_source),
    configure_source_policy(
        [load_uri_allowed_origins(['https://example.com']),
         allow_unverified_https(true),source_fetch_timeout(2),
         max_source_redirects(1)],
        source_policy([origin(https,'example.com',443)],2,1,true)),
    format("88. HTTPS source opt-in policy ok~n").

read_test_file(File, Text) :-
    setup_call_cleanup(open(File, read, Stream, [type(binary)]),
                       read_test_bytes(Stream, Bytes), close(Stream)),
    atom_codes(Text, Bytes).

read_test_bytes(Stream, Bytes) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> Bytes = []
    ; Bytes = [Byte|Rest], read_test_bytes(Stream, Rest)
    ).

caught_resource(Goal, Category) :-
    catch((Goal, fail),
          error(resource_error(Resource), _),
          resource_category(Resource, Category)).

resource_category(actors, actors).
resource_category(input_size(_,_,_), input_size).

caught_authentication(Goal, Route) :-
    catch((Goal, fail),
          error(authentication_required(Route), _),
          true).

caught_rate_limit(Goal, Identity, Resource) :-
    catch((Goal, fail),
          error(rate_limit_exceeded(Identity, Resource, _, _), _),
          true).

caught_capacity(Goal, Identity, Resource) :-
    catch((Goal, fail),
          error(resource_limit_exceeded(Identity, Resource, _), _),
          true).

caught_origin(Goal) :-
    catch((Goal, fail),
          error(permission_error(open, websocket_origin, _), _),
          true).

caught_sandbox(Goal) :-
    catch((Goal, fail),
          error(permission_error(_, sandboxed, _), _),
          true).

caught_permission(Goal) :-
    catch((Goal, fail),
          error(permission_error(_, _, _), _),
          true).

caught_source_permission(Goal, Object) :-
    catch((Goal, fail),
          error(permission_error(load, Object, _), _),
          true).

caught_source_domain(Goal, Domain) :-
    catch((Goal, fail),
          error(domain_error(Domain, _), _),
          true).

caught_profile_violation(Goal, Profile, Subject) :-
    catch((Goal, fail),
          error(profile_violation(Profile, Subject), _),
          true).

caught_procedure_error(Goal, Procedure) :-
    catch((Goal, fail),
          error(existence_error(procedure, Procedure), _),
          true).

spawn_ref_makers(0, _) :- !.
spawn_ref_makers(N, Target) :-
    spawn((make_ref(Ref), Target ! made_ref(Ref)), _, [link(false)]),
    Next is N - 1,
    spawn_ref_makers(Next, Target).

collect_refs(0, []) :- !.
collect_refs(N, [Ref|Refs]) :-
    receive({ made_ref(Ref) -> true }, [timeout(2), on_timeout(fail)]),
    Next is N - 1,
    collect_refs(Next, Refs).
