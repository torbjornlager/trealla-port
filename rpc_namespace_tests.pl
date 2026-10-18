% SPDX-License-Identifier: MIT
:- module(rpc_namespace_tests,[rpc_namespace_tests/0,rpc_namespace_live_test/1]).
:- use_module(rpc).
:- use_module(actors).
:- use_module(distribution).
:- use_module(namespace_tests).

create_test_promise(Parent) :-
    make_ref(Ref),rpc:start_promise_setup(Ref,rpc_namespace_tests:setup_threads(Ref,Resources)),
    self(Me),Parent ! test_promise(Me,Ref,Resources).
setup_threads(Ref,resources(Q,W,T)) :-
    rpc:start_promise_threads(Ref,sleep(60),300),
    once(rpc:promise_state(Ref,Q,W,T,_,_,_)).
create_in_scope(P,Ref,Resources) :-
    self(Self),namespace_tests:run_scope(P,rpc_namespace_tests:create_test_promise(Self),ok),
    receive({test_promise(P,Ref,Resources) -> true},[timeout(2),on_timeout(fail)]).
queue_exists(Q) :- catch(message_queue_property(Q,size(_)),_,fail).
thread_gone(none) :- !.
thread_gone(T) :- \+ catch(thread_property(T,status(_)),_,fail).
await(Goal,N) :- (call(Goal) -> true ; N>0,sleep(0.005),M is N-1,await(Goal,M)).
assert_disposed(Ref,resources(Q,W,T)) :-
    \+ rpc:promise_state(Ref,_,_,_,_,_,_),\+ queue_exists(Q),
    await(rpc_namespace_tests:thread_gone(W),200),await(rpc_namespace_tests:thread_gone(T),200).
expect_missing(Ref) :- catch(yield(Ref,_),E,true),nonvar(E),E=error(existence_error(promise,Ref),_).

rpc_namespace_tests :-
    namespace_disposal_resources,
    namespace_disposal_collector,
    namespace_disposal_error_continuation,
    forall(between(1,20,_),namespace_creation_race),
    writeln('Namespace promise disposal: all regressions passed').

namespace_disposal_resources :-
    namespace_tests:new_scope(NS,P),namespace_tests:new_scope(OtherNS,Other),
    create_in_scope(P,Pending,PendingR),create_in_scope(P,Ready,ReadyR),
    rpc:deliver_promise_answer(Ready,success([ready],false)),
    create_in_scope(Other,Kept,KeptR),
    make_ref(Local),rpc:start_promise(Local,sleep(60),300),
    make_ref(HTTP),rpc:promise_transaction(
        rpc:new_promise_state(HTTP,_,client_namespace(http_client(test_http_owner)))),
    namespace_tests:run_scope(P,(yield(Pending,timeout,[timeout(0)])),ok),
    namespace_tests:run_scope(P,(yield(Pending,Waiting,[timeout(0),on_timeout(Waiting=waiting)])),ok),
    % Namespace disposal bypasses caller ownership only for its recorded owner.
    web_prolog:retire_websocket_namespace(NS),web_prolog:retire_websocket_namespace(NS),
    assert_disposed(Pending,PendingR),assert_disposed(Ready,ReadyR),
    namespace_tests:run_scope(P,rpc_namespace_tests:expect_missing(Pending),ok),
    namespace_tests:run_scope(P,rpc_namespace_tests:expect_missing(Ready),ok),
    namespace_tests:run_scope(P,rpc_namespace_tests:create_test_promise(Other),Rejected),
    Rejected=error(error(permission_error(create,promise,client_namespace(NS)),_)),
    actors:actor_thread(P,_),rpc:promise_active(Kept),rpc:promise_active(Local),rpc:promise_active(HTTP),
    namespace_tests:run_scope(Other,(yield(Kept,timeout,[timeout(0)])),ok),
    rpc:deliver_promise_answer(Kept,success([retained],false)),
    namespace_tests:run_scope(Other,yield(Kept,success([retained],false)),ok),assert_disposed(Kept,KeptR),
    promise_cleanup(Local),rpc:dispose_promise(HTTP),web_prolog:retire_websocket_namespace(OtherNS),
    namespace_tests:stop_scope(P),namespace_tests:stop_scope(Other),
    writeln('pending/ready resources reclaimed; survivors, callbacks, retry and other owners preserved: ok').

