% SPDX-License-Identifier: MIT

:- module(auth_policy,
    [ configure_auth_policy/2,
      reset_auth_policy/0,
      normalize_auth_mode/2,
      current_auth_mode/1,
      request_principal/3,
      principal_id/2,
      principal_has_capability/2,
      require_route_access/2,
      ws_require_allowed_origin/2
    ]).

/** <module> Native node authentication and WebSocket origin policy

This module is the small Trealla-native counterpart of Trinity's node_auth
boundary.  Authentication, execution profile, sandboxing, ownership, and
resource governance deliberately remain separate checks.

The default `auth(open)` preserves the historical public-node behaviour.
`auth(private)` requires an authenticated principal for `/call` and `/ws`.
`auth(dev)` grants the configured development principal only to a direct
loopback peer.  Bearer credentials can be supplied at startup with
`bearer_token(Id, Token, Capabilities)`; plaintext tokens are retained only
in memory and are never sent over the protocol or written by this module.

Trusted identity headers follow Trinity's security boundary: they are
honoured only from loopback or a private-network TCP peer.  In particular,
an `X-Web-Prolog-User: node:...` identity may claim `internal_transport` for
native node-to-node connections on such a network.
*/

:- dynamic auth_configuration/1.

default_auth_configuration(
    auth_config(open, dev, [execute], [], [], [], [], http)).

%! configure_auth_policy(+Options, -Configuration) is det.

configure_auth_policy(Options, Configuration) :-
    option(auth(Mode0), Options, open),
    normalize_auth_mode(Mode0, Mode),
    option(dev_principal(DevId0), Options, dev),
    normalize_nonempty_atom(dev_principal, DevId0, DevId),
    option(dev_capabilities(DevCaps0), Options, [execute]),
    normalize_capabilities(DevCaps0, DevCaps),
    option(authenticated_default_capabilities(DefaultCaps0), Options, []),
    normalize_capabilities(DefaultCaps0, DefaultCaps1),
    remove_privileged_defaults(DefaultCaps1, DefaultCaps),
    collect_principals(Options, Principals),
    collect_bearer_tokens(Options, Tokens),
    option(ws_allowed_origins(Origins0), Options, []),
    normalize_origins(Origins0, Origins),
    ( memberchk(ssl(true), Options) -> Scheme = https ; Scheme = http ),
    Configuration = auth_config(Mode, DevId, DevCaps, DefaultCaps,
                                Principals, Tokens, Origins, Scheme),
    retractall(auth_configuration(_)),
    asserta(auth_configuration(Configuration)).

reset_auth_policy :-
    default_auth_configuration(Configuration),
    retractall(auth_configuration(_)),
    asserta(auth_configuration(Configuration)).

current_configuration(Configuration) :-
    ( auth_configuration(Configuration) -> true
    ; default_auth_configuration(Configuration)
    ).

current_auth_mode(Mode) :-
    current_configuration(auth_config(Mode, _, _, _, _, _, _, _)).

normalize_auth_mode(off, open) :- !.
normalize_auth_mode(public, open) :- !.
normalize_auth_mode(development, dev) :- !.
normalize_auth_mode(Mode, Mode) :-
    memberchk(Mode, [open, private, dev]), !.
normalize_auth_mode(Mode, _) :-
    throw(error(domain_error(node_auth_mode, Mode),
                context(auth_policy:normalize_auth_mode/2,
                        'auth mode must be open, private, or dev'))).

collect_principals([], []).
collect_principals([principal(Id0, Caps0)|Options],
                   [principal(Id, Caps)|Principals]) :- !,
    normalize_nonempty_atom(principal, Id0, Id),
    normalize_capabilities(Caps0, Caps),
    collect_principals(Options, Principals).
collect_principals([_|Options], Principals) :-
    collect_principals(Options, Principals).

collect_bearer_tokens([], []).
collect_bearer_tokens([bearer_token(Id0, Token0, Caps0)|Options],
                      [token(Id, Token, Caps)|Tokens]) :- !,
    normalize_nonempty_atom(principal, Id0, Id),
    normalize_nonempty_atom(bearer_token, Token0, Token),
    normalize_capabilities(Caps0, Caps),
    collect_bearer_tokens(Options, Tokens).
collect_bearer_tokens([bearer_token(Id0, Token0)|Options],
                      [token(Id, Token, [execute])|Tokens]) :- !,
    normalize_nonempty_atom(principal, Id0, Id),
    normalize_nonempty_atom(bearer_token, Token0, Token),
    collect_bearer_tokens(Options, Tokens).
collect_bearer_tokens([_|Options], Tokens) :-
    collect_bearer_tokens(Options, Tokens).

normalize_nonempty_atom(_, Value, Atom) :-
    text_atom(Value, Atom), Atom \== '', !.
normalize_nonempty_atom(Kind, Value, _) :-
    throw(error(domain_error(Kind, Value),
                context(auth_policy:configure_auth_policy/2,
                        'value must be non-empty text'))).

