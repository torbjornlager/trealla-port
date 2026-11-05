% SPDX-License-Identifier: MIT
:- module(integer_relations,[succ/2]).
:- use_module(library(error)).

% All supplied arguments are integers, including when the other is a variable.
% Keep this relation shared by node calls and private actor modules so turning
% sandbox admission off cannot select different type or binding semantics.
succ(Before, After) :-
    successor_argument(Before),
    successor_argument(After),
    ( integer(Before) -> After is Before+1
    ; integer(After) -> After > 0, Before is After-1
    ; throw(error(instantiation_error, succ/2))
    ).

successor_argument(Value) :-
    ( var(Value) -> true
    ; must_be(integer, Value),
      (Value >= 0 -> true
      ; throw(error(domain_error(not_less_than_zero,Value),succ/2)))
    ).
