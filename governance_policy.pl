% SPDX-License-Identifier: MIT

:- module(governance_policy,
    [ configure_governance_policy/2,
      reset_governance_policy/0,
      current_governance_policy/1,
      quota_identity/4,
      enforce_call_request_rate_limit/2,
      enforce_session_spawn_rate_limit/2,
      enforce_ws_command_rate_limit/3,
      with_inflight_call_limit/3,
      reserve_ws_actor_capacity/3,
      commit_ws_actor_capacity/2,
      release_capacity_reservation/1,
      forget_ws_actor_owner/1,
      forget_ws_actor_owners/1
    ]).

/** <module> Per-principal rate and concurrency governance

Fixed-window request limits and atomic concurrency reservations for the
public execution surfaces.  This layer is intentionally separate from
authentication, profiles, sandboxing, and absolute process resource limits.
Authenticated principals share a quota across their connections. Anonymous
HTTP traffic is grouped by immediate peer address; each anonymous WebSocket
gets a private connection identity.
*/

:- use_module(actors, [make_ref/1]).
:- use_module(auth_policy, [principal_id/2, principal_has_capability/2]).

:- dynamic active_governance_policy/1.
:- dynamic rate_bucket/4.
:- dynamic capacity_reservation/4.
:- dynamic capacity_resource/3.

:- meta_predicate with_inflight_call_limit(+, +, 0).

:- catch(mutex_create(_, [alias('$node_governance')]),
         error(permission_error(create, mutex, '$node_governance'), _),
         true).

default_governance_policy(
    governance_policy(60, 500, 100, 1000, 4, 16)).

reset_governance_policy :-
    default_governance_policy(Policy),
    retractall(active_governance_policy(_)),
    assertz(active_governance_policy(Policy)),
    retractall(rate_bucket(_, _, _, _)),
    retractall(capacity_reservation(_, _, _, _)),
    retractall(capacity_resource(_, _, _)).

current_governance_policy(Policy) :-
    active_governance_policy(Policy), !.
current_governance_policy(Policy) :-
    default_governance_policy(Policy).

configure_governance_policy(Options, Policy) :-
    default_governance_policy(
        governance_policy(DWindow,DCall,DSpawn,DWS,DInflight,DActors)),
    option(rate_window_seconds(Window0), Options, DWindow),
    option(max_call_requests_per_window(Call0), Options, DCall),
    option(max_session_spawns_per_window(Spawn0), Options, DSpawn),
    option(max_ws_commands_per_window(WS0), Options, DWS),
    option(max_inflight_calls(Inflight0), Options, DInflight),
    option(max_ws_actors_per_principal(Actors0), Options, DActors),
    normalize_positive(rate_window_seconds, Window0, Window),
    normalize_limit(max_call_requests_per_window, Call0, Call),
    normalize_limit(max_session_spawns_per_window, Spawn0, Spawn),
    normalize_limit(max_ws_commands_per_window, WS0, WS),
    normalize_limit(max_inflight_calls, Inflight0, Inflight),
    normalize_limit(max_ws_actors_per_principal, Actors0, Actors),
    Policy = governance_policy(Window,Call,Spawn,WS,Inflight,Actors),
    retractall(active_governance_policy(_)),
    assertz(active_governance_policy(Policy)),
    retractall(rate_bucket(_, _, _, _)),
    retractall(capacity_reservation(_, _, _, _)),
    retractall(capacity_resource(_, _, _)).

normalize_positive(_, Value, Value) :- integer(Value), Value > 0, !.
normalize_positive(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                governance_policy:configure_governance_policy/2)).

normalize_limit(_, unlimited, unlimited) :- !.
normalize_limit(Name, Value, Value) :-
    normalize_positive(Name, Value, Value).

%! quota_identity(+Principal, +Peer, +Transport, -Identity) is det.

quota_identity(Principal, _, _, Identity) :-
    principal_id(Principal, Identity), Identity \== anonymous, !.
quota_identity(_, Peer, http, anon(PeerId)) :- !,
    peer_identity(Peer, PeerId).
quota_identity(_, _, websocket, anon_ws(Ref)) :-
    make_ref(Ref).

peer_identity(Host:_, Identity) :- !, peer_identity(Host, Identity).
peer_identity(ip(A,B,C,D), Identity) :- !,
    format(atom(Identity), '~w.~w.~w.~w', [A,B,C,D]).
peer_identity(Peer, Peer).

enforce_call_request_rate_limit(Principal, Identity) :-
    enforce_rate_limit(Principal, Identity, call_request).

enforce_session_spawn_rate_limit(Principal, Identity) :-
    enforce_rate_limit(Principal, Identity, session_spawn).

enforce_ws_command_rate_limit(Principal, Identity, _Command) :-
    enforce_rate_limit(Principal, Identity, ws_command).

