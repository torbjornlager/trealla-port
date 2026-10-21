% SPDX-License-Identifier: MIT
:- module(receiver_lineage_tests,[run/0,race_batch/2,diagnostic_checks/0]).
:- use_module(actors).
:- use_module(web_prolog, []).
:- use_module(receiver_lineage, []).
:- use_module(namespace_tests, []).
:- use_module(rpc_namespace_tests, []).

peer(principal(peer,[execute,internal_transport])).
token(a,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa').
token(b,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb').
wire(Key,JSON) :- token(Key,Token),atom_chars(Token,Cs),web_prolog:object([lineage-string(Cs)],JSON).
in_lineage(Relay,Key,Goal) :- wire(Key,JSON),peer(P),
    receiver_lineage:with_wire_context(JSON,Relay,P,spawn,call(Goal)).
:- meta_predicate in_lineage(+, +, 0).
wait :- receive({finish -> true}).
assert_gone(Pid) :-
    get_time(Now),Deadline is Now+2,
    (retired_before(Pid,Deadline) -> true
    ; throw(error(test_timeout(actor_retirement(Pid)),receiver_lineage_tests))).
retired_before(Pid,Deadline) :-
    (actors:actor_thread(Pid,_) ->
        get_time(Now),Now<Deadline,sleep(0.005),retired_before(Pid,Deadline)
    ; true).
new_relay(Base,Relay) :- namespace_tests:new_scope(Base,Relay).
close_relay(Base,Relay) :- web_prolog:retire_websocket_namespace(Base),namespace_tests:stop_scope(Relay).
expect_error(Goal,Pattern) :- catch(call(Goal),Error,true),nonvar(Error),Error=Pattern.
:- meta_predicate expect_error(0,+).

run :-
    diagnostic_checks,race_batch(after_prefix,20),
    writeln('Receiver delegated lineage: all regressions passed').

race_prefix :-
    authority_and_tokens,namespace_isolation,connection_cleanup,
    preparation_race(unnamed),preparation_race(named).

% Fixed batches run in fresh engine processes. No per-iteration success output
% or runtime hooks are added to the interleaving being investigated.
race_batch(Mode,Count) :-
    (memberchk(Mode,[isolated,after_prefix]),integer(Count),Count>0 -> true
    ; throw(error(domain_error(creation_race_batch,Mode-Count),race_batch/2))),
    format('creation_race_batch_started(~w,~w)~n',[Mode,Count]),
    (Mode==after_prefix ->
        race_step(prefix,race(0,unavailable,unavailable,unavailable,unavailable),race_prefix)
    ; true),
    writeln(creation_race_iterations_started),race_iterations(1,Count),
    format('creation_race_batch_passed(~w,~w)~n',[Mode,Count]).
race_iterations(I,Count) :-
    (I>Count -> true
    ; creation_race(I),Next is I+1,race_iterations(Next,Count)).

authority_and_tokens :-
    wire(a,JSON),
    expect_error(receiver_lineage:with_wire_context(JSON,test,principal(browser,[execute]),spawn,true),
        error(permission_error(use,transport_lineage,_),_)),
    expect_error(receiver_lineage:with_wire_context(pairs([string([l,i,n,e,a,g,e])-string([x])]),test,principal(peer,[internal_transport]),spawn,true),
        error(domain_error(transport_lineage,_),_)),
    expect_error(receiver_lineage:with_wire_context(pairs([]),test,principal(peer,[internal_transport]),lineage_close,true),
        error(existence_error(field,lineage),_)),
    wire(a,pairs(Fields)),
    expect_error(receiver_lineage:with_wire_context(pairs([string([a,c,c,o,u,n,t])-string([x])|Fields]),test,principal(peer,[internal_transport]),spawn,true),
        error(domain_error(transport_lineage,_),_)),
    forall(member(Mode,[blacklist,whitelist]),
        (expect_error(sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,
              receiver_lineage:close_namespace(ws_lineage(test,a)),[],_,_),error(permission_error(_,_,_),_)),
         expect_error(sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,
              actors:with_actor_namespace(ws_lineage(test,a),true),[],_,_),error(permission_error(_,_,_),_)))),
    actors:current_actor_namespace(none),writeln('authority, token, account and sandbox validation: ok').

