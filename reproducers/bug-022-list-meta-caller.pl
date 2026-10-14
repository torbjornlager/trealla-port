% SPDX-License-Identifier: MIT

:- module(bug_022_list_meta_caller, [reproducer/0]).

:- use_module('bug-022-list-meta-library.pl').

reproducer :-
    term_context(local_callback, CallableModule),
    term_context([call(local_callback)], ListModule),
    writeq(contexts(CallableModule, ListModule)),
    nl.
