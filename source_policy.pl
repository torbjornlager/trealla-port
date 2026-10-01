% SPDX-License-Identifier: MIT

:- module(source_policy,
    [ configure_source_policy/2,
      current_source_policy/1,
      default_source_policy/1,
      reset_source_policy/0,
      resolve_source_options/2,
      fetch_source_uri/2,
      normalize_source_origin/2,
      resolve_redirect_uri/3,
      resolve_source_host/3,
      source_address_allowed/2
    ]).

/** <module> Controlled remote source loading

`src_uri/1` is disabled unless the node operator supplies an exact origin
allowlist. Every redirect is resolved and checked against the same list
before a connection is opened. Host names are resolved once, the numeric
destination is checked, and the connection is made to that same address so
DNS rebinding cannot move the fetch after authorization. By default only
public addresses are accepted; `load_uri_allowed_ip_ranges/1` replaces that
default with an explicit address/CIDR allowlist for private or pinned sources.
Bodies are read incrementally under the node's source-size ceiling and a
separate wall-clock deadline.

Trealla's TLS client does not currently verify host names.  HTTPS source
origins are consequently rejected unless the operator explicitly enables
`allow_unverified_https(true)`.  This opt-in does not turn unverified TLS
into authenticated TLS; it only records that the deployment accepts that
runtime limitation.
*/

:- use_module(library(error)).
:- use_module(library(socket), [tcp_host_to_address/2]).
:- use_module(library(sockets)).
:- use_module(resource_policy).
:- use_module(ip_policy, [ip_matches/2,peer_ip/2,valid_ip_pattern/1]).

:- dynamic active_source_policy/1.
:- dynamic source_origin_alias/6.

default_source_policy(source_policy([], 10, 5, false, public)).

reset_source_policy :-
    default_source_policy(Policy),
    retractall(active_source_policy(_)),
    retractall(source_origin_alias(_,_,_,_,_,_)),
    assertz(active_source_policy(Policy)).

current_source_policy(Policy) :- active_source_policy(Policy), !.
current_source_policy(Policy) :- default_source_policy(Policy).

configure_source_policy(Options, Policy) :-
    option(load_uri_allowed_origins(Origins0), Options, []),
    must_be(list, Origins0),
    normalize_source_origins(Origins0, Origins),
    option(source_fetch_timeout(Timeout0), Options, 10),
    positive_number(source_fetch_timeout, Timeout0, Timeout),
    option(max_source_redirects(Redirects0), Options, 5),
    nonnegative_integer(max_source_redirects, Redirects0, Redirects),
    option(allow_unverified_https(Unverified0), Options, false),
    boolean_option(allow_unverified_https, Unverified0, Unverified),
    option(load_uri_origin_aliases(Aliases0), Options, []),
    must_be(list, Aliases0),
    normalize_source_aliases(Aliases0, Aliases),
    source_address_policy(Options, AddressPolicy),
    Policy = source_policy(Origins, Timeout, Redirects, Unverified,
                           AddressPolicy),
    retractall(active_source_policy(_)),
    retractall(source_origin_alias(_,_,_,_,_,_)),
    assert_source_aliases(Aliases),
    assertz(active_source_policy(Policy)).

normalize_source_aliases([], []).
normalize_source_aliases([Spec|Specs], [Alias|Aliases]) :-
    source_alias_pair(Spec, Origin0, Endpoint0),
    normalize_source_origin(Origin0, origin(Scheme, Host, Port)),
    normalize_source_origin(Endpoint0,
                            origin(EndpointScheme, EndpointHost, EndpointPort)),
    Alias = source_origin_alias(Scheme, Host, Port,
                                EndpointScheme, EndpointHost, EndpointPort),
    normalize_source_aliases(Specs, Aliases).

source_alias_pair(Origin=Endpoint, Origin, Endpoint) :- !.
source_alias_pair(Spec, Origin, Endpoint) :-
    atom(Spec),
    atomic_list_concat([Origin,Endpoint], '=', Spec),
    Origin \== '', Endpoint \== '',
    !.
source_alias_pair(Spec, _, _) :-
    throw(error(domain_error(load_uri_origin_alias, Spec),
                source_policy:configure_source_policy/2)).

assert_source_aliases([]).
assert_source_aliases([Alias|Aliases]) :-
    assertz(Alias),
    assert_source_aliases(Aliases).