spawn_family(Parent,Name,Root,Child,Ref,Resources) :-
    spawn_runtime((self(Me),spawn_runtime(receiver_lineage_tests:wait,C,[link(false),'$entry_context'(caller)]),
           register(Name,C),rpc_namespace_tests:create_test_promise(Parent),
           Parent ! family(Me,C),receiver_lineage_tests:wait),Root,[link(false),monitor(true),'$entry_context'(caller)]),
    receive({family(Root,Child) -> true},[timeout(2),on_timeout(fail)]),
    receive({test_promise(Root,Ref,Resources) -> true},[timeout(2),on_timeout(fail)]).

namespace_isolation :-
    new_relay(Base,Relay),self(Parent),
    in_lineage(Relay,a,member(_,[first,second])),actors:current_actor_namespace(none),
    namespace_tests:new_name(Name),namespace_tests:new_name(OtherName),
    in_lineage(Relay,a,spawn_family(Parent,Name,Root,Child,Ref,Resources)),
    in_lineage(Relay,b,spawn_family(Parent,OtherName,Other,OtherChild,Kept,KeptResources)),
    % Same token on another connection denotes another owner.
    new_relay(Base2,Relay2),in_lineage(Relay2,a,spawn_runtime(receiver_lineage_tests:wait,Separate,[link(false),monitor(true),'$entry_context'(caller)])),
    token(a,A),NS=ws_lineage(Relay,A),actors:actor_namespace(Root,NS),actors:actor_namespace(Child,NS),
    in_lineage(Relay,b,(\+ receiver_lineage:check_actor(Root))),
    in_lineage(Relay,a,receiver_lineage:check_actor(Child)),
    receiver_lineage:close_namespace(NS),receiver_lineage:close_namespace(NS),
    receive({down(Root,Root,kill) -> true},[timeout(2),on_timeout(fail)]),assert_gone(Child),
    whereis(Name,undefined),whereis(OtherName,OtherChild),
    rpc_namespace_tests:assert_disposed(Ref,Resources),rpc:promise_active(Kept),
    actors:actor_thread(Other,_),actors:actor_thread(OtherChild,_),actors:actor_thread(Separate,_),
    expect_error(in_lineage(Relay,a,true),error(permission_error(register,closed_namespace,NS),_)),
    expect_error(actors:with_actor_namespace(NS,spawn(true,_)),error(permission_error(register,closed_namespace,NS),_)),
    expect_error(actors:with_actor_namespace(NS,register(Name,Other)),error(permission_error(register,closed_namespace,NS),_)),
    expect_error(actors:with_actor_namespace(NS,rpc_namespace_tests:create_test_promise(Parent)),error(permission_error(create,promise,_),_)),
    % A queued spawn must wake its reader even if closure wins the race.
    thread_self(Reader),web_prolog:relay_message(unused,'$lineage'(NS,'$spawn'(true,[],Reader,legacy))),
    thread_get_message('$spawn_failed'(_)),
    close_relay(Base,Relay),close_relay(Base2,Relay2),
    receive({down(Other,Other,kill) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(Separate,Separate,kill) -> true},[timeout(2),on_timeout(fail)]),
    assert_gone(OtherChild),rpc_namespace_tests:assert_disposed(Kept,KeptResources),
    writeln('descendants, names, promises, late admission and unrelated lineages: ok').

connection_cleanup :-
    new_relay(Base,Relay),
    in_lineage(Relay,a,spawn_runtime(receiver_lineage_tests:wait,A,[link(false),monitor(true),'$entry_context'(caller)])),
    in_lineage(Relay,b,spawn_runtime(receiver_lineage_tests:wait,B,[link(false),monitor(true),'$entry_context'(caller)])),
    close_relay(Base,Relay),
    receive({down(A,A,kill) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(B,B,kill) -> true},[timeout(2),on_timeout(fail)]),
    expect_error(in_lineage(Relay,b,true),error(permission_error(use,closed_connection,Relay),_)),
    writeln('connection loss closes every delegated namespace: ok').

