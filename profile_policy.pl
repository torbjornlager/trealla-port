% SPDX-License-Identifier: MIT

:- module(profile_policy,
       [ normalize_profile/2,
         min_profile/3,
         endpoint_profile_ceiling/2,
         profile_allows_route/2,
         effective_profile_for_route/3,
         profile_check_route/2,
         profile_check_command/2,
         profile_check_goal/2,
         profile_check_goal/3,
         profile_check_spawn_options/2,
         normalize_relation_patterns/2
       ]).

/** <module> Web Prolog execution-profile policy

This module is the Trealla counterpart of Trinity's node profile policy.  It
defines the ordered RELATION, ISObase, ISOtope, and ACTOR profiles, route
ceilings, submitted-goal checks, and source-option checks.  `workbench` is the
unrestricted development profile and has ACTOR rank; the historical aliases
`stateless` and `session` normalize to `isobase` and `isotope`.

These checks enforce capability boundaries, but they are not a sandbox.
Resource limits, module visibility, foreign predicates, and URI fetching need
their own policy layers before a node can safely accept untrusted programs.
*/

:- use_module(library(error)).


                 /*******************************
                 *       PROFILE ORDERING        *
                 *******************************/

normalize_profile(stateless, isobase) :- !.
normalize_profile(session, isotope) :- !.
normalize_profile(Profile, Profile) :-
    valid_profile(Profile),
    !.
normalize_profile(Profile, _) :-
    throw(error(domain_error(node_profile, Profile),
                context(profile_policy:normalize_profile/2,
                        'expected workbench, relation, isobase, isotope, actor, stateless, or session'))).

valid_profile(workbench).
valid_profile(relation).
valid_profile(isobase).
valid_profile(isotope).
valid_profile(actor).

profile_rank(relation, 0).
profile_rank(isobase, 1).
profile_rank(isotope, 2).
profile_rank(actor, 3).
profile_rank(workbench, 3).

profile_at_least(Profile0, Required0) :-
    normalize_profile(Profile0, Profile),
    normalize_profile(Required0, Required),
    profile_rank(Profile, Rank),
    profile_rank(Required, RequiredRank),
    Rank >= RequiredRank.

min_profile(ProfileA0, ProfileB0, Minimum) :-
    normalize_profile(ProfileA0, ProfileA),
    normalize_profile(ProfileB0, ProfileB),
    profile_rank(ProfileA, RankA),
    profile_rank(ProfileB, RankB),
    ( RankA =< RankB -> Minimum = ProfileA ; Minimum = ProfileB ).


                 /*******************************
                 *         ROUTE POLICY          *
                 *******************************/

endpoint_profile_ceiling(call, isobase).
endpoint_profile_ceiling(toplevel_spawn, isotope).
endpoint_profile_ceiling(toplevel_call, isotope).
endpoint_profile_ceiling(toplevel_next, isotope).
endpoint_profile_ceiling(toplevel_poll, isotope).
endpoint_profile_ceiling(toplevel_stop, isotope).
endpoint_profile_ceiling(toplevel_abort, isotope).
endpoint_profile_ceiling(toplevel_halt, isotope).
endpoint_profile_ceiling(toplevel_respond, isotope).
endpoint_profile_ceiling(ws, actor).

profile_allows_route(relation, call) :- !.
profile_allows_route(Profile, Route) :-
    endpoint_profile_ceiling(Route, Required),
    profile_at_least(Profile, Required).

effective_profile_for_route(Profile0, Route, Effective) :-
    normalize_profile(Profile0, Profile),
    endpoint_profile_ceiling(Route, Ceiling),
    min_profile(Profile, Ceiling, Effective).

profile_check_route(Profile0, Route) :-
    normalize_profile(Profile0, Profile),
    ( profile_allows_route(Profile, Route) -> true
    ; throw(error(profile_violation(Profile, route(Route)),
                  context(profile_policy:profile_check_route/2,
                          'route is not available in the configured node profile')))
    ).


                 /*******************************
                 *       PROTOCOL COMMANDS       *
                 *******************************/

