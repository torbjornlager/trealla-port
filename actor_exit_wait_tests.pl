% SPDX-License-Identifier: MIT
:- module(actor_exit_wait_tests,[run/0]).
:- use_module(actors).

% An exit reason is a committed runtime decision. Catching its unwind token
% (including inside host cleanup) must not admit another mailbox operation.
run :-
    forall(member(Options,[[],[timeout(0)],[timeout(1)],[deadline(0)]]),
           caught_exit(Options)),
    caught_signal,
    ordinary_exception,
    writeln('Committed exits cannot re-enter mailbox waits: all regressions passed').

caught_exit(Options) :-
    self(Parent),
    spawn((catch(exit(committed_wait_exit),actor_exit,true),
           receive({continue -> send(Parent,resumed_after_exit)},Options),
           send(Parent,resumed_after_exit)), Pid,[link(false),monitor(true)]),
    expect_down(Pid,committed_wait_exit).

caught_signal :-
    self(Parent),
    spawn((catch((send(Parent,ready),receive({finish -> true})),actor_exit,true),
           receive({continue -> send(Parent,resumed_after_exit)})),
          Pid,[link(false),monitor(true)]),
    receive({ready -> true},[timeout(1),on_timeout(throw(no_readiness))]),
    exit(Pid,committed_signal_exit),
    expect_down(Pid,committed_signal_exit).

ordinary_exception :-
    self(Parent),
    spawn((catch(throw(actor_exit),actor_exit,true),
           receive({continue -> send(Parent,ordinary_catch_resumed)})),
          Pid,[link(false),monitor(true)]),
    send(Pid,continue),
    receive({ordinary_catch_resumed -> true},[timeout(1),on_timeout(fail)]),
    expect_down(Pid,true).

expect_down(Pid,Reason) :-
    receive({down(Pid,Pid,Reason) -> true},
            [timeout(1),on_timeout(throw(committed_exit_wait_timeout(Pid)))]),
    receive({resumed_after_exit -> throw(committed_exit_resumed)},
            [timeout(0),on_timeout(true)]).
