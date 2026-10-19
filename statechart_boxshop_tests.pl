% SPDX-License-Identifier: MIT
:- module(statechart_boxshop_tests,[run/0]).
:- use_module(actors).
:- use_module(statechart_actor).
:- use_module(statechart_actor_tests,[]).
run :- empty_declarations,boxshop,
 writeln('Empty dynamic predicates and unchanged boxshop-2: all passed').
empty_declarations :-
 self(Self),
 spawn((\+ welcome,\+ color(_),findall(X,kept(X),[existing]),
        assertz(welcome),welcome,retractall(welcome),\+welcome,
        assertz(color(red)),color(red),retractall(color(_)),\+color(_),
        Self ! empty_dynamic_ok),P,
       [src_list([(:- dynamic((welcome/0,color/1))),kept(existing),(:- dynamic(kept/1))]),monitor(true),link(false)]),
 receive({empty_dynamic_ok -> true;down(P,P,Reason) -> throw(empty_dynamic_failed(Reason))},[timeout(2),on_timeout(fail)]),
 statechart_actor_tests:down(P),
 writeln('empty zero/unary declarations, later assertions and existing clauses: ok').
boxshop :-
 setup_call_cleanup(open('fixtures/statecharts/12-boxshop-2.xml',read,S),statechart_actor_tests:read_all(S,[],Codes),close(S)),atom_codes(Text,Codes),
 self(Self),statechart_spawn(P,[src_text(Text),trace(true),io_target(Self),monitor(true),link(false)]),
 statechart_actor_tests:config(P,[form,'Color']),
 send(P,says(unrecognized)),statechart_actor_tests:config(P,[form,'Color']),
 receive({terminal_io_output(P,'I did not hear you.') -> true},[timeout(9),on_timeout(fail)]),
 statechart_actor_tests:config(P,[form,'Color']),
 send(P,says(color(red))),statechart_actor_tests:config(P,[form,'Size']),
 send(P,says(size(small))),statechart_actor_tests:config(P,['Respond']),
 receive({terminal_io_output(P,'You want a small red box!\n') -> true},[timeout(2),on_timeout(fail)]),
 statechart_actor_tests:down(P),
 writeln('boxshop fallback, eight-second timeout, slot collection and final order: ok').