profile_check_command(Profile, Command) :-
    command_required_profile(Command, Required),
    ( profile_at_least(Profile, Required) -> true
    ; normalize_profile(Profile, Normalized),
      throw(error(profile_violation(Normalized, command(Command)),
                  context(profile_policy:profile_check_command/2,
                          'command is not available in the effective profile')))
    ).

command_required_profile(transport_hello, relation).
command_required_profile(toplevel_spawn, isotope).
command_required_profile(toplevel_call, isotope).
command_required_profile(toplevel_next, isotope).
command_required_profile(toplevel_stop, isotope).
command_required_profile(toplevel_abort, isotope).
command_required_profile(toplevel_halt, isotope).
command_required_profile(toplevel_respond, isotope).
command_required_profile(browser_io_reply, actor).
command_required_profile(spawn, actor).
command_required_profile(send, actor).
command_required_profile(monitor, actor).
command_required_profile(demonitor, actor).
command_required_profile(exit, actor).
command_required_profile(io_request, actor).
command_required_profile(Command, _) :-
    throw(error(domain_error(web_prolog_command, Command),
                profile_policy:profile_check_command/2)).


                 /*******************************
                 *          GOAL POLICY          *
                 *******************************/

profile_check_goal(Profile, Goal) :-
    profile_check_goal(Profile, Goal, []).

profile_check_goal(Profile0, Goal, RelationPatterns) :-
    normalize_profile(Profile0, Profile),
    must_be(callable, Goal),
    ( Profile == relation
    -> relation_check_goal(Goal, RelationPatterns)
    ;  profile_check_goal_1(Profile, Goal)
    ).

profile_check_goal_1(Profile, Goal) :-
    ( var(Goal) -> true
    ; Goal = (_Module:Inner) -> profile_check_goal_1(Profile, Inner)
    ; Goal = (Left, Right) -> profile_check_goal_1(Profile, Left),
                              profile_check_goal_1(Profile, Right)
    ; Goal = (Left; Right) -> profile_check_goal_1(Profile, Left),
                             profile_check_goal_1(Profile, Right)
    ; Goal = (If -> Then) -> profile_check_goal_1(Profile, If),
                             profile_check_goal_1(Profile, Then)
    ; Goal = (\+ Inner) -> profile_check_goal_1(Profile, Inner)
    ; meta_goal_arguments(Goal, Nested) ->
        ensure_goal_profile(Profile, Goal),
        profile_check_nested_goals(Profile, Nested)
    ; ensure_goal_profile(Profile, Goal)
    ).

profile_check_nested_goals(_, []).
profile_check_nested_goals(Profile, [Goal|Goals]) :-
    profile_check_goal_1(Profile, Goal),
    profile_check_nested_goals(Profile, Goals).

meta_goal_arguments(call(Goal), [Goal]).
meta_goal_arguments(call(Goal, _), [Goal]).
meta_goal_arguments(call(Goal, _, _), [Goal]).
meta_goal_arguments(once(Goal), [Goal]).
meta_goal_arguments(ignore(Goal), [Goal]).
meta_goal_arguments(catch(Goal, _, Handler), [Goal, Handler]).
meta_goal_arguments(setup_call_cleanup(Setup, Goal, Cleanup),
                    [Setup, Goal, Cleanup]).
meta_goal_arguments(call_cleanup(Goal, Cleanup), [Goal, Cleanup]).
meta_goal_arguments(forall(Generator, Test), [Generator, Test]).
meta_goal_arguments(findall(_, Goal, _), [Goal]).
meta_goal_arguments(bagof(_, Goal, _), [Goal]).
meta_goal_arguments(setof(_, Goal, _), [Goal]).
meta_goal_arguments(time(Goal), [Goal]).
meta_goal_arguments(spawn(Goal), [Goal]).
meta_goal_arguments(spawn(Goal, _), [Goal]).
meta_goal_arguments(spawn(Goal, _, _), [Goal]).
meta_goal_arguments(parallel(Goals), Goals) :- is_list(Goals).
meta_goal_arguments(first_solution(_, Goals), Goals) :- is_list(Goals).
meta_goal_arguments(first_solution(_, Goals, _), Goals) :- is_list(Goals).
meta_goal_arguments(toplevel_call(_, Goal), [Goal]).
meta_goal_arguments(toplevel_call(_, Goal, _), [Goal]).

