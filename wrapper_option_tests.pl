% SPDX-License-Identifier: MIT
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(server_actor).
:- use_module(supervisor_actor).
:- use_module(distribution).

:- meta_predicate expect_wrapper_error(0,?,+).
expect_wrapper_error(Goal,Formal,PI) :-
    catch(call(Goal),Error,true),nonvar(Error),
    Error=error(Formal,context(PI,'invalid wrapper option')).

wrapper_option_tests :-
    wrapper_invalid_values,
    wrapper_early_rejection,
    wrapper_success_and_precedence,
    writeln('Specialized wrapper option validation: all regressions passed').

wrapper_invalid_values :-
    expect_wrapper_error(toplevel_spawn(_,[session(true),session(maybe)]),
        type_error(boolean,maybe),toplevel_actors:toplevel_spawn/2),
    expect_wrapper_error(toplevel_spawn(_,[time_limit(0)]),
        domain_error(time_limit,0),toplevel_actors:toplevel_spawn/2),
    expect_wrapper_error(toplevel_spawn(_,[idle_limit(_)]),
        instantiation_error,toplevel_actors:toplevel_spawn/2),
    expect_wrapper_error(toplevel_spawn(_,[name(unsupported)]),
        domain_error(spawn_option,name(unsupported)),toplevel_actors:toplevel_spawn/2),
    expect_wrapper_error(server_spawn(no_such_callback,[],_,[name(42)]),
        type_error(atom,42),server_actor:server_spawn/4),
    expect_wrapper_error(server_spawn(no_such_callback,[],_,[unknown(1)]),
        domain_error(spawn_option,unknown(1)),server_actor:server_spawn/4),
    expect_wrapper_error(supervisor_spawn([],_,[strategy(one_for_one),strategy(random)]),
        domain_error(supervisor_strategy,random),supervisor_actor:supervisor_spawn/3),
    expect_wrapper_error(supervisor_spawn([],_,[intensity(-1)]),
        domain_error(not_less_than_zero,-1),supervisor_actor:supervisor_spawn/3),
    expect_wrapper_error(supervisor_spawn([],_,[period(0)]),
        domain_error(supervisor_period,0),supervisor_actor:supervisor_spawn/3),
    expect_wrapper_error(supervisor_spawn([],_,[period(1)|bad]),
        type_error(list,_),supervisor_actor:supervisor_spawn/3),
    expect_wrapper_error(supervisor_spawn([],_,Options),
        instantiation_error,supervisor_actor:supervisor_spawn/3),var(Options),
    expect_wrapper_error(toplevel_spawn(_,[Option]),
        instantiation_error,toplevel_actors:toplevel_spawn/2),var(Option),
    writeln('wrapper values, unknown options, malformed lists and duplicates: ok').

wrapper_early_rejection :-
    actors(Before),
    expect_wrapper_error(toplevel_spawn(P,[src_uri('http://invalid/source'),session(bad)]),
        type_error(boolean,bad),toplevel_actors:toplevel_spawn/2),var(P),
    expect_wrapper_error(server_spawn(no_such_callback,[],S,
        [src_uri('http://invalid/source'),name(42)]),type_error(atom,42),server_actor:server_spawn/4),var(S),
    expect_wrapper_error(supervisor_spawn([child(bad,[])],Sup,[period(0)]),
        domain_error(supervisor_period,0),supervisor_actor:supervisor_spawn/3),var(Sup),
    expect_wrapper_error(remote_toplevel_spawn(not_a_connection,R,
        [src_uri('http://invalid/source'),session(bad)]),type_error(boolean,bad),distribution:remote_toplevel_spawn/3),var(R),
    actors(After),sort(Before,Sorted),sort(After,Sorted),
    writeln('validation precedes callback/source/child work and actor creation: ok').

wrapper_echo(Request,State,Request,State).
wrapper_success_and_precedence :-
    % Scalar first-occurrence semantics and framework entry metadata survive.
    toplevel_spawn(P,[session(false),session(true),monitor(true),link(false),
        time_limit(infinite),time_limit(0.5),idle_limit(1),idle_limit(infinite)]),
    toplevel_call(P,true),receive({success(P,_,false) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),
    writeln('toplevel scalar precedence and monitor metadata: ok'),
    make_ref(Id),format(atom(Name),'wrapper_server_~w',[Id]),
    format(atom(Other),'wrapper_unused_~w',[Id]),
    server_spawn(wrapper_echo,[],S,[name(Name),name(Other),monitor(true),link(false)]),
    whereis(Name,S),whereis(Other,undefined),server_request(Name,hello,hello),
    server_halt(S,true),receive({down(S,S,true) -> true},[timeout(2),on_timeout(fail)]),
    writeln('named server precedence and monitor metadata: ok'),
    make_ref(SId),format(atom(SName),'wrapper_supervisor_~w',[SId]),
    supervisor_spawn([],Sup,[name(SName),strategy(one_for_one),strategy(one_for_all),
        intensity(0),intensity(2),period(0.25),period(1),monitor(true),link(false)]),
    whereis(SName,Sup),supervisor_count_children(Sup,Counts),
    memberchk(specs-0,Counts),memberchk(active-0,Counts),supervisor_halt(Sup),
    receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)]),
    writeln('named wrappers, supported values, precedence and monitor metadata: ok').

wrapper_options_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),remote_node_open(URL,Node),
    setup_call_cleanup(true,user:wrapper_live_session(Node),remote_node_close(Node)),
    format('Live validated toplevel wrapper on ~w: ok~n',[Port]).
wrapper_live_session(Node) :-
    expect_wrapper_error(remote_toplevel_spawn(Node,P,[session(maybe)]),
        type_error(boolean,maybe),distribution:remote_toplevel_spawn/3),var(P),
    remote_toplevel_spawn(Node,Top,[session(true),time_limit(infinite),idle_limit(infinite)]),
    remote_toplevel_call_synch(Node,Top,X=ok,A,[template(X),timeout(3)]),
    A==success(Top,[ok],false),
    remote_toplevel_call_synch(Node,Top,Y=again,B,[template(Y),timeout(3)]),
    B==success(Top,[again],false),remote_toplevel_halt(Node,Top).
