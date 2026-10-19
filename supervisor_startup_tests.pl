% SPDX-License-Identifier: MIT
:- module(supervisor_startup_tests,[run/0]).
:- use_module(actors).
:- use_module(supervisor_actor).
:- use_module(supervisor_startup,[]).
:- use_module(server_actor).

:- multifile actors:hook_spawn_reserved/2, actors:hook_send/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$startup_test_observer',Observer),
    thread_send_message(Observer,reserved(Pid)),fail.
actors:hook_send(_, '$stop'(_,_)) :-
    nb_current('$startup_cleanup_fault',true),
    nb_delete('$startup_cleanup_fault'),throw(cleanup_probe_error).
actors:hook_send(Pid,'$stop'(_,_)) :-
    nb_current('$startup_test_observer',Observer),
    thread_send_message(Observer,stop_seen(Pid)),fail.

enable(Observer) :- nb_setval('$startup_test_observer',Observer).
callback(hold,Observer,ok,Observer) :- !,
    actors:send(Observer,callback_entered),actors:receive({never -> true}).
callback(_,State,ok,State).

run :-
    initial_exception,initial_failure,
    provisional_child,
    forall(member(Policy-Reason,[0.1-true,infinity-true,brutal_kill-kill]),
        rollback_policy(Policy,Reason,false)),
    rollback_policy(0.02,shutdown,true),
    cleanup_error_preserves_primary,
    dynamic_error_and_retry,
    committed_exit,
    controls_propagate,
    writeln('Supervisor startup cleanup: all regressions passed').

server_spec(Id,Policy,spec(Id,server(supervisor_startup_tests:callback,[]),temporary,Policy,worker)).
source_error_start(server(supervisor_startup_tests:callback,
    [src_list([(:- throw(source_setup_error))])])).

initial_exception :-
    thread_self(Observer),source_error_start(Bad),
    supervisor_spawn(supervisor_startup_tests:[
        child(startup_a,[start(server(callback,[])),restart(temporary)]),
        child(startup_b,[start(server(callback,[])),restart(temporary)]),
        child(startup_bad,[start(Bad),restart(temporary)])],Sup,
        [monitor(true),link(false),src_list([(:- supervisor_startup_tests:enable(Observer))])]),
    receive({down(Sup,Sup,exception(source_setup_error)) -> true},[timeout(4),on_timeout(throw(initial_exception_missing))]),
    reserved([A,B,C]),
    forall(member(P,[A,B,C]),\+actors:actor_thread(P,_)),
    stopped([C,B,A]),
    whereis(startup_a,undefined),whereis(startup_b,undefined),whereis(startup_bad,undefined),
    writeln('initial source exception rolls back in reverse order and preserves original error: ok').

initial_failure :-
    thread_self(Observer),server_spec(startup_duplicate,0.1,Spec),
    spawn_runtime((supervisor_startup_tests:enable(Observer),
                   supervisor_actor:sup_init([Spec,Spec],sup(one_for_one,1,5,[],[]))),Sup,
                  [monitor(true),link(false),'$entry_context'(caller)]),
    receive({down(Sup,Sup,init_failed) -> true},[timeout(3),on_timeout(fail)]),
    reserved([Pid]),stopped([Pid]),\+actors:actor_thread(Pid,_),
    whereis(startup_duplicate,undefined),
    writeln('ordinary initial startup failure retains init_failed and rolls back: ok').

provisional_child :-
    thread_self(Observer),enable(Observer),self(Self),
    Self ! down(unrelated,application,unrelated_reason),
    server_spec(startup_provisional,0.1,Spec),Spec=spec(Id,Start,_,_,_),
    catch(supervisor_startup:with_startup_scope(
       (supervisor_startup:start_child(Spec,Start,Id,Pid),
        monitor(Pid,AppRef),nb_setval('$startup_app_monitor',Pid-AppRef),
        throw(before_admission))),Error,true),
    Error==before_admission,
    nb_getval('$startup_app_monitor',P-R),
    receive({down(P,R,true) -> true},[timeout(1),on_timeout(fail)]),
    receive({down(unrelated,application,unrelated_reason) -> true},[timeout(0),on_timeout(fail)]),
    reserved([P]),stopped([P]),\+actors:actor_thread(P,_),
    whereis(startup_provisional,undefined),
    nb_delete('$startup_test_observer'),nb_delete('$startup_app_monitor'),
    % A failed provisional attempt must not retain the server's name.
    server_spawn(supervisor_startup_tests:callback,[],Again,[name(startup_provisional)]),
    server_halt(Again,_),
    writeln('exception after creation but before admission reclaims child/name and preserves application monitors: ok').