normalize_capabilities(Capabilities0, Capabilities) :-
    ( is_list(Capabilities0) -> true
    ; throw(error(type_error(list, Capabilities0),
                  auth_policy:configure_auth_policy/2))
    ),
    normalize_capability_list(Capabilities0, Capabilities1),
    sort(Capabilities1, Capabilities).

normalize_capability_list([], []).
normalize_capability_list([Capability0|Capabilities0],
                          [Capability|Capabilities]) :-
    text_atom(Capability0, Capability),
    ( memberchk(Capability, [public_read, execute, admin,
                            internal_transport]) -> true
    ; throw(error(domain_error(node_capability, Capability0),
                  auth_policy:configure_auth_policy/2))
    ),
    normalize_capability_list(Capabilities0, Capabilities).

remove_privileged_defaults([], []).
remove_privileged_defaults([Capability|Capabilities], Rest) :-
    ( memberchk(Capability, [admin, internal_transport]) -> Rest = Tail
    ; Rest = [Capability|Tail]
    ),
    remove_privileged_defaults(Capabilities, Tail).

normalize_origins(Origins0, Origins) :-
    ( is_list(Origins0) -> true
    ; throw(error(type_error(list, Origins0),
                  auth_policy:configure_auth_policy/2))
    ),
    normalize_origin_list(Origins0, Origins).

normalize_origin_list([], []).
normalize_origin_list([Origin0|Origins0], [Origin|Origins]) :-
    normalize_origin(Origin0, Origin),
    normalize_origin_list(Origins0, Origins).

%! request_principal(+Peer, +Headers, -Principal) is det.

request_principal(Peer, Headers, Principal) :-
    current_configuration(auth_config(Mode, DevId, DevCaps, DefaultCaps,
                                      Principals, Tokens, _, _)),
    ( bearer_principal(Headers, Tokens, Principal0) -> Principal = Principal0
    ; header_principal(Peer, Headers, Principals, DefaultCaps, Principal1)
    -> Principal = Principal1
    ; Mode == dev, peer_is_loopback(Peer)
    -> Principal = principal(DevId, DevCaps)
    ; anonymous_capabilities(Mode, Caps), Principal = anonymous(Caps)
    ).

bearer_principal(Headers, Tokens, principal(Id, Capabilities)) :-
    memberchk(authorization-Header, Headers),
    bearer_header_token(Header, Token),
    member(token(Id, Stored, Capabilities), Tokens),
    Token == Stored, !.

bearer_header_token(Header0, Token) :-
    text_atom(Header0, Header),
    atom_codes(Header, Codes0), trim_codes(Codes0, Codes),
    take_word(Codes, SchemeCodes, Rest0),
    drop_space(Rest0, TokenCodes), TokenCodes \== [],
    atom_codes(Scheme0, SchemeCodes), downcase_atom_codes(Scheme0, Scheme),
    Scheme == bearer,
    atom_codes(Token, TokenCodes).

take_word([], [], []).
take_word([C|Cs], [], [C|Cs]) :- code_space(C), !.
take_word([C|Cs], [C|Word], Rest) :- take_word(Cs, Word, Rest).

header_principal(Peer, Headers, Principals, DefaultCaps, Principal) :-
    peer_is_private(Peer),
    header_first(Headers,
                 ['x-web-prolog-user', 'x-web-prolog-principal',
                  'x-authenticated-user'], Id0),
    normalize_nonempty_atom(principal, Id0, Id),
    ( atom_concat('node:', _, Id),
      header_capabilities(Headers, HeaderCaps),
      memberchk(internal_transport, HeaderCaps)
    -> add_public_read(HeaderCaps, Caps), Principal = principal(Id, Caps)
    ; memberchk(principal(Id, Caps), Principals)
    -> Principal = principal(Id, Caps)
    ; DefaultCaps \== []
    -> Principal = principal(Id, DefaultCaps)
    ; Principal = unknown(Id)
    ).

header_first(Headers, [Name|_], Value) :- memberchk(Name-Value, Headers), !.
header_first(Headers, [_|Names], Value) :- header_first(Headers, Names, Value).

header_capabilities(Headers, Capabilities) :-
    header_first(Headers, ['x-web-prolog-capabilities',
                           'x-web-prolog-caps'], Value),
    text_atom(Value, Atom), atomic_list_concat(Parts0, ',', Atom),
    trim_atom_list(Parts0, Parts),
    normalize_capabilities(Parts, Capabilities).

trim_atom_list([], []).
trim_atom_list([Atom0|Atoms0], Atoms) :-
    atom_codes(Atom0, Codes0), trim_codes(Codes0, Codes),
    ( Codes == [] -> Atoms = Rest
    ; atom_codes(Atom, Codes), Atoms = [Atom|Rest]
    ),
    trim_atom_list(Atoms0, Rest).

add_public_read(Caps0, Caps) :- sort([public_read|Caps0], Caps).

anonymous_capabilities(open, [public_read, execute]).
anonymous_capabilities(private, [public_read]).
anonymous_capabilities(dev, [public_read]).

principal_id(anonymous(_), anonymous).
principal_id(principal(Id, _), Id).
principal_id(unknown(Id), Id).

