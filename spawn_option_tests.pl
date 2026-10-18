% SPDX-License-Identifier: MIT
:- use_module(actors).
:- use_module(distribution).
:- use_module(toplevel_actors).

:- meta_predicate expect_spawn_error(0,?,+).
expect_spawn_error(Goal,Formal,PI) :-
    catch(call(Goal),Error,true),nonvar(Error),
    Error=error(Formal,context(PI,'invalid spawn option')).

spawn_option_tests :-
    spawn_invalid_options,
    spawn_supported_vectors,
    spawn_rejection_before_side_effects,
    spawn_source_and_pid_sharing,
    spawn_runtime_metadata,
    spawn_wrapper_options,
    writeln('Spawn option validation: all regressions passed').
spawn_invalid_options :-
    expect_spawn_error(spawn(true,_,[unknown(1)]),domain_error(spawn_option,unknown(1)),actors:spawn/3),
    expect_spawn_error(spawn(true,_,[name(example)]),domain_error(spawn_option,name(example)),actors:spawn/3),
    expect_spawn_error(spawn(true,_,[link(true),link(maybe)]),type_error(boolean,maybe),actors:spawn/3),
    expect_spawn_error(spawn(true,_,[monitor(1)]),type_error(boolean,1),actors:spawn/3),
    expect_spawn_error(spawn(true,_,[node(42)]),type_error(atom_or_string,42),actors:spawn/3),
    expect_spawn_error(spawn(true,_,[target(_)]),instantiation_error,actors:spawn/3),
    expect_spawn_error(spawn(true,_,[io_target(_)]),instantiation_error,actors:spawn/3),
    expect_spawn_error(spawn(true,_,[link(true)|bad]),type_error(list,_),actors:spawn/3),
    expect_spawn_error(spawn(true,_,Options),instantiation_error,actors:spawn/3),var(Options),
    expect_spawn_error(spawn(true,_,[Option]),instantiation_error,actors:spawn/3),var(Option),
    expect_spawn_error(spawn(true,_,[src_predicates([p/bad])]),type_error(predicate_indicator,p/bad),actors:spawn/3),
    expect_spawn_error(spawn(true,_,['$entry_context'(caller)]),
        permission_error(option,internal_spawn_option,'$entry_context'(caller)),actors:spawn/3),
    writeln('unknown, malformed, duplicate and internal options rejected: ok').
spawn_rejection_before_side_effects :-
    actors(Before),
    expect_spawn_error(spawn(receive({never -> true}),Pid,
        [src_uri('http://invalid/source'),unknown(1)]),domain_error(spawn_option,unknown(1)),actors:spawn/3),var(Pid),
    % Validation must precede the transparent connection hook.
    expect_spawn_error(spawn(true,Remote,[node('http://127.0.0.1:1'),monitor(bad)]),
        type_error(boolean,bad),actors:spawn/3),var(Remote),
    expect_spawn_error(remote_spawn(not_a_connection,true,Explicit,[unknown(1)]),
        domain_error(spawn_option,unknown(1)),distribution:remote_spawn/4),var(Explicit),
    actors(After),sort(Before,S),sort(After,S),
    writeln('local and remote rejection precede source, routing and allocation: ok').
spawn_source_and_pid_sharing :-
    self(Parent),
    spawn((test_spawn_value(V),Parent ! value(V)),Pid,
        [link(false),monitor(true),src_list([test_spawn_value(ok)])]),
    receive({value(ok) -> true}),receive({down(Pid,Pid,true) -> true}),
    spawn(Parent ! seen(SharedPid),SharedPid,[monitor(true),link(false)]),
    receive({seen(Seen) -> Seen==SharedPid}),receive({down(SharedPid,SharedPid,true) -> true}),
    % First scalar occurrence still determines the installed monitor.
    spawn(receive({stop -> true}),NoMonitor,[link(false),monitor(false),monitor(true)]),
    once(\+ actors:monitor(Parent,NoMonitor,NoMonitor)),
    monitor(NoMonitor,Ref),NoMonitor ! stop,receive({down(NoMonitor,Ref,true) -> true}),
    writeln('private source, PID sharing, spawn monitors and precedence: ok').
spawn_runtime_metadata :-
    self(Parent),
    spawn_runtime(Parent ! runtime_ok,Pid,
        ['$entry_context'(caller),link(false),monitor(true)]),
    receive({runtime_ok -> true}),receive({down(Pid,Pid,true) -> true}),
    expect_spawn_error(spawn_runtime(true,_,['$entry_context'(other)]),
        domain_error(entry_context,other),actors:spawn/3),
    writeln('framework entry context survives internal validation: ok').
spawn_wrapper_options :-
    toplevel_spawn(P,[session(true),time_limit(infinite),idle_limit(infinite)]),
    toplevel_call(P,true,[]),receive({success(P,_,false) -> true}),
    toplevel_halt(P,_),
    writeln('toplevel separates consumed wrapper options: ok').

spawn_options_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    remote_node_open(URL,Node),
    setup_call_cleanup(true,user:spawn_options_live_session(Node,URL),remote_node_close(Node)),
    format('Live explicit and transparent validated spawning on ~w: ok~n',[Port]).
spawn_options_live_session(Node,URL) :-
    remote_spawn(Node,receive({finish -> true}),P,[monitor(true),link(false)]),
    remote_send(Node,P,finish),receive({down(P,_,true) -> true},[timeout(3),on_timeout(fail)]),
    self(Parent),
    spawn((self(Me),Parent ! shared_pid(Me)),Pid,[node(URL),link(false),monitor(true)]),
    receive({shared_pid(Seen) -> user:matching_remote_self(Seen,Pid)},[timeout(3),on_timeout(fail)]),
    receive({down(Pid,Pid,true) -> true},[timeout(3),on_timeout(fail)]),
    expect_spawn_error(remote_spawn(Node,true,Unbound,[link(true),link(bad)]),
        type_error(boolean,bad),distribution:remote_spawn/4),var(Unbound).

% Existing peers report self either as the wire id or its canonical address.
matching_remote_self(Seen,Pid) :-
    Pid=Wire@_,(Seen==Pid -> true ; Seen==Wire).

spawn_supported_vectors :-
    actors:validate_spawn_options([node("http://localhost:3061"),link(true),monitor(false),
        target(parent),io_target('$browser_io'(parent)),src_text([112,46]),
        src_list([p(X)]),src_predicates([p/0]),src_uri('http://localhost/source')],public),
    var(X),
    writeln('supported address/source formats and source variable sharing: ok').
