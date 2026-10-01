% SPDX-License-Identifier: MIT

:- module(sandbox_policy,
       [ normalize_sandbox_mode/2,
         sandbox_check_goal/4,
         sandbox_prepare_goal/5,
         sandbox_prepare_spawn/7,
         sandbox_prepare_options/5,
         sandbox_call/5,
         sandbox_call/6,
         sandbox_call/7,
         sandbox_call/8,
         sandbox_call/9,
         sandbox_call/10,
         sandbox_call/11,
         sandbox_call/12,
         sandbox_spawn/7,
         sandbox_toplevel_call/7,
         sandbox_assert/5,
         sandbox_assert/6,
         sandbox_asserta/5,
         sandbox_asserta/6,
         sandbox_assertz/5,
         sandbox_assertz/6,
         sandbox_retract/5,
         sandbox_retractall/5,
         sandbox_abolish/5,
         sandbox_abolish/6
       ]).

/** <module> Native Trealla sandbox and public source policy

Trealla does not provide SWI-Prolog's `library(sandbox)`.  This module ports
the node-owned, runtime-independent policy instead: public goals are walked,
dangerous ambient capabilities are denied, source is parsed and validated
before loading, and opaque meta-calls are rewritten through runtime guards.

`blacklist` preserves ordinary Prolog except for explicitly dangerous
families. `whitelist` additionally permits only a conservative catalog of
pure predicates, actor operations admitted by the active profile, and
predicates defined by the submitted source. `off` performs profile checks but
does not apply sandbox policy.  This is defense in depth; OS containment is
still required for an internet-facing node.
*/

:- use_module(library(error)).
:- use_module(profile_policy).
:- use_module(isolation).
:- use_module(resource_policy).
:- use_module(source_policy).

% Source text is parsed in this module before it is installed in an actor's
% private module.  Keep the public actor syntax available at that boundary;
% Trealla does not implicitly import these operators from actors.pl here.
:- op(800,  xfx, !).
:- op(200,  xfx, @).
:- op(1000, xfy, if).


                 /*******************************
                 *            MODES              *
                 *******************************/

normalize_sandbox_mode(off, off) :- !.
normalize_sandbox_mode(blacklist, blacklist) :- !.
normalize_sandbox_mode(whitelist, whitelist) :- !.
normalize_sandbox_mode(on, whitelist) :- !.
normalize_sandbox_mode(demo, whitelist) :- !.
normalize_sandbox_mode(strict, whitelist) :- !.
normalize_sandbox_mode(Mode, _) :-
    throw(error(domain_error(node_sandbox_mode, Mode),
                context(sandbox_policy:normalize_sandbox_mode/2,
                        'expected off, blacklist, or whitelist (on/demo/strict alias whitelist)'))).


                 /*******************************
                 *         PUBLIC CHECKS         *
                 *******************************/

sandbox_check_goal(Mode0, Profile, Module, Goal) :-
    normalize_sandbox_mode(Mode0, Mode),
    profile_check_goal(Profile, Goal),
    ( Mode == off -> true
    ; sandbox_check_goal_(Mode, Profile, Module, [], Goal)
    ).

sandbox_prepare_goal(Mode0, Profile, Module, Goal0, Goal) :-
    normalize_sandbox_mode(Mode0, Mode),
    profile_check_goal(Profile, Goal0),
    ( Mode == off -> Goal = Goal0
    ; sandbox_check_goal_(Mode, Profile, Module, [], Goal0),
      rewrite_goal(Mode, Profile, Module, [], Goal0, Goal)
    ).

sandbox_prepare_spawn(Mode0, Profile, Module, Goal0, Options0,
                      Goal, Options) :-
    normalize_sandbox_mode(Mode0, Mode),
    must_be(list, Options0),
    profile_check_spawn_options(Profile, Options0),
    resolve_source_options(Options0, ResolvedOptions),
    check_source_options_size(ResolvedOptions),
    ( Mode == off -> Goal = Goal0, Options = ResolvedOptions
    ; prepare_source_options(Mode, Profile, ResolvedOptions, Options, AppPIs),
      check_spawn_options(Options0),
      profile_check_goal(Profile, Goal0),
      sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal0),
      rewrite_goal(Mode, Profile, Module, AppPIs, Goal0, Goal)
    ).

sandbox_prepare_options(Mode0, Profile, _Module, Options0, Options) :-
    normalize_sandbox_mode(Mode0, Mode),
    must_be(list, Options0),
    profile_check_spawn_options(Profile, Options0),
    resolve_source_options(Options0, ResolvedOptions),
    check_source_options_size(ResolvedOptions),
    ( Mode == off -> Options = ResolvedOptions
    ; prepare_source_options(Mode, Profile, ResolvedOptions, Options, _),
      check_spawn_options(Options0)
    ).


                 /*******************************
                 *          GOAL WALKER          *
                 *******************************/

sandbox_check_goal_(_Mode, _Profile, _Module, _AppPIs, Goal) :-
    var(Goal),
    !.
sandbox_check_goal_(Mode, Profile, Module, AppPIs, Qualified:Goal) :-
    atom(Qualified),
    !,
    ( permitted_qualified_module(Qualified), known_actor_goal(Goal)
    -> sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal)
    ; throw_sandbox(call, Qualified:Goal, module_qualification)
    ).
