% SPDX-License-Identifier: MIT
:- module(worker_scope_tests,[run/0]).
:- use_module(actors).
:- use_module(parallel).
:- use_module(worker_cleanup,[]).

:- multifile actors:hook_admit_spawn/2, actors:hook_spawn_reserved/2.

% Faults apply only to scoped workers in the scenario's own thread.
actors:hook_admit_spawn(_, Options) :-
    memberchk('$worker_scope'(_),Options),
    worker_scope_tests:admit_probe.
actors:hook_spawn_reserved(Pid, Options) :-
    memberchk('$worker_scope'(Scope),Options),
    worker_scope_tests:reserved_probe(Pid,Scope).

admit_probe :-
    nb_current('$scope_test_mode',Mode),
    nb_getval('$scope_test_count',N0),N is N0+1,nb_setval('$scope_test_count',N),
    (Mode==startup_error,N==2 -> throw(startup_error(original)) ; true).
reserved_probe(Pid,Scope) :-
    nb_current('$scope_test_mode',Mode),
    nb_getval('$scope_test_pids',Pids),nb_setval('$scope_test_pids',[Pid|Pids]),
    nb_setval('$scope_test_key',Scope),
    (Mode=reserved_interrupt(Observer), Pids\=[] ->
      self(Self),actors:actor_thread(Observer,NativeObserver),
      thread_self(NativeCaller),thread_send_message(NativeObserver,reserved(Self,Pid,NativeCaller)),
      thread_get_message(never_release_startup)
    ; true).
probe_start(Mode) :-
    nb_setval('$scope_test_mode',Mode),nb_setval('$scope_test_count',0),
    nb_setval('$scope_test_pids',[]).
probe_clear :-
    nb_delete('$scope_test_mode'),nb_delete('$scope_test_count'),
    nb_delete('$scope_test_pids'),nb_delete('$scope_test_key').

run :-
    forall(member(Kind,[parallel,first,tuned_first]),startup_error(Kind)),
    scope_failure_and_cut,
    forall(member(Kind,[parallel,first,tuned_first]),
        (interruption(Kind,waiting),interruption(Kind,reserved))),
    forall(member(Kind,[parallel,first,tuned_first]),termination(Kind)),
    nested_and_bindings,
    public_metadata_rejected,
    writeln('Worker scopes: all regressions passed').

invoke(parallel,Goals) :- parallel(Goals).
invoke(first,Goals) :- first_solution(_,Goals).
invoke(tuned_first,Goals) :- first_solution(_,Goals,[on_error(continue)]).

startup_error(Kind) :-
    setup_call_cleanup(probe_start(startup_error),
      (catch(invoke(Kind,[actors:receive({never -> true}),true]),Error,true),
       Error==startup_error(original),
       nb_getval('$scope_test_pids',[Pid]),\+actors:actor_thread(Pid,_),
       nb_getval('$scope_test_key',Key),\+nb_current(Key,_),
       no_worker_messages([Pid])),
      probe_clear),
    format('~w partial startup exception preserves error and reclaims worker: ok~n',[Kind]).

scope_failure_and_cut :-
    setup_call_cleanup(probe_start(pass),
      (\+worker_cleanup:with_worker_scope(S,
           (worker_cleanup:spawn_worker(S,actors:receive({never -> true}),_),fail)),
       nb_getval('$scope_test_pids',[A]),\+actors:actor_thread(A,_),
       nb_getval('$scope_test_key',K),\+nb_current(K,_),
       once(worker_cleanup:with_worker_scope(T,
           (worker_cleanup:spawn_worker(T,actors:receive({never -> true}),_),member(_,[a,b])))),
       nb_getval('$scope_test_pids',[B,A]),\+actors:actor_thread(B,_),
       nb_getval('$scope_test_key',L),\+nb_current(L,_)),probe_clear),
    writeln('scope finalizers cover ordinary failure and cuts: ok').

% Workers tell the observer only after their real actor threads have started.
blocked(Observer) :-
    self(Self),send(Observer,worker(Self)),receive({never -> true}).
coordinator(Kind,Stage,Observer) :-
    (Stage==reserved -> Mode=reserved_interrupt(Observer);Mode=pass),
    probe_start(Mode),self(Self),
    Self ! down(unrelated,probe,killed),
    scope_diagnostic(Kind,Stage,self_send_complete),
    catch(invoke(Kind,[worker_scope_tests:blocked(Observer),worker_scope_tests:blocked(Observer)]),Error,true),
    scope_diagnostic(Kind,Stage,after_unwind(Error)),
    nb_getval('$scope_test_pids',Pids),
    require(forall(member(P,Pids),\+actors:actor_thread(P,_)),workers_still_registered(Pids)),
    nb_getval('$scope_test_key',Key),require(\+nb_current(Key,_),scope_record_remains),
    scope_diagnostic(Kind,Stage,before_assertion),
    catch(receive({down(unrelated,probe,killed) -> true},[timeout(0),on_timeout(throw(missing_unrelated))]),
          AssertionError,
          (scope_diagnostic(Kind,Stage,assertion_failed(AssertionError)),throw(AssertionError))),
    scope_diagnostic(Kind,Stage,assertion_passed),
    no_worker_messages(Pids),
    (Stage==waiting ->
      nb_getval('$scope_extra_monitor',Worker-Ref),
      receive({down(Worker,Ref,_) -> true},[timeout(2),on_timeout(throw(missing_extra_monitor(Worker,Ref)))])
    ; true),
    probe_clear,send(Observer,cleaned(Self,Error)).

