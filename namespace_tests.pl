% SPDX-License-Identifier: MIT
:- module(namespace_tests,[namespace_tests/0,namespace_live_test/1]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(supervisor_actor).

scope_loop(Parent) :-
    receive({
        run(Ref,Goal) ->
            catch((call(Goal) -> Outcome=ok ; Outcome=failed),E,Outcome=error(E)),
            Parent ! scope_result(Ref,Outcome),scope_loop(Parent);
        finish -> true
    }).
new_scope(NS,P) :-
    make_ref(Id),NS=ws_client(Id),self(Parent),
    actors:spawn_scoped(namespace_tests:scope_loop(Parent),P,
        [link(false),monitor(true),'$entry_context'(caller)],NS,internal).
run_scope(P,Goal,Outcome) :-
    make_ref(Ref),P ! run(Ref,Goal),
    receive({scope_result(Ref,Outcome) -> true},[timeout(3),on_timeout(fail)]).
stop_scope(P) :- P ! finish,receive({down(P,P,_) -> true},[timeout(3),on_timeout(fail)]).
new_name(Name) :- make_ref(Id),format(atom(Name),'namespace_name_~w',[Id]).
closed_error(NS,error(error(permission_error(register,closed_namespace,NS),context(actors:register/2,_)))).

namespace_tests :-
    namespace_names_and_survivors,
    namespace_reservation_and_publication,
    namespace_inflight_publication,
    forall(between(1,20,_),namespace_registration_race),
    writeln('WebSocket registration namespace teardown: all regressions passed').

namespace_names_and_survivors :-
    new_scope(A,PA),new_scope(B,PB),
    new_name(Owned),new_name(Remote),new_name(Other),new_name(Trusted),
    new_name(Late),new_name(Service),self(Self),
    spawn(receive({finish -> true}),Target,[link(false),monitor(true)]),
    run_scope(PA,register(Owned,Target),ok),
    run_scope(PA,register(Remote,701@'http://namespace-remote.test'),ok),
    run_scope(PB,register(Other,702@'http://namespace-remote.test'),ok),
    register(Trusted,Self),register_service(Service,Target),
    % Uniqueness and visibility stay node-wide, regardless of owning scope.
    run_scope(PB,whereis(Owned,Target),ok),
    run_scope(PB,register(Owned,703@'http://namespace-remote.test'),Taken),
    Taken==error(name_is_in_use(Owned)),
    retire_registry_namespace(A),retire_registry_namespace(A),
    whereis(Owned,undefined),whereis(Remote,undefined),
    whereis(Other,702@'http://namespace-remote.test'),whereis(Trusted,Self),
    whereis_service(Service,Target),actors:actor_thread(Target,_),actors:actor_thread(PA,_),
    run_scope(PA,register(Late,704@'http://namespace-remote.test'),Rejected),closed_error(A,Rejected),
    run_scope(PA,namespace_tests:try_named_supervisor(Late),RejectedSpawn),closed_error(A,RejectedSpawn),
    run_scope(PB,register(Owned,705@'http://namespace-remote.test'),ok),
    % A repeated close cannot erase a replacement owned by another client.
    retire_registry_namespace(A),whereis(Owned,705@'http://namespace-remote.test'),
    retire_registry_namespace(B),whereis(Owned,undefined),whereis(Other,undefined),
    unregister(Trusted),unregister_service(Service),
    Target ! finish,receive({down(Target,Target,true) -> true},[timeout(2),on_timeout(fail)]),
    stop_scope(PA),stop_scope(PB),
    writeln('creator ownership, node-wide uniqueness, late admission and surviving actors: ok').
try_named_supervisor(Name) :- supervisor_actor:supervisor_spawn([],_,[name(Name),link(false)]).

reserve_and_wait(Parent,Name) :-
    actors:reserve_spawn_name(Name,Token),
    Parent ! reserved(Token),receive({publish -> true}),
    catch(namespace_tests:publish_test_actor(Token),Error,true),
    Parent ! publication(Error),actors:release_spawn_name(Token).
publish_test_actor(Token) :- spawn_runtime(true,_,[link(false),'$name_reservation'(Token)]).
namespace_reservation_and_publication :-
    new_scope(NS,P),new_name(Name),self(Parent),make_ref(Ref),
    P ! run(Ref,namespace_tests:reserve_and_wait(Parent,Name)),
    receive({reserved(Token) -> true},[timeout(2),on_timeout(fail)]),
    actors:reserved_spawn_name(Name,Token),retire_registry_namespace(NS),
    \+ actors:reserved_spawn_name(Name,Token),\+ actors:spawn_name_owner(Token,_),
    % Reuse the freed name while the old creator is still alive.
    register(Name,888@'http://namespace-remote.test'),P ! publish,
    receive({publication(Error) -> true},[timeout(3),on_timeout(fail)]),
    Error=error(permission_error(register,closed_namespace,NS),_),
    receive({scope_result(Ref,ok) -> true},[timeout(2),on_timeout(fail)]),
    whereis(Name,888@'http://namespace-remote.test'),unregister(Name),stop_scope(P),
    writeln('pending reservation retired and late startup publication rejected: ok').

wait_preparation(Parent) :-
    self(Me),Parent ! preparing(Me),receive({continue_preparation -> true}).
should_not_run(Parent) :- Parent ! unexpected_goal_execution.
create_preparing(Parent,Name) :-
    with_spawn_name([name(Name)],_,namespace_tests:create_preparing_actor(Parent)).
create_preparing_actor(Parent,NameOptions) :-
    append(NameOptions,[link(false),monitor(true),'$entry_context'(caller),
        src_list([(:- namespace_tests:wait_preparation(Parent))])],Options),
    spawn_runtime(namespace_tests:should_not_run(Parent),_,Options).
namespace_inflight_publication :-
    new_scope(NS,P),new_name(Name),self(Parent),make_ref(Ref),
    P ! run(Ref,namespace_tests:create_preparing(Parent,Name)),
    receive({preparing(Child) -> true},[timeout(3),on_timeout(fail)]),
    monitor(Child,ChildRef),retire_registry_namespace(NS),Child ! continue_preparation,
    receive({scope_result(Ref,Result) -> true},[timeout(3),on_timeout(fail)]),
    closed_error(NS,Result),
    receive({down(Child,ChildRef,_) -> true},[timeout(3),on_timeout(fail)]),
    whereis(Name,undefined),actors:actor_thread(P,_),
    receive({unexpected_goal_execution -> fail},[timeout(0),on_timeout(true)]),
    stop_scope(P),
    writeln('disconnect during child source preparation prevents late publication/goal execution: ok').

namespace_registration_race :-
    new_scope(NS,P),new_name(Name),make_ref(Ref),
    P ! run(Ref,register(Name,999@'http://namespace-remote.test')),
    retire_registry_namespace(NS),
    receive({scope_result(Ref,Result) -> true},[timeout(2),on_timeout(fail)]),
    ( Result==ok -> true ; closed_error(NS,Result) ),
    whereis(Name,undefined),stop_scope(P).

namespace_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    remote_node_open(URL,A),remote_node_open(URL,B),
    setup_call_cleanup(true,namespace_tests:live_namespace_sessions(A,B),
        (remote_node_close(A),remote_node_close(B))),
    format('Live WebSocket namespace teardown on ~w: ok~n',[Port]).
live_namespace_sessions(A,B) :-
    remote_toplevel_spawn(A,TA,[session(true)]),remote_toplevel_spawn(B,TB,[session(true)]),
    new_name(Name),new_name(Other),
    remote_toplevel_call_synch(A,TA,register(Name,901@'http://namespace-remote.test'),_,[timeout(3)]),
    remote_toplevel_call_synch(B,TB,(whereis(Name,901@'http://namespace-remote.test'),register(Other,902@'http://namespace-remote.test')),Before,[timeout(3)]),
    Before=success(_,_,_),remote_node_close(A),
    wait_alias_gone(B,TB,Name,50),
    remote_toplevel_call_synch(B,TB,whereis(Other,902@'http://namespace-remote.test'),After,[timeout(3)]),
    After=success(_,_,_),remote_toplevel_halt(B,TB).
wait_alias_gone(B,Top,Name,Tries) :-
    remote_toplevel_call_synch(B,Top,whereis(Name,undefined),Answer,[timeout(3)]),
    (Answer=success(_,_,_) -> true
    ; Tries>0,sleep(0.02),Next is Tries-1,wait_alias_gone(B,Top,Name,Next)).