sandbox_check_goal_(_Mode, _Profile, _Module, _AppPIs, Qualified:Goal) :-
    !,
    throw_sandbox(call, Qualified:Goal, module_qualification).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, (A,B)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, A),
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, B).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, (A;B)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, A),
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, B).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, (A->B)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, A),
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, B).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, (\+ A)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, A).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, receive(Clauses)) :- !,
    check_receive(Mode, Profile, Module, AppPIs, Clauses, []).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, receive(Clauses,Options)) :- !,
    check_receive(Mode, Profile, Module, AppPIs, Clauses, Options).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, spawn(Goal)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, spawn(Goal,_Pid)) :- !,
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, spawn(Goal,_Pid,Options)) :- !,
    check_nested_spawn(Mode, Profile, Module, AppPIs, Goal, Options).
sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal) :-
    meta_goal_parts(Goal, Nested),
    !,
    check_meta_instantiation(Mode, Goal, Nested),
    check_leaf(Mode, Module, AppPIs, Goal),
    check_nested(Mode, Profile, Module, AppPIs, Nested).
sandbox_check_goal_(Mode, _Profile, Module, AppPIs, Goal) :-
    check_leaf(Mode, Module, AppPIs, Goal).

check_nested(_, _, _, _, []).
check_nested(Mode, Profile, Module, AppPIs, [Goal|Goals]) :-
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal),
    check_nested(Mode, Profile, Module, AppPIs, Goals).

check_meta_instantiation(whitelist, Goal, Nested) :-
    contains_variable_goal(Nested),
    !,
    throw_sandbox(call, Goal, opaque_meta_call).
check_meta_instantiation(_, _, _).

contains_variable_goal([Goal|_]) :- var(Goal), !.
contains_variable_goal([_|Goals]) :- contains_variable_goal(Goals).

meta_goal_parts(call(Goal), [Goal]).
meta_goal_parts(call(Goal,_), [Goal]).
meta_goal_parts(call(Goal,_,_), [Goal]).
meta_goal_parts(call(Goal,_,_,_), [Goal]).
meta_goal_parts(call(Goal,_,_,_,_), [Goal]).
meta_goal_parts(call(Goal,_,_,_,_,_), [Goal]).
meta_goal_parts(call(Goal,_,_,_,_,_,_), [Goal]).
meta_goal_parts(call(Goal,_,_,_,_,_,_,_), [Goal]).
meta_goal_parts(once(Goal), [Goal]).
meta_goal_parts(ignore(Goal), [Goal]).
meta_goal_parts(catch(Goal,_,Recover), [Goal,Recover]).
meta_goal_parts(setup_call_cleanup(Setup,Goal,Cleanup), [Setup,Goal,Cleanup]).
meta_goal_parts(call_cleanup(Goal,Cleanup), [Goal,Cleanup]).
meta_goal_parts(forall(Generate,Test), [Generate,Test]).
meta_goal_parts(findall(_,Goal,_), [Goal]).
meta_goal_parts(findnsols(_,_,Goal,_), [Goal]).
meta_goal_parts(bagof(_,Goal,_), [Goal]).
meta_goal_parts(setof(_,Goal,_), [Goal]).
meta_goal_parts(time(Goal), [Goal]).
meta_goal_parts(spawn(Goal), [Goal]).
meta_goal_parts(spawn(Goal,_), [Goal]).
meta_goal_parts(spawn(Goal,_,_), [Goal]).
meta_goal_parts(parallel(Goals), Goals) :- is_list(Goals).
meta_goal_parts(first_solution(_,Goals), Goals) :- is_list(Goals).
meta_goal_parts(first_solution(_,Goals,_), Goals) :- is_list(Goals).
meta_goal_parts(toplevel_call(_,Goal), [Goal]).
meta_goal_parts(toplevel_call(_,Goal,_), [Goal]).

check_nested_spawn(whitelist, _Profile, _Module, _AppPIs, _Goal, Options) :-
    var(Options), !,
    throw_sandbox(option, Options, opaque_spawn_options).
check_nested_spawn(Mode, Profile, Module, AppPIs, Goal, Options) :-
    ( is_list(Options)
    -> profile_check_spawn_options(Profile, Options),
       check_spawn_options(Options),
       nested_source_predicate_indicators(Options, DeferredPIs),
       append(AppPIs, DeferredPIs, NestedAppPIs)
    ; NestedAppPIs = AppPIs
    ),
    sandbox_check_goal_(Mode, Profile, Module, NestedAppPIs, Goal).

nested_source_predicate_indicators([], []).
nested_source_predicate_indicators([src_predicates(PIs)|Options], All) :- !,
    must_be(list, PIs),
    maplist(check_declared_pi, PIs),
    append(PIs, Rest, All),
    nested_source_predicate_indicators(Options, Rest).
nested_source_predicate_indicators([_|Options], PIs) :-
    nested_source_predicate_indicators(Options, PIs).

check_receive(Mode, Profile, Module, AppPIs, Braced, Options) :-
    receive_term(Braced, Clauses),
    check_receive_clauses(Mode, Profile, Module, AppPIs, Clauses),
    check_receive_options(Mode, Profile, Module, AppPIs, Options).

receive_term({Clauses}, Clauses) :- !.
receive_term(Clauses, Clauses).

check_receive_clauses(M,P,C,A,(Clause;Clauses)) :- !,
    check_receive_clauses(M,P,C,A,Clause), check_receive_clauses(M,P,C,A,Clauses).
check_receive_clauses(M,P,C,A,(Head->Body)) :- !,
    check_receive_head(M,P,C,A,Head), sandbox_check_goal_(M,P,C,A,Body).
check_receive_clauses(_,_,_,_,_).

check_receive_head(M,P,C,A,Head) :-
    nonvar(Head), Head = if(_Pattern,Guard), !,
    sandbox_check_goal_(M,P,C,A,Guard).
check_receive_head(_,_,_,_,_).