:- meta_predicate require(0,+).
require(Goal,Error) :- (call(Goal)->true;throw(Error)).
attach_monitor(Pid,Observer) :-
    monitor(Pid,Ref),nb_setval('$scope_extra_monitor',Pid-Ref),
    send(Observer,extra_ready).

interruption(Kind,Stage) :-
    self(Self),spawn_runtime(worker_scope_tests:coordinator(Kind,Stage,Self),Caller,[link(false),monitor(true),'$entry_context'(caller)]),
    setup_call_cleanup(true,
      ((Stage==waiting ->
         receive({worker(First) -> true},[timeout(3),on_timeout(fail)]),
         receive({worker(_) -> true},[timeout(3),on_timeout(fail)]),
         actors:actor_thread(Caller,Thread),
         thread_signal(Thread,worker_scope_tests:attach_monitor(First,Self)),
         receive({extra_ready -> true},[timeout(3),on_timeout(fail)])
       ; % This hook deliberately holds the registry mutex. Native receive
         % avoids taking it through self/1 before the signal releases startup.
         thread_get_message(reserved(Caller,_,Thread))),
       scope_diagnostic(Kind,Stage,observer_before_signal(Caller)),
       thread_signal(Thread,throw('$abort_goal')),
       (Stage==reserved -> receive({worker(_) -> true},[timeout(3),on_timeout(fail)]);true),
       receive({cleaned(Caller,'$abort_goal') -> true;down(Caller,Caller,Why) -> throw(coordinator_failed(Why))},[timeout(3),on_timeout(throw(missing_cleanup(Kind,Stage)))]),
       receive({down(Caller,Caller,true) -> true},[timeout(3),on_timeout(fail)])),
      exit(Caller,kill)),
    format('~w interruption during ~w cleans scope and preserves monitors: ok~n',[Kind,Stage]).

% Opt-in test diagnostics only. Peeks and deferred snapshots do not consume
% messages; the original zero-time assertion and failure term are unchanged.
scope_diagnostic(Kind,Stage,Phase) :-
    ( getenv('WORKER_SCOPE_DIAGNOSTICS',Enabled),
      (Enabled == '1' ; Enabled == failure)
    -> (Enabled == failure, Phase \= assertion_failed(_)
       -> true
       ; scope_snapshot(Kind,Stage,Phase))
    ; true ).

scope_snapshot(Kind,Stage,Phase) :-
       thread_self(Thread),
       (thread_peek_message(Thread,down(unrelated,probe,killed)) -> Native=present;Native=absent),
       (nb_current('$actor_deferred',Deferred) -> true;Deferred=[]),
       (nb_current('$scope_test_pids',Pids) -> true;Pids=[]),
       (nb_current('$scope_test_key',Key) ->
           (nb_current(Key,_) -> Scope=present;Scope=absent)
       ; Scope=not_recorded),
       format(atom(Line),'~q~n',[scope_diag(Kind,Stage,Phase,Thread,Native,Deferred,Pids,Scope)]),
       write(Line),flush_output.

terminating_coordinator(Kind,Observer) :-
    invoke(Kind,[worker_scope_tests:blocked(Observer),worker_scope_tests:blocked(Observer)]).
termination(Kind) :-
    self(Self),spawn_runtime(worker_scope_tests:terminating_coordinator(Kind,Self),Caller,[link(false),monitor(true),'$entry_context'(caller)]),
    setup_call_cleanup(true,
      (receive({worker(A) -> true},[timeout(3),on_timeout(fail)]),
       receive({worker(B) -> true},[timeout(3),on_timeout(fail)]),
       monitor(A,RA),monitor(B,RB),exit(Caller,killed),
       receive({down(Caller,Caller,killed) -> true},[timeout(3),on_timeout(fail)]),
       receive({down(A,RA,_) -> true},[timeout(3),on_timeout(fail)]),
       receive({down(B,RB,_) -> true},[timeout(3),on_timeout(fail)]),
       \+actors:actor_thread(A,_),\+actors:actor_thread(B,_)),exit(Caller,kill)),
    format('~w caller termination stops workers without waiting on dying mailbox: ok~n',[Kind]).

no_worker_messages(Pids) :-
    receive({
      Pid-_ if memberchk(Pid,Pids) -> throw(leftover_worker_result(Pid));
      down(Pid,Pid,_) if memberchk(Pid,Pids) -> throw(leftover_worker_down(Pid))
    },[timeout(0),on_timeout(true)]).

nested_and_bindings :-
    parallel([parallel:first_solution(X,[X=ok,actors:receive({never -> true})]),Y=kept]),X==ok,Y==kept,
    \+parallel([Z=a,Z=b]),
    first_solution(expected,[actors:receive({never -> true}),true]),
    first_solution(V,[fail,throw(ignored),V=ok],[on_error(continue)]),V==ok,
    parallel([]),\+first_solution(_,[]),
    findall(A,first_solution(A,[A=only]),[only]),
    writeln('nested scopes, bindings, mismatch, policies and single-result semantics: ok').
public_metadata_rejected :-
    catch(spawn(true,_,['$worker_scope'(forged)]),Error,true),
    Error=error(permission_error(option,internal_spawn_option,'$worker_scope'(forged)),_),
    writeln('worker ownership metadata remains private: ok').