has_collector(Ref) :- once(rpc:promise_state(Ref,_,_,_,C,_,_)),C\==none.
namespace_disposal_collector :-
    namespace_tests:new_scope(NS,P),create_in_scope(P,Ref,R),make_ref(Request),
    P ! run(Request,yield(Ref,_)),await(rpc_namespace_tests:has_collector(Ref),200),
    web_prolog:retire_websocket_namespace(NS),
    receive({scope_result(Request,Result) -> true},[timeout(2),on_timeout(fail)]),
    Result=error(error(existence_error(promise,Ref),_)),assert_disposed(Ref,R),
    actors:actor_thread(P,_),namespace_tests:run_scope(P,true,ok),namespace_tests:stop_scope(P),
    writeln('waiting collector wakes with missing reference and its actor survives caught error: ok').

% Force an unresponsive collector claim on the test's still-live native thread.
% Disposal must retire/stop every promise even if one queue cannot be reclaimed.
claim_for_test(Ref,Thread) :-
    rpc:promise_transaction((retract(rpc:promise_state(Ref,Q,W,T,none,R,Owner)),
        assertz(rpc:promise_state(Ref,Q,W,T,collector(Thread),R,Owner)))).
namespace_disposal_error_continuation :-
    namespace_tests:new_scope(NS,P),create_in_scope(P,Blocked,resources(Q,W,T)),
    create_in_scope(P,Other,R),thread_self(Me),claim_for_test(Blocked,Me),
    catch(dispose_namespace_promises(NS),Error,true),
    Error=error(resource_error(promise_cleanup_timeout(Blocked)),promise_cleanup/1),
    assert_disposed(Other,R),queue_exists(Q),
    await(rpc_namespace_tests:thread_gone(W),200),await(rpc_namespace_tests:thread_gone(T),200),
    rpc:promise_transaction(rpc:release_promise_claim(Blocked,collector(Me))),
    dispose_namespace_promises(NS),\+ queue_exists(Q),namespace_tests:stop_scope(P),
    writeln('all promises retired despite one cleanup error; active queue stays safe and retryable: ok').

namespace_creation_race :-
    namespace_tests:new_scope(NS,P),make_ref(Request),
    P ! run(Request,rpc_namespace_tests:create_test_promise(P)),
    dispose_namespace_promises(NS),
    receive({scope_result(Request,Result) -> true},[timeout(2),on_timeout(fail)]),
    (Result==ok -> true
    ; Result=error(error(permission_error(create,promise,client_namespace(NS)),_))),
    \+ rpc:promise_state(_,_,_,_,_,_,client_namespace(NS)),namespace_tests:stop_scope(P).

rpc_namespace_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    remote_node_open(URL,A),remote_node_open(URL,B),
    setup_call_cleanup(true,rpc_namespace_tests:live_disposal(A,B,URL),
        (remote_node_close(A),remote_node_close(B))),
    format('Live WebSocket promise disposal on ~w: ok~n',[Port]).
live_disposal(A,B,URL) :-
    remote_toplevel_spawn(A,TA,[session(true)]),remote_toplevel_spawn(B,TB,[session(true)]),
    % A creates a pending promise; B creates its own promise, retaining retry.
    remote_toplevel_call_synch(A,TA,promise(URL,(sleep(30),X=a),Ref,[template(X)]),Ans,[template(Ref),timeout(3)]),
    Ans=success(_,[PromiseRef],false),
    remote_toplevel_call_synch(B,TB,promise(URL,Y=b,Keep,[template(Y)]),KAns,[template(Keep),timeout(3)]),
    KAns=success(_,[Kept],false),remote_node_close(A),
    % The client boundary does not expose lifecycle internals. Existing owner
    % isolation still hides A's now-disposed reference from the other client.
    remote_toplevel_call_synch(B,TB,catch(yield(PromiseRef,_),E,true),Gone,[template(E),timeout(3)]),
    Gone=success(_,[error(existence_error(promise,PromiseRef),_)],false),
    remote_toplevel_call_synch(B,TB,yield(Kept,Answer),Collected,[template(Answer),timeout(3)]),
    Collected=success(_,[success([b],false)],false),remote_toplevel_halt(B,TB).
