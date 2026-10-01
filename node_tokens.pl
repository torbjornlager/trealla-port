% SPDX-License-Identifier: MIT

:- module(node_tokens,
    [ configure_token_store/1,
      issue_token/4,
      verify_bearer_token/2,
      revoke_token/1,
      current_tokens/1,
      token_count/1,
      clear_all_tokens/0,
      set_tokens_file/1,
      clear_tokens_file/0,
      current_tokens_file/1,
      load_tokens/0,
      save_tokens/0
    ]).

/** <module> Persistent hashed bearer-token store

Token and persistence formats intentionally match Trinity's SWI implementation:
`wp_<64-bit-id>_<192-bit-secret>` is returned exactly once, while only a
salted SHA-256 hash and administrative metadata are retained. Store files use
portable `token/8` Prolog terms and are replaced atomically.
*/

:- use_module(crypto_portable).

:- dynamic token_record/9.
% token_record(Id, Hash, Principal, Capabilities, Created, Expires,
%              LastUsed, Revoked, Label).
:- dynamic tokens_file_path/1.

:- catch(mutex_create(_, [alias('$node_tokens')]),
         error(permission_error(create, mutex, '$node_tokens'), _), true).

configure_token_store(Options) :-
    ( memberchk(tokens_file(File), Options)
    -> set_tokens_file(File), load_tokens
    ; memberchk(token_store_file(File), Options)
    -> set_tokens_file(File), load_tokens
    ; true
    ).

issue_token(Principal0, Capabilities0, Options, FullToken) :-
    normalize_nonempty_atom(principal, Principal0, Principal),
    normalize_capabilities(Capabilities0, Capabilities),
    normalize_token_options(Options, ExpiresAt, Label),
    get_time(Created),
    with_mutex('$node_tokens',
        issue_token_locked(Principal, Capabilities, Created, ExpiresAt, Label,
                           Id, Secret)),
    atomic_list_concat([wp,Id,Secret], '_', FullToken).

issue_token_locked(Principal, Capabilities, Created, ExpiresAt, Label,
                   Id, Secret) :-
    fresh_token_id(Id), fresh_secret(Secret), hash_secret(Id, Secret, Hash),
    assertz(token_record(Id,Hash,Principal,Capabilities,Created,ExpiresAt,
                         0,false,Label)),
    catch(save_tokens_locked, Error,
          ( retract(token_record(Id,Hash,Principal,Capabilities,Created,
                                 ExpiresAt,0,false,Label)),
            throw(Error) )).

normalize_token_options(Options, ExpiresAt, Label) :-
    ( is_list(Options) -> true
    ; throw(error(type_error(list, Options), node_tokens:issue_token/4))
    ),
    get_time(Now),
    ( memberchk(expires_at(At), Options)
    -> ( number(At), At > Now -> ExpiresAt = At
       ; throw(error(domain_error(token_expiry, At), node_tokens:issue_token/4)) )
    ; memberchk(expires_in(Seconds), Options)
    -> ( number(Seconds), Seconds > 0 -> ExpiresAt is Now+Seconds
       ; throw(error(domain_error(token_expiry, Seconds), node_tokens:issue_token/4)) )
    ; ExpiresAt = 0
    ),
    ( memberchk(label(Label0), Options)
    -> normalize_text_atom(label, Label0, Label)
    ; Label = ''
    ).

verify_bearer_token(Token, principal(Principal, Capabilities)) :-
    parse_token(Token, Id, Secret),
    with_mutex('$node_tokens',
        verify_bearer_token_locked(Id, Secret, Principal, Capabilities)).

verify_bearer_token_locked(Id, Secret, Principal, Capabilities) :-
    token_record(Id,Hash,Principal,Capabilities,_,Expires,_,false,_),
    token_not_expired(Expires),
    hash_secret(Id, Secret, PresentedHash),
    secure_equal(PresentedHash, Hash),
    retract(token_record(Id,Hash,Principal,Capabilities,Created,Expires,_,
                         false,Label)),
    get_time(Now),
    assertz(token_record(Id,Hash,Principal,Capabilities,Created,Expires,Now,
                         false,Label)).

token_not_expired(0) :- !.
token_not_expired(Expires) :- get_time(Now), Now < Expires.

revoke_token(Id0) :-
    normalize_nonempty_atom(token_id, Id0, Id),
    with_mutex('$node_tokens', revoke_token_locked(Id)).

revoke_token_locked(Id) :-
    retract(token_record(Id,Hash,Principal,Caps,Created,Expires,Used,Old,Label)),
    assertz(token_record(Id,Hash,Principal,Caps,Created,Expires,Used,true,Label)),
    catch(save_tokens_locked, Error,
          ( retract(token_record(Id,Hash,Principal,Caps,Created,Expires,Used,
                                 true,Label)),
            assertz(token_record(Id,Hash,Principal,Caps,Created,Expires,Used,
                                 Old,Label)),
            throw(Error) )).

current_tokens(Tokens) :-
    with_mutex('$node_tokens',
        findall(token_info(Id,Principal,Caps,Created,Expires,Used,Revoked,Label),
                token_record(Id,_,Principal,Caps,Created,Expires,Used,Revoked,Label),
                Tokens)).

token_count(Count) :- current_tokens(Tokens), length(Tokens, Count).

clear_all_tokens :-
    with_mutex('$node_tokens', retractall(token_record(_,_,_,_,_,_,_,_,_))).

set_tokens_file(Path0) :-
    normalize_nonempty_atom(tokens_file, Path0, Path),
    with_mutex('$node_tokens',
        ( retractall(tokens_file_path(_)), assertz(tokens_file_path(Path)) )).