principal_has_capability(principal(_, Capabilities), Capability) :-
    capability_granted(Capabilities, Capability).
principal_has_capability(anonymous(Capabilities), Capability) :-
    capability_granted(Capabilities, Capability).

capability_granted(Capabilities, _) :- memberchk(admin, Capabilities), !.
capability_granted(Capabilities, Capability) :-
    memberchk(Capability, Capabilities).

require_route_access(Principal, Route) :-
    ( principal_has_capability(Principal, execute) -> true
    ; Principal = anonymous(_)
    -> throw(error(authentication_required(Route),
                   context(auth_policy:require_route_access/2,
                           'node execution requires authentication')))
    ; principal_id(Principal, Id),
      throw(error(authorization_error(Id, execution),
                  context(auth_policy:require_route_access/2,
                          'principal is not authorized for node execution')))
    ).

%! ws_require_allowed_origin(+Peer, +Headers) is det.

ws_require_allowed_origin(Peer, Headers) :-
    ( memberchk(origin-Origin0, Headers),
      text_atom(Origin0, OriginAtom), OriginAtom \== ''
    -> normalize_origin(OriginAtom, Origin),
       ( ws_origin_allowed(Peer, Headers, Origin) -> true
       ; throw(error(permission_error(open, websocket_origin, OriginAtom),
                     context(auth_policy:ws_require_allowed_origin/2,
                             'WebSocket Origin not allowed')))
       )
    ; true
    ).

ws_origin_allowed(_, _, Origin) :-
    current_configuration(auth_config(_, _, _, _, _, _, Allowed, _)),
    memberchk(Origin, Allowed), !.
ws_origin_allowed(Peer, Headers, Origin) :-
    memberchk(host-Host0, Headers), text_atom(Host0, Host),
    request_scheme(Peer, Headers, Scheme),
    format(atom(HostOrigin0), '~w://~w', [Scheme, Host]),
    normalize_origin(HostOrigin0, HostOrigin),
    Origin == HostOrigin.

request_scheme(Peer, Headers, Scheme) :-
    peer_is_private(Peer),
    memberchk('x-forwarded-proto'-Proto0, Headers), !,
    text_atom(Proto0, Proto), downcase_atom_codes(Proto, Scheme).
request_scheme(_, _, Scheme) :-
    current_configuration(auth_config(_, _, _, _, _, _, _, Scheme)).

normalize_origin(Origin0, Origin) :-
    text_atom(Origin0, Atom0),
    atom_codes(Atom0, Codes0), trim_codes(Codes0, Codes1),
    lower_codes(Codes1, Codes2), strip_trailing_slash(Codes2, Codes),
    Codes \== [], atom_codes(Origin, Codes), !.
normalize_origin(Origin, _) :-
    throw(error(domain_error(websocket_origin, Origin),
                auth_policy:configure_auth_policy/2)).

strip_trailing_slash(Codes0, Codes) :-
    append(Codes, [0'/], Codes0), !.
strip_trailing_slash(Codes, Codes).

peer_is_loopback(Host:_) :- !, peer_is_loopback(Host).
peer_is_loopback(ip(127, 0, 0, 1)).
peer_is_loopback(ip(0, 0, 0, 0, 0, 0, 0, 1)).
peer_is_loopback(Host) :-
    text_atom(Host, Atom), memberchk(Atom, ['127.0.0.1', '::1', localhost]).

peer_is_private(Peer) :- peer_is_loopback(Peer), !.
peer_is_private(Host:_) :- !, peer_is_private(Host).
peer_is_private(ip(10, _, _, _)).
peer_is_private(ip(172, B, _, _)) :- B >= 16, B =< 31.
peer_is_private(ip(192, 168, _, _)).
peer_is_private(Host) :-
    text_atom(Host, Atom),
    ( atom_concat('10.', _, Atom)
    ; atom_concat('192.168.', _, Atom)
    ; atom_concat('172.', Tail, Atom),
      atomic_list_concat([BAtom|_], '.', Tail),
      atom_number(BAtom, B), B >= 16, B =< 31
    ).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- is_list(Value), !, atom_chars(Atom, Value).
text_atom(Value, Atom) :- number(Value), !, atom_number(Atom, Value).

downcase_atom_codes(Atom, Lower) :-
    atom_codes(Atom, Codes), lower_codes(Codes, LowerCodes),
    atom_codes(Lower, LowerCodes).

lower_codes([], []).
lower_codes([C|Cs], [L|Ls]) :-
    ( C >= 65, C =< 90 -> L is C + 32 ; L = C ),
    lower_codes(Cs, Ls).

trim_codes(Codes0, Codes) :-
    drop_space(Codes0, Left), reverse(Left, Reversed),
    drop_space(Reversed, RightReversed), reverse(RightReversed, Codes).

drop_space([C|Cs], Rest) :- code_space(C), !, drop_space(Cs, Rest).
drop_space(Cs, Cs).

code_space(32).
code_space(9).
code_space(10).
code_space(13).

:- initialization(reset_auth_policy).