positive_number(_, Value, Value) :- number(Value), Value > 0, !.
positive_number(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                context(source_policy:configure_source_policy/2,
                        'expected positive seconds'))).

nonnegative_integer(_, Value, Value) :- integer(Value), Value >= 0, !.
nonnegative_integer(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                context(source_policy:configure_source_policy/2,
                        'expected a non-negative integer'))).

boolean_option(_, true, true) :- !.
boolean_option(_, false, false) :- !.
boolean_option(Name, Value, _) :-
    throw(error(domain_error(Name, Value),
                source_policy:configure_source_policy/2)).

source_address_policy(Options, allowlist(Patterns)) :-
    memberchk(load_uri_allowed_ip_ranges(Patterns0), Options), !,
    must_be(list, Patterns0),
    normalize_ip_patterns(Patterns0, Patterns).
source_address_policy(_, public).

normalize_ip_patterns([], []).
normalize_ip_patterns([Pattern0|Patterns0], [Pattern|Patterns]) :-
    source_text_atom(Pattern0, Pattern1), ascii_lower_atom(Pattern1, Pattern),
    ( valid_ip_pattern(Pattern) -> true
    ; throw(error(domain_error(load_uri_allowed_ip_ranges, Pattern0),
                  context(source_policy:configure_source_policy/2,
                          'expected an IPv4 CIDR or exact IPv4/IPv6 address')))
    ),
    normalize_ip_patterns(Patterns0, Patterns).


                 /*******************************
                 *       OPTION RESOLUTION      *
                 *******************************/

resolve_source_options([], []).
resolve_source_options([src_uri(URI)|Options],
                       [src_text(Text)|Resolved]) :-
    !,
    fetch_source_uri(URI, Text),
    resolve_source_options(Options, Resolved).
resolve_source_options([Option|Options], [Option|Resolved]) :-
    resolve_source_options(Options, Resolved).

fetch_source_uri(URI0, Text) :-
    source_text_atom(URI0, URI),
    atom_length(URI, URILength),
    ( URILength =< 4096 -> true
    ; throw(error(resource_error(input_size(src_uri, URILength, 4096)),
                  resource_policy))
    ),
    current_source_policy(source_policy(Origins, Timeout, Redirects,
                                        AllowUnverifiedHTTPS, AddressPolicy)),
    ( Origins == []
    -> throw(error(permission_error(load, source_uri, URI),
                   context(source_policy:fetch_source_uri/2,
                           'src_uri/1 is disabled until load_uri_allowed_origins/1 is configured')))
    ; true
    ),
    create_resource_timer(Timeout, Timer),
    catch(fetch_source_uri_(URI, Origins, Redirects,
                            AllowUnverifiedHTTPS, AddressPolicy, Bytes), Error0,
          ( disarm_resource_timer(Timer),
            source_fetch_exception(Error0, URI, Error),
            throw(Error) )),
    disarm_resource_timer(Timer),
    utf8_decode(Bytes, Codes),
    atom_codes(Text, Codes).

source_fetch_exception(error(time_limit_exceeded(_, _), _), URI,
                       error(resource_error(source_fetch_timeout(URI)),
                             source_policy)) :- !.
source_fetch_exception(time_limit_exceeded, URI,
                       error(resource_error(source_fetch_timeout(URI)),
                             source_policy)) :- !.
source_fetch_exception(Error, _, Error).

fetch_source_uri_(URI, Origins, Redirects, AllowUnverifiedHTTPS,
                  AddressPolicy, Bytes) :-
    parse_http_uri(URI, Scheme, Host, Port, Path),
    require_allowed_origin(URI, Scheme, Host, Port, Origins),
    resolve_source_host(URI, Host, Address),
    require_source_address(URI, Address, AddressPolicy),
    source_connection_route(URI, Scheme, Host, Port, Address,
                            ConnectScheme, ConnectAddress, ConnectPort),
    require_supported_tls(URI, ConnectScheme, AllowUnverifiedHTTPS),
    open_source_connection(ConnectScheme, Host, ConnectAddress, ConnectPort,
                           Stream),
    catch(( send_source_request(Stream, Host, Port, Path),
            read_status(Stream, Status),
            read_headers(Stream, Headers),
            source_response(Status, Headers, Stream, URI, Origins,
                            Redirects, AllowUnverifiedHTTPS, AddressPolicy,
                            Bytes) ),
          Error, ( catch(close(Stream), _, true), throw(Error) )),
    catch(close(Stream), _, true).

