% SPDX-License-Identifier: MIT
:- module(native_thread_control,[signal/2,cancel/1]).
:- meta_predicate signal(+,0).

% On the deployed engine, a detached thread can retire and its storage can
% be reused between native signal lookup and delivery. Native IDs do not
% repeat. Recheck the intended ID in the receiver before executing control
% code; a late signal must not terminate an unrelated HTTP/actor worker.
signal(Thread, Goal) :-
    thread_signal(Thread,native_thread_control:deliver(Thread,Goal)).

deliver(Expected, Goal) :-
    thread_self(Actual),
    (Actual == Expected -> call(Goal);true).

cancel(Thread) :- signal(Thread,thread_exit(cancelled)).
