% SPDX-License-Identifier: MIT
% Standalone Trealla test: no Web Prolog modules, source loading or networking.
:- module(repeated_exit_cleanup,[run/1]).
:- dynamic exit_reason/1.

% withdraw models removing the first-exit guard at the start of at_exit.
% retain is a diagnostic control, not a proposed complete runtime repair.
run(Policy) :-
    memberchk(Policy,[withdraw,retain]),
    mutex_create(_,[alias(reproducer_exit_registry)]),
    thread_self(Parent),
    thread_create(repeated_exit_cleanup:worker(Parent),Thread,
        [detached(true),at_exit(repeated_exit_cleanup:cleanup(Policy,Parent))]),
    thread_get_message(ready),
    thread_signal(Thread,repeated_exit_cleanup:request_exit(Parent,first)),
    thread_get_message(request(first,true)),
    thread_get_message(cleanup_entered),
    % A barrier puts the second request inside the cleanup window; the full
    % application reaches this window intermittently with back-to-back closes.
    thread_signal(Thread,repeated_exit_cleanup:request_exit(Parent,second)),
    thread_get_message(request(second,First)),
    thread_send_message(Thread,release_cleanup),
    (thread_get_message(Parent,cleanup_finished,[timeout(0.5)]) ->
        writeq(completed(Policy,second_request(First))),nl
    ; (exit_reason(kill) -> Recorded=yes ; Recorded=no),
      writeq(missing_cleanup(Policy,second_request(First),reason_recorded(Recorded))),nl,
      fail).

worker(Parent) :-
    catch((thread_send_message(Parent,ready),thread_get_message(wait)),actor_exit,true).
request_exit(Parent,Request) :-
    with_mutex(reproducer_exit_registry,repeated_exit_cleanup:commit(First)),
    thread_send_message(Parent,request(Request,First)),
    (First==true -> throw(actor_exit) ; true).
commit(First) :-
    (exit_reason(_) -> First=false ; assertz(exit_reason(kill)),First=true).
cleanup(Policy,Parent) :-
    (Policy==withdraw -> retract(exit_reason(_)) ; true),
    thread_send_message(Parent,cleanup_entered),
    thread_get_message(release_cleanup),
    thread_send_message(Parent,cleanup_finished).
