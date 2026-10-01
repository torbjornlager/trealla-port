% SPDX-License-Identifier: MIT

:- module(ip_policy,
    [ configure_ip_policy/2,
      current_ip_policy/1,
      current_ip_usage/1,
      default_ip_policy/1,
      reset_ip_policy/0,
      client_ip/3,
      peer_ip/2,
      peer_is_trusted_proxy/1,
      require_ip_access/3,
      ip_access_denied/3,
      record_ip_offense/2,
      record_ip_offense_address/1,
      ip_temp_banned/1,
      clear_ip_bans/0,
      ip_matches/2,
      valid_ip_pattern/1
    ]).

/** <module> Client IP, CIDR, and trusted-proxy policy

The policy is off by default.  A blocklist denies matching client addresses;
a non-empty allowlist denies every address that it does not match.  IPv4 CIDR
patterns and exact IPv4/IPv6 addresses are accepted.

Forwarded headers are security-sensitive.  `X-Forwarded-For` is considered
only when the immediate TCP peer matches `trusted_proxy_ranges/1`, whose
default is deliberately empty.  The rightmost forwarded address is used, so
a client-prepended value cannot displace the address observed by a proxy that
appends to the header.
*/

:- use_module(library(error)).

:- dynamic active_ip_policy/1.
:- dynamic ip_strike/2.
:- dynamic ip_ban/2.

:- catch(mutex_create(_, [alias('$node_ip_policy')]),
         error(permission_error(create, mutex, '$node_ip_policy'), _),
         true).

default_ip_policy(ip_policy([], [], [], 0, 60, 900)).

reset_ip_policy :-
    default_ip_policy(Policy),
    retractall(active_ip_policy(_)), assertz(active_ip_policy(Policy)),
    clear_ip_bans.

current_ip_policy(Policy) :- active_ip_policy(Policy), !.
current_ip_policy(Policy) :- default_ip_policy(Policy).

current_ip_usage(ip_usage(Bans, Strikes)) :-
    get_time(Now),
    with_mutex('$node_ip_policy',
        ( sweep_expired_bans(Now),
          findall(ban(IP,Expires), ip_ban(IP, Expires), Bans),
          findall(strike(IP,Time), ip_strike(IP, Time), Strikes) )).

configure_ip_policy(Options, Policy) :-
    option(ip_blocklist(Block0), Options, []),
    option(ip_allowlist(Allow0), Options, []),
    option(trusted_proxy_ranges(Trusted0), Options, []),
    normalize_patterns(ip_blocklist, Block0, Block),
    normalize_patterns(ip_allowlist, Allow0, Allow),
    normalize_patterns(trusted_proxy_ranges, Trusted0, Trusted),
    option(auto_ban_threshold(Threshold0), Options, 0),
    option(auto_ban_window_seconds(Window0), Options, 60),
    option(auto_ban_seconds(BanSeconds0), Options, 900),
    normalize_nonnegative(auto_ban_threshold, Threshold0, Threshold),
    normalize_positive(auto_ban_window_seconds, Window0, Window),
    normalize_positive(auto_ban_seconds, BanSeconds0, BanSeconds),
    Policy = ip_policy(Block,Allow,Trusted,Threshold,Window,BanSeconds),
    retractall(active_ip_policy(_)), assertz(active_ip_policy(Policy)),
    clear_ip_bans.

normalize_patterns(Name, Patterns0, Patterns) :-
    must_be(list, Patterns0),
    normalize_pattern_list(Name, Patterns0, Patterns1),
    sort(Patterns1, Patterns).

normalize_pattern_list(_, [], []).
normalize_pattern_list(Name, [Pattern0|Patterns0], [Pattern|Patterns]) :-
    text_atom(Pattern0, Pattern1), lower_atom(Pattern1, Pattern),
    ( valid_ip_pattern(Pattern) -> true
    ; throw(error(domain_error(Name, Pattern0),
                  context(ip_policy:configure_ip_policy/2,
                          'expected an IPv4 CIDR or exact IPv4/IPv6 address')))
    ),
    normalize_pattern_list(Name, Patterns0, Patterns).

normalize_nonnegative(_, Value, Value) :- integer(Value), Value >= 0, !.
normalize_nonnegative(Name, Value, _) :-
    throw(error(domain_error(Name, Value), ip_policy:configure_ip_policy/2)).