check_receive_options(_,_,_,_,Options) :- var(Options), !.
check_receive_options(M,P,C,A,Options) :-
    ( is_list(Options) -> check_receive_option_list(M,P,C,A,Options) ; true ).

check_receive_option_list(_,_,_,_,[]).
check_receive_option_list(M,P,C,A,[on_timeout(Goal)|Options]) :- !,
    sandbox_check_goal_(M,P,C,A,Goal), check_receive_option_list(M,P,C,A,Options).
check_receive_option_list(M,P,C,A,[_|Options]) :- check_receive_option_list(M,P,C,A,Options).

check_leaf(Mode, Module, AppPIs, Goal) :-
    ( forbidden_goal(Goal, Category)
    -> throw_sandbox(call, Goal, Category)
    ; special_goal_check(Mode, Module, AppPIs, Goal)
    -> true
    ; Mode == whitelist,
      \+ whitelist_goal(Module, AppPIs, Goal)
    -> throw_sandbox(call, Goal, not_whitelisted)
    ; true
    ).

special_goal_check(blacklist, _Module, _AppPIs, Goal) :-
    dynamic_clause_goal(Goal, Clause),
    var(Clause),
    !.
special_goal_check(_Mode, _Module, _AppPIs, Goal) :-
    dynamic_clause_goal(Goal, Clause),
    !,
    check_asserted_clause_head(Clause),
    clause_body(Clause, Body),
    ( Body == true -> true ; \+ forbidden_goal(Body, _) ).
special_goal_check(_Mode, _Module, _AppPIs, retract(Head)) :- !,
    ( var(Head) -> true ; check_clause_head(Head) ).
special_goal_check(_Mode, _Module, _AppPIs, retractall(Head)) :- !,
    ( var(Head) -> true ; check_clause_head(Head) ).
special_goal_check(_Mode, _Module, _AppPIs, abolish(PI)) :- !,
    ( var(PI) -> true ; check_mutable_pi(PI) ).
special_goal_check(_Mode, _Module, _AppPIs, abolish(Name, Arity)) :- !,
    ( ( var(Name) ; var(Arity) ) -> true
    ; check_mutable_pi(Name/Arity)
    ).
special_goal_check(_, _, _, format(_, Format, _)) :- !,
    reject_format_meta_call(Format).

dynamic_clause_goal(assert(Clause), Clause).
dynamic_clause_goal(assert(Clause,_), Clause).
dynamic_clause_goal(asserta(Clause), Clause).
dynamic_clause_goal(asserta(Clause,_), Clause).
dynamic_clause_goal(assertz(Clause), Clause).
dynamic_clause_goal(assertz(Clause,_), Clause).

clause_body((_Head :- Body), Body) :- !.
clause_body(_, true).

check_asserted_clause_head((Head :- _)) :- !, check_clause_head(Head).
check_asserted_clause_head(Head) :- check_clause_head(Head).

permitted_qualified_module(actors).
permitted_qualified_module(toplevel_actors).

known_actor_goal(Goal) :-
    callable(Goal), functor(Goal, Name, Arity),
    actor_safe_pi(Name/Arity).


                 /*******************************
                 *         SOURCE POLICY         *
                 *******************************/

prepare_source_options(Mode, Profile, Options0, Options, AppPIs) :-
    materialize_source_options(Options0, PlainOptions, Terms0),
    normalize_source_terms(Terms0, Terms),
    source_predicate_indicators(Terms, AppPIs),
    validate_rewrite_source_terms(Mode, Profile, actor_context, AppPIs,
                                  Terms, Rewritten),
    ( Rewritten == [] -> Options = PlainOptions
    ; Options = [src_list(Rewritten)|PlainOptions]
    ).

materialize_source_options([], [], []).
materialize_source_options([Option|Options0], Options, Terms) :-
    ( Option = src_text(Text)
    -> source_text_terms(Text, Here), Options = Rest
    ; Option = src_list(Here)
    -> must_be(list, Here), Options = Rest
    ; Option = src_uri(URI)
    -> throw(error(domain_error(resolved_source_option, src_uri(URI)),
                   sandbox_policy:sandbox_prepare_options/5))
    ; Option = src_predicates(PIs)
    -> throw(error(permission_error(copy, server_predicates, PIs),
                   context(sandbox_policy:sandbox_prepare_options/5,
                           'public src_predicates/1 must be materialized by the sending node')))
    ; Options = [Option|Rest], Here = []
    ),
    materialize_source_options(Options0, Rest, Tail),
    append(Here, Tail, Terms).

source_text_terms(Text0, Terms) :-
    source_text_atom(Text0, Text),
    setup_call_cleanup(open_string(Text, Stream),
                       read_source_terms(Stream, Terms), close(Stream)).

source_text_atom(Text, Text) :- atom(Text), !.
source_text_atom(Text, Atom) :- string(Text), !, atom_string(Atom, Text).
source_text_atom(Text, Atom) :- is_list(Text), !,
    ( Text = [C|_], integer(C) -> atom_codes(Atom, Text)
    ; atom_chars(Atom, Text)
    ).
source_text_atom(Text, _) :- throw(error(type_error(text, Text), src_text/1)).

read_source_terms(Stream, Terms) :-
    read_term(Stream, Term, []),
    ( Term == end_of_file -> Terms = []
    ; Terms = [Term|Rest], read_source_terms(Stream, Rest)
    ).

normalize_source_terms([], []).
normalize_source_terms([Term0|Terms0], Terms) :-
    ( Term0 = (_ --> _) -> expand_term(Term0, Expanded), term_list(Expanded, Here)
    ; Here = [Term0]
    ),
    normalize_source_terms(Terms0, Rest),
    append(Here, Rest, Terms).

