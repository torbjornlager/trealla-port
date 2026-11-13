% SPDX-License-Identifier: MIT
:- module(relay_shared_db_tests,[run/0]).
:- use_module(actors).
:- use_module(isolation,[]).

run :-
    isolation:bootstrap_text('$bootstrap_probe',Bootstrap),is_list(Bootstrap),
    catch(spawn(true,_,['$shared_db'(false)]),PublicError,true),
    PublicError=error(permission_error(option,internal_spawn_option,'$shared_db'(false)),_),
    actors:validate_spawn_options(['$shared_db'(false)],runtime),
    actors:validate_spawn_options(['$shared_db'(true)],runtime),
    setup_call_cleanup(
      (make_ref(FileRef),format(atom(File),'/tmp/trealla-relay-shared-~w.pl',[FileRef]),
       open(File,write,Stream),format(Stream,'relay_marker(shared).~n',[]),close(Stream),
       isolation:configure_shared_db([File])),
      checks,
      (isolation:clear_shared_db,delete_file(File))),
    writeln('Trusted relay uses a minimal private module; public actors retain shared/private databases: passed').
checks :-
    actors:spawn_scoped(actors:receive({stop->true}),Minimal,
        [link(false),'$shared_db'(false)],none,internal),
    isolation:actor_module(Minimal,Module),atom(Module),
    \+isolation:actor_source_module(Minimal,_),
    actors:send(Minimal,stop),wait_gone(Minimal,100),
    actors:spawn_scoped(actors:receive({stop->true}),Sourced,
        [link(false),'$shared_db'(false),'$entry_context'(caller),src_list([p(local)])],none,internal),
    isolation:actor_source_module(Sourced,_),
    actors:send(Sourced,stop),wait_gone(Sourced,100),
    self(Main),
    spawn((relay_marker(X),actors:send(Main,shared(X))),Normal,[link(false)]),
    receive({shared(shared)->true},[timeout(2),on_timeout(throw(shared_database_lost))]),
    wait_gone(Normal,100),isolation:shared_db_text(_).
wait_gone(Pid,N) :-
    (actors:actor_thread(Pid,_) -> N>0,sleep(0.01),Next is N-1,wait_gone(Pid,Next);true).
