% SPDX-License-Identifier: MIT
% Regression: every creation predicate that accepts src_* options applies the
% source policy when called from a sandboxed query. toplevel_spawn/1-2,
% server_spawn/3-4 and server_upgrade/3 used to reach their runtime
% implementations unrewritten, so a visitor's source directive ran unchecked.
:- module(creation_source_policy_tests,[run/0]).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(toplevel_actors,[]).
:- use_module(server_actor,[]).
:- use_module(sandbox_policy,[]).
:- dynamic(creation_probe_ran/0).

forbidden_text(":- open('/dev/null',read,S), close(S), creation_source_policy_tests:assertz(creation_probe_ran).").

refused(Mode, Goal0, Label) :-
    retractall(creation_probe_ran),
    sandbox_policy:sandbox_prepare_goal(Mode, actor, user, Goal0, Goal),
    catch((call(Goal), Outcome = created), E, Outcome = E),
    (   \+ creation_probe_ran,
        Outcome = error(permission_error(execute,sandboxed_directive,_),_)
    ->  format('~w refuses a forbidden source directive under ~w policy: ok~n',[Label,Mode])
    ;   throw(creation_source_not_checked(Label,Mode,Outcome))
    ).

run :-
    forbidden_text(Text),
    forall(member(Mode,[blacklist,whitelist]),
      ( refused(Mode, toplevel_spawn(_,[src_text(Text)]), 'toplevel_spawn/2'),
        refused(Mode, server_spawn(creation_cb,0,_,[src_text(Text)]), 'server_spawn/4'),
        refused(Mode, server_upgrade(_,creation_cb,[src_text(Text)]), 'server_upgrade/3') )),
    safe_toplevel_source,
    writeln('Creation source policy: all regressions passed').

% Declarations and clauses remain accepted through the rewritten path.
safe_toplevel_source :-
    sandbox_policy:sandbox_prepare_goal(blacklist, actor, user,
        toplevel_spawn(P,[src_text(':- dynamic(creation_ok/1). creation_ok(yes).')]), Goal),
    % Deterministic, like spawn/3: a leftover choice point would leave a
    % toplevel session waiting for next/stop after the nested spawn.
    setup_call_cleanup(true, call(Goal), Det = true),
    (   Det == true -> true ; throw(creation_source_left_choice_point) ),
    must_be(nonvar, P),
    toplevel_actors:toplevel_halt(P),
    writeln('toplevel_spawn/2 still accepts declarations and clauses: ok').
