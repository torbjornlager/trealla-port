% SPDX-License-Identifier: MIT
:- module(http_session_identity, [session_owner/5]).

:- use_module(auth_policy, [principal_id/2]).
:- use_module(crypto_portable, [secure_random_bytes/2, bytes_hex/2, sha256_hex/2,
                                hmac_sha256_hex/3, secure_equal/2]).

:- dynamic visitor_secret/1.
:- catch(mutex_create(_, [alias('$http_visitor_secret')]),
         error(permission_error(create, mutex, '$http_visitor_secret'), _), true).

% This identity owns HTTP sessions only. It never grants execution or admin
% access, and rate limits still use the normal principal/client IP identity.
session_owner(URL, anonymous(_), Headers, visitor(Hash), ExtraHeaders) :- !,
    visitor_cookie(URL, Name, Secure),
    ( cookie_value(Headers, Name, Cookie), valid_cookie(Cookie, Nonce) ->
        ExtraHeaders = []
    ; secure_random_bytes(32, Bytes),
      bytes_hex(Bytes, Nonce),
      get_time(Now), Expiry is floor(Now) + 86400,
      format(atom(Data), '~d.~w', [Expiry, Nonce]),
      sign_cookie(Data, Mac),
      format(atom(Header),
             '~w=~w.~w; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax~w',
             [Name, Data, Mac, Secure]),
      ExtraHeaders = ['Set-Cookie'-Header]
    ),
    sha256_hex(Nonce, Hash).
session_owner(_, Principal, _, principal(Id), []) :-
    principal_id(Principal, Id).

visitor_cookie(URL, '__Host-wp_visitor', '; Secure') :-
    sub_atom(URL, 0, 8, _, 'https://'), !.
visitor_cookie(_, wp_visitor, '').

cookie_value(Headers, Name, Cookie) :-
    member(cookie-Value, Headers),
    atomic_list_concat(Fields, ';', Value),
    member(Field, Fields),
    atom_codes(Field, Codes),
    drop_cookie_space(Codes, Start),
    atom_codes(Trimmed, Start),
    atomic_list_concat([Name, Cookie], '=', Trimmed), !.

drop_cookie_space([C|Rest], Start) :-
    ( C =:= 32 ; C =:= 9 ), !,
    drop_cookie_space(Rest, Start).
drop_cookie_space(Codes, Codes).

valid_cookie(Cookie, Nonce) :-
    atomic_list_concat([ExpiryText, Nonce, Mac], '.', Cookie),
    atom_length(Nonce, 64), atom_length(Mac, 64),
    catch(atom_number(ExpiryText, Expiry), _, fail),
    integer(Expiry), get_time(Now), Expiry > Now, Expiry =< Now + 86400,
    atomic_list_concat([ExpiryText, Nonce], '.', Data),
    sign_cookie(Data, Expected),
    secure_equal(Mac, Expected).

sign_cookie(Data, Mac) :-
    with_mutex('$http_visitor_secret',
        ( visitor_secret(Key) -> true
        ; secure_random_bytes(32, Key), assertz(visitor_secret(Key))
        )),
    hmac_sha256_hex(Key, Data, Mac).
