% Manual test suite for actors_trealla.pl on Trealla Prolog.
%
% Run from this directory with:
%
%   tpl -g "consult(tests), t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, format('~nALL OK~n'), halt"
%
% Trealla lacks plunit, so this is a flat list of goals rather than
% the plunit suite in tests.pl. Each goal prints its own ok line.

:- use_module(actors).
:- use_module(parallel).

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
