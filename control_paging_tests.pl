% SPDX-License-Identifier: MIT
:- module(control_paging_tests,[run/0]).
:- use_module(actors).
:- use_module(toplevel_actors).

run :-
    self(Self),
    toplevel_spawn(P,[session(true),target(Self),src_text('local_truth.')]),
    setup_call_cleanup(true,control_paging_tests:checks(P),toplevel_halt(P,true)),
    writeln('Conditional paging: commitment, determinism, alternatives and cut scope passed').

checks(P) :-
    final(P,(true->true;fail),ok),
    final(P,(fail->fail;true),ok),
    final(P,(F=foo,(F==foo->true;F==bar)),ok),
    final(P,(F=foo,(F==bar->fail;F==foo)),ok),
    toplevel_call(P,(true->fail;true),[limit(1)]),
    receive({failure(P)->true},[timeout(2),on_timeout(fail)]),
    toplevel_call(P,(member(X,[a,b]),(true->!;fail)),[template(X),limit(1)]),
    receive({success(P,[a],false)->true},[timeout(2),on_timeout(fail)]),
    toplevel_call(P,(member(X,[a,b])->member(Y,[1,2]);fail),[template(X-Y),limit(1)]),
    receive({success(P,[a-1],true)->true},[timeout(2),on_timeout(fail)]),
    toplevel_next(P),
    receive({success(P,[a-2],false)->true},[timeout(2),on_timeout(fail)]).

final(P,G,T) :-
    toplevel_call(P,G,[template(T),limit(1)]),
    receive({success(P,[T],false)->true},[timeout(2),on_timeout(fail)]).
