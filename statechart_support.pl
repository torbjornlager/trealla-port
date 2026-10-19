% SPDX-License-Identifier: MIT
:- module(statechart_support,[debug/3,rethrow_reserved/1]).
debug(_,_,_).
rethrow_reserved(Error) :-
    (sandbox_policy:reserved_runtime_control(Error) -> throw(Error);true).
