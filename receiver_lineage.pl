% SPDX-License-Identifier: MIT
:- module(receiver_lineage,
    [with_wire_context/5, ensure_open/1, check_actor/1,
     close_namespace/1, close_connection/1, open_client_namespace/2,
     transport_fields/1, configure_transport/1, transport_options/2]).

% Native retained contexts span authenticated transport attachments.
% Legacy lineage-only peers retain connection-scoped delegation.
:- use_module(actors, []).
:- use_module(rpc, []).
:- use_module(actor_authority, []).
:- use_module(auth_policy, [principal_has_capability/2, principal_id/2]).
:- use_module(crypto_portable, [secure_random_bytes/2, bytes_hex/2]).
:- dynamic connection_lineage/2, connection_base/2, closed_connection/1,
    context_binding/4, context_default/4, namespace_principal/2,
    principal_account/2, peer_transport_token/2.
:- meta_predicate with_wire_context(+, +, +, +, 0).

% Context ids are minted at the client origin. Only authenticated node
% transports may carry them; the connection is merely an attachment.
open_client_namespace(NS, Principal) :-
    principal_id(Principal, Id),
    with_mutex('$actor_registry',
        (namespace_principal(NS,_) -> true ; assertz(namespace_principal(NS,Id)))).

fresh_token(Token) :- secure_random_bytes(16,Bytes),bytes_hex(Bytes,Token).

transport_fields(Fields) :-
    actors:current_actor_namespace(NS),NS \== none,!,
    with_mutex('$actor_registry',
        (actors:ensure_registry_namespace_open(NS),
         (context_binding(Origin,Token,NS,Account) -> true
         ; web_prolog:current_node_url(Origin),fresh_token(Token),
           (namespace_principal(NS,Id) -> true ; Id=anonymous(NS)),
           (principal_account(Id,Account) -> true
           ;fresh_token(Account),assertz(principal_account(Id,Account))),
           assertz(context_binding(Origin,Token,NS,Account))))),
    Fields=[lineage-string_atom(Token),account-string_atom(Account),
            context_origin-string_atom(Origin),context_default-boolean(true)].
transport_fields([]).

configure_transport(Options) :-
    (memberchk(peer_transport_tokens(Pairs),Options) -> true ; Pairs=[]),
    (is_list(Pairs),ground(Pairs),maplist(validate_peer,Pairs) -> true
    ;throw(error(domain_error(peer_transport_tokens,redacted),receiver_lineage))),
    retractall(peer_transport_token(_,_)),
    forall(member(URL-Token,Pairs),assertz(peer_transport_token(URL,Token))).
validate_peer(URL-Token) :-
    atom(URL),atom(Token),
    (sub_atom(URL,0,7,_,'http://');sub_atom(URL,0,8,_,'https://')),
    \+ sub_atom(Token,_,_,_,'\r'),\+ sub_atom(Token,_,_,_,'\n').
transport_options(URL,[header('Authorization',Bearer)]) :-
    peer_transport_token(URL,Token),format(atom(Bearer),'Bearer ~w',[Token]).
transport_options(_,[]).

with_wire_context(JSON, Relay, Principal, Command, Goal) :-
    (web_prolog:json_field(JSON,lineage,Value) ->
        require_transport(Principal,Value),wire_token(Value,Token),
        (web_prolog:json_field(JSON,account,Account0) -> wire_token(Account0,Account) ; Account=Token),
        (web_prolog:json_field(JSON,context_origin,Origin0) ->
            wire_origin(Origin0,Origin),
            with_mutex('$actor_registry',
                (resolve_context(Origin,Token,Account,Relay,Command,NS),
                 bind_default(JSON,Relay,Origin,Token,Account)))
        ; NS=ws_lineage(Relay,Token),
          with_mutex('$actor_registry',remember_attachment(Relay,NS,Command))),
        actors:with_actor_namespace(NS,actor_authority:with_transport_authority(once(Goal)))
    ; context_default(Relay,Origin,Token,Account) ->
        require_transport(Principal,Token),
        with_mutex('$actor_registry',resolve_context(Origin,Token,Account,Relay,Command,NS)),
        actors:with_actor_namespace(NS,actor_authority:with_transport_authority(once(Goal)))
    ; Command==lineage_close ->
        require_transport(Principal,lineage_close),
        throw(error(existence_error(field,lineage),lineage_close))
    ; actors:actor_namespace(Relay,Base) -> actors:with_actor_namespace(Base,once(Goal))
    ; once(Goal)).