rollback_policy(Policy,Expected,Hold) :-
    self(Self),server_spec(startup_policy,Policy,Spec0),
    Spec0=spec(Id,server(CB,_),Restart,Policy,Type),
    Spec=spec(Id,server(CB,[initial_state(Self)]),Restart,Policy,Type),
    catch(supervisor_startup:with_startup_scope(
       (supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),sup(_,_,_,[ch(_,Pid,_)],_)),
        monitor(Pid,AppRef),nb_setval('$startup_app_monitor',Pid-AppRef),
        (Hold==true -> make_ref(Request),send(Pid,'$call'(Self,Request,hold)),
           receive({callback_entered -> true},[timeout(2),on_timeout(fail)]) ; true),
        throw(policy_probe))),Error,true),
    Error==policy_probe,nb_getval('$startup_app_monitor',P-R),
    receive({down(P,R,Expected) -> true},[timeout(2),on_timeout(throw(wrong_shutdown_policy(Policy,Expected)))]),
    \+actors:actor_thread(P,_),whereis(startup_policy,undefined),
    nb_delete('$startup_app_monitor'),
    format('rollback shutdown(~q), blocked=~w preserves reason ~w: ok~n',[Policy,Hold,Expected]).

cleanup_error_preserves_primary :-
    self(Self),
    server_spec(startup_cleanup_a,0.1,A),server_spec(startup_cleanup_b,0.1,B),
    catch(supervisor_startup:with_startup_scope(
       (supervisor_actor:do_start_child(A,sup(one_for_one,1,5,[],[]),State),
        supervisor_actor:do_start_child(B,State,sup(_,_,_,Children,_)),
        findall(P,member(ch(_,P,_),Children),Pids),
        nb_setval('$startup_cleanup_pids',Pids),
        nb_setval('$startup_cleanup_fault',true),
        send(Self,unrelated_cleanup_message),throw(primary_startup_error))),Error,true),
    Error==primary_startup_error,
    nb_getval('$startup_cleanup_pids',Owned),
    forall(member(P,Owned),\+actors:actor_thread(P,_)),
    whereis(startup_cleanup_a,undefined),whereis(startup_cleanup_b,undefined),
    receive({unrelated_cleanup_message -> true},[timeout(0),on_timeout(fail)]),
    nb_delete('$startup_cleanup_pids'),
    writeln('shutdown exception cannot replace startup error or skip remaining children: ok').

dynamic_error_and_retry :-
    supervisor_spawn([],Sup,[monitor(true),link(false)]),
    setup_call_cleanup(true,
      (supervisor_spawn_child(Sup,supervisor_startup_tests:child(startup_stable,
          [start(server(callback,[])),restart(temporary)]),ok),
       supervisor_which_children(Sup,Before),
       source_error_start(Bad),
       supervisor_spawn_child(Sup,supervisor_startup_tests:child(startup_retry,[start(Bad)]),Reply),
       Reply==error(source_setup_error),
       supervisor_which_children(Sup,After),Before==After,
       supervisor_count_children(Sup,[specs-1,active-1,supervisors-0,workers-1]),
       whereis(startup_retry,undefined),actors:actor_thread(Sup,_),
       supervisor_spawn_child(Sup,supervisor_startup_tests:child(startup_retry,
          [start(server(callback,[])),restart(temporary)]),ok),
       supervisor_spawn_child(Sup,supervisor_startup_tests:child(startup_retry,[start(true)]),error(already_present)),
       supervisor_count_children(Sup,[specs-2,active-2,supervisors-0,workers-2]),
       supervisor_halt(Sup),
       receive({down(Sup,Sup,true) -> true},[timeout(3),on_timeout(fail)])),
      exit(Sup,kill)),
    whereis(startup_stable,undefined),whereis(startup_retry,undefined),
    writeln('dynamic setup exception preserves state, replies with original error and allows id/name reuse: ok').

committed_exit :-
    self(Self),spawn_runtime(supervisor_startup_tests:exit_during_start(Self),Sup,
      [monitor(true),link(false),'$entry_context'(caller)]),
    receive({owned_child(Child) -> true},[timeout(2),on_timeout(fail)]),monitor(Child,Ref),
    Sup ! finish,
    receive({down(Sup,Sup,stopped) -> true},[timeout(3),on_timeout(fail)]),
    receive({down(Child,Ref,_) -> true},[timeout(3),on_timeout(fail)]),
    writeln('committed supervisor exit retains parent containment without waiting on dying mailbox: ok').
exit_during_start(Observer) :-
    server_spec(startup_exit,0.1,Spec),
    supervisor_startup:with_startup_scope(
      (supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),sup(_,_,_,[ch(_,P,_)],_)),
       send(Observer,owned_child(P)),receive({finish -> exit(stopped)}))).
controls_propagate :-
    forall(member(Control,[actor_exit,'$abort_goal','$resource_idle']),
      (catch(supervisor_actor:startup_error_reply(Control,_),E,true),E==Control)),
    writeln('reserved runtime controls are rethrown rather than converted to addition replies: ok').

reserved([]).
reserved([P|Ps]) :- receive({reserved(P) -> true},[timeout(1),on_timeout(fail)]),reserved(Ps).
stopped([]).
stopped([P|Ps]) :- receive({stop_seen(Actual) -> Actual==P},[timeout(1),on_timeout(fail)]),stopped(Ps).
