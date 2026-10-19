% SPDX-License-Identifier: MIT
:- module(remote_server,[prepare/7,run/2]).
:- use_module(remote_supervisor,[]).
:- use_module(profile_policy,[]).
:- use_module(sandbox_policy,[]).
prepare(M,P,Wire,Options,Entry,Prepared,yes) :-
 nonvar(Wire),compound(Wire),functor(Wire,server_loop,2),
 sandbox_policy:resolve_source_options(Options,Resolved),
 sandbox_policy:materialize_source_options(Resolved,_,Terms),
 sandbox_policy:source_predicate_indicators(Terms,PIs),
 \+ memberchk(server_loop/2,PIs),!,
 Wire=server_loop(Callback0,State),
 profile_policy:profile_check_goal(P,server_spawn(Callback0,State,_)),
 remote_supervisor:source_goal(Callback0,Callback),
 remote_supervisor:prepare_start(M,P,Resolved,server(Callback,[initial_state(State)]),server(Guard,Loaded)),
 exclude(initial_state_option,Loaded,Prepared),
 Entry=remote_server:run(Guard,State).
prepare(_,_,_,_,_,_,no).
initial_state_option(initial_state(_)).
run(Guard,State) :- server_actor:server_loop(Guard,State).
