% SPDX-License-Identifier: MIT
:- module(node_settings_tests,[run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(node_settings,[]).
:- use_module(resource_policy).
:- use_module(governance_policy).
:- use_module(source_policy).
:- use_module(profile_policy).

run :-
    configure_resource_policy([max_term_text_bytes(70001),max_source_text_bytes(90001)],_),
    configure_governance_policy([rate_window_seconds(71),max_inflight_calls(13)],_),
    configure_source_policy([load_uri_allowed_origins([
        'https://source.example.test','http://source.example.test:8080',
        'https://source.example.test:443'])], _),
    setup_call_cleanup(
      (node_settings:register_node_settings(65001,'https://one.example',actor,blacklist,dev),
       node_settings:register_node_settings(65002,'https://two.example',isobase,whitelist,open)),
      settings_checks,
      (node_settings:forget_node_settings(65001),node_settings:forget_node_settings(65002))),
    writeln('Public node settings, context inheritance and cleanup: passed').

settings_checks :-
    findall(K-V,node_setting(K,V),[]),
    profile_check_goal(relation,node_setting(profile,_)),
    node_settings:with_node_settings(65001,
      (node_setting(url,'https://one.example'),node_setting(profile,actor),
       node_setting(max_term_text_bytes,70001),node_setting(max_load_text_bytes,90001),
       node_setting(rate_window_seconds,71),node_setting(max_inflight_calls,13),
       \+node_setting(rate_window_seconds,60),\+node_setting(max_inflight_calls,4),
       \+node_setting(max_term_text_bytes,32768),
       node_setting(load_uri_allowed_origins,
         ['http://source.example.test:8080','https://source.example.test:443']),
       \+node_setting(load_uri_allowed_origins,[]),
       \+node_setting(load_uri_allowed_origins,ns_not_a_list),
       \+node_setting(timeout,_),\+node_setting(max_sessions_per_principal,_),
       \+node_setting(shared_db_source,_),\+node_setting(principal_policies,_),
       node_settings:with_node_settings(65002,
         (node_setting(url,'https://two.example'),node_setting(profile,isobase),
          \+node_setting(max_ws_frame_bytes,_),\+node_setting(max_session_spawns_per_window,_))),
       node_setting(url,'https://one.example'),
       configure_governance_policy([rate_window_seconds(72)],_),
       node_setting(rate_window_seconds,72),\+node_setting(rate_window_seconds,71),
       catch(node_settings:with_node_settings(65002,throw(ns_restore)),ns_restore,true),
       node_setting(url,'https://one.example'),
       self(Me),spawn((node_setting(url,U),Me!ns_url(U)),Pid,[monitor(true)]),
       receive({ns_url(U)->U=='https://one.example'},[timeout(2)]),
       receive({down(Pid,_,_)->true},[timeout(2)]),
       \+node_settings:actor_node(Pid,_))),
    findall(K-V,node_setting(K,V),[]),
    node_settings:forget_node_settings(65001),
    node_settings:with_node_settings(65001,findall(K-V,node_setting(K,V),[])),
    node_settings:register_node_settings(65002,'https://two.example',relation,blacklist,open),
    node_settings:with_node_settings(65002,
      (node_setting(profile,relation),node_setting(max_inflight_calls,_),
       \+node_setting(max_load_text_bytes,_),\+node_setting(max_session_spawns_per_window,_),
       \+node_setting(max_ws_frame_bytes,_))),
    \+node_settings:connection_node(_,_).
