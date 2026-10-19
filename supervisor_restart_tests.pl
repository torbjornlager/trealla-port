% SPDX-License-Identifier: MIT
:- module(supervisor_restart_tests,[run/0]).
:- use_module(actors).
:- use_module(supervisor_actor).
:- use_module(server_actor).
:- dynamic attempts/2, identities/3, failure/2, observer/1, stop_fault/2.
:- catch(mutex_create(_,[alias('$restart_test')]),_,true).
:- multifile actors:hook_send/2.
actors:hook_send(Pid,'$stop'(_,_)) :-
    supervisor_restart_tests:observe_stop(Pid),fail.
observe_stop(Pid) :-
    identities(Pid,Id,N),actors:actor_alive(Pid),observer(Observer),
    thread_send_message(Observer,stopping(Id,N)),
    (retract(stop_fault(Id,Error)) -> throw(Error);true).

callback(hold,Parent,ok,Parent) :- !,
    actors:send(Parent,held),actors:receive({never -> true}).
callback(_,State,ok,State).
starting(Id) :-
    with_mutex('$restart_test',
      ((retract(attempts(Id,Old))->N is Old+1;N=1),assertz(attempts(Id,N)))),
    actors:self(Pid),assertz(identities(Pid,Id,N)),
    (failure(Id,N) -> throw(replacement_error(Id));true).

run :-
    explicit_retry,
    forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]),automatic(Strategy,normal)),
    automatic(one_for_one,policies),
    automatic(one_for_one,cleanup_error),
    ordinary_failure_vectors,
    controls,cleanup_control,
    writeln('Supervisor restart failure cleanup: all regressions passed').
reset :-
    retractall(attempts(_,_)),retractall(identities(_,_,_)),
    retractall(failure(_,_)),retractall(observer(_)),retractall(stop_fault(_,_)).
child(Id,Policy,child(Id,[start(server(supervisor_restart_tests:callback,
    [src_list([(:- supervisor_restart_tests:starting(Id))])])),restart(permanent),shutdown(Policy)])).

explicit_retry :-
    reset,child(explicit,0.1,Spec),child(stable,infinity,Stable),
    supervisor_spawn(supervisor_restart_tests:[Spec,Stable],Sup,[monitor(true),link(false)]),
    setup_call_cleanup(true,
      (supervisor_which_children(Sup,[info(explicit,Old,worker,permanent),info(stable,Sibling,worker,permanent)]),
       monitor(Old,AppOld),
       supervisor_terminate_child(Sup,explicit,ok),
       receive({down(Old,AppOld,true) -> true},[timeout(2),on_timeout(fail)]),
       assertz(failure(explicit,2)),
       supervisor_respawn_child(Sup,explicit,error(replacement_error(explicit))),
       supervisor_which_children(Sup,[info(explicit,undefined,worker,permanent),info(stable,Sibling,worker,permanent)]),
       server_request(Sibling,ping,ok),
       supervisor_count_children(Sup,[specs-2,active-1,supervisors-0,workers-1]),
       whereis(explicit,undefined),
       identities(Failed,explicit,2),\+actors:actor_thread(Failed,_),
       supervisor_respawn_child(Sup,explicit,ok(New)),New\==Old,
       supervisor_which_children(Sup,[info(explicit,New,worker,permanent),info(stable,Sibling,worker,permanent)]),
       supervisor_respawn_child(Sup,explicit,error(running)),
       supervisor_respawn_child(Sup,absent,error(not_found)),
       supervisor_halt(Sup),
       receive({down(Sup,Sup,true) -> true},[timeout(3),on_timeout(fail)])),
      exit(Sup,kill)),
    reset,writeln('explicit replacement exception rolls back, retains inactive spec and permits retry with ok(Pid): ok').

