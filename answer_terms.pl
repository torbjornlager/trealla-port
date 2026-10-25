% SPDX-License-Identifier: MIT
:- module(answer_terms,[check_answer_term/1,finite_query_error/2]).

% A check after nb_setval or a thread handoff is too late: these operations
% can copy a rational tree as an acyclic approximation on Trealla v3.14.10.
check_answer_term(Term) :-
    ( acyclic_term(Term) -> true
    ; cyclic_term_error(Error),throw(Error)
    ).

% Defensive envelope for any still-cyclic exception reaching our handler.
% v3.14.10 catch/3 itself can lose a cycle; this cannot recover that information.
finite_query_error(Error0, Error) :-
    ( acyclic_term(Error0) -> Error=Error0 ; cyclic_term_error(Error) ).

cyclic_term_error(error(representation_error(cyclic_term),answer_terms)).
