% SPDX-License-Identifier: MIT
:- module(worker_cleanup,
    [with_worker_scope/2, spawn_worker/3, close_worker_scope/1,
     release_worker/2, tidy_up_all/1]).

/** <module> Local worker ownership for actor generics

A thread-local nonbacktrackable record survives failure and exception unwinds.
Each pid is recorded before its thread is created, including interrupted
startup. A fresh key per invocation keeps nested combinators independent.
*/
:- use_module(actors).
:- meta_predicate with_worker_scope(-,0), spawn_worker(+,0,-).
:- multifile actors:hook_spawn_reserved/2.

actors:hook_spawn_reserved(Pid, Options) :-
    memberchk('$worker_scope'(Scope), Options),
    worker_cleanup:record_worker(Scope, Pid).

with_worker_scope(Scope, Goal) :-
    make_ref(Token), format(atom(Scope), '$worker_scope_~w', [Token]),
    % Establish cleanup before installing the record or entering user work.
    setup_call_cleanup(true,
        (nb_setval(Scope, []),
         catch(call(Goal), Error,
               (catch(close_worker_scope(Scope), _, true), throw(Error)))),
        close_worker_scope(Scope)).

spawn_worker(none, Goal, Pid) :- !,
    spawn_runtime(Goal, Pid, [monitor(true),'$entry_context'(caller)]).
spawn_worker(Scope, Goal, Pid) :-
    spawn_runtime(Goal, Pid,
        [monitor(true),'$entry_context'(caller),'$worker_scope'(Scope)]).

record_worker(Scope, Pid) :-
    nb_getval(Scope, Pids), nb_setval(Scope, [Pid|Pids]).

release_worker(none, _) :- !.
release_worker(Scope, Pid) :-
    (nb_current(Scope, Pids0), select(Pid, Pids0, Pids)
    -> nb_setval(Scope, Pids)
    ; true).

close_worker_scope(Scope) :-
    (nb_current(Scope, Reversed)
    -> reverse(Reversed, Pids),
       (actor_terminating -> stop_workers_on_exit(Pids)
       ; tidy_up_all(Pids)),
       nb_delete(Scope)
    ; true).

% A dying actor cannot wait on its own mailbox. Retire only our links before
% requesting stops, so parent teardown will not send duplicate exit signals.
stop_workers_on_exit([]).
stop_workers_on_exit([Pid|Pids]) :-
    demonitor(Pid, [flush]),
    retire_worker_link(Pid), exit(Pid, kill),
    stop_workers_on_exit(Pids).

retire_worker_link(Pid) :-
    self(Self),
    with_mutex('$actor_registry', retractall(actors:link(Self, Pid))).

% The private monitor is an ordering barrier before draining result messages.
% Only the combinator's spawn monitor and this cleanup monitor are consumed.
tidy_up_all([]).
tidy_up_all([Pid|Pids]) :-
    tidy_up(Pid), tidy_up_all(Pids).

tidy_up(Pid) :-
    demonitor(Pid, [flush]),
    setup_call_cleanup(monitor(Pid, Ref),
        (retire_worker_link(Pid), exit(Pid, kill),
         receive({down(Pid, Ref, _) -> true}),
         drain_worker_messages(Pid)),
        demonitor(Ref, [flush])).

drain_worker_messages(Pid) :-
    receive({
        Pid-_ -> drain_worker_messages(Pid) ;
        down(Pid, Pid, _) -> drain_worker_messages(Pid)
    }, [timeout(0)]).