% An origin alias is an explicit operator-controlled route from a public
% source origin to a trusted internal HTTP endpoint.  It is useful when a
% local TLS-terminating proxy already authenticates the public service and
% Trealla cannot preserve the original SNI while connecting to a pinned IP.
% The original origin and resolved public address are still policy-checked;
% only the final connection target is replaced.
source_connection_route(_, Scheme, Host, Port, _,
                        ConnectScheme, ConnectAddress, ConnectPort) :-
    source_origin_alias(Scheme, Host, Port,
                        ConnectScheme, ConnectHost, ConnectPort),
    !,
    format(atom(Endpoint), '~w://~w:~w',
           [ConnectScheme,ConnectHost,ConnectPort]),
    resolve_source_host(Endpoint, ConnectHost, ConnectAddress).
source_connection_route(_, Scheme, _, Port, Address,
                        Scheme, Address, Port).

source_response(Status, Headers, Stream, URI, Origins, Redirects,
                AllowUnverifiedHTTPS, AddressPolicy, Bytes) :-
    redirect_status(Status),
    !,
    ( Redirects > 0 -> true
    ; throw(error(resource_error(source_redirects),
                  context(source_policy:fetch_source_uri/2, URI)))
    ),
    require_header(Headers, location, Location),
    resolve_redirect_uri(URI, Location, NextURI),
    % Close before recursively opening the redirect target.  In particular,
    % no credentials or connection state can cross an origin boundary.
    close(Stream),
    NextRedirects is Redirects - 1,
    fetch_source_uri_(NextURI, Origins, NextRedirects,
                      AllowUnverifiedHTTPS, AddressPolicy, Bytes).
source_response(Status, Headers, Stream, URI, _, _, _, _, Bytes) :-
    ( Status >= 200, Status < 300
    -> current_resource_policy(resource_policy(_,_,_,_,_,Limit,_)),
       read_response_body(Stream, Headers, Limit, Bytes)
    ; throw(error(source_uri_http_status(URI, Status),
                  source_policy:fetch_source_uri/2))
    ).

redirect_status(301). redirect_status(302). redirect_status(303).
redirect_status(307). redirect_status(308).


                 /*******************************
                 *          URI POLICY          *
                 *******************************/

normalize_source_origins([], []).
normalize_source_origins([Origin0|Origins0], [Origin|Origins]) :-
    normalize_source_origin(Origin0, Origin),
    normalize_source_origins(Origins0, Origins).

normalize_source_origin(Origin0, origin(Scheme, Host, Port)) :-
    source_text_atom(Origin0, Origin),
    parse_http_uri(Origin, Scheme, Host, Port, Path),
    ( Path == '/' -> true
    ; throw(error(domain_error(source_origin, Origin),
                  context(source_policy:normalize_source_origin/2,
                          'an allowed origin must not contain a path, query, or fragment')))
    ).

require_allowed_origin(URI, Scheme, Host, Port, Origins) :-
    ( memberchk(origin(Scheme, Host, Port), Origins) -> true
    ; throw(error(permission_error(load, source_origin, URI),
                  source_policy:fetch_source_uri/2))
    ).

require_supported_tls(_, http, _) :- !.
require_supported_tls(_, https, true) :- !.
require_supported_tls(URI, https, false) :-
    throw(error(permission_error(load, unverified_https_source, URI),
                context(source_policy:fetch_source_uri/2,
                        'Trealla TLS lacks host-name verification; opt in explicitly or use a verified fetch proxy'))).

resolve_source_host(URI, Host, Address) :-
    ( catch(tcp_host_to_address(Host, Address0), _, fail)
    -> peer_ip(Address0, Address)
    ; throw(error(existence_error(source_host, Host),
                  context(source_policy:fetch_source_uri/2, URI)))
    ).

require_source_address(URI, Address, Policy) :-
    ( source_address_allowed(Address, Policy) -> true
    ; throw(error(permission_error(load, source_address, Address),
                  context(source_policy:fetch_source_uri/2, URI)))
    ).

source_address_allowed(Address, allowlist(Patterns)) :-
    member(Pattern, Patterns), ip_matches(Address, Pattern), !.
source_address_allowed(Address, public) :-
    public_source_address(Address).