ensure_goal_profile(Profile, Goal) :-
    ( goal_required_profile(Goal, Required),
      \+ profile_at_least(Profile, Required)
    -> throw(error(profile_violation(Profile, goal(Goal)),
                   context(profile_policy:profile_check_goal/2,
                           'goal is not available in the effective profile')))
    ; true
    ).

goal_required_profile(Goal, actor) :- actor_goal(Goal), !.
goal_required_profile(Goal, isotope) :- isotope_goal(Goal), !.

actor_goal(Goal) :-
    functor(Goal, Name, Arity),
    actor_predicate(Name, Arity).

actor_predicate(self, 1).
actor_predicate(spawn, 1).
actor_predicate(spawn, 2).
actor_predicate(spawn, 3).
actor_predicate(actors, 1).
actor_predicate(exit, 1).
actor_predicate(exit, 2).
actor_predicate(cancel, 1).
actor_predicate(send, 2).
actor_predicate(send, 3).
actor_predicate(!, 2).
actor_predicate(receive, 1).
actor_predicate(receive, 2).
actor_predicate(monitor, 2).
actor_predicate(demonitor, 1).
actor_predicate(demonitor, 2).
actor_predicate(flush, 0).
actor_predicate(register, 2).
actor_predicate(whereis, 2).
actor_predicate(unregister, 1).
actor_predicate(register_service, 2).
actor_predicate(whereis_service, 2).
actor_predicate(unregister_service, 1).
actor_predicate(output, 1).
actor_predicate(output, 2).
actor_predicate(input, 2).
actor_predicate(input, 3).
actor_predicate(respond, 2).
actor_predicate(toplevel_spawn, 1).
actor_predicate(toplevel_spawn, 2).
actor_predicate(toplevel_call, 2).
actor_predicate(toplevel_call, 3).
actor_predicate(toplevel_next, 1).
actor_predicate(toplevel_next, 2).
actor_predicate(toplevel_stop, 1).
actor_predicate(toplevel_abort, 1).
actor_predicate(toplevel_halt, 1).
actor_predicate(toplevel_halt, 2).
actor_predicate(parallel, 1).
actor_predicate(first_solution, 2).
actor_predicate(first_solution, 3).

isotope_goal(Goal) :-
    functor(Goal, Name, Arity),
    isotope_predicate(Name, Arity).

isotope_predicate(listing, 0).
isotope_predicate(listing, 1).
isotope_predicate(assert, 1).
isotope_predicate(assert, 2).
isotope_predicate(asserta, 1).
isotope_predicate(asserta, 2).
isotope_predicate(assertz, 1).
isotope_predicate(assertz, 2).
isotope_predicate(retract, 1).
isotope_predicate(retractall, 1).
isotope_predicate(abolish, 1).
isotope_predicate(abolish, 2).
isotope_predicate(nb_setval, 2).
isotope_predicate(b_setval, 2).
isotope_predicate(flag, 3).
isotope_predicate(write, 1).
isotope_predicate(write, 2).
isotope_predicate(writeln, 1).
isotope_predicate(writeln, 2).
isotope_predicate(write_term, 2).
isotope_predicate(write_term, 3).
isotope_predicate(write_canonical, 1).
isotope_predicate(write_canonical, 2).
isotope_predicate(writeq, 1).
isotope_predicate(writeq, 2).
isotope_predicate(print, 1).
isotope_predicate(print, 2).
isotope_predicate(nl, 0).
isotope_predicate(nl, 1).
isotope_predicate(put_char, 1).
isotope_predicate(put_char, 2).
isotope_predicate(format, 1).
isotope_predicate(format, 2).
isotope_predicate(format, 3).
isotope_predicate(with_output_to, 2).
isotope_predicate(flush_output, 0).
isotope_predicate(flush_output, 1).
isotope_predicate(read, 1).
isotope_predicate(read, 2).
isotope_predicate(read_term, 2).
isotope_predicate(read_term, 3).


                 /*******************************
                 *       RELATION ALLOWLIST      *
                 *******************************/