term_list([], []) :- !.
term_list([Term|Terms], [Term|Terms]) :- !.
term_list(Term, [Term]).

source_predicate_indicators(Terms, PIs) :-
    findall(PI, (member(Term, Terms), source_head(Term, Head), head_pi(Head, PI)), Raw),
    sort(Raw, PIs).

source_head((:- _), _) :- !, fail.
source_head((Head :- _), Head) :- !.
source_head(Head, Head).

head_pi(Head, Name/Arity) :-
    check_clause_head(Head), functor(Head, Name, Arity).

validate_rewrite_source_terms(_, _, _, _, [], []).
validate_rewrite_source_terms(Mode, Profile, Module, AppPIs,
                              [Term0|Terms0], [Term|Terms]) :-
    validate_rewrite_source_term(Mode, Profile, Module, AppPIs, Term0, Term),
    validate_rewrite_source_terms(Mode, Profile, Module, AppPIs, Terms0, Terms).

validate_rewrite_source_term(_Mode, _Profile, _Module, _AppPIs,
                             (:- Directive), (:- Directive)) :- !,
    safe_source_directive(Directive).
validate_rewrite_source_term(Mode, Profile, Module, AppPIs,
                             (Head :- Body0), (Head :- Body)) :- !,
    check_clause_head(Head),
    profile_check_goal(Profile, Body0),
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Body0),
    rewrite_goal(Mode, Profile, Module, AppPIs, Body0, Body).
validate_rewrite_source_term(_Mode, _Profile, _Module, _AppPIs, Fact, Fact) :-
    check_clause_head(Fact).

safe_source_directive(dynamic(PI)) :- !, check_mutable_pi(PI).
safe_source_directive(discontiguous(PI)) :- !, check_mutable_pi(PI).
safe_source_directive(Directive) :-
    throw(error(permission_error(execute, sandboxed_directive, (:- Directive)),
                context(sandbox_policy:safe_source_directive/1,
                        'source directive is disabled in sandbox mode'))).

check_declared_pi((A,B)) :- !, check_declared_pi(A), check_declared_pi(B).
check_declared_pi(Name/Arity) :- atom(Name), integer(Arity), Arity >= 0, !.
check_declared_pi(PI) :-
    throw(error(type_error(predicate_indicator, PI),
                sandbox_policy:check_declared_pi/1)).

check_mutable_pi((A,B)) :- !, check_mutable_pi(A), check_mutable_pi(B).
check_mutable_pi(PI) :-
    check_declared_pi(PI),
    PI = Name/Arity,
    ( safe_source_head_pi(Name/Arity) -> true
    ; throw_sandbox(modify, PI, reserved_head)
    ).

check_clause_head(Head) :-
    ( var(Head) -> throw(error(instantiation_error, sandbox_policy:check_clause_head/1))
    ; Head = _:_ -> throw_sandbox(clause, Head, qualified_head)
    ; callable(Head), functor(Head, Name, Arity),
      safe_source_head_pi(Name/Arity) -> true
    ; throw_sandbox(clause, Head, reserved_head)
    ).

safe_source_head_pi(Name/_Arity) :- atom(Name), \+ sub_atom(Name, 0, 1, _, '$'),
    \+ reserved_source_name(Name).

reserved_source_name('$actor_load').
reserved_source_name('$actor_call').
reserved_source_name('$actor_cleanup').
reserved_source_name(module).
reserved_source_name(initialization).
reserved_source_name(term_expansion).
reserved_source_name(goal_expansion).
reserved_source_name(sandbox_call).
reserved_source_name(sandbox_spawn).
reserved_source_name(sandbox_toplevel_call).
reserved_source_name(sandbox_assert).
reserved_source_name(sandbox_asserta).
reserved_source_name(sandbox_assertz).
reserved_source_name(sandbox_retract).
reserved_source_name(sandbox_retractall).
reserved_source_name(sandbox_abolish).

check_spawn_options([]).
check_spawn_options([node(Node)|Options]) :-
    loopback_node_url(Node),
    !,
    check_spawn_options(Options).
check_spawn_options([node(Node)|_]) :- !,
    throw(error(permission_error(option, sandboxed, node(Node)),
                context(sandbox_policy:sandbox_prepare_spawn/7,
                        'server-side remote spawn is disabled for public code'))).
check_spawn_options([_|Options]) :- check_spawn_options(Options).

loopback_node_url(Node0) :-
    source_text_atom(Node0, Node),
    member(Prefix, ['http://127.0.0.1:', 'https://127.0.0.1:',
                    'ws://127.0.0.1:', 'wss://127.0.0.1:',
                    'http://localhost:', 'https://localhost:',
                    'ws://localhost:', 'wss://localhost:']),
    atom_concat(Prefix, _, Node),
    !.


                 /*******************************
                 *        RUNTIME REWRITE        *
                 *******************************/

rewrite_goal(Mode, Profile, Module, AppPIs, Goal0, Goal) :-
    rewrite_goal_(Mode, Profile, Module, AppPIs, Goal0, Goal), !.
rewrite_goal(_, _, _, _, Goal, Goal).

rewrite_goal_(Mode, Profile, Module, AppPIs, Var,
              sandbox_policy:sandbox_call(Mode,Profile,Module,AppPIs,Var)) :- var(Var).
% Match the SWI actor I/O prelude without requiring Trealla to redefine a
% built-in predicate.  The stream-specific writeln/2 remains forbidden.
rewrite_goal_(_M,_P,_C,_A,writeln(Term),
              actors:terminal_output(Term,[source(io)])).