normalize_positive(_, Value, Value) :- integer(Value), Value > 0, !.
normalize_positive(Name, Value, _) :-
    throw(error(domain_error(Name, Value), ip_policy:configure_ip_policy/2)).


                 /*******************************
                 *       CLIENT RESOLUTION      *
                 *******************************/

client_ip(Peer, Headers, IP) :-
    ( peer_is_trusted_proxy(Peer),
      forwarded_client_ip(Headers, Forwarded)
    -> IP = Forwarded
    ; peer_ip(Peer, IP)
    ).

peer_is_trusted_proxy(Peer) :-
    peer_ip(Peer, IP),
    current_ip_policy(ip_policy(_,_,Trusted,_,_,_)),
    ip_matches_any(IP, Trusted).

forwarded_client_ip(Headers, IP) :-
    memberchk('x-forwarded-for'-Value0, Headers),
    text_atom(Value0, Value),
    atomic_list_concat(Parts0, ',', Value),
    trim_nonempty_atoms(Parts0, Parts), Parts \== [],
    last_atom(Parts, Candidate0), lower_atom(Candidate0, Candidate),
    valid_exact_ip(Candidate),
    IP = Candidate.

last_atom([Atom], Atom) :- !.
last_atom([_|Atoms], Atom) :- last_atom(Atoms, Atom).

peer_ip(Host:_, IP) :- !, peer_ip(Host, IP).
peer_ip(ip(A,B,C,D), IP) :- !,
    format(atom(IP), '~w.~w.~w.~w', [A,B,C,D]).
peer_ip(ip(A,B,C,D,E,F,G,H), IP) :- !,
    format(atom(IP), '~16r:~16r:~16r:~16r:~16r:~16r:~16r:~16r',
           [A,B,C,D,E,F,G,H]).
peer_ip(Peer, IP) :-
    text_atom(Peer, PeerAtom), lower_atom(PeerAtom, IP).


                 /*******************************
                 *          ACCESS GATE         *
                 *******************************/

require_ip_access(Peer, Headers, IP) :-
    client_ip(Peer, Headers, IP),
    ( ip_access_denied_address(IP)
    -> throw(error(permission_error(access, client_ip, IP),
                   context(ip_policy:require_ip_access/3,
                           'client address is denied by node IP policy')))
    ; true
    ).

ip_access_denied(Peer, Headers, IP) :-
    client_ip(Peer, Headers, IP), ip_access_denied_address(IP).

ip_access_denied_address(IP) :-
    current_ip_policy(ip_policy(Block,Allow,_,_,_,_)),
    ( ip_matches_any(IP, Block)
    ; ip_temp_banned(IP)
    ; Allow \== [], \+ ip_matches_any(IP, Allow)
    ).

ip_matches_any(IP, [Pattern|_]) :- ip_matches(IP, Pattern), !.
ip_matches_any(IP, [_|Patterns]) :- ip_matches_any(IP, Patterns).


                 /*******************************
                 *          AUTO-BAN            *
                 *******************************/

record_ip_offense(Peer, Headers) :-
    client_ip(Peer, Headers, IP), record_ip_offense_address(IP).

record_ip_offense_address(IP) :-
    current_ip_policy(ip_policy(_,Allow,_,Threshold,Window,BanSeconds)),
    ( Threshold > 0, \+ ip_matches_any(IP, Allow)
    -> get_time(Now),
       with_mutex('$node_ip_policy',
          record_strike(IP, Now, Threshold, Window, BanSeconds))
    ; true
    ).

record_strike(IP, Now, Threshold, Window, BanSeconds) :-
    Cutoff is Now - Window,
    retract_old_strikes(IP, Cutoff),
    assertz(ip_strike(IP, Now)),
    findall(Time, ip_strike(IP, Time), Times), length(Times, Count),
    ( Count >= Threshold
    -> Expires is Now + BanSeconds,
       retractall(ip_ban(IP, _)), assertz(ip_ban(IP, Expires)),
       retractall(ip_strike(IP, _)), sweep_expired_bans(Now)
    ; true
    ).

retract_old_strikes(IP, Cutoff) :-
    ( ip_strike(IP, Time), Time < Cutoff,
      retract(ip_strike(IP, Time)), fail
    ; true
    ).

