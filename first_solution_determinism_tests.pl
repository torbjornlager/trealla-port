% SPDX-License-Identifier: MIT
:- module(first_solution_determinism_tests,[run/0]).
:- use_module(actors).
:- use_module(parallel).

run :-
    option_validation,
    selection_probe,
    forall(member(Kind,[failure,exception,exit]),continued_solver(Kind)),
    writeln('first_solution continuation determinism: all regressions passed').

% Every option occurrence is validated before any value is used: a later
% duplicate is checked, and pending options or values are never bound.
option_validation :-
    option_error([on_fail(stop),on_fail(maybe)],domain_error(first_solution_policy,maybe)),
    option_error([on_error(1)],type_error(atom,1)),
    option_error([timeout(1)],domain_error(first_solution_option,timeout(1))),
    option_error([on_error(Pending)],instantiation_error),var(Pending),
    option_error([Entry],instantiation_error),var(Entry),
    first_solution(X,[member(X,[a,b])],[on_fail(stop),on_error(continue)]),X==a,
    writeln('first_solution option validation: every occurrence, no bindings: ok').

option_error(Options,Formal) :-
    catch((first_solution(_,[true],Options),Result=accepted),error(Formal0,_),Result=Formal0),
    ( subsumes_term(Formal,Result) -> true ; throw(first_solution_option_error(Options,Result)) ).

% select/3 offers a search for another occurrence even though worker pids are
% unique. Record determinism before cutting, so the probe cannot hide it.
selection_probe :-
    call_cleanup(select(first,[first,second],Rest),Finished=true),
    (var(Finished)->State=choicepoint;State=deterministic),!,
    Rest==[second],State==choicepoint,
    writeln('select/3 leaves a choice point when removing a unique head pid: confirmed').

continued_solver(Kind) :-
    self(Self),send(Self,down(unrelated,probe,normal)),
    spawn_runtime(first_solution_determinism_tests:gate,Gate,
      [link(false),monitor(true),'$entry_context'(caller)]),
    setup_call_cleanup(true,
      probe(Gate,Kind),exit(Gate,kill)),
    receive({down(Gate,Gate,_) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(unrelated,probe,normal) -> true},[timeout(0),on_timeout(fail)]),
    format('~w continue returns deterministically and preserves unrelated notifications: ok~n',[Kind]).

probe(Gate,Kind) :-
    call_cleanup(
      first_solution(X,
        [first_solution_determinism_tests:broken(Gate,Kind),
         first_solution_determinism_tests:solved(Gate,X)],
        [on_fail(continue),on_error(continue)]),
      Finished=true),
    (var(Finished)->State=choicepoint;State=deterministic),!,
    X==ok,
    (State==deterministic -> true;throw(leftover_choicepoint(Kind))).

% Install the gate's monitor before permitting the first worker to terminate.
% Its normal spawn monitor is already installed, so the caller receives the
% failure/exit before the gate releases the successful solver. No timing sleeps.
gate :-
    receive({broken(Pid) -> true}),monitor(Pid,Ref),send(Pid,release),
    receive({down(Pid,Ref,_) -> true}),demonitor(Ref,[flush]),
    receive({waiting(Winner) -> true}),send(Winner,go).
broken(Gate,Kind) :-
    self(Self),send(Gate,broken(Self)),receive({release -> fault(Kind)}).
fault(failure) :- fail.
fault(exception) :- throw(test_solver_error).
fault(exit) :- exit(killed).
solved(Gate,ok) :-
    self(Self),send(Gate,waiting(Self)),receive({go -> true}).
