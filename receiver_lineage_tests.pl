% SPDX-License-Identifier: MIT
:- module(receiver_lineage_tests,[run/0]).
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
assert_gone(Pid) :- (actors:actor_thread(Pid,_) -> sleep(0.005),assert_gone(Pid) ; true).
new_relay(Base,Relay) :- namespace_tests:new_scope(Base,Relay).
close_relay(Base,Relay) :- web_prolog:retire_websocket_namespace(Base),namespace_tests:stop_scope(Relay).
expect_error(Goal,Pattern) :- catch(call(Goal),Error,true),nonvar(Error),Error=Pattern.
:- meta_predicate expect_error(0,+).

run :-
    authority_and_tokens,namespace_isolation,connection_cleanup,
    preparation_race(unnamed),preparation_race(named),
    forall(between(1,20,_),creation_race),
    writeln('Receiver delegated lineage: all regressions passed').

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

creation_race :-
    new_relay(Base,Relay),self(Parent),make_ref(Ref),wire(a,JSON),peer(P),
    % Open before racing so the connection snapshot contains the lineage.
    in_lineage(Relay,a,true),token(a,A),NS=ws_lineage(Relay,A),
    spawn_runtime((catch(receiver_lineage:with_wire_context(JSON,Relay,P,spawn,
                      spawn_runtime(receiver_lineage_tests:wait,Child,[link(false),'$entry_context'(caller)])),E,true),
           Parent ! raced(Ref,Child,E)),Worker,[link(false),monitor(true),'$entry_context'(caller)]),
    receiver_lineage:close_namespace(NS),
    receive({raced(Ref,Result,Error) -> true},[timeout(2),on_timeout(fail)]),
    (var(Error) -> assert_gone(Result) ; Error=error(permission_error(register,closed_namespace,NS),_)),
    receive({down(Worker,Worker,true) -> true},[timeout(2),on_timeout(fail)]),
    \+ actors:actor_namespace(_,NS),close_relay(Base,Relay).

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