ip_temp_banned(IP) :-
    ip_ban(IP, Expires), get_time(Now), Expires > Now, !.

sweep_expired_bans(Now) :-
    ( ip_ban(IP, Expires), Expires =< Now,
      retract(ip_ban(IP, Expires)), fail
    ; true
    ).

clear_ip_bans :-
    with_mutex('$node_ip_policy',
               ( retractall(ip_strike(_, _)), retractall(ip_ban(_, _)) )).


                 /*******************************
                 *          IP MATCHING         *
                 *******************************/

ip_matches(IP0, Pattern0) :-
    text_atom(IP0, IP1), lower_atom(IP1, IP),
    text_atom(Pattern0, Pattern1), lower_atom(Pattern1, Pattern),
    ( atomic_list_concat([Network,PrefixAtom], '/', Pattern)
    -> catch(atom_number(PrefixAtom, Prefix), _, fail),
       ipv4_to_int(Network, NetworkInt),
       ipv4_to_int(IP, IPInt), ipv4_mask(Prefix, Mask),
       (IPInt /\ Mask) =:= (NetworkInt /\ Mask)
    ; IP == Pattern
    ).

ipv4_mask(0, 0) :- !.
ipv4_mask(Prefix, Mask) :-
    Prefix > 0, Prefix =< 32,
    Mask is (4294967295 << (32 - Prefix)) /\ 4294967295.

valid_ip_pattern(Pattern0) :-
    text_atom(Pattern0, Pattern1), lower_atom(Pattern1, Pattern),
    ( atomic_list_concat([Network,PrefixAtom], '/', Pattern)
    -> ipv4_to_int(Network, _), catch(atom_number(PrefixAtom, Prefix), _, fail),
       integer(Prefix), Prefix >= 0, Prefix =< 32
    ; valid_exact_ip(Pattern)
    ).

valid_exact_ip(IP) :- ipv4_to_int(IP, _), !.
valid_exact_ip(IP) :- valid_ipv6_text(IP).

ipv4_to_int(IP, Int) :-
    atomic_list_concat(Parts, '.', IP), Parts = [A0,B0,C0,D0],
    octet(A0, A), octet(B0, B), octet(C0, C), octet(D0, D),
    Int is (A << 24) \/ (B << 16) \/ (C << 8) \/ D.

octet(Atom, Value) :-
    catch(atom_number(Atom, Value), _, fail),
    integer(Value), Value >= 0, Value =< 255.

% Exact IPv6 matching is textual. Validation deliberately accepts compressed
% forms while rejecting characters that cannot occur in an IPv6 literal.
valid_ipv6_text(IP) :-
    atom_codes(IP, Codes), memberchk(0':, Codes),
    forall(member(Code, Codes), ipv6_code(Code)).

ipv6_code(Code) :- Code >= 0'0, Code =< 0'9, !.
ipv6_code(Code) :- Code >= 0'a, Code =< 0'f, !.
ipv6_code(0':). ipv6_code(0'.).


                 /*******************************
                 *          TEXT HELPERS        *
                 *******************************/

trim_nonempty_atoms([], []).
trim_nonempty_atoms([Atom0|Atoms0], Atoms) :-
    atom_codes(Atom0, Codes0), trim_codes(Codes0, Codes),
    ( Codes == [] -> Atoms = Rest
    ; atom_codes(Atom, Codes), Atoms = [Atom|Rest]
    ),
    trim_nonempty_atoms(Atoms0, Rest).

trim_codes(Codes0, Codes) :-
    drop_space(Codes0, Left), reverse(Left, Reversed),
    drop_space(Reversed, RightReversed), reverse(RightReversed, Codes).

drop_space([Code|Codes], Rest) :-
    memberchk(Code, [9,10,13,32]), !, drop_space(Codes, Rest).
drop_space(Codes, Codes).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, Atom) :- is_list(Value), !, atom_chars(Atom, Value).

lower_atom(Atom, Lower) :-
    atom_codes(Atom, Codes), lower_codes(Codes, LowerCodes),
    atom_codes(Lower, LowerCodes).

lower_codes([], []).
lower_codes([Code|Codes], [Lower|Lowers]) :-
    ( Code >= 0'A, Code =< 0'Z -> Lower is Code + 32 ; Lower = Code ),
    lower_codes(Codes, Lowers).

:- initialization(reset_ip_policy).