failure_ids(one_for_one,b,b).
failure_ids(one_for_all,a,b).
failure_ids(rest_for_one,b,c).
automatic(Strategy,Mode) :-
    reset,thread_self(Observer),assertz(observer(Observer)),
    failure_ids(Strategy,Trigger,Failed),assertz(failure(Failed,2)),
    (Mode==policies -> AP=0.02,CP=brutal_kill ; AP=infinity,CP=0.1),
    child(a,AP,A),child(b,0.1,B),child(c,CP,C),
    self(Self),
    % State supplies an observer for the blocked callback policy test.
    (Mode==policies -> A=child(a,AOpts),select(start(server(CB,Opts)),AOpts,Rest),
       append([initial_state(Self)],Opts,WithState),
       ASource=child(a,[start(server(CB,WithState))|Rest]) ; ASource=A),
    supervisor_spawn(supervisor_restart_tests:[ASource,B,C],Sup,
       [strategy(Strategy),intensity(5),monitor(true),link(false)]),
    setup_call_cleanup(true,
      (supervisor_which_children(Sup,Children),
       Children=[info(a,PA,_,_),info(b,PB,_,_),info(c,PC,_,_)],
       monitor(PA,RA),monitor(PB,RB),monitor(PC,RC),monitor(Sup,ExtraSup),
       (Mode==policies -> make_ref(Request),send(PA,'$call'(Self,Request,hold)),
         receive({held -> true},[timeout(2),on_timeout(fail)]) ; true),
       (Mode==cleanup_error -> assertz(stop_fault(c,cleanup_error(c)));true),
       member(info(Trigger,TriggerPid,_,_),Children),server_halt(TriggerPid,_),
       Expected=restart_failed(Failed,replacement_error(Failed)),
       receive({down(Sup,Sup,Expected) -> true},[timeout(4),on_timeout(throw(missing_restart_failure(Strategy,Mode)))]),
       receive({down(Sup,ExtraSup,Expected) -> true},[timeout(0),on_timeout(fail)]),
       (Mode==policies -> AReason=shutdown,CReason=kill
       ; Mode==cleanup_error -> AReason=true,CReason=shutdown
       ; AReason=true,CReason=true),
       receive({down(PA,RA,AReason) -> true},[timeout(1),on_timeout(fail)]),
       receive({down(PB,RB,true) -> true},[timeout(1),on_timeout(fail)]),
       receive({down(PC,RC,CReason) -> true},[timeout(1),on_timeout(fail)]),
       forall(identities(P,_,_),\+actors:actor_thread(P,_)),
       whereis(a,undefined),whereis(b,undefined),whereis(c,undefined),
       check_replacement_order(Strategy),
       (Mode==normal -> check_stops(Strategy);drain_stops)),
      exit(Sup,kill)),
    reset,format('~w replacement failure (~w): actual failed id, rollback, shutdown and extra monitors preserved: ok~n',[Strategy,Mode]).

check_replacement_order(one_for_one) :- attempts(a,1),attempts(b,2),attempts(c,1).
check_replacement_order(one_for_all) :- attempts(a,2),attempts(b,2),attempts(c,1).
check_replacement_order(rest_for_one) :- attempts(a,1),attempts(b,2),attempts(c,2).
check_stops(Strategy) :-
    find_stops(Stops0),
    failure_ids(Strategy,_,Failed),exclude(=(Failed-2),Stops0,Stops),
    (Strategy==one_for_one -> Stops=[b-1,c-1,a-1]
    ; Strategy==one_for_all -> Stops=[a-1,b-1,c-1,a-2]
    ; Stops=[b-1,c-1,b-2,a-1]).
find_stops(Stops) :-
    receive({stopping(Id,N) -> Stops=[Id-N|Rest],find_stops(Rest)},
            [timeout(0),on_timeout(Stops=[])]).
drain_stops :- find_stops(_).

% Ordinary failure is distinct from a startup exception. Invalid private
% vectors force that branch without changing the public child validator.
ordinary_failure_vectors :-
    self(Self),make_ref(Ref),State=sup(one_for_one,5,5,[ch(inactive,undefined,bad)],[]),
    supervisor_actor:handle_call(restart_child(inactive),Self,Ref,State,After),
    State==After,receive({Ref-error(start_failed) -> true},[timeout(0),on_timeout(fail)]),
    catch(supervisor_actor:restart_child_record(inactive,bad,_),Error,true),
    Error==restart_failed(inactive,start_failed),
    writeln('ordinary replacement failure retains error(start_failed) and automatic failure classification: ok').
controls :-
    forall(member(Control,[actor_exit,'$abort_goal','$resource_idle']),
      (catch(supervisor_actor:restart_child_error(id,Control),E,true),E==Control)),
    writeln('restart error wrapping preserves reserved runtime controls: ok').

cleanup_control :-
    reset,thread_self(Observer),assertz(observer(Observer)),
    server_spawn(supervisor_restart_tests:callback,[],Pid,
      [name(control_probe),src_list([(:-supervisor_restart_tests:starting(control_probe))])]),
    monitor(Pid,AppRef),self(Self),send(Self,unrelated_control_message),
    assertz(stop_fault(control_probe,'$abort_goal')),
    Spec=spec(control_probe,server(supervisor_restart_tests:callback,[]),temporary,0.1,worker),
    catch(supervisor_startup:cleanup_children([ch(control_probe,Pid,Spec)]),Error,true),
    Error=='$abort_goal',
    receive({down(Pid,AppRef,shutdown) -> true},[timeout(2),on_timeout(fail)]),
    receive({unrelated_control_message -> true},[timeout(0),on_timeout(fail)]),
    \+actors:actor_thread(Pid,_),whereis(control_probe,undefined),drain_stops,reset,
    writeln('cleanup propagates abort controls and preserves the application monitor: ok').