public_source_address(Address) :-
    ip_matches(Address, '0.0.0.0/0'), !,
    \+ nonpublic_ipv4(Address).
public_source_address(Address) :-
    public_ipv6(Address).

nonpublic_ipv4(Address) :-
    member(Pattern,
           ['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8',
            '169.254.0.0/16','172.16.0.0/12','192.0.0.0/24',
            '192.0.2.0/24','192.168.0.0/16','198.18.0.0/15',
            '198.51.100.0/24','203.0.113.0/24','224.0.0.0/4',
            '240.0.0.0/4']),
    ip_matches(Address, Pattern), !.

% Global-unicast IPv6 currently occupies 2000::/3. Numeric resolver output
% always begins with an explicit first hextet, so compressed local forms do
% not need special cases here.
public_ipv6(Address) :-
    atom_codes(Address, Codes),
    take_hextet(Codes, Hextet, [0':|_]), Hextet \== [],
    hex_number(Hextet, 0, Value),
    Value >= 8192, Value < 16384.

take_hextet([0':|Codes], [], [0':|Codes]) :- !.
take_hextet([Code|Codes], [Code|Hextet], Rest) :-
    take_hextet(Codes, Hextet, Rest).

hex_number([], Value, Value).
hex_number([Code|Codes], Value0, Value) :-
    hex_digit_value(Code, Digit),
    Value1 is Value0 * 16 + Digit,
    hex_number(Codes, Value1, Value).

parse_http_uri(URI, Scheme, Host, Port, Path) :-
    atom(URI),
    ( sub_atom(URI, SchemeLength, 3, _, '://'), SchemeLength > 0
    -> sub_atom(URI, 0, SchemeLength, _, Scheme0),
       Start is SchemeLength + 3, sub_atom(URI, Start, _, 0, Rest),
       ascii_lower_atom(Scheme0, Scheme1)
    ; Scheme1 = invalid
    ),
    ( Scheme1 == http -> Scheme = http, Default = 80
    ; Scheme1 == https -> Scheme = https, Default = 443
    ; throw(error(domain_error(source_uri, URI),
                  source_policy:fetch_source_uri/2))
    ),
    reject_uri_fragment(URI),
    split_authority_path(Rest, Authority, Path),
    valid_authority(URI, Authority, Host0, Port, Default),
    ascii_lower_atom(Host0, Host),
    valid_host(URI, Host),
    safe_uri_component(URI, Host),
    safe_uri_component(URI, Path).

split_authority_path(Rest, Authority, Path) :-
    atom_codes(Rest, Codes), take_authority(Codes, AuthorityCodes, Tail),
    atom_codes(Authority, AuthorityCodes),
    ( Tail == [] -> Path = '/'
    ; Tail = [0'?|_] -> atom_codes(Query, Tail), atom_concat('/', Query, Path)
    ; atom_codes(Path, Tail)
    ).

take_authority([], [], []).
take_authority([Code|Codes], [], [Code|Codes]) :-
    ( Code =:= 0'/ ; Code =:= 0'? ), !.
take_authority([Code|Codes], [Code|Authority], Tail) :-
    take_authority(Codes, Authority, Tail).

reject_uri_fragment(URI) :-
    ( sub_atom(URI, _, 1, _, '#')
    -> throw(error(domain_error(source_uri_fragment, URI),
                   source_policy:fetch_source_uri/2))
    ; true
    ).

valid_authority(URI, Authority, Host, Port, Default) :-
    ( Authority == '' ; sub_atom(Authority, _, 1, _, '@') )
    -> throw(error(domain_error(source_uri_authority, URI),
                   source_policy:fetch_source_uri/2))
    ; ( sub_atom(Authority, Colon, 1, _, ':')
      -> sub_atom(Authority, 0, Colon, _, Host),
         Start is Colon + 1,
         sub_atom(Authority, Start, _, 0, PortAtom),
         catch(atom_number(PortAtom, Port0), _, fail),
         integer(Port0), Port0 > 0, Port0 =< 65535,
         Port = Port0
      ; Host = Authority, Port = Default
      ),
      Host \== ''.
valid_authority(URI, _, _, _, _) :-
    throw(error(domain_error(source_uri_authority, URI),
                source_policy:fetch_source_uri/2)).

valid_host(URI, Host) :-
    atom_codes(Host, Codes), Codes \== [],
    ( forall(member(Code, Codes), host_code(Code)) -> true
    ; throw(error(domain_error(source_uri_host, URI),
                  source_policy:fetch_source_uri/2))
    ).

host_code(Code) :- Code >= 0'a, Code =< 0'z, !.
host_code(Code) :- Code >= 0'0, Code =< 0'9, !.
host_code(0'-). host_code(0'.).
% Docker Compose service aliases may contain an underscore. Public source
% hosts still have to resolve to an address admitted by the egress policy;
% this extension primarily permits explicit operator-controlled aliases.
host_code(0'_).

safe_uri_component(URI, Atom) :-
    atom_codes(Atom, Codes),
    ( member(Code, Codes), (Code < 32 ; Code =:= 127) )
    -> throw(error(domain_error(source_uri, URI),
                   source_policy:fetch_source_uri/2))
    ; true.

resolve_redirect_uri(Base0, Location0, URI) :-
    source_text_atom(Base0, Base), source_text_atom(Location0, Location),
    ( catch(parse_http_uri(Location, _, _, _, _), _, fail)
    -> URI = Location
    ; atom_concat('//', Tail, Location)
    -> base_scheme(Base, Scheme), format(atom(URI), '~w://~w', [Scheme,Tail])
    ; atom_concat('?', _, Location)
    -> strip_query(Base, PlainBase), atom_concat(PlainBase, Location, URI)
    ; base_root(Base, Root),
      ( atom_concat('/', _, Location)
      -> atom_concat(Root, Location, URI)
      ; base_directory(Base, Directory), atom_concat(Directory, Location, URI)
      )
    ).

base_scheme(Base, Scheme) :-
    parse_http_uri(Base, Scheme, _, _, _).

base_root(Base, Root) :-
    parse_http_uri(Base, Scheme, Host, Port, _),
    default_port(Scheme, Default),
    ( Port =:= Default -> format(atom(Root), '~w://~w', [Scheme,Host])
    ; format(atom(Root), '~w://~w:~w', [Scheme,Host,Port])
    ).

base_directory(Base, Directory) :-
    parse_http_uri(Base, _, _, _, Path0), strip_query(Path0, Path),
    atom_codes(Path, Codes),
    ( append(Prefix, [0'/|Suffix], Codes), \+ memberchk(0'/, Suffix)
    -> append(Prefix, [0'/], DirectoryCodes), atom_codes(PathDirectory, DirectoryCodes)
    ; PathDirectory = '/'
    ),
    base_root(Base, Root), atom_concat(Root, PathDirectory, Directory).

strip_query(URI, Plain) :-
    ( sub_atom(URI, Before, 1, _, '?') -> sub_atom(URI, 0, Before, _, Plain)
    ; Plain = URI
    ).

default_port(http, 80). default_port(https, 443).


                 /*******************************
                 *          HTTP CLIENT         *
                 *******************************/

open_source_connection(http, _, Address, Port, Stream) :-
    socket_client_open(Address:Port, Stream, [type(binary)]).
open_source_connection(https, _, Address, Port, Stream) :-
    socket_client_open(Address:Port, Stream, [ssl(true),type(binary)]).

send_source_request(Stream, Host, Port, Path) :-
    write_http(Stream, 'GET ~w HTTP/1.1\r\n', [Path]),
    write_http(Stream, 'Host: ~w:~w\r\n', [Host,Port]),
    write_http(Stream, 'Accept: text/x-prolog, text/plain;q=0.9, */*;q=0.1\r\n', []),
    write_http(Stream, 'Connection: close\r\n\r\n', []),
    flush_output(Stream).

write_http(Stream, Format, Arguments) :-
    format(atom(Atom), Format, Arguments), atom_codes(Atom, Bytes),
    write_bytes(Stream, Bytes).

write_bytes(_, []).
write_bytes(Stream, [Byte|Bytes]) :-
    put_byte(Stream, Byte), write_bytes(Stream, Bytes).

read_status(Stream, Status) :-
    read_http_line(Stream, 4096, Codes), atom_codes(Line, Codes),
    atomic_list_concat([Version,CodeAtom|_], ' ', Line),
    atom_concat('HTTP/', _, Version), atom_number(CodeAtom, Status), !.
read_status(_, _) :-
    throw(error(source_uri_protocol_error(status_line),
                source_policy:fetch_source_uri/2)).

read_headers(Stream, Headers) :- read_headers(Stream, 65536, Headers).

read_headers(Stream, Remaining, Headers) :-
    read_http_line(Stream, 8192, Line),
    length(Line, Length), Next is Remaining - Length - 2,
    ( Next >= 0 -> true
    ; throw(error(resource_error(input_size(source_headers, 65537, 65536)),
                  resource_policy))
    ),
    ( Line == [] -> Headers = []
    ; parse_header(Line, Header), Headers = [Header|Rest],
      read_headers(Stream, Next, Rest)
    ).

parse_header(Codes, Name-Value) :-
    append(NameCodes, [0':|RawValue], Codes), !,
    trim_space(RawValue, ValueCodes), ascii_lower_codes(NameCodes, Lower),
    atom_codes(Name, Lower), atom_codes(Value, ValueCodes).
parse_header(_, _) :-
    throw(error(source_uri_protocol_error(header),
                source_policy:fetch_source_uri/2)).

require_header([Name-Value|_], Name, Value) :- !.
require_header([_|Headers], Name, Value) :- require_header(Headers, Name, Value).
require_header([], Name, _) :-
    throw(error(source_uri_protocol_error(missing_header(Name)),
                source_policy:fetch_source_uri/2)).

optional_header([Name-Value|_], Name, Value) :- !.
optional_header([_|Headers], Name, Value) :- optional_header(Headers, Name, Value).

read_response_body(Stream, Headers, Limit, Bytes) :-
    ( optional_header(Headers, 'transfer-encoding', Encoding),
      header_has_token(Encoding, chunked)
    -> read_chunked_body(Stream, Limit, Bytes)
    ; optional_header(Headers, 'content-length', LengthAtom)
    -> ( catch(atom_number(LengthAtom, Length), _, fail),
         integer(Length), Length >= 0
       -> enforce_body_limit(Length, Limit), read_exact_bytes(Stream, Length, Bytes)
       ; throw(error(source_uri_protocol_error(content_length(LengthAtom)),
                     source_policy:fetch_source_uri/2))
       )
    ; read_to_eof(Stream, Limit, 0, Bytes)
    ).

header_has_token(Value, Token) :-
    ascii_lower_atom(Value, Lower), atomic_list_concat(Parts0, ',', Lower),
    trim_atoms(Parts0, Parts), memberchk(Token, Parts).

read_chunked_body(Stream, Limit, Bytes) :-
    read_http_line(Stream, 1024, SizeLine), chunk_size(SizeLine, Size),
    ( Size =:= 0 -> read_headers(Stream, _), Bytes = []
    ; enforce_body_limit(Size, Limit),
      read_exact_bytes(Stream, Size, Head), expect_crlf(Stream),
      Remaining is Limit - Size,
      read_chunked_body(Stream, Remaining, Tail), append(Head, Tail, Bytes)
    ).

chunk_size(Line, Size) :-
    ( append(Digits, [0';|_], Line) -> true ; Digits = Line ),
    Digits \== [], hex_value(Digits, 0, Size), !.
chunk_size(Line, _) :-
    throw(error(source_uri_protocol_error(chunk_size(Line)),
                source_policy:fetch_source_uri/2)).

hex_value([], Value, Value).
hex_value([Code|Codes], Value0, Value) :-
    hex_digit_value(Code, Digit), Value1 is Value0 * 16 + Digit,
    hex_value(Codes, Value1, Value).

hex_digit_value(C, V) :- C >= 0'0, C =< 0'9, !, V is C - 0'0.
hex_digit_value(C, V) :- C >= 0'a, C =< 0'f, !, V is C - 0'a + 10.
hex_digit_value(C, V) :- C >= 0'A, C =< 0'F, V is C - 0'A + 10.

read_exact_bytes(_, 0, []) :- !.
read_exact_bytes(Stream, Count, [Byte|Bytes]) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1
    -> throw(error(source_uri_protocol_error(unexpected_eof),
                   source_policy:fetch_source_uri/2))
    ; Next is Count - 1, read_exact_bytes(Stream, Next, Bytes)
    ).

read_to_eof(Stream, Limit, Count, Bytes) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> Bytes = []
    ; Next is Count + 1, enforce_body_limit(Next, Limit),
      Bytes = [Byte|Rest], read_to_eof(Stream, Limit, Next, Rest)
    ).

enforce_body_limit(Size, Limit) :-
    ( Size =< Limit -> true
    ; throw(error(resource_error(input_size(src_uri, Size, Limit)),
                  resource_policy))
    ).

expect_crlf(Stream) :-
    get_byte(Stream, CR), get_byte(Stream, LF),
    ( CR =:= 13, LF =:= 10 -> true
    ; throw(error(source_uri_protocol_error(chunk_ending),
                  source_policy:fetch_source_uri/2))
    ).

read_http_line(Stream, Limit, Line) :-
    ( Limit > 0 -> true
    ; throw(error(resource_error(input_size(source_http_line, 1, 0)),
                  resource_policy))
    ),
    get_byte(Stream, Byte),
    ( Byte =:= -1
    -> throw(error(source_uri_protocol_error(unexpected_eof),
                   source_policy:fetch_source_uri/2))
    ; Byte =:= 13
    -> get_byte(Stream, LF),
       ( LF =:= 10 -> Line = []
       ; throw(error(source_uri_protocol_error(line_ending),
                     source_policy:fetch_source_uri/2)) )
    ; Next is Limit - 1, Line = [Byte|Rest],
      read_http_line(Stream, Next, Rest)
    ).

trim_atoms([], []).
trim_atoms([Atom|Atoms], [Trimmed|Rest]) :-
    atom_codes(Atom, Codes), trim_space(Codes, TrimmedCodes),
    atom_codes(Trimmed, TrimmedCodes), trim_atoms(Atoms, Rest).

trim_space(Codes, Trimmed) :-
    drop_space(Codes, Left), reverse(Left, Reversed),
    drop_space(Reversed, ReversedTrimmed), reverse(ReversedTrimmed, Trimmed).

drop_space([Code|Codes], Rest) :-
    ( Code =:= 32 ; Code =:= 9 ), !, drop_space(Codes, Rest).
drop_space(Codes, Codes).

ascii_lower_codes([], []).
ascii_lower_codes([Code|Codes], [Lower|Lowers]) :-
    ( Code >= 0'A, Code =< 0'Z -> Lower is Code + 32 ; Lower = Code ),
    ascii_lower_codes(Codes, Lowers).

ascii_lower_atom(Atom, Lower) :-
    atom_codes(Atom, Codes), ascii_lower_codes(Codes, LowerCodes),
    atom_codes(Lower, LowerCodes).

source_text_atom(Text, Text) :- atom(Text), !.
source_text_atom(Text, Atom) :- string(Text), !, atom_string(Atom, Text).
source_text_atom(Text, Atom) :- is_list(Text), !,
    ( Text = [Code|_], integer(Code) -> atom_codes(Atom, Text)
    ; atom_chars(Atom, Text)
    ).
source_text_atom(Text, _) :-
    throw(error(type_error(text, Text), source_policy)).

utf8_decode([], []).
utf8_decode([Byte|Bytes], [Code|Codes]) :-
    ( Byte =< 127 -> Code = Byte, Rest = Bytes
    ; Byte >= 194, Byte =< 223 ->
      continuation(Bytes, B2, Rest),
      Code is ((Byte /\ 31) << 6) \/ (B2 /\ 63)
    ; Byte >= 224, Byte =< 239 ->
      continuation(Bytes, B2, R1), continuation(R1, B3, Rest),
      Code is ((Byte /\ 15) << 12) \/ ((B2 /\ 63) << 6) \/ (B3 /\ 63),
      Code >= 2048, (Code < 55296 ; Code > 57343)
    ; Byte >= 240, Byte =< 244 ->
      continuation(Bytes, B2, R1), continuation(R1, B3, R2),
      continuation(R2, B4, Rest),
      Code is ((Byte /\ 7) << 18) \/ ((B2 /\ 63) << 12) \/
              ((B3 /\ 63) << 6) \/ (B4 /\ 63),
      Code >= 65536, Code =< 1114111
    ; invalid_utf8
    ), !,
    utf8_decode(Rest, Codes).
utf8_decode(_, _) :- invalid_utf8.

continuation([Byte|Bytes], Byte, Bytes) :- Byte >= 128, Byte =< 191, !.
continuation(_, _, _) :- invalid_utf8.

invalid_utf8 :-
    throw(error(source_uri_protocol_error(invalid_utf8),
                source_policy:fetch_source_uri/2)).