normalize_relation_patterns(Patterns0, Patterns) :-
    must_be(list, Patterns0),
    normalize_relation_patterns_(Patterns0, Patterns).

normalize_relation_patterns_([], []).
normalize_relation_patterns_([Pattern0|Patterns0], [Pattern|Patterns]) :-
    normalize_relation_pattern(Pattern0, Pattern),
    normalize_relation_patterns_(Patterns0, Patterns).

normalize_relation_pattern(Name/Arity, Pattern) :-
    atom(Name), integer(Arity), Arity >= 0,
    !,
    functor(Pattern, Name, Arity).
normalize_relation_pattern(Pattern, Pattern) :-
    callable(Pattern),
    !.
normalize_relation_pattern(Pattern, _) :-
    throw(error(type_error(relation_pattern, Pattern),
                profile_policy:normalize_relation_patterns/2)).

relation_check_goal(Goal, Patterns) :-
    ( Goal = (Left, Right) -> relation_check_goal(Left, Patterns),
                             relation_check_goal(Right, Patterns)
    ; relation_goal_allowed(Goal, Patterns) -> true
    ; functor(Goal, Name, Arity),
      throw(error(existence_error(procedure, Name/Arity),
                  context(profile_policy:profile_check_goal/3,
                          'relation is not served by this node')))
    ).

relation_goal_allowed(Goal, Patterns) :-
    member(Pattern0, Patterns),
    copy_term(Pattern0, Pattern),
    subsumes_term(Pattern, Goal),
    !.


                 /*******************************
                 *        SOURCE OPTIONS         *
                 *******************************/

profile_check_spawn_options(Profile0, Options) :-
    normalize_profile(Profile0, Profile),
    must_be(list, Options),
    profile_check_spawn_options_(Options, Profile).

profile_check_spawn_options_([], _).
profile_check_spawn_options_([Option|Options], Profile) :-
    ( source_option(Option) -> profile_check_source_option(Profile, Option)
    ; true
    ),
    profile_check_spawn_options_(Options, Profile).

source_option(src_text(_)).
source_option(src_list(_)).
source_option(src_predicates(_)).
source_option(src_uri(_)).

profile_check_source_option(relation, Option) :-
    !,
    throw(error(profile_violation(relation, option(Option)),
                context(profile_policy:profile_check_spawn_options/2,
                        'source loading is not available in the RELATION profile'))).
profile_check_source_option(Profile, Option) :-
    ( profile_at_least(Profile, isobase) -> true
    ; throw(error(profile_violation(Profile, option(Option)),
                  profile_policy:profile_check_spawn_options/2))
    ),
    profile_check_source_contents(Profile, Option).

profile_check_source_contents(Profile, src_list(Terms)) :-
    !,
    must_be(list, Terms),
    profile_check_source_terms(Profile, Terms).
profile_check_source_contents(_Profile, src_predicates(PIs)) :-
    !,
    must_be(list, PIs).
profile_check_source_contents(_Profile, src_uri(_)) :- !.
profile_check_source_contents(_Profile, src_text(_)) :- !.

profile_check_source_terms(_, []).
profile_check_source_terms(Profile, [Term|Terms]) :-
    profile_check_source_term(Profile, Term),
    profile_check_source_terms(Profile, Terms).

profile_check_source_term(Profile, (:- Directive)) :- !,
    profile_check_goal(Profile, Directive).
profile_check_source_term(Profile, (_Head :- Body)) :- !,
    profile_check_goal(Profile, Body).
profile_check_source_term(_, _).
