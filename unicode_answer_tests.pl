% SPDX-License-Identifier: MIT
% Identical public-interface assertions for native SWI and Trealla clients.
:- module(unicode_answer_tests,[live/1,live_success/1,legacy_diagnostic/3]).
:- if(current_prolog_flag(dialect,swi)).
:- use_module('../trinity-demonstrator/prolog/web_prolog/node.pl').
:- use_module('../trinity-demonstrator/prolog/web_prolog/actor_api.pl').
:- use_module('../trinity-demonstrator/prolog/web_prolog/toplevel_actors.pl').
:- else.
:- use_module(actor_api).
:- use_module(actors).
:- use_module(distribution).
:- endif.

live(URL) :-
    toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true)]),
    setup_call_cleanup(true,checks(P),stop(P)),
    format('Unicode answers, errors, paging and sharing on ~w: passed~n',[URL]).

% SWI's current transparent connection to Trealla does not opt into canonical
% asynchronous answers. Keep its error/literal fidelity observations separate.
live_success(URL) :-
    toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true)]),
    setup_call_cleanup(true,
      (check(async_success,async_success(P)),check(paging,paging(P))),stop(P)),
    format('Unicode success answers, paging and sharing on ~w: passed~n',[URL]).

checks(P) :-
    check(async_success,async_success(P)),
    check(async_error,async_error(P)),
    check(paging,paging(P)),
    check(sync_error,sync_error(P)).

:- meta_predicate check(+,0).
check(Stage,Goal) :-
    (call(Goal) -> true ; throw(error(unicode_answer_check_failed(Stage),live/1))).

async_success(P) :-
    toplevel_call(P,T=row('é','€','漢字','😀',nested(X,X,Y)),
                  [template(T)]),
    receive({success(P,[Row],false) -> true},[timeout(5),on_timeout(fail)]),
    check(async_value(Row),
      (Row=row('é','€','漢字','😀',nested(A,B,C)),
       var(A),A==B,var(C),A\==C,var(T),var(X),var(Y))).

async_error(P) :-
    toplevel_call(P,throw(error(unicode('€',V,V),context('漢字','😀')))),
    receive({error(P,Error) -> true},[timeout(5),on_timeout(fail)]),
    check(async_error_value(Error),
      (Error=error(unicode('€',D,E),context('漢字','😀')),var(D),D==E,var(V))).

paging(P) :-
    toplevel_call_synch(P,member(U,['€','漢字','😀']),First,
                       [template(U),limit(2),timeout(5)]),
    First==success(P,['€','漢字'],true),var(U),
    toplevel_next_synch(P,Last,[limit(2),timeout(5)]),
    Last==success(P,['😀'],false).

sync_error(P) :-
    toplevel_call_synch(P,throw(error(unicode('😀',W,W),context('€','漢字'))),Thrown,
                       [timeout(5)]),
    Thrown=error(P,error(unicode('😀',F,G),context('€','漢字'))),
    var(F),F==G,var(W).

stop(P) :-
    exit(P,kill),
    receive({down(P,_,_) -> true},[timeout(5),on_timeout(fail)]).

% Separate diagnostic: not a Unicode requirement or a waived assertion.
legacy_diagnostic(URL,Row,Error) :-
    toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true)]),
    setup_call_cleanup(true,
      (toplevel_call(P,T=row(X,X,_Y,'$VAR'(1)),[template(T)]),
       receive({success(P,[Row],false) -> true},[timeout(5),on_timeout(fail)]),
       toplevel_call(P,throw(error(unicode('€'),context('漢字','😀')))),
       receive({error(P,Error) -> true},[timeout(5),on_timeout(fail)])),
      stop(P)).
