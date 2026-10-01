% SPDX-License-Identifier: MIT

% Trealla v3.12.6 (8fa6f4e) changes if-then-else commitment semantics after
% the control term has been rebuilt recursively.  Run with:
%
%   tpl -f reproducers/bug-019-rebuilt-if-then-else.pl \
%       -g "reproducer,halt"
%
% Expected output:
%
%   expected_failure
%
% Observed output:
%
%   unexpected_else
%   unexpected_success

reproducer :-
    rebuild_control((true -> fail ; writeln(unexpected_else)), Goal),
    ( call(Goal) ->
        writeln(unexpected_success)
    ; writeln(expected_failure)
    ).

rebuild_control((Left0 ; Right0), (Left ; Right)) :- !,
    rebuild_control(Left0, Left),
    rebuild_control(Right0, Right).
rebuild_control((If0 -> Then0), (If -> Then)) :- !,
    rebuild_control(If0, If),
    rebuild_control(Then0, Then).
rebuild_control(Goal, Goal).