enforce_rate_limit(Principal, _, _) :- quota_exempt(Principal), !.
enforce_rate_limit(_, Identity, Kind) :-
    current_governance_policy(Policy),
    rate_spec(Kind, Policy, Limit, Resource),
    ( Limit == unlimited -> true
    ; Policy = governance_policy(Window,_,_,_,_,_),
      get_time(Now), WindowId is floor(Now / Window),
      with_mutex('$node_governance',
                 increment_rate_bucket(Kind, Identity, WindowId, Limit,
                                       Resource, Window))
    ).

rate_spec(call_request, governance_policy(_,Limit,_,_,_,_),
          Limit, call_requests).
rate_spec(session_spawn, governance_policy(_,_,Limit,_,_,_),
          Limit, session_spawns).
rate_spec(ws_command, governance_policy(_,_,_,Limit,_,_),
          Limit, ws_commands).

increment_rate_bucket(Kind, Identity, WindowId, Limit, Resource, Window) :-
    retract_old_windows(WindowId),
    retractall_old_buckets(Kind, Identity, WindowId),
    ( retract(rate_bucket(Kind, Identity, WindowId, Count0)) -> true
    ; Count0 = 0
    ),
    Count is Count0 + 1,
    ( Count =< Limit
    -> assertz(rate_bucket(Kind, Identity, WindowId, Count))
    ; assertz(rate_bucket(Kind, Identity, WindowId, Count0)),
      throw(error(rate_limit_exceeded(Identity, Resource, Limit, Window),
                  context(governance_policy,
                          'principal request rate limit exceeded')))
    ).

retract_old_windows(WindowId) :-
    ( rate_bucket(Kind, Identity, OtherWindow, Count),
      OtherWindow =\= WindowId,
      retract(rate_bucket(Kind, Identity, OtherWindow, Count)),
      fail
    ; true
    ).

retractall_old_buckets(Kind, Identity, WindowId) :-
    ( rate_bucket(Kind, Identity, OtherWindow, _),
      OtherWindow =\= WindowId,
      retract(rate_bucket(Kind, Identity, OtherWindow, _)),
      fail
    ; true
    ).

with_inflight_call_limit(Principal, Identity, Goal) :-
    reserve_capacity(Principal, Identity, inflight_call, Reservation),
    setup_call_cleanup(true, Goal, release_capacity_reservation(Reservation)).

reserve_ws_actor_capacity(Principal, Identity, Reservation) :-
    reserve_capacity(Principal, Identity, ws_actor, Reservation).

reserve_capacity(Principal, _, _, none) :- quota_exempt(Principal), !.
reserve_capacity(_, Identity, Kind, reservation(Kind, Token)) :-
    current_governance_policy(Policy),
    capacity_spec(Kind, Policy, Limit, Resource),
    ( Limit == unlimited -> Token = none
    ; with_mutex('$node_governance',
          reserve_capacity_locked(Kind, Identity, Limit, Resource, Token))
    ).

capacity_spec(inflight_call, governance_policy(_,_,_,_,Limit,_),
              Limit, inflight_calls).
capacity_spec(ws_actor, governance_policy(_,_,_,_,_,Limit),
              Limit, ws_actors).

reserve_capacity_locked(Kind, Identity, Limit, Resource, Token) :-
    findall(T, capacity_reservation(Kind, Identity, T, _), Reservations),
    findall(P, capacity_resource(Kind, Identity, P), Resources),
    length(Reservations, Reserved), length(Resources, Active),
    Count is Reserved + Active,
    ( Count < Limit
    -> make_ref(Token), thread_self(Owner),
       assertz(capacity_reservation(Kind, Identity, Token, Owner))
    ; throw(error(resource_limit_exceeded(Identity, Resource, Limit),
                  context(governance_policy,
                          'principal concurrency limit reached')))
    ).

commit_ws_actor_capacity(none, _) :- !.
commit_ws_actor_capacity(reservation(ws_actor, none), _) :- !.
commit_ws_actor_capacity(reservation(ws_actor, Token), Pid) :-
    with_mutex('$node_governance',
        ( retract(capacity_reservation(ws_actor, Identity, Token, _))
        -> assertz(capacity_resource(ws_actor, Identity, Pid))
        ; true
        )).

release_capacity_reservation(none) :- !.
release_capacity_reservation(reservation(_, none)) :- !.
release_capacity_reservation(reservation(Kind, Token)) :-
    with_mutex('$node_governance',
               retractall(capacity_reservation(Kind, _, Token, _))).

forget_ws_actor_owner(Pid) :-
    with_mutex('$node_governance',
               retractall(capacity_resource(ws_actor, _, Pid))).

forget_ws_actor_owners([]).
forget_ws_actor_owners([actor(_, Pid, _)|Actors]) :-
    forget_ws_actor_owner(Pid),
    forget_ws_actor_owners(Actors).

quota_exempt(Principal) :-
    principal_has_capability(Principal, admin), !.
quota_exempt(Principal) :-
    principal_has_capability(Principal, internal_transport).

:- initialization(reset_governance_policy).
