% SPDX-License-Identifier: MIT
:- module(receive_caller_tests, [run/0]).
:- use_module(actors).
:- use_module(isolation, []).
:- use_module(toplevel_actors, []).

run :-
    submitted('self(S),send(S,guard_probe),receive({guard_probe if runtime_property(persistent(true))->Result=accepted},[timeout(0),on_timeout(Result=lost)])', Result),
    require(Result==accepted,submitted_guard_api_lost),
    submitted('self(S),send(S,rpc(data,data)),receive({rpc(A,B)->runtime_property(persistent(true)),Result=pair(A,B)},[timeout(0),on_timeout(throw(body_lost))])', Pair),
    require(Pair==pair(data,data),pattern_or_body_changed),
    submitted('receive({},[timeout(0),on_timeout((runtime_property(persistent(true)),Result=expired))])', Expired),
    require(Expired==expired,timeout_api_lost),
    writeln('PASS submitted receive guards, bodies and timeout API dispatch; message patterns remain data').

submitted(Text, Result) :-
    read_term_from_atom(Text, Goal, [variable_names(Names)]),
    memberchk('Result'=Result,Names),
    isolation:execution_goal(Goal, Prepared),
    call(Prepared).

require(Goal, Error) :- (call(Goal)->true;throw(Error)).