clear_tokens_file :-
    with_mutex('$node_tokens', retractall(tokens_file_path(_))).

current_tokens_file(Path) :- tokens_file_path(Path).

load_tokens :-
    ( current_tokens_file(File), exists_file(File)
    -> read_tokens_file(File, Records),
       with_mutex('$node_tokens', replace_token_records(Records))
    ; true
    ).

read_tokens_file(File, Records) :-
    setup_call_cleanup(open(File, read, Stream, [encoding(utf8)]),
                       read_token_terms(Stream, Records), close(Stream)),
    unique_token_ids(Records, []).

read_token_terms(Stream, Records) :-
    read_term(Stream, Term, []),
    ( Term == end_of_file -> Records = []
    ; validate_token_term(Term, Record)
    -> Records = [Record|Rest], read_token_terms(Stream, Rest)
    ; throw(error(domain_error(token_store_record, Term),
                  node_tokens:load_tokens/0))
    ).

validate_token_term(token(Id0,Hash0,Principal0,Caps0,Created,Expires,
                          Revoked,Label0),
                    token_record(Id,Hash,Principal,Caps,Created,Expires,0,
                                 Revoked,Label)) :-
    normalize_nonempty_atom(token_id, Id0, Id),
    normalize_nonempty_atom(token_hash, Hash0, Hash),
    atom_length(Hash, 64),
    atom_hex(Hash),
    normalize_nonempty_atom(principal, Principal0, Principal),
    normalize_capabilities(Caps0, Caps),
    number(Created), number(Expires),
    memberchk(Revoked, [true,false]),
    normalize_text_atom(label, Label0, Label).

replace_token_records(Records) :-
    retractall(token_record(_,_,_,_,_,_,_,_,_)),
    assert_token_records(Records).

assert_token_records([]).
assert_token_records([Record|Records]) :-
    assertz(Record), assert_token_records(Records).

save_tokens :- with_mutex('$node_tokens', save_tokens_locked).

save_tokens_locked :- \+ tokens_file_path(_), !.
save_tokens_locked :-
    tokens_file_path(File), atom_concat(File, '.tmp', Temporary),
    catch(( setup_call_cleanup(open(Temporary, write, Stream, [encoding(utf8)]),
                               write_token_records(Stream), close(Stream)),
            rename_file(Temporary, File) ),
          Error,
          ( catch(delete_file(Temporary), _, true), throw(Error) )).

write_token_records(Stream) :-
    ( token_record(Id,Hash,Principal,Caps,Created,Expires,_,Revoked,Label),
      format(Stream, '~q.~n',
             [token(Id,Hash,Principal,Caps,Created,Expires,Revoked,Label)]),
      fail
    ; true
    ).

fresh_token_id(Id) :-
    secure_random_bytes(8, Bytes), bytes_hex(Bytes, Candidate),
    ( token_record(Candidate,_,_,_,_,_,_,_,_) -> fresh_token_id(Id)
    ; Id = Candidate
    ).

fresh_secret(Secret) :- secure_random_bytes(24, Bytes), bytes_hex(Bytes, Secret).

hash_secret(Id, Secret, Hash) :-
    format(atom(Data), '~w:~w', [Id,Secret]), sha256_hex(Data, Hash).

parse_token(Token0, Id, Secret) :-
    normalize_nonempty_atom(bearer_token, Token0, Token),
    atomic_list_concat([wp,Id,Secret], '_', Token),
    atom_length(Id, 16), atom_length(Secret, 48),
    atom_hex(Id), atom_hex(Secret).

unique_token_ids([], _).
unique_token_ids([token_record(Id,_,_,_,_,_,_,_,_)|Records], Seen) :-
    ( memberchk(Id, Seen)
    -> throw(error(permission_error(load, duplicate_token_id, Id),
                   node_tokens:load_tokens/0))
    ; unique_token_ids(Records, [Id|Seen])
    ).

atom_hex(Atom) :- atom_chars(Atom, Chars), hex_chars(Chars).
hex_chars([]).
hex_chars([Char|Chars]) :-
    char_code(Char, Code),
    ( Code >= 0'0, Code =< 0'9
    ; Code >= 0'a, Code =< 0'f
    ; Code >= 0'A, Code =< 0'F
    ),
    hex_chars(Chars).

normalize_capabilities(Capabilities0, Capabilities) :-
    ( is_list(Capabilities0) -> true
    ; throw(error(type_error(list, Capabilities0), node_tokens:issue_token/4))
    ),
    normalize_capability_list(Capabilities0, Capabilities1),
    sort(Capabilities1, Capabilities).

normalize_capability_list([], []).
normalize_capability_list([Capability0|Capabilities0],
                          [Capability|Capabilities]) :-
    normalize_nonempty_atom(capability, Capability0, Capability),
    ( memberchk(Capability, [public_read,execute,admin,internal_transport])
    -> true
    ; throw(error(domain_error(node_capability, Capability), node_tokens))
    ),
    normalize_capability_list(Capabilities0, Capabilities).

normalize_nonempty_atom(Name, Value, Atom) :-
    normalize_text_atom(Name, Value, Atom), Atom \== '', !.
normalize_nonempty_atom(Name, Value, _) :-
    throw(error(domain_error(Name, Value), node_tokens)).

normalize_text_atom(_, Value, Value) :- atom(Value), !.
normalize_text_atom(_, Value, Atom) :- string(Value), !, atom_chars(Atom, Value).
normalize_text_atom(Name, Value, _) :-
    throw(error(type_error(Name, Value), node_tokens)).
