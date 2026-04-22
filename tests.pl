% Manual test suite for Trealla Prolog.
%
% Run from this directory with:
%
%   tpl -g "consult(tests), t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16,t17,t18, format('~nALL OK~n'), halt"
%
% Trealla lacks plunit, so this is a flat list of goals.
% t1-t10  test actors.pl
% t11-t18 test toplevel_actors.pl

:- use_module(actors).
:- use_module(parallel).
:- use_module(toplevel_actors).

t1 :-
    self(Me),
    Me ! hello,
    receive({hello -> true}),
    format("1. basic receive ok~n").

t2 :-
    self(Me),
    Me ! first,
    Me ! second,
    receive({second -> true}),
    receive({first -> true}),
    format("2. deferred ok~n").

t3 :-
    ( receive({_ -> fail}, [timeout(0), on_timeout(true)])
    -> format("3. timeout(0) ok~n")
    ; format("3. timeout(0) FAIL~n"), fail ).

t4 :-
    self(Me),
    Me ! val(1),
    Me ! val(2),
    receive({val(X) if X > 1 -> true}),
    X == 2,
    receive({val(Y) -> true}),
    Y == 1,
    format("4. guard ok (X=~w Y=~w)~n", [X, Y]).

t5 :-
    spawn(receive({stop -> true}), Pid, [monitor(true), link(false)]),
    exit(Pid, kill),
    receive({down(Pid, Pid, kill) -> true}),
    format("5. exit_monitor ok~n").

t6 :-
    spawn(receive({_ -> true}), Pid, [monitor(true), link(false)]),
    exit(Pid, bye),
    receive({down(Pid, Pid, R) -> true}),
    format("6. exit_other (reason=~w) ok~n", [R]).

t7 :-
    spawn(receive({ping(From) -> From ! pong}), Pid, [link(false)]),
    register(pinger, Pid),
    self(Me),
    pinger ! ping(Me),
    receive({pong -> true}),
    format("7. register ok~n").

t8 :-
    parallel([(_=a, sleep(0.05)),
              (_=b, sleep(0.05)),
              (_=c, sleep(0.05))]),
    format("8. parallel_ok ok~n").

t9 :-
    ( parallel([(_=a, sleep(0.05)),
                (_=b, fail),
                (_=c, sleep(0.05))])
    -> format("9. parallel_fail FAIL~n"), fail
    ; format("9. parallel_fail ok~n") ).

t10 :-
    first_solution(X, [(sleep(0.3), X=slow), (sleep(0.05), X=fast)]),
    X == fast,
    format("10. first_solution ok (X=~w)~n", [X]).

t11 :-
    findall(Batch, findnsols(3, X, member(X, [a,b,c,d,e]), Batch), Batches),
    Batches = [[a,b,c],[d,e]],
    format("11. findnsols batches ok~n").

t12 :-
    findall(X, offset(2, member(X, [a,b,c,d,e])), L),
    L = [c,d,e],
    format("12. offset ok~n").

t13 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, between(1,5,N), [template(N), limit(3)]),
    receive({ success(Pid, Slice, true) -> true }),
    Slice = [1,2,3],
    format("13. toplevel first batch ok~n").

t14 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, between(1,5,N), [template(N), limit(3)]),
    receive({ success(Pid, S1, true) -> true }),
    toplevel_next(Pid),
    receive({ success(Pid, S2, false) -> true }),
    S1 = [1,2,3], S2 = [4,5],
    format("14. toplevel_next ok~n").

t15 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, fail, []),
    receive({ failure(Pid) -> true }),
    format("15. toplevel failure ok~n").

t16 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me)]),
    toplevel_call(Pid, throw(oops), []),
    receive({ error(Pid, oops) -> true }),
    format("16. toplevel error ok~n").

t17 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, member(X,[1,2,3,4]), [template(X), limit(2)]),
    receive({ success(Pid, _, true) -> true }),
    toplevel_stop(Pid),
    toplevel_call(Pid, true, []),
    receive({ success(Pid, _, false) -> true }),
    format("17. toplevel_stop+reuse ok~n").

t18 :-
    self(Me),
    toplevel_spawn(Pid, [target(Me), session(true)]),
    toplevel_call(Pid, between(1,3,N), [template(N)]),
    receive({ success(Pid, [1,2,3], false) -> true }),
    toplevel_call(Pid, between(4,6,N2), [template(N2)]),
    receive({ success(Pid, [4,5,6], false) -> true }),
    format("18. session multi-call ok~n").
