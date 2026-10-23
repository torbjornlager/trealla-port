% SPDX-License-Identifier: MIT
% Standalone probe for exit-time mutex release: a detached thread locks a
% mutex and ends without unlocking it, so the engine's thread-exit cleanup
% must release it, while this thread contends for the same mutex through
% with_mutex/2. Primitives only; loads no Web Prolog file.

:- catch(mutex_create(_, [alias(probe_unlock_all)]),
         error(permission_error(create, mutex, probe_unlock_all), _), true).

unlock_all_probe(N) :-
    forall(between(1,N,I),
        (catch(unlock_all_case,E,(writeq(case_exception(I,E)),nl,flush_output,throw(E))))),
    writeln('all regressions passed').

unlock_all_case :-
    thread_self(Parent),
    thread_create(holder(Parent),_,[detached(true)]),
    thread_get_message(Parent,holder_locked,[timeout(2)]),
    contend(200).

% Ends holding the mutex: release is left to thread-exit cleanup. The short
% hold lets the parent block in mutex_lock/1 before that release happens.
holder(Parent) :-
    mutex_lock(probe_unlock_all),
    thread_send_message(Parent,holder_locked),
    sleep(0.003).

contend(0) :- !.
contend(K) :-
    with_mutex(probe_unlock_all,true),
    K1 is K-1,contend(K1).
