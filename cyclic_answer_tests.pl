% SPDX-License-Identifier: MIT
:- module(cyclic_answer_tests,[run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(node,[]).
:- use_module(answer_terms,[]).

run :-
    guard,sharing,local_cycle,later_page,http_cleanup,
    receive({_ -> fail},[timeout(0)]),
    writeln('Cyclic answer rejection: all regressions passed').

cycle_error(Error) :-
    nonvar(Error),acyclic_term(Error),
    Error=error(representation_error(cyclic_term),_).
guard :-
    X=f(X),catch(answer_terms:check_answer_term(X),E,true),cycle_error(E),
    answer_terms:finite_query_error(error(probe(X),ctx),F),cycle_error(F),
    answer_terms:finite_query_error(error(probe(A),context(test,A)),Ordinary),
    Ordinary=error(probe(B),context(test,C)),var(B),B==C,
    writeln('pre-copy guard and finite exception envelope: ok').
with_top(Goal) :-
    toplevel_spawn(P,[session(true),link(false)]),
    setup_call_cleanup(true,call(Goal,P),toplevel_halt(P,true)).
sharing :- with_top(cyclic_answer_tests:shared).
shared(P) :-
    toplevel_call_synch(P,X=pair(Y,Y),Answer,[template(X-Y),timeout(2)]),
    Answer=success(P,[pair(A,B)-C],false),var(A),A==B,B==C,var(X),var(Y).
local_cycle :- with_top(cyclic_answer_tests:local).
local(P) :-
    toplevel_call_synch(P,(X=f(X),\+acyclic_term(X)),A,[template(ok),timeout(2)]),
    A==success(P,[ok],false),
    toplevel_call_synch(P,X=f(X),Error,[template(X),timeout(2)]),
    Error=error(P,E),cycle_error(E),
    toplevel_call_synch(P,throw(ordinary_error),Ordinary,[timeout(2)]),
    Ordinary==error(P,ordinary_error),
    toplevel_call_synch(P,true,Healthy,[timeout(2)]),Healthy==success(P,[true],false).
later_page :- with_top(cyclic_answer_tests:page).
page(P) :-
    toplevel_call_synch(P,(X=ok;X=f(X)),First,[template(X),limit(1),timeout(2)]),
    First==success(P,[ok],true),
    toplevel_next_synch(P,Next,[timeout(2)]),Next=error(P,E),cycle_error(E),
    toplevel_call_synch(P,true,Healthy,[timeout(2)]),Healthy==success(P,[true],false).
http_cleanup :-
    catch(node:compute_answer(X=f(X),X,0,1,true,_),E,true),cycle_error(E),
    catch(node:compute_answer((Y=ok;Y=f(Y)),Y,0,2,true,_),F,true),cycle_error(F),
    \+node:http_page_claim(_,_),\+node:cache(_,_,_,_),
    node:compute_answer(Z=pair(V,V),Z-V,0,1,true,success([pair(A,B)-C],false)),
    var(A),A==B,B==C,
    node:compute_answer((R=f(R),\+acyclic_term(R)),ok,0,1,true,success([ok],false)),
    writeln('HTTP pre-handoff rejection, cleanup and finite controls: ok').
