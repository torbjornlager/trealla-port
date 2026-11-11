% SPDX-License-Identifier: MIT
:- module(node_discovery_tests, [run/0]).
:- use_module(web_prolog).
:- use_module(actors).
:- use_module(isolation, []).

run :-
    setup_call_cleanup(true, metadata_checks, isolation:clear_shared_db),
    published_service_checks,
    writeln('Shared database and live service discovery metadata: passed').

metadata_checks :-
    isolation:clear_shared_db,
    isolation:shared_db_predicates([]),
    isolation:configure_shared_db(['fixtures/source/shared-discovery.pl']),
    isolation:shared_db_predicates(PIs),
    Expected=[discovery_empty/1,discovery_fact/1,discovery_grammar/3,discovery_rule/1,last/2],
    must_equal(PIs, Expected, definitions_imports_dcg_and_exclusions),
    % Private session source and shared shadows cannot alter the node contract.
    setup_call_cleanup(
        isolation:prepare_actor(discovery_private, user,
            [src_text('private_only(secret). discovery_fact(private).')], _),
        isolation:shared_db_predicates(Expected),
        isolation:cleanup_actor(discovery_private)),
    isolation:configure_shared_db(['fixtures/source/shared-discovery.pl',
                                 'fixtures/source/shared-shadow.pl']),
    isolation:shared_db_predicates(Layered),
    append(Expected,[shadow_one/1,shadow_zero/0],Layered),
    isolation:configure_shared_db(['fixtures/source/shared-discovery-no-init.pl']),
    isolation:shared_db_predicates([discovery_unstarted/1]),
    isolation:clear_shared_db,
    isolation:shared_db_predicates([]).

published_service_checks :-
    actors:published_service_names([]),
    setup_call_cleanup(
        spawn(receive({stop->true}), Pid, [monitor(true)]),
        ( register(discovery_private_alias, Pid),
          actors:published_service_names([]),
          register_service(discovery_public, Pid),
          actors:published_service_names([discovery_public]),
          unregister_service(discovery_public),
          actors:published_service_names([]),
          register_service(discovery_public, Pid),
          Pid ! stop,
          receive({down(Pid,_,_)->true},[timeout(2),on_timeout(throw(introspection_message_missing))]),
          actors:published_service_names([]) ),
        exit(Pid,kill)).

must_equal(Actual, Expected, Label) :-
    ( Actual == Expected -> true ; throw(mismatch(Label, Actual, Expected)) ).
