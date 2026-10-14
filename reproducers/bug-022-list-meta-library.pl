% SPDX-License-Identifier: MIT

:- module(bug_022_list_meta_library, [term_context/2]).

:- meta_predicate term_context(:, -).

term_context(Term, Module) :-
    strip_module(Term, Module, _).
