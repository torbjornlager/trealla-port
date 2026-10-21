% SPDX-License-Identifier: MIT
% Separate diagnostics for transport differences exposed by creation tests.
% These are observations, not passing conformance assertions.
:- module(remote_toplevel_creation_diagnostics,[wide_answer/2]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(distribution).

wide_answer(URL,Observation) :-
    setup_call_cleanup(true,
      (toplevel_spawn(P,[node(URL),session(false),link(false),monitor(true)]),
       toplevel_call(P,X='€',[template(X)]),
       receive({success(P,['€'],false) -> Observation=delivered;
                error(P,E) -> Observation=error(E)},
         [timeout(2),on_timeout(Observation=missing_answer)]),
       receive({down(P,P,_) -> true},[timeout(2),on_timeout(fail)])),
      remote_drop_connection(URL)).