% Keep the original entry available for targeted reruns.
creation_race :- creation_race(1).
creation_race(Iteration) :-
    Context=race(Iteration,NS,Ref,Worker,Result),
    race_step(relay_startup,Context,new_relay(Base,Relay)),
    self(Parent),make_ref(Ref),wire(a,JSON),peer(P),
    token(a,A),NS=ws_lineage(Relay,A),
    % Open before racing so the connection snapshot contains the lineage.
    race_step(open_namespace,Context,in_lineage(Relay,a,true)),
    race_step(worker_startup,Context,
        spawn_runtime((catch(receiver_lineage:with_wire_context(JSON,Relay,P,spawn,
                          spawn_runtime(receiver_lineage_tests:wait,Child,
                              [link(false),'$entry_context'(caller)])),E,true),
               Parent ! raced(Ref,Child,E)),Worker,
              [link(false),monitor(true),'$entry_context'(caller)])),
    race_step(close_namespace,Context,receiver_lineage:close_namespace(NS)),
    race_step(await_raced_reply,Context,
        receive({raced(Ref,Result,Error) -> true},[timeout(2),on_timeout(fail)])),
    (var(Error) ->
        race_step(child_pid,Context,(integer(Result),Result>=1000000000)),
        race_step(child_retirement,Context,assert_gone(Result))
    ; race_step(startup_error(Error),Context,
          Error=error(permission_error(register,closed_namespace,NS),_))),
    % Select the worker's notification before checking its reason, so the
    % diagnostic distinguishes a missing notification from an unexpected one.
    race_step(await_worker_down,Context,
        receive({down(Worker,Worker,Reason) -> true},[timeout(2),on_timeout(fail)])),
    race_step(worker_reason(Reason),Context,Reason==true),
    % Preserve this immediate assertion. Adding a wait would conceal whether
    % the original test expects namespace retirement before it is guaranteed.
    race_step(namespace_empty,Context,\+ actors:actor_namespace(_,NS)),
    race_step(relay_teardown,Context,close_relay(Base,Relay)).

:- meta_predicate race_step(+, +, 0).
race_step(Stage,Context,Goal) :-
    catch((call(Goal) -> Outcome=passed ; Outcome=failed),
          Error,Outcome=exception(Error)),
    (Outcome==passed -> true ; race_failure(Stage,Context,Outcome)).
race_failure(Stage,Context,Outcome) :-
    catch(race_snapshot(Context,Snapshot),Error,Snapshot=snapshot_error(Error)),
    throw(error(lineage_creation_race(Stage,Outcome,Context,Snapshot),
                context(receiver_lineage_tests:creation_race/1,'test-only diagnostic'))).

% Only read the test's actors/namespace and the observer's mailbox. All
% snapshots happen after failure, and no messages are consumed or flushed.
race_snapshot(race(_,NS,_,Worker,Child),
              snapshot(Closed,NamespaceRows,Actors,Deferred,QueueHead)) :-
    with_mutex('$actor_registry',
        receiver_lineage_tests:registry_snapshot(NS,Worker,Child,Closed,NamespaceRows,Rows)),
    native_statuses(Rows,Actors),actors:deferred_list(Deferred),thread_self(Self),
    catch((thread_peek_message(Self,Head) -> QueueHead=message(Head) ; QueueHead=empty),
          Error,QueueHead=exception(Error)).
registry_snapshot(NS,Worker,Child,Closed,NamespaceRows,Rows) :-
    (ground(NS),NS=ws_lineage(_,_) ->
        findall(P,actors:actor_namespace(P,NS),NamespaceRows),
        (actors:closed_registry_namespace(NS) -> Closed=true ; Closed=false)
    ; NamespaceRows=[],Closed=unknown),
    add_known_pid(Worker,NamespaceRows,Pids0),add_known_pid(Child,Pids0,Pids1),
    sort(Pids1,Pids),actor_rows(Pids,Rows).