rewrite_goal_(M,P,C,A,(X0,Y0),(X,Y)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,Y0,Y).
rewrite_goal_(M,P,C,A,(X0;Y0),(X;Y)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,Y0,Y).
rewrite_goal_(M,P,C,A,(X0->Y0),(X->Y)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,Y0,Y).
rewrite_goal_(M,P,C,A,(\+X0),(\+X)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,receive(Q0),receive(Q)) :- rewrite_receive(M,P,C,A,Q0,Q).
rewrite_goal_(M,P,C,A,receive(Q0,O0),receive(Q,O)) :- rewrite_receive(M,P,C,A,Q0,Q), rewrite_receive_options(M,P,C,A,O0,O).
rewrite_goal_(M,P,C,A,spawn(X),sandbox_policy:sandbox_spawn(M,P,C,A,X,_,[])).
rewrite_goal_(M,P,C,A,spawn(X,Pid),sandbox_policy:sandbox_spawn(M,P,C,A,X,Pid,[])).
rewrite_goal_(M,P,C,A,spawn(X,Pid,O),sandbox_policy:sandbox_spawn(M,P,C,A,X,Pid,O)).
rewrite_goal_(M,P,C,A,toplevel_call(Pid,X),sandbox_policy:sandbox_toplevel_call(M,P,C,A,Pid,X,[])).
rewrite_goal_(M,P,C,A,toplevel_call(Pid,X,O),sandbox_policy:sandbox_toplevel_call(M,P,C,A,Pid,X,O)).
rewrite_goal_(M,P,C,A,once(X0),once(X)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,ignore(X0),ignore(X)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,catch(X0,E,H0),catch(X,E,H)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,H0,H).
rewrite_goal_(M,P,C,A,setup_call_cleanup(S0,X0,K0),setup_call_cleanup(S,X,K)) :- rewrite_goal(M,P,C,A,S0,S), rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,K0,K).
rewrite_goal_(M,P,C,A,call_cleanup(X0,K0),call_cleanup(X,K)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,K0,K).
rewrite_goal_(M,P,C,A,forall(X0,Y0),forall(X,Y)) :- rewrite_goal(M,P,C,A,X0,X), rewrite_goal(M,P,C,A,Y0,Y).
rewrite_goal_(M,P,C,A,findall(T,X0,B),findall(T,X,B)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,findnsols(N,T,X0,B),findnsols(N,T,X,B)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,bagof(T,X0,B),bagof(T,X,B)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,setof(T,X0,B),setof(T,X,B)) :- rewrite_goal(M,P,C,A,X0,X).
rewrite_goal_(M,P,C,A,call(X),sandbox_policy:sandbox_call(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,call(X,B),sandbox_policy:sandbox_call(M,P,C,A,X,B)).
rewrite_goal_(M,P,C,A,call(X,B,D),sandbox_policy:sandbox_call(M,P,C,A,X,B,D)).
rewrite_goal_(M,P,C,A,call(X,B,D,E),sandbox_policy:sandbox_call(M,P,C,A,X,B,D,E)).
rewrite_goal_(M,P,C,A,call(X,B,D,E,F),sandbox_policy:sandbox_call(M,P,C,A,X,B,D,E,F)).
rewrite_goal_(M,P,C,A,call(X,B,D,E,F,G),sandbox_policy:sandbox_call(M,P,C,A,X,B,D,E,F,G)).
rewrite_goal_(M,P,C,A,call(X,B,D,E,F,G,H),sandbox_policy:sandbox_call(M,P,C,A,X,B,D,E,F,G,H)).
rewrite_goal_(M,P,C,A,call(X,B,D,E,F,G,H,I),sandbox_policy:sandbox_call(M,P,C,A,X,B,D,E,F,G,H,I)).
rewrite_goal_(M,P,C,A,assert(X),sandbox_policy:sandbox_assert(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,assert(X,R),sandbox_policy:sandbox_assert(M,P,C,A,X,R)).
rewrite_goal_(M,P,C,A,asserta(X),sandbox_policy:sandbox_asserta(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,asserta(X,R),sandbox_policy:sandbox_asserta(M,P,C,A,X,R)).
rewrite_goal_(M,P,C,A,assertz(X),sandbox_policy:sandbox_assertz(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,assertz(X,R),sandbox_policy:sandbox_assertz(M,P,C,A,X,R)).
rewrite_goal_(M,P,C,A,retract(X),sandbox_policy:sandbox_retract(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,retractall(X),sandbox_policy:sandbox_retractall(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,abolish(X),sandbox_policy:sandbox_abolish(M,P,C,A,X)).
rewrite_goal_(M,P,C,A,abolish(N,R),sandbox_policy:sandbox_abolish(M,P,C,A,N,R)).

rewrite_receive(M,P,C,A,{Q0},{Q}) :- !, rewrite_receive_clauses(M,P,C,A,Q0,Q).
rewrite_receive(M,P,C,A,Q0,Q) :- rewrite_receive_clauses(M,P,C,A,Q0,Q).

rewrite_receive_clauses(M,P,C,A,(X0;Y0),(X;Y)) :- !,
    rewrite_receive_clauses(M,P,C,A,X0,X), rewrite_receive_clauses(M,P,C,A,Y0,Y).
rewrite_receive_clauses(M,P,C,A,(H0->B0),(H->B)) :- !,
    rewrite_receive_head(M,P,C,A,H0,H), rewrite_goal(M,P,C,A,B0,B).
rewrite_receive_clauses(_,_,_,_,Q,Q).

rewrite_receive_head(M,P,C,A,H0,H) :-
    nonvar(H0), H0 = if(Pattern,G0), !,
    H = if(Pattern,G),
    rewrite_goal(M,P,C,A,G0,G).
rewrite_receive_head(_,_,_,_,H,H).

rewrite_receive_options(_,_,_,_,Options,Options) :- var(Options), !.
rewrite_receive_options(M,P,C,A,Options0,Options) :-
    ( is_list(Options0) -> rewrite_receive_option_list(M,P,C,A,Options0,Options)
    ; Options = Options0 ).
rewrite_receive_option_list(_,_,_,_,[],[]).
rewrite_receive_option_list(M,P,C,A,[on_timeout(G0)|Os0],[on_timeout(G)|Os]) :- !,
    rewrite_goal(M,P,C,A,G0,G), rewrite_receive_option_list(M,P,C,A,Os0,Os).
rewrite_receive_option_list(M,P,C,A,[O|Os0],[O|Os]) :- rewrite_receive_option_list(M,P,C,A,Os0,Os).

sandbox_call(Mode,Profile,Module,AppPIs,Closure) :-
    guarded_call(Mode,Profile,Module,AppPIs,Closure,[]).
sandbox_call(M,P,C,A,X,B) :- guarded_call(M,P,C,A,X,[B]).
sandbox_call(M,P,C,A,X,B,D) :- guarded_call(M,P,C,A,X,[B,D]).
sandbox_call(M,P,C,A,X,B,D,E) :- guarded_call(M,P,C,A,X,[B,D,E]).
sandbox_call(M,P,C,A,X,B,D,E,F) :- guarded_call(M,P,C,A,X,[B,D,E,F]).
sandbox_call(M,P,C,A,X,B,D,E,F,G) :- guarded_call(M,P,C,A,X,[B,D,E,F,G]).
sandbox_call(M,P,C,A,X,B,D,E,F,G,H) :- guarded_call(M,P,C,A,X,[B,D,E,F,G,H]).
sandbox_call(M,P,C,A,X,B,D,E,F,G,H,I) :- guarded_call(M,P,C,A,X,[B,D,E,F,G,H,I]).

guarded_call(Mode, Profile, Module, AppPIs, Closure, Extra) :-
    must_be(callable, Closure),
    Closure =.. [Name|Args0], append(Args0, Extra, Args), Goal0 =.. [Name|Args],
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal0),
    rewrite_goal(Mode, Profile, Module, AppPIs, Goal0, Goal),
    call_in_context(Module, Goal).

sandbox_assert(M,P,C,A,Clause) :- guarded_assert(assertz,M,P,C,A,Clause).
sandbox_assert(M,P,C,A,Clause,Ref) :- guarded_assert_ref(assertz,M,P,C,A,Clause,Ref).
sandbox_asserta(M,P,C,A,Clause) :- guarded_assert(asserta,M,P,C,A,Clause).
sandbox_asserta(M,P,C,A,Clause,Ref) :- guarded_assert_ref(asserta,M,P,C,A,Clause,Ref).
sandbox_assertz(M,P,C,A,Clause) :- guarded_assert(assertz,M,P,C,A,Clause).
sandbox_assertz(M,P,C,A,Clause,Ref) :- guarded_assert_ref(assertz,M,P,C,A,Clause,Ref).

sandbox_retract(_Mode, _Profile, Module, _AppPIs, Head) :-
    check_clause_head(Head), context_module(Module, RuntimeModule),
    call(RuntimeModule:retract(Head)).

sandbox_retractall(_Mode, _Profile, Module, _AppPIs, Head) :-
    check_clause_head(Head), context_module(Module, RuntimeModule),
    call(RuntimeModule:retractall(Head)).

sandbox_abolish(_Mode, _Profile, Module, _AppPIs, PI) :-
    check_mutable_pi(PI), context_module(Module, RuntimeModule),
    call(RuntimeModule:abolish(PI)).

% Trealla's native abolish/2 takes an option list, unlike the ISO/SWI
% Name,Arity form exposed by the Web Prolog profile. Normalize that portable
% form to abolish/1 so it cannot escape the actor's private module.
sandbox_abolish(_Mode, _Profile, Module, _AppPIs, Name, Arity) :-
    check_mutable_pi(Name/Arity), context_module(Module, RuntimeModule),
    call(RuntimeModule:abolish(Name/Arity)).

sandbox_spawn(Mode, Profile, Module, _AppPIs, Goal0, Pid, Options0) :-
    context_module(Module, RuntimeModule),
    % Nested src_predicates/1 is resolved only at runtime, after the parent
    % session's submitted source has been installed in its private module.
    % Materialize it here before the public-source validator sees the option.
    isolation:rewrite_source_options(Options0, RuntimeModule, Options1),
    sandbox_prepare_spawn(Mode, Profile, Module, Goal0, Options1,
                          Goal, Options),
    actors:spawn(Goal, Pid, Options).

sandbox_toplevel_call(Mode, Profile, Module, AppPIs, Pid, Goal0, Options) :-
    profile_check_goal(Profile, Goal0),
    sandbox_check_goal_(Mode, Profile, Module, AppPIs, Goal0),
    rewrite_goal(Mode, Profile, Module, AppPIs, Goal0, Goal),
    toplevel_actors:toplevel_call(Pid, Goal, Options).

guarded_assert(Operation, Mode, Profile, Module, AppPIs, Clause0) :-
    check_asserted_clause_head(Clause0),
    ( Clause0 = (Head :- Body0)
    -> profile_check_goal(Profile, Body0),
       sandbox_check_goal_(Mode, Profile, Module, AppPIs, Body0),
       rewrite_goal(Mode, Profile, Module, AppPIs, Body0, Body), Clause = (Head :- Body)
    ; Clause = Clause0
    ),
    context_module(Module, RuntimeModule),
    Goal =.. [Operation, Clause], call(RuntimeModule:Goal).

guarded_assert_ref(Operation, Mode, Profile, Module, AppPIs, Clause0, Ref) :-
    check_asserted_clause_head(Clause0),
    ( Clause0 = (Head :- Body0)
    -> profile_check_goal(Profile, Body0),
       sandbox_check_goal_(Mode, Profile, Module, AppPIs, Body0),
       rewrite_goal(Mode, Profile, Module, AppPIs, Body0, Body), Clause = (Head :- Body)
    ; Clause = Clause0
    ),
    context_module(Module, RuntimeModule),
    Goal =.. [Operation, Clause, Ref], call(RuntimeModule:Goal).

call_in_context(Module, Goal) :- context_module(Module, RuntimeModule), call(RuntimeModule:Goal).

context_module(actor_context, Module) :- !,
    ( bb_get('$actor_source_module', Module) -> true
    ; throw(error(existence_error(actor_context, source_module), sandbox_policy))
    ).
context_module(Module, Module).


                 /*******************************
                 *       DENY/ALLOW TABLES       *
                 *******************************/

throw_sandbox(Action, Subject, Category) :-
    throw(error(permission_error(Action, sandboxed, Subject),
                context(sandbox_policy:sandbox_check_goal/4, Category))).

forbidden_goal(Goal, Category) :- callable(Goal), functor(Goal,N,A), forbidden_pi(N/A,Category).

forbidden_pi(open/3,stream_io). forbidden_pi(open/4,stream_io).
forbidden_pi(close/1,stream_io). forbidden_pi(close/2,stream_io).
forbidden_pi(current_input/1,stream_io). forbidden_pi(current_output/1,stream_io).
forbidden_pi(set_input/1,stream_io). forbidden_pi(set_output/1,stream_io).
forbidden_pi(get_byte/1,stream_io). forbidden_pi(get_byte/2,stream_io).
forbidden_pi(get_char/1,stream_io). forbidden_pi(get_char/2,stream_io).
forbidden_pi(get_code/1,stream_io). forbidden_pi(get_code/2,stream_io).
forbidden_pi(put_byte/1,stream_io). forbidden_pi(put_byte/2,stream_io).
forbidden_pi(put_char/1,stream_io). forbidden_pi(put_char/2,stream_io).
forbidden_pi(put_code/1,stream_io). forbidden_pi(put_code/2,stream_io).
forbidden_pi(read/1,stream_io). forbidden_pi(read/2,stream_io).
forbidden_pi(read_term/2,stream_io). forbidden_pi(read_term/3,stream_io).
forbidden_pi(write/1,stream_io). forbidden_pi(write/2,stream_io).
forbidden_pi(writeln/2,stream_io).
forbidden_pi(writeq/1,stream_io). forbidden_pi(writeq/2,stream_io).
forbidden_pi(write_term/2,stream_io). forbidden_pi(write_term/3,stream_io).
forbidden_pi(format/1,stream_io). forbidden_pi(format/2,stream_io). forbidden_pi(format/3,stream_io).
forbidden_pi(nl/0,stream_io). forbidden_pi(nl/1,stream_io).
forbidden_pi(consult/1,module_loading). forbidden_pi(reconsult/1,module_loading).
forbidden_pi((ensure_loaded)/1,module_loading). forbidden_pi(load_files/1,module_loading).
forbidden_pi(load_files/2,module_loading). forbidden_pi((use_module)/1,module_loading).
forbidden_pi((use_module)/2,module_loading). forbidden_pi(unload_file/1,module_loading).
forbidden_pi(halt/0,runtime_state). forbidden_pi(halt/1,runtime_state).
forbidden_pi(shell/1,process_execution). forbidden_pi(shell/2,process_execution).
forbidden_pi(system/1,process_execution). forbidden_pi(process_create/2,process_execution).
forbidden_pi(process_create/3,process_execution). forbidden_pi(process_kill/1,process_execution).
forbidden_pi(delete_file/1,filesystem). forbidden_pi(rename_file/2,filesystem).
forbidden_pi(make_directory/1,filesystem). forbidden_pi(delete_directory/1,filesystem).
forbidden_pi(directory_files/2,filesystem). forbidden_pi(working_directory/2,filesystem).
forbidden_pi(exists_file/1,filesystem). forbidden_pi(exists_directory/1,filesystem).
forbidden_pi(access_file/2,filesystem). forbidden_pi(read_file_to_string/3,filesystem).
forbidden_pi(getenv/2,environment). forbidden_pi(setenv/2,environment). forbidden_pi(unsetenv/1,environment).
forbidden_pi(socket_client_open/3,network). forbidden_pi(socket_server_open/3,network).
forbidden_pi(http_open/3,network). forbidden_pi(http_get/3,network). forbidden_pi(http_post/4,network).
forbidden_pi(load_foreign_library/1,foreign_code). forbidden_pi(load_foreign_library/2,foreign_code).
forbidden_pi(thread_create/3,threads). forbidden_pi(thread_send_message/2,threads).
forbidden_pi(thread_get_message/1,threads). forbidden_pi(thread_get_message/2,threads).
forbidden_pi(thread_get_message/3,threads). forbidden_pi(thread_signal/2,threads).
forbidden_pi(message_queue_create/1,threads). forbidden_pi(message_queue_create/2,threads).
forbidden_pi(message_queue_destroy/1,threads). forbidden_pi(mutex_create/2,threads).
forbidden_pi(mutex_lock/1,threads). forbidden_pi(mutex_unlock/1,threads).
forbidden_pi(with_mutex/2,threads). forbidden_pi(bb_put/2,runtime_state).
forbidden_pi(bb_get/2,runtime_reflection). forbidden_pi(bb_delete/1,runtime_state).
forbidden_pi(current_predicate/1,runtime_reflection). forbidden_pi(predicate_property/2,runtime_reflection).
forbidden_pi(current_prolog_flag/2,runtime_reflection). forbidden_pi(set_prolog_flag/2,runtime_state).
forbidden_pi(op/3,parser_state). forbidden_pi(char_conversion/2,parser_state).
forbidden_pi(clause/2,runtime_reflection). forbidden_pi(listing/0,runtime_reflection).
forbidden_pi(listing/1,runtime_reflection).

whitelist_goal(_Module, AppPIs, Goal) :-
    functor(Goal,N,A), (memberchk(N/A,AppPIs); safe_pi(N/A); actor_safe_pi(N/A)).

safe_pi(true/0). safe_pi(fail/0). safe_pi(repeat/0). safe_pi(!/0).
safe_pi((=)/2). safe_pi((\=)/2). safe_pi((==)/2). safe_pi((\==)/2).
safe_pi((@<)/2). safe_pi((@=<)/2). safe_pi((@>)/2). safe_pi((@>=)/2).
safe_pi(compare/3). safe_pi(var/1). safe_pi(nonvar/1). safe_pi(atom/1).
safe_pi(integer/1). safe_pi(float/1). safe_pi(number/1). safe_pi(atomic/1).
safe_pi(compound/1). safe_pi(callable/1). safe_pi(ground/1). safe_pi(acyclic_term/1).
safe_pi(functor/3). safe_pi(arg/3). safe_pi((=..)/2). safe_pi(copy_term/2).
safe_pi(numbervars/3). safe_pi(term_variables/2). safe_pi(term_hash/2).
safe_pi((is)/2). safe_pi((=:=)/2). safe_pi((=\=)/2). safe_pi((<)/2).
safe_pi((=<)/2). safe_pi((>)/2). safe_pi((>=)/2).
safe_pi(between/3). safe_pi(succ/2). safe_pi(length/2). safe_pi(member/2).
safe_pi(memberchk/2). safe_pi(append/3). safe_pi(reverse/2). safe_pi(select/3).
safe_pi(nth0/3). safe_pi(nth1/3). safe_pi(sort/2). safe_pi(msort/2). safe_pi(keysort/2).
safe_pi(atom_length/2). safe_pi(atom_concat/3). safe_pi(sub_atom/5).
safe_pi(atom_chars/2). safe_pi(atom_codes/2). safe_pi(char_code/2).
safe_pi(number_chars/2). safe_pi(number_codes/2). safe_pi(atom_number/2).
safe_pi(atomic_list_concat/2). safe_pi(atomic_list_concat/3).
safe_pi(read_term_from_atom/3). safe_pi(random_between/3). safe_pi(sleep/1).
safe_pi(call/1). safe_pi(call/2). safe_pi(call/3). safe_pi(call/4).
safe_pi(call/5). safe_pi(call/6). safe_pi(call/7). safe_pi(call/8).
safe_pi(once/1). safe_pi(ignore/1). safe_pi(catch/3). safe_pi(setup_call_cleanup/3).
safe_pi(call_cleanup/2). safe_pi(forall/2). safe_pi(findall/3). safe_pi(findnsols/4).
safe_pi(bagof/3). safe_pi(setof/3). safe_pi(time/1).
safe_pi(assert/1). safe_pi(assert/2). safe_pi(asserta/1). safe_pi(asserta/2).
safe_pi(assertz/1). safe_pi(assertz/2). safe_pi(retract/1). safe_pi(retractall/1).
safe_pi(abolish/1). safe_pi(abolish/2).

actor_safe_pi(self/1). actor_safe_pi(spawn/1). actor_safe_pi(spawn/2). actor_safe_pi(spawn/3).
actor_safe_pi(send/2). actor_safe_pi(send/3). actor_safe_pi(! / 2).
actor_safe_pi(receive/1). actor_safe_pi(receive/2). actor_safe_pi(monitor/2).
actor_safe_pi(demonitor/1). actor_safe_pi(demonitor/2). actor_safe_pi(exit/1).
actor_safe_pi(exit/2). actor_safe_pi(register/2). actor_safe_pi(whereis/2).
actor_safe_pi(unregister/1). actor_safe_pi(output/1). actor_safe_pi(output/2).
actor_safe_pi(writeln/1).
actor_safe_pi(input/2). actor_safe_pi(input/3). actor_safe_pi(respond/2).
actor_safe_pi(make_ref/1). actor_safe_pi(flush/0).
actor_safe_pi(toplevel_spawn/1). actor_safe_pi(toplevel_spawn/2).
actor_safe_pi(toplevel_call/2). actor_safe_pi(toplevel_call/3).
actor_safe_pi(toplevel_next/1). actor_safe_pi(toplevel_next/2).
actor_safe_pi(toplevel_stop/1). actor_safe_pi(toplevel_abort/1).
actor_safe_pi(parallel/1). actor_safe_pi(first_solution/2). actor_safe_pi(first_solution/3).

reject_format_meta_call(Format) :-
    source_text_atom(Format, Atom),
    ( sub_atom(Atom, _, 2, _, '~@')
    -> throw(error(permission_error(use, format_specifier, '~@'), format/3))
    ; true
    ).