wire_origin(string(Chars),Origin) :-
    atom_chars(Origin,Chars),
    (sub_atom(Origin,0,7,_,'http://');sub_atom(Origin,0,8,_,'https://')),!.
wire_origin(Value,_) :- throw(error(domain_error(transport_context_origin,Value),receiver_lineage)).

resolve_context(Origin,Token,Account,Relay,Command,NS) :-
    ensure_connection_open(Relay),
    (context_binding(Origin,Token,Known,StoredAccount) ->
        (StoredAccount==Account -> NS=Known
        ;throw(error(permission_error(rebind,client_account,Token),receiver_lineage)))
    ; web_prolog:current_node_url(Local),Origin==Local ->
        throw(error(permission_error(use,closed_client_context,Token),receiver_lineage))
    ; fresh_token(Id),NS=delegated_context(Id),
      assertz(context_binding(Origin,Token,NS,Account))),
    remember_attachment(Relay,NS,Command).

remember_attachment(Relay,NS,Command) :-
    ensure_connection_open(Relay),
    (Command==lineage_close -> true ; actors:ensure_registry_namespace_open(NS)),
    remember_connection_base(Relay),
    (connection_lineage(Relay,NS) -> true ; assertz(connection_lineage(Relay,NS))).

bind_default(JSON,Relay,Origin,Token,Account) :-
    (web_prolog:json_field(JSON,context_default,boolean(true)) ->
        (context_default(Relay,O,T,A) ->
            (O-T-A==Origin-Token-Account -> true
            ;throw(error(permission_error(rebind,client_context,Relay),receiver_lineage)))
        ;assertz(context_default(Relay,Origin,Token,Account)))
    ;true).

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
    actors:current_actor_namespace(NS),
    (NS=ws_lineage(_,_) -> actors:actor_namespace(Pid,NS)
    ;NS=delegated_context(_) -> actors:actor_namespace(Pid,NS)
    ; \+ actors:actor_namespace(Pid,ws_lineage(_,_)),
      \+ actors:actor_namespace(Pid,delegated_context(_))).

close_namespace(NS) :-
    ground(NS),
    (NS=ws_lineage(_,_);NS=delegated_context(_)),!,
    with_mutex('$actor_registry',retire_namespace_locked(NS)),
    finish_namespace_close(NS).
% A returning transport must never retire the original client context.
close_namespace(_).

retire_namespace_locked(NS) :- actors:retire_registry_namespace(NS).
finish_namespace_close(NS) :-
    setup_call_cleanup(true,rpc:dispose_namespace_promises(NS),
        (close_outgoing(NS),receiver_lineage:stop_namespace_actors(NS))).

close_outgoing(NS) :-
    forall(hook_context_closed(NS),true).
:- multifile hook_context_closed/1.

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
    close_outgoing(Base),
    with_mutex('$actor_registry',
        (findall(Relay,connection_base(Relay,Base),Relays),
         retractall(context_binding(_,_,Base,_)),
         retractall(namespace_principal(Base,_)))),
    close_relays(Relays).
close_relays([]).
close_relays([Relay|Relays]) :-
    with_mutex('$actor_registry',
        ((closed_connection(Relay) -> true ; assertz(closed_connection(Relay))),
         findall(NS,retract(connection_lineage(Relay,NS)),Namespaces),
         retractall(context_default(Relay,_,_,_)),
         retractall(connection_base(Relay,_)))),
    close_namespaces(Namespaces),close_relays(Relays).
close_namespaces([]).
close_namespaces([NS|Namespaces]) :-
    close_unattached_namespace(NS),close_namespaces(Namespaces).

close_unattached_namespace(NS) :-
    with_mutex('$actor_registry',
        ((NS=ws_lineage(_,_);NS=delegated_context(_)),
         \+ connection_lineage(_,NS)
        -> retire_namespace_locked(NS),Retired=true
        ;Retired=false)),
    (Retired==true
    -> setup_call_cleanup(true,finish_namespace_close(NS),
           with_mutex('$actor_registry',
               (NS=delegated_context(_) -> retractall(context_binding(_,_,NS,_));true)))
    ;true).

% Authenticated delegated attachments may address native local pids for open
% language sends. Browser connections retain their relay capability mapping.
transport_connection(Relay) :- connection_lineage(Relay,_).
