% SPDX-License-Identifier: MIT
:- use_module(rpc).
:- use_module(actors).
:- use_module(node).

rpc_ownership_tests :-
    namespace_promise_isolation,
    trusted_promise_sharing,
    http_request_owners,
    missing_client_identity,
    writeln('Promise ownership: all regressions passed').

owner_actor(Parent) :-
    self(Me),
    receive({
        create ->
            make_ref(Ref),rpc:promise_owner_context(Owner),
            rpc:promise_transaction(rpc:new_promise_state(Ref,_,Owner)),
            rpc:deliver_promise_answer(Ref,success([secret],false)),
            Parent ! created(Me,Ref),user:owner_actor(Parent) ;
        collect(Ref) ->
            catch(yield(Ref,Answer,[timeout(0)]),E,true),
            Parent ! collected(Me,Answer,E),user:owner_actor(Parent) ;
        cleanup(Ref) ->
            promise_cleanup(Ref),Parent ! cleaned(Me),user:owner_actor(Parent) ;
        child_collect(Ref) ->
            spawn(user:owner_child_collect(Parent,Ref),_,[link(false)]),
            user:owner_actor(Parent) ;
        stop -> true
    }).
owner_child_collect(Parent,Ref) :-
    yield(Ref,Answer),Parent ! child_collected(Answer).

namespace_promise_isolation :-
    self(Parent),make_ref(IdA),make_ref(IdB),
    actors:spawn_scoped(user:owner_actor(Parent),A,[link(false),monitor(true)],ws_client(IdA),public),
    actors:spawn_scoped(user:owner_actor(Parent),B,[link(false),monitor(true)],ws_client(IdB),public),
    actors:spawn_scoped(user:owner_actor(Parent),Same,[link(false),monitor(true)],ws_client(IdA),public),
    A ! create,receive({created(A,Ref) -> true;down(A,A,Why) -> throw(owner_actor_down(Why))},[timeout(2),on_timeout(throw(create_timeout))]),
    B ! collect(Ref),
    receive({collected(B,Answer,E) -> var(Answer),E=error(existence_error(promise,Ref),_)}),
    B ! cleanup(Ref),receive({cleaned(B) -> true}),
    % Trusted local code has sharing, but no implicit access to client promises.
    catch(yield(Ref,_),LocalError,true),LocalError=error(existence_error(promise,Ref),_),
    promise_cleanup(Ref),
    Same ! collect(Ref),receive({collected(Same,Success,NoError) -> Success==success([secret],false),var(NoError)}),
    A ! create,receive({created(A,Ref2) -> true}),
    A ! child_collect(Ref2),receive({child_collected(ChildAnswer) -> ChildAnswer==success([secret],false)}),
    A ! stop,B ! stop,Same ! stop,
    receive({down(A,A,true) -> true}),receive({down(B,B,true) -> true}),receive({down(Same,Same,true) -> true}),
    writeln('different client namespaces isolated; same namespace and descendants share: ok').

trusted_promise_sharing :-
    make_ref(Ref),rpc:promise_owner_context(trusted_local),
    rpc:promise_transaction(rpc:new_promise_state(Ref,_,trusted_local)),
    rpc:deliver_promise_answer(Ref,success([secret],false)),
    self(Parent),spawn(user:owner_child_collect(Parent,Ref),P,[link(false),monitor(true)]),
    receive({child_collected(Answer) -> Answer==success([secret],false)}),
    receive({down(P,P,true) -> true}),
    writeln('trusted standalone actors preserve local sharing: ok').

http_request_owners :-
    node:with_http_promise_namespace(user:capture_http_owner(First)),
    node:with_http_promise_namespace(user:check_other_http_owner(First)),
    \+ node:current_http_promise_namespace(_),
    rpc:promise_owner_context(trusted_local),
    writeln('HTTP requests have fresh identities inherited by execution actors: ok').
capture_http_owner(owner(Owner,Ref)) :-
    rpc:promise_owner_context(Owner),Owner=client_namespace(http_client(_)),ground(Owner),
    catch(node:with_http_promise_namespace(user:throw_nested_owner(Owner)),Nested,true),
    Nested==nested_owner_error,rpc:promise_owner_context(Restored),Restored==Owner,
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_,Owner)),
    rpc:deliver_promise_answer(Ref,success([secret],false)),
    node:compute_answer(rpc:promise_owner_context(ExecutionOwner),ExecutionOwner,0,1,Answer),
    Answer==success([Owner],false).
check_other_http_owner(owner(Old,Ref)) :-
    rpc:promise_owner_context(New),New\==Old,
    catch(yield(Ref,_),E,true),E=error(existence_error(promise,Ref),_),
    promise_cleanup(Ref),
    % Only the fixture uses internal disposal; clients cannot invoke this API.
    rpc:dispose_promise(Ref).

:- use_module(distribution).
rpc_ownership_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    remote_node_open(URL,A),remote_node_open(URL,B),
    setup_call_cleanup(
        (remote_toplevel_spawn(A,TA,[session(true)]),remote_toplevel_spawn(B,TB,[session(true)])),
        user:live_owner_sessions(A,TA,B,TB,URL),
        (remote_toplevel_halt(A,TA),remote_toplevel_halt(B,TB),remote_node_close(A),remote_node_close(B))),
    format('Live WebSocket promise ownership on ~w: ok~n',[Port]).
live_owner_sessions(A,TA,B,TB,URL) :-
    remote_toplevel_call_synch(A,TA,
        promise(URL,X=secret,Ref,[template(X)]),Created,
        [template(Ref),timeout(3)]),
    Created=success(TA,[Reference],false),ground(Reference),
    remote_toplevel_call_synch(B,TB,yield(Reference,_,[timeout(0)]),Denied,[timeout(3)]),
    Denied=error(TB,error(existence_error(promise,Reference),_)),
    remote_toplevel_call_synch(B,TB,promise_cleanup(Reference),Cleaned,[template(ok),timeout(3)]),
    Cleaned==success(TB,[ok],false),
    remote_toplevel_call_synch(A,TA,yield(Reference,Answer),Collected,[template(Answer),timeout(3)]),
    Collected==success(TA,[success([secret],false)],false),
    % Real HTTP requests also have distinct owners; module identity is shared.
    promise(URL,promise(URL,true,RemoteRef),Http,[template(RemoteRef)]),
    yield(Http,HttpResult),HttpResult=success([HTTPRef],false),
    promise(URL,yield(HTTPRef,_),OtherHttp),yield(OtherHttp,HttpDenied),
    HttpDenied=error(error(existence_error(promise,HTTPRef),_)).

missing_client_identity :-
    self(Parent),
    findall(Ref,rpc:promise_state(Ref,_,_,_,_,_,_),Before),
    actors:spawn_scoped(user:owner_actor(Parent),A,
        [link(false),monitor(true)],broken_client(_),public),
    A ! create,
    receive({down(A,A,exception(error(permission_error(create,promise,client_context),_))) -> true},
            [timeout(2),on_timeout(fail)]),
    findall(Ref,rpc:promise_state(Ref,_,_,_,_,_,_),After),Before==After,
    writeln('missing public identity is rejected before resource creation: ok').

throw_nested_owner(Outer) :-
    rpc:promise_owner_context(Inner),Inner\==Outer,throw(nested_owner_error).
