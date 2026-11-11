% SPDX-License-Identifier: MIT
:- module(node_settings,
    [ node_setting/2,
      register_node_settings/5,
      forget_node_settings/1,
      with_node_settings/2
    ]).

/** <module> Public settings of the serving node

Only the explicit Appendix B allowlist is exposed. Listener identity follows
the connection into its actors, including retained sessions and private source
workers. Resource, source and governance policies are process-wide in this
host; read their current enforced values rather than caching startup options.
No serving context means no available settings, even if a listener exists.
*/

:- use_module(actors, []).
:- dynamic node_public/5, connection_node/2, actor_node/2.
:- meta_predicate with_node_settings(+, 0).

register_node_settings(Port, URL, Profile0, Sandbox, Auth) :-
    ( Profile0 == workbench -> Profile = actor ; Profile = Profile0 ),
    retractall(node_public(Port,_,_,_,_)),
    assertz(node_public(Port,URL,Profile,Sandbox,Auth)).

forget_node_settings(Port) :- retractall(node_public(Port,_,_,_,_)).

with_node_settings(Port, Goal) :-
    thread_self(Thread),
    setup_call_cleanup(asserta(connection_node(Thread,Port),Ref),
                       call(Goal), erase(Ref)).

current_node(Port) :-
    thread_self(Thread), connection_node(Thread,Port), !.
current_node(Port) :-
    thread_self(Thread), actors:thread_pid(Thread,Pid), actor_node(Pid,Port).

:- multifile actors:hook_spawn_reserved/2, actors:hook_stop/1.
actors:hook_spawn_reserved(Pid, _) :-
    ( node_settings:current_node(Port)
    -> assertz(node_settings:actor_node(Pid,Port))
    ; true ).
actors:hook_stop(Pid) :- retractall(node_settings:actor_node(Pid,_)).

%! node_setting(?Key, ?Value) is nondet.
% Unknown, private and unavailable settings fail. The host has no separate
% polling timeout or per-principal session ceiling, so neither is reported.
node_setting(Key, Value) :-
    current_node(Port),
    node_public(Port,URL,Profile,Sandbox,Auth),
    public_setting(Key,Family),
    family_visible(Family,Profile),
    % Policy getters take output arguments; a bound mismatch must not make
    % them fall back to default policies or validate the caller's value.
    setting_value(Key,URL,Profile,Sandbox,Auth,Current),
    Value = Current.

family_visible(always, _).
family_visible(private_db, Profile) :- memberchk(Profile,[isobase,isotope,actor]).
family_visible(stateless_api, _).
family_visible(session_api, Profile) :- memberchk(Profile,[isotope,actor]).
family_visible(actor_api, actor).

public_setting(url, always).
public_setting(profile, always).
public_setting(sandbox, always).
public_setting(auth, always).
public_setting(rate_window_seconds, always).
public_setting(max_inflight_calls, stateless_api).
public_setting(max_term_text_bytes, stateless_api).
public_setting(max_call_requests_per_window, stateless_api).
public_setting(max_load_text_bytes, private_db).
public_setting(load_uri_allowed_origins, private_db).
public_setting(max_session_spawns_per_window, session_api).
public_setting(max_ws_actors_per_principal, actor_api).
public_setting(max_ws_frame_bytes, actor_api).
public_setting(max_ws_commands_per_window, actor_api).

setting_value(url, URL, _, _, _, URL).
setting_value(profile, _, Profile, _, _, Profile).
setting_value(sandbox, _, _, Sandbox, _, Sandbox).
setting_value(auth, _, _, _, Auth, Auth).
setting_value(rate_window_seconds, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(Value,_,_,_,_,_)).
setting_value(max_inflight_calls, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(_,_,_,_,Value,_)).
setting_value(max_call_requests_per_window, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(_,Value,_,_,_,_)).
setting_value(max_session_spawns_per_window, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(_,_,Value,_,_,_)).
setting_value(max_ws_actors_per_principal, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(_,_,_,_,_,Value)).
setting_value(max_ws_commands_per_window, _, _, _, _, Value) :-
    governance_policy:current_governance_policy(governance_policy(_,_,_,Value,_,_)).
setting_value(max_term_text_bytes, _, _, _, _, Value) :-
    resource_policy:current_resource_policy(resource_policy(_,_,_,Value,_,_)).
setting_value(max_load_text_bytes, _, _, _, _, Value) :-
    resource_policy:current_resource_policy(resource_policy(_,_,_,_,Value,_)).
setting_value(max_ws_frame_bytes, _, _, _, _, Value) :-
    resource_policy:current_resource_policy(resource_policy(_,_,_,_,_,Value)).
setting_value(load_uri_allowed_origins, _, _, _, _, Value) :-
    source_policy:current_source_policy(source_policy(Origins,_,_,_,_)),
    origin_atoms(Origins,Atoms), sort(Atoms,Value).

origin_atoms([],[]).
origin_atoms([origin(Scheme,Host,Port)|Origins],[Atom|Atoms]) :-
    format(atom(Atom),'~w://~w:~w',[Scheme,Host,Port]),
    origin_atoms(Origins,Atoms).
