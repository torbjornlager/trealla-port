% SPDX-License-Identifier: MIT
:- module(actor_authority, [check_exit/1, open_namespace/2, close_namespace/1]).

% Ownership policy for public hosted actors. The core calls a policy hook
% before either local termination or distribution routing. Trusted unscoped
% callers retain the standalone library API. A connection/account identifier
% is not an exit capability for actors in another client namespace.
:- use_module(actors, []).
:- use_module(auth_policy, [principal_has_capability/2]).
:- multifile actors:hook_check_exit/1.
actors:hook_check_exit(Pid) :- actor_authority:check_exit(Pid).
:- dynamic owner_namespace/1, closed_owner_namespace/1.
:- op(200, xfx, @).

open_namespace(Namespace, Principal) :-
    (principal_has_capability(Principal, admin) ->
        with_mutex('$actor_registry', assertz(owner_namespace(Namespace)))
    ; true).

close_namespace(Namespace) :-
    with_mutex('$actor_registry',
        (owner_namespace(Namespace) ->
            assertz(closed_owner_namespace(Namespace)), prune_closed_owners
        ; true)).

% Cached HTTP producers may outlive their request; preserve their authority
% until their final actor retires. The authority table never authorizes an
% ordinary namespace, even when it has the same principal/account name.
prune_closed_owners :-
    forall((closed_owner_namespace(Namespace),
            \+ actors:actor_namespace(_,Namespace)),
           (retractall(owner_namespace(Namespace)),
            retractall(closed_owner_namespace(Namespace)))).

:- multifile actors:hook_stop/1.
actors:hook_stop(_) :-
    with_mutex('$actor_registry', actor_authority:prune_closed_owners).

check_exit(Pid) :-
    actors:current_actor_namespace(Namespace),
    (Namespace == none -> true
    ; namespace_owner(Namespace) -> true
    ; owned_target(Namespace, Pid) -> true
    ; actors:logical_pid(Pid), \+ actors:actor_thread(Pid,_),
      \+ actors:actor_namespace(Pid,_) -> true
    ; throw(error(permission_error(exit,actor,Pid),
                  context(actors:exit/2,'target is outside the caller ownership tree')))).

namespace_owner(Namespace) :- owner_namespace(Namespace), !.
namespace_owner(ws_lineage(Relay,_)) :-
    actors:actor_namespace(Relay,Base), owner_namespace(Base).

owned_target(Namespace, Pid) :-
    actors:actor_namespace(Pid,Namespace), !.
% Remote linked work belongs to its local parent's client scope. Distribution
% still performs the receiver-side command check; a known route alone does
% not authorize a different local namespace to use that route for exit.
owned_target(Namespace, Pid) :-
    nonvar(Pid), Pid = _@_,
    actors:link(Parent,Pid), actors:actor_namespace(Parent,Namespace), !.
