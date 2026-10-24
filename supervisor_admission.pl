% SPDX-License-Identifier: MIT
:- module(supervisor_admission,[supervisor_spec_goals/2]).

% Admission inspects existing structure only. Unknown terms remain opaque goals
% for the caller's policy; never manufacture a child, option list or server start.
supervisor_spec_goals(Specs, [Specs]) :- var(Specs), !.
supervisor_spec_goals([], []) :- !.
supervisor_spec_goals([Spec|Specs], Goals) :- !,
    child_goals(Spec, Here),
    supervisor_spec_goals(Specs, Rest),
    append(Here, Rest, Goals).
supervisor_spec_goals(_, []).

child_goals(Spec, [Spec]) :- var(Spec), !.
child_goals(child(_,Options), Goals) :- !, option_goals(Options, Goals).
child_goals(_, []).

option_goals(Options, [Options]) :- var(Options), !.
option_goals([], []) :- !.
option_goals([Option|Options], Goals) :- !,
    ( var(Option)
    -> Goals=[Option|Rest], option_goals(Options,Rest)
    ; Option=start(Start)
    -> start_goals(Start,Goals)
    ; option_goals(Options,Goals)
    ).
option_goals(_, []).

start_goals(Start, [Start]) :- var(Start), !.
start_goals(server(_,_), []) :- !.
start_goals(start_sub_supervisor(Specs,_), Goals) :- !,
    supervisor_spec_goals(Specs,Goals).
start_goals(Goal,[Goal]).
