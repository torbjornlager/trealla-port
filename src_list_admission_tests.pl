% SPDX-License-Identifier: MIT
:- module(src_list_admission_tests,[run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(sandbox_policy).

check(Goal) :-
    ( call(Goal) -> true ; throw(error(src_list_admission_check_failed(Goal),run/0)) ).

run :-
    forall(member(Mode,[blacklist,whitelist]),
      ( nonbinding(Mode), unresolved_at_runtime(Mode), malformed_at_runtime(Mode),
        forbidden_source(Mode), forbidden_runtime_goal(Mode),
        forbidden_static_goal(Mode), unknown_whitelist_goal(Mode),
        computed_source(Mode), partial_source(Mode), constructed_clause(Mode),
        literal_source(Mode) )),
    opaque_whitelist_options,
    lower_profile,
    write('Constructed src_list admission: all regressions passed'),nl.

nonbinding(Mode) :-
    Goal=(Clauses=[p(X,X)],spawn(p(Y,Y),Pid,[src_list(Clauses)])),
    term_variables(Goal,Before),
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,Goal,Guarded),
    term_variables(Goal,After),
    check(Before==After),check(var(Clauses)),check(var(X)),check(var(Y)),check(var(Pid)),
    check(nonvar(Guarded)),
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(true,_,[src_list([Clause])]),_),check(var(Clause)).

expect_error(Goal, Pattern) :-
    catch(call(Goal),Error,true),check(nonvar(Error)),check(Error=Pattern).

unresolved_at_runtime(Mode) :-
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(true,Pid,[src_list(Clauses)]),Guarded),
    expect_error(call(Guarded),error(instantiation_error,_)),
    check(var(Clauses)),check(var(Pid)).

malformed_at_runtime(Mode) :-
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(true,Pid,[src_list(Clauses)]),Guarded),
    Clauses=[p(ok)|bad],
    expect_error(call(Guarded),error(type_error(list,_),_)),check(var(Pid)).

forbidden_source(Mode) :-
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(loaded,Pid,[src_list(Clauses)]),Guarded),
    Clauses=[(loaded :- open('/must-not-be-opened',read,_))],
    expect_error(call(Guarded),error(permission_error(call,sandboxed,_),_)),check(var(Pid)).

forbidden_runtime_goal(Mode) :-
    sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(Goal,Pid,[src_list(Clauses)]),Guarded),
    Clauses=[loaded],Goal=open('/must-not-be-opened',read,_),
    expect_error(call(Guarded),error(permission_error(call,sandboxed,_),_)),check(var(Pid)).

forbidden_static_goal(Mode) :-
    expect_error(sandbox_prepare_goal(Mode,actor,src_list_admission_tests,
        spawn(open('/must-not-be-opened',read,_),Pid,[src_list(Clauses)]),_),
        error(permission_error(call,sandboxed,_),_)),
    check(var(Clauses)),check(var(Pid)).

unknown_whitelist_goal(blacklist).
unknown_whitelist_goal(whitelist) :-
    sandbox_prepare_goal(whitelist,actor,src_list_admission_tests,
        spawn(not_in_actual_source,Pid,[src_list(Clauses)]),Guarded),
    Clauses=[loaded],
    expect_error(call(Guarded),error(permission_error(call,sandboxed,_),context(_,not_whitelisted))),
    check(var(Pid)).

% Execute in the same source-bearing private actor context used by the public
% endpoint. Exact normal termination makes false assertions visible as failure.
execute(Mode,Raw) :-
    sandbox_prepare_spawn(Mode,actor,actor_context,Raw,[monitor(true)],Goal,Options),
    setup_call_cleanup(spawn(Goal,Session,Options),
       ( receive({down(Session,Session,Reason)->true},
                  [timeout(5),on_timeout(throw(missing_source_test_session))]),
         check(Reason==true) ),
       (catch(exit(Session,kill),_,true),catch(demonitor(Session,[flush]),_,true))).

computed_source(Mode) :-
    execute(Mode,
      (A is 96+1,B is 97+1,
       Clauses=[data([A,B],[a,b],pair(S,S))],self(Parent),
       spawn((data(C,T,Pair),C==[97,98],T==[a,b],Pair=pair(X,Y),
              var(X),X==Y,Parent!source_data_ok),P,
             [src_list(Clauses),monitor(true)]),
       var(S),
       receive({source_data_ok->true},[timeout(2),on_timeout(throw(missing_source_data))]),
       receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(missing_source_child))]))).

partial_source(Mode) :-
    execute(Mode,
      (Tail=[],self(Parent),
       spawn((loaded,Parent!partial_ok),P,[src_list([loaded|Tail]),monitor(true)]),
       receive({partial_ok->true},[timeout(2),on_timeout(throw(missing_partial_data))]),
       receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(missing_partial_child))]))).

constructed_clause(Mode) :-
    execute(Mode,
      (Clause=loaded,self(Parent),
       spawn((loaded,Parent!clause_ok),P,[src_list([Clause]),monitor(true)]),
       receive({clause_ok->true},[timeout(2),on_timeout(throw(missing_clause_data))]),
       receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(missing_clause_child))]))).

literal_source(Mode) :-
    execute(Mode,
      (spawn(true,P,[src_list([data([97,98],[a,b])]),monitor(true)]),
       receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(missing_literal_child))]))).

opaque_whitelist_options :-
    expect_error(sandbox_prepare_goal(whitelist,actor,src_list_admission_tests,
        spawn(true,_,Options),_),error(permission_error(option,sandboxed,_),_)),
    check(var(Options)).

lower_profile :-
    forall(member(Mode,[blacklist,whitelist]),
      (expect_error(sandbox_prepare_goal(Mode,isotope,src_list_admission_tests,
          spawn(true,Pid,[src_list(Clauses)]),_),error(profile_violation(isotope,_),_)),
       check(var(Clauses)),check(var(Pid)))).
