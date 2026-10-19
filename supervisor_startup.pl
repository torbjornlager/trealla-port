% SPDX-License-Identifier: MIT
:- module(supervisor_startup,
    [with_startup_scope/1, start_child/4, remember_monitor/2]).

/** <module> Ownership until supervisor child admission commits

Only initial startup and dynamic additions enter this scope. Automatic and
explicit restart paths retain their existing behavior. The journal contains
copies used for cleanup; the live child specs and state are never replaced
by those copies.
*/
:- use_module(actors).
:- meta_predicate with_startup_scope(0).
:- multifile actors:hook_spawn_reserved/2.

actors:hook_spawn_reserved(Pid, _) :-
    nb_current('$sup_starting_child', Key-Spec),
    supervisor_startup:record_child(Key, Pid, Spec).

with_startup_scope(Goal) :-
    make_ref(Token),format(atom(Key),'$supervisor_startup_~w',[Token]),
    (nb_current('$sup_startup_scope',Previous) -> Saved=some(Previous);Saved=none),
    setup_call_cleanup(true,
      (nb_setval(Key,[]),nb_setval('$sup_startup_scope',Key),
       catch((once(Goal) -> nb_setval(Key,[]) ; fail),Error,
             (catch(rollback(Key),_,true),throw(Error)))),
      finish_scope(Key,Saved)).

finish_scope(Key,Saved) :-
    setup_call_cleanup(true,rollback(Key),
      (nb_delete(Key),restore('$sup_startup_scope',Saved))).
restore(Key,some(Value)) :- nb_setval(Key,Value).
restore(Key,none) :- nb_delete(Key).

start_child(Spec,Start,Id,Pid) :-
    (nb_current('$sup_startup_scope',Key)
    -> (nb_current('$sup_starting_child',Previous) -> Saved=some(Previous);Saved=none),
       setup_call_cleanup(true,
         (nb_setval('$sup_starting_child',Key-Spec),
          supervisor_actor:do_spawn_child(Start,Id,Pid)),
         restore('$sup_starting_child',Saved))
    ; supervisor_actor:do_spawn_child(Start,Id,Pid)).

record_child(Key,Pid,Spec) :-
    nb_getval(Key,Children),nb_setval(Key,[owned(Pid,Spec,none)|Children]).
remember_monitor(Pid,Ref) :-
    (nb_current('$sup_startup_scope',Key),nb_current(Key,Children0),
     select(owned(Pid,Spec,none),Children0,Rest)
    -> nb_setval(Key,[owned(Pid,Spec,some(Ref))|Rest])
    ; true).

rollback(Key) :-
    (nb_current(Key,Children) -> rollback_children(Key,Children,none,Error),
       (Error=some(E) -> throw(E);true)
    ; true).
rollback_children(_,[],Error,Error).
rollback_children(Key,[Child|Children],First,Error) :-
    catch((rollback_child(Child) -> Outcome=ok
          ; Outcome=error(error(supervisor_startup_cleanup_failed(Child),supervisor_startup))),
          E,Outcome=error(E)),
    nb_setval(Key,Children),
    (First==none,Outcome=error(Why) -> Next=some(Why);Next=First),
    rollback_children(Key,Children,Next,Error).

rollback_child(owned(_,_,Monitor)) :-
    actor_terminating,!,
    % Retain normal parent-link containment on committed actor termination.
    % Its mailbox is dying, so do not wait for shutdown notifications here.
    (Monitor=some(Ref) -> demonitor(Ref,[flush]);true).
rollback_child(owned(Pid,spec(_,Start,_,Shutdown,_),Monitor)) :-
    (Monitor=some(Ref) -> demonitor(Ref,[flush]);true),
    setup_call_cleanup(monitor(Pid,CleanupRef),
      (self(Self),
       % Parent teardown must not send a second exit during child cleanup.
       with_mutex('$actor_registry',retractall(actors:link(Self,Pid))),
       catch(shutdown(Pid,Shutdown,Start,CleanupRef),Error,
         (catch(force_stop(Pid,Shutdown,CleanupRef),_,true),throw(Error)))),
      demonitor(CleanupRef,[flush])).

shutdown(Pid,brutal_kill,_,Ref) :- !,
    exit(Pid,kill),wait_down(Pid,Ref).
shutdown(Pid,Policy,Start,Ref) :-
    (supervisor_actor:request_stop(Pid,Start,StopRef)
    -> (Policy==infinity -> wait_down(Pid,Ref)
       ; receive({down(Pid,Ref,_) -> true},[timeout(Policy),on_timeout(fail)]) -> true
       ; exit(Pid,shutdown),wait_down(Pid,Ref)),
       supervisor_actor:flush_stop_reply(StopRef)
    ; exit(Pid,shutdown),wait_down(Pid,Ref)).
wait_down(Pid,Ref) :- receive({down(Pid,Ref,_) -> true}).

% If the requested shutdown itself throws, still stop this owned child and
% continue rolling back the rest. A primary startup error remains primary.
force_stop(Pid,Policy,Ref) :-
    (Policy==brutal_kill -> exit(Pid,kill);exit(Pid,shutdown)),
    (actor_terminating -> true;wait_down(Pid,Ref)).