add_known_pid(Pid,Pids,[Pid|Pids]) :- integer(Pid),!.
add_known_pid(_,Pids,Pids).
actor_rows([],[]).
actor_rows([P|Pids],[actor(P,Alive,Threads,Reasons,Finishing,Preparing,Namespaces,Monitors)|Rows]) :-
    (actors:actor_alive(P) -> Alive=true ; Alive=false),
    findall(T,actors:pid_thread(P,T),Threads),findall(R,actors:exit_reason(P,R),Reasons),
    (actors:actor_finishing(P) -> Finishing=true ; Finishing=false),
    (actors:lineage_preparing(P) -> Preparing=true ; Preparing=false),
    findall(NS,actors:actor_namespace(P,NS),Namespaces),
    findall(watcher(W,Ref),actors:monitor(W,P,Ref),Monitors),actor_rows(Pids,Rows).
native_statuses([],[]).
native_statuses([actor(P,A,Ts,R,F,L,NS,M)|Rows],
                [actor(P,A,Statuses,R,F,L,NS,M)|Rest]) :-
    thread_statuses(Ts,Statuses),native_statuses(Rows,Rest).
thread_statuses([],[]).
thread_statuses([T|Ts],[thread(T,Status)|Rest]) :-
    (catch(thread_property(T,status(S)),Error,S=exception(Error)) -> Status=S
    ; Status=unavailable),thread_statuses(Ts,Rest).

% Verify the new diagnostic mechanism itself without manufacturing a runtime
% race: preserve bindings, report failure/exception, and leave messages alone.
diagnostic_checks :-
    Context=race(diagnostic,unavailable,unavailable,unavailable,unavailable),
    race_step(bindings,Context,X=kept),X==kept,
    make_ref(Ref),self(Self),Self ! diagnostic_sentinel(Ref),
    catch(race_step(probe_failure,Context,fail),Failure,true),
    nonvar(Failure),Failure=error(lineage_creation_race(probe_failure,failed,_,_),_),
    receive({diagnostic_sentinel(Ref) -> true},[timeout(0),on_timeout(fail)]),
    catch(race_step(probe_exception,Context,throw(probe_error)),Exception,true),
    nonvar(Exception),Exception=error(lineage_creation_race(probe_exception,exception(probe_error),_,_),_),
    get_time(Now),Past is Now-1,
    \+ retired_before(Self,Past),
    writeln('Creation-race diagnostics preserve messages and identify failed stages: ok').

preparing_spawn(Parent, unnamed) :-
    preparing_actor(Parent,[]).
preparing_spawn(Parent, named) :-
    namespace_tests:new_name(Name),
    with_spawn_name([name(Name)],_,receiver_lineage_tests:preparing_actor(Parent)).
preparing_actor(Parent,NameOptions) :-
    append(NameOptions,[link(false),'$entry_context'(caller),
        src_list([(:- namespace_tests:wait_preparation(Parent))])],Options),
    spawn_runtime(namespace_tests:should_not_run(Parent),_,Options).
preparation_race(Kind) :-
    new_relay(Base,Relay),self(Parent),make_ref(Ref),
    spawn_runtime((catch(receiver_lineage_tests:in_lineage(Relay,a,
                         receiver_lineage_tests:preparing_spawn(Parent,Kind)),E,true),
                   Parent ! preparation_result(Ref,E)),Creator,
                  [link(false),monitor(true),'$entry_context'(caller)]),
    receive({preparing(Child) -> true},[timeout(3),on_timeout(fail)]),
    monitor(Child,Monitor),token(a,A),NS=ws_lineage(Relay,A),
    receiver_lineage:close_namespace(NS),
    % Preparation finishes under existing source-loader limits, then rejects
    % activation. It must wake its waiting creator even without a name option.
    actors:lineage_preparing(Child),Child ! continue_preparation,
    receive({preparation_result(Ref,Error) -> true},[timeout(3),on_timeout(fail)]),
    Error=error(permission_error(register,closed_namespace,NS),_),
    receive({down(Child,Monitor,_) -> true},[timeout(3),on_timeout(fail)]),
    receive({down(Creator,Creator,true) -> true},[timeout(3),on_timeout(fail)]),
    receive({unexpected_goal_execution -> fail},[timeout(0),on_timeout(true)]),
    \+ actors:actor_namespace(_,NS),close_relay(Base,Relay),
    format('closure during ~w preparation rejects activation and wakes creator: ok~n',[Kind]).
