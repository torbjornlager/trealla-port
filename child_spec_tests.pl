% SPDX-License-Identifier: MIT
:- module(child_spec_tests,[child_spec_tests/0]).
:- use_module(actors).
:- use_module(supervisor_actor).

:- meta_predicate expect_child_error(0,?,+).
expect_child_error(Goal,Formal,PI) :-
    catch(call(Goal),Error,true),nonvar(Error),
    Error=error(Formal,context(PI,'invalid child specification')).

child_spec_tests :-
    child_invalid_specs,
    child_nested_and_early_rejection,
    child_defaults_and_sharing,
    child_dynamic_validation,
    writeln('Supervisor child specification validation: all regressions passed').

child_invalid_specs :-
    expect_child_error(supervisor_spawn(_,_),instantiation_error,supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true)])|bad],_),type_error(list,_),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([wrong],_),type_error(supervisor_child_spec,wrong),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(_,[start(true)])],_),instantiation_error,supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[])],_),missing_start_option(a),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true)|bad])],_),type_error(list,_),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),_])],_),instantiation_error,supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),unknown(1)])],_),domain_error(supervisor_child_option,unknown(1)),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),restart(temporary),restart(bad)])],_),domain_error(supervisor_child_restart,bad),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),type(bad)])],_),domain_error(supervisor_child_type,bad),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),shutdown(-1)])],_),domain_error(supervisor_child_shutdown,-1),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(42)])],_),type_error(callable,42),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(42:true)])],_),type_error(atom,42),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true)]),child(a,[start(true)])],_),permission_error(duplicate,supervisor_child_id,a),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(42,[start(server(foo,[]))])],_),type_error(atom,42),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(server(foo,[unknown(1)]))])],_),domain_error(spawn_option,unknown(1)),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(true),start(42)])],_),type_error(callable,42),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(a,[start(server(foo,[initial_state(_),_]))])],_),instantiation_error,supervisor_actor:supervisor_spawn/3),
    Cyclic=[child(a,[start(true)])|Cyclic],
    expect_child_error(supervisor_spawn(Cyclic,_),representation_error(cyclic_term),supervisor_actor:supervisor_spawn/3),
    writeln('malformed specifications, IDs, options and duplicate occurrences: ok').

child_nested_and_early_rejection :-
    actors(Before),
    expect_child_error(supervisor_spawn([
        child(waiter,[start(receive({stop -> true}))]),child(bad,[])],Pid,
        [src_uri('http://invalid/source')]),missing_start_option(bad),supervisor_actor:supervisor_spawn/3),var(Pid),
    expect_child_error(supervisor_spawn([child(outer,[start(start_sub_supervisor([child(inner,[])],[]))])],_),missing_start_option(inner),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(outer,[start(supervisor_actor:start_sub_supervisor([],[period(0)]))])],_),domain_error(supervisor_period,0),supervisor_actor:supervisor_spawn/3),
    expect_child_error(supervisor_spawn([child(outer,[start(start_sub_supervisor([child(x,[start(true)]),child(x,[start(true)])],[]))])],_),permission_error(duplicate,supervisor_child_id,x),supervisor_actor:supervisor_spawn/3),
    actors(After),sort(Before,Sorted),sort(After,Sorted),
    writeln('recursive validation precedes source loading and all child startup: ok').

child_defaults_and_sharing :-
    once(supervisor_actor:normalise_child_specs(user,[
        child(a,[start(foo(X))]),
        child(b,[start(server(callback(X),[initial_state(state(X))]))]),
        child(c,[start(true),type(supervisor)]),
        child(d,[start(true),restart(temporary),restart(permanent),shutdown(0),shutdown(infinity)])
    ],Specs)),
    Specs=[spec(a,user:foo(A),permanent,5,worker),
           spec(b,server(user:callback(B),[initial_state(state(C))]),permanent,5,worker),
           spec(c,user:true,permanent,infinity,supervisor),
           spec(d,user:true,temporary,0,worker)],
    var(X),X==A,X==B,X==C,
    once(supervisor_actor:normalise_child_specs(user,[
        child(e,[start(server(callback(Y),[initial_state(Y)])),shutdown(0.25)]),
        child(f,[start(true),shutdown(brutal_kill)])],Extra)),
    Extra=[spec(e,server(user:callback(D),[initial_state(E)]),permanent,0.25,worker),
           spec(f,user:true,permanent,brutal_kill,worker)],
    var(Y),Y==D,Y==E,
    writeln('defaults, first-option precedence and shared goal/state variables: ok').

child_wait :- receive({stop -> true}).

child_dynamic_validation :-
    supervisor_spawn([],Sup,[monitor(true),link(false)]),
    expect_child_error(supervisor_spawn_child(Sup,child(bad,[]),_),missing_start_option(bad),supervisor_actor:supervisor_spawn_child/3),
    supervisor_count_children(Sup,Counts),memberchk(specs-0,Counts),memberchk(active-0,Counts),
    supervisor_spawn_child(Sup,child(waiter,[start(child_wait),restart(temporary),restart(permanent)]),Added),Added==ok,
    supervisor_spawn_child(Sup,child(waiter,[start(true)]),Duplicate),Duplicate==error(already_present),
    supervisor_count_children(Sup,After),memberchk(specs-1,After),memberchk(active-1,After),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)]),
    writeln('dynamic rejection preserves state and valid duplicate reply: ok').
