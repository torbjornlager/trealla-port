% SPDX-License-Identifier: MIT
:- module(http_session_context_tests,[run/0]).
:- use_module(web_prolog).
:- use_module(http_sessions, []).
:- use_module(actors, []).
:- use_module(rpc_namespace_tests, []).

access(session_access(context_test,principal(context_test,[execute]),context_test)).
new_session(Pid) :-
    access(Access),
    http_sessions:session_request(19999,Access,actor,blacklist,toplevel_spawn,
        pairs([]),200,spawned(Pid)).
command(Pid,Command,Fields,Event) :-
    access(Access),atom_number(Text,Pid),
    http_sessions:session_request(19999,Access,actor,blacklist,Command,
        [pid=Text|Fields],200,Event).
query(Pid,Goal) :-
    command(Pid,toplevel_call,[goal=Goal,limit='1'],success(Pid,_,false)).
halt_session(Pid) :- command(Pid,toplevel_halt,[],_).

run :-
    setup_call_cleanup(new_session(A),
      setup_call_cleanup(new_session(B),once(check_sessions(A,B)),halt_session(B)),
      catch(ignore(halt_session(A)),_,true)),
    writeln('HTTP sessions: separate names/promises, owner collection and teardown: ok').

check_sessions(A,B) :-
    actors:actor_namespace(A,NA),NA=isotope_session(_),
    actors:actor_namespace(B,NB),NB=isotope_session(_),NA\==NB,
    query(A,'self(S),register(http_context_test,S)'),
    query(B,'whereis(http_context_test,undefined),self(S),register(http_context_test,S)'),
    query(A,'self(S),whereis(http_context_test,S)'),
    query(B,'self(S),whereis(http_context_test,S)'),
    actors:self(Self),
    actors:with_actor_namespace(NA,
        rpc_namespace_tests:create_test_promise(Self)),
    actors:receive({test_promise(_,Ref,Resources)->true},[timeout(2),on_timeout(fail)]),
    actors:with_actor_namespace(NB,
        (rpc_namespace_tests:expect_missing(Ref),rpc:promise_cleanup(Ref))),
    actors:with_actor_namespace(NA,
        (rpc:yield(Ref,timeout,[timeout(0)]))),
    % Definitive HTTP session retirement must release its promises and names.
    halt_session(A),
    rpc_namespace_tests:await(rpc_namespace_tests:assert_disposed(Ref,Resources),200),
    \+actors:registered(NA,http_context_test,_),
    query(B,'self(S),whereis(http_context_test,S)'),
    catch(actors:with_actor_namespace(NA,actors:register(late_http_context,123)),E,true),
    nonvar(E),E=error(permission_error(register,closed_namespace,NA),_),
    catch(actors:with_actor_namespace(NA,
        (actors:make_ref(NewRef),rpc:start_promise_setup(NewRef,true))),CreateError,true),
    nonvar(CreateError),
    CreateError=error(permission_error(create,promise,client_namespace(NA)),_).
