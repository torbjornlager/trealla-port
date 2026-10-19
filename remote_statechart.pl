% SPDX-License-Identifier: MIT
:- module(remote_statechart,[prepare/7]).
:- use_module(statechart_actor,[]).
:- use_module(sandbox_policy,[]).
:- use_module(profile_policy,[]).
% Match only the four SWI framework entry shapes. Supplied definitions of
% these predicates retain ordinary source-loading and sandbox treatment.
prepare(M,P,Wire,Options,Entry,Prepared,yes) :-
 nonvar(Wire),entry_source(Wire,Trace,Source,PI),
 sandbox_policy:resolve_source_options(Options,Resolved),
 sandbox_policy:materialize_source_options(Resolved,_,Terms),
 sandbox_policy:source_predicate_indicators(Terms,PIs),
 \+ memberchk(PI,PIs),!,
 must_be(boolean,Trace),
 profile_policy:profile_check_goal(P,statechart_spawn(_,_)),
 statechart_actor:prepare_chart(M,P,user,Source,Trace,Resolved,Entry,Prepared).
prepare(_,_,_,_,_,_,no).
entry_source(interpret(URI),true,statechart_actor:interpret(URI),interpret/1).
entry_source(interpret_text(Text),true,statechart_actor:interpret_text(Text),interpret_text/1).
entry_source(interpret_trace(Trace,URI),Trace,statechart_actor:interpret(URI),interpret_trace/2).
entry_source(interpret_text_trace(Trace,Text),Trace,statechart_actor:interpret_text(Text),interpret_text_trace/2).
