% SPDX-License-Identifier: MIT
:- module(receiver_lineage,
    [with_wire_context/5, ensure_open/1, check_actor/1,
     close_namespace/1, close_connection/1]).

% Receiver-side delegated lifetime only. Tokens are scoped to the accepted
% connection, never global capabilities. No downstream delegation is implied.
:- use_module(actors, []).
:- use_module(rpc, []).
:- use_module(auth_policy, [principal_has_capability/2]).
:- dynamic connection_lineage/2, connection_base/2, closed_connection/1.
:- meta_predicate with_wire_context(+, +, +, +, 0).

with_wire_context(JSON, Relay, Principal, Command, Goal) :-
    (web_prolog:json_field(JSON,lineage,Value) ->
        require_transport(Principal,Value),wire_token(Value,Token),
        (web_prolog:json_field(JSON,account,Account) -> wire_token(Account,_) ; true),
        Namespace=ws_lineage(Relay,Token),
        with_mutex('$actor_registry',
            (ensure_connection_open(Relay),
             (Command==lineage_close -> true ; actors:ensure_registry_namespace_open(Namespace)),
             remember_connection_base(Relay),
             (connection_lineage(Relay,Namespace) -> true
             ; assertz(connection_lineage(Relay,Namespace))))),
        actors:with_actor_namespace(Namespace,once(Goal))
    ; Command==lineage_close ->
        require_transport(Principal,lineage_close),
        throw(error(existence_error(field,lineage),lineage_close))
    ; once(Goal)).

require_transport(Principal,Value) :-
    (principal_has_capability(Principal,internal_transport) -> true
    ; throw(error(permission_error(use,transport_lineage,Value),receiver_lineage))).

wire_token(string(Chars),Token) :-
    is_list(Chars),length(Chars,32),hex_chars(Chars),!,atom_chars(Token,Chars).
wire_token(Value,_) :- throw(error(domain_error(transport_lineage,Value),receiver_lineage)).
hex_chars([]).
hex_chars([C|Cs]) :- char_code(C,Code),
    (Code>=48,Code=<57 ; Code>=65,Code=<70 ; Code>=97,Code=<102),!,hex_chars(Cs).

ensure_connection_open(Relay) :-
    (closed_connection(Relay) ->
        throw(error(permission_error(use,closed_connection,Relay),receiver_lineage))
    ; true).
ensure_open(Namespace) :-
    with_mutex('$actor_registry',actors:ensure_registry_namespace_open(Namespace)).

check_actor(Pid) :-
    actors:current_actor_namespace(Namespace),
    (Namespace=ws_lineage(_,_) -> actors:actor_namespace(Pid,Namespace)
    ; \+ actors:actor_namespace(Pid,ws_lineage(_,_))).

close_namespace(Namespace) :-
    Namespace=ws_lineage(_,_),ground(Namespace),
    % Closing registry admission shares the spawn mutex. Every successful
    % reservation is now in the snapshot; later descendant spawns are denied.
    actors:retire_registry_namespace(Namespace),
    setup_call_cleanup(true,rpc:dispose_namespace_promises(Namespace),
        receiver_lineage:stop_namespace_actors(Namespace)).

stop_namespace_actors(Namespace) :-
    with_mutex('$actor_registry',
        findall(Pid,(actors:actor_namespace(Pid,Namespace),\+ actors:lineage_preparing(Pid)),Pids)),
    stop_actors(Pids).
stop_actors([]).
stop_actors([Pid|Pids]) :-
    catch(actors:exit(Pid,kill),_,true),stop_actors(Pids).

remember_connection_base(Relay) :-
    (connection_base(Relay,_) -> true
    ; actors:actor_namespace(Relay,Base) -> assertz(connection_base(Relay,Base))
    ; true).

close_connection(Base) :-
    with_mutex('$actor_registry',findall(Relay,connection_base(Relay,Base),Relays)),
    close_relays(Relays).
close_relays([]).
close_relays([Relay|Relays]) :-
    with_mutex('$actor_registry',
        ((closed_connection(Relay) -> true ; assertz(closed_connection(Relay))),
         findall(NS,connection_lineage(Relay,NS),Namespaces))),
    close_namespaces(Namespaces),close_relays(Relays).
close_namespaces([]).
close_namespaces([NS|Namespaces]) :-
    setup_call_cleanup(true,close_namespace(NS),close_namespaces(Namespaces)).
