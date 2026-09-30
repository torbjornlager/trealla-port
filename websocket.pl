:- module(websocket,
    [ http_open_websocket/3,
      ws_open/3,
      ws_send/2,
      ws_receive/2,
      ws_receive/3,
      ws_close/3,
      ws_accept/3,
      ws_accept/4,
      websocket_server/2,
      websocket_server/3,
      websocket_server_start/3,
      websocket_server_start/4,
      websocket_server_stop/1,
      websocket_server_open/2,
      websocket_server_open/3,
      websocket_server_accept/3,
      websocket_server_close/1
    ]).

/** <module> Native WebSocket transport for Trealla Prolog

This module implements the RFC 6455 opening handshake and wire framing using
ordinary Trealla socket streams.  It deliberately does not use Logtalk or a
foreign stream filter.  The public message terms follow the useful subset of
SWI-Prolog's WebSocket API: `text(Text)`, `binary(Bytes)`, `ping(Bytes)`,
`pong(Bytes)`, and `close(Code, Reason)`.

Both `ws://` and native Trealla `wss://` sockets are supported.  The latter
requires a Trealla build with OpenSSL enabled.  RFC 6455 subprotocol
negotiation is optional; Web Prolog itself uses no WebSocket subprotocol.
*/

:- use_module(library(sockets)).

:- meta_predicate(websocket_server(+, 2)).
:- meta_predicate(websocket_server(+, 2, +)).
:- meta_predicate(websocket_server_start(+, 2, -)).
:- meta_predicate(websocket_server_start(+, 2, -, +)).


                 /*******************************
                 *          PUBLIC API          *
                 *******************************/

%! http_open_websocket(+URL, -WebSocket, +Options) is det.
%
%  Open a client WebSocket. Recognised options are
%  `max_payload_length(Bytes)`, `header(Name, Value)`, `subprotocol(Atom)`,
%  `subprotocols(List)`, and `certfile(File)` for TLS client credentials.

http_open_websocket(URL, WebSocket, Options) :-
    ws_url(URL, Scheme, Host, Port, Path),
    websocket_client_socket_options(Scheme, Options, SocketOptions),
    socket_client_open(Host:Port, Stream, SocketOptions),
    catch(client_handshake(Stream, Host, Port, Path, Options), Error,
          ( close(Stream), throw(Error) )),
    ws_open(Stream, WebSocket, [role(client)|Options]).

%! ws_open(+Stream, -WebSocket, +Options) is det.
%
%  Wrap an already-upgraded bidirectional stream. `role(client)` means that
%  outgoing frames are masked; `role(server)` means incoming frames must be
%  masked. The default payload limit is 16 MiB.

ws_open(Stream, ws(Stream, Role, Max), Options) :-
    option_value(role, Options, server, Role),
    ( memberchk(Role, [client,server]) -> true
    ; throw(error(domain_error(websocket_role, Role), ws_open/3))
    ),
    option_value(max_payload_length, Options, 16777216, Max),
    integer(Max), Max >= 0.

%! ws_send(+WebSocket, +Message) is det.

ws_send(WS, text(Text)) :- !,
    text_codes(Text, Codes), utf8_encode(Codes, Payload),
    send_frame(WS, 1, Payload).
ws_send(WS, binary(Payload)) :- !,
    must_be_bytes(Payload), send_frame(WS, 2, Payload).
ws_send(WS, ping(Payload)) :- !,
    control_payload(Payload), send_frame(WS, 9, Payload).
ws_send(WS, pong(Payload)) :- !,
    control_payload(Payload), send_frame(WS, 10, Payload).
ws_send(WS, close(Code, Reason)) :- !,
    close_payload(Code, Reason, Payload), send_frame(WS, 8, Payload).
ws_send(_, Message) :-
    throw(error(domain_error(websocket_message, Message), ws_send/2)).

%! ws_receive(+WebSocket, -Message) is det.
%! ws_receive(+WebSocket, -Message, +Options) is det.
%
%  Read one complete message. Fragmented data messages are reassembled.
%  Ping frames are answered automatically and pong frames are skipped.

ws_receive(WS, Message) :-
    ws_receive(WS, Message, []).

ws_receive(ws(Stream, Role, DefaultMax), Message, Options) :-
    option_value(max_payload_length, Options, DefaultMax, Max),
    receive_message(ws(Stream, Role, Max), none, [], Message).

%! ws_close(+WebSocket, +Code, +Reason) is det.

ws_close(ws(Stream, Role, Max), Code, Reason) :-
    catch(ws_send(ws(Stream, Role, Max), close(Code, Reason)), _, true),
    close(Stream).

%! websocket_server_open(+Port, -Server) is det.
%! websocket_server_accept(+Server, -WebSocket, -Path) is det.
%! websocket_server_close(+Server) is det.
%
%  Low-level standalone server API. Each accepted socket has completed its
%  HTTP upgrade when this predicate returns. The caller owns the WebSocket.

websocket_server_open(Port, websocket_server(Socket)) :-
    websocket_server_open(Port, websocket_server(Socket), []).

websocket_server_open(Port, websocket_server(Socket), Options) :-
    websocket_server_socket_options(Options, SocketOptions),
    socket_server_open(Port, Socket, SocketOptions).

websocket_server_accept(websocket_server(Socket), WebSocket, Path) :-
    socket_server_accept(Socket, _, Stream, [type(binary)]),
    catch(server_handshake(Stream, Path), Error,
          ( close(Stream), throw(Error) )),
    ws_open(Stream, WebSocket, [role(server)]).

websocket_server_close(websocket_server(Socket)) :-
    socket_server_close(Socket).

%! websocket_server(+Port, :Handler) is det.
%
%  Run a concurrent server in the calling thread. Every accepted connection
%  is upgraded and handled in its own detached thread by calling
%  `Handler(WebSocket, Path)`. This predicate normally does not return.

websocket_server(Port, Handler) :-
    websocket_server(Port, Handler, []).

websocket_server(Port, Handler, Options) :-
    websocket_server_open(Port, websocket_server(Socket), Options),
    catch(websocket_accept_loop(Socket, Handler, Options), Error,
          ( socket_server_close(Socket), throw(Error) )).

%! websocket_server_start(+Port, :Handler, -Server) is det.
%! websocket_server_stop(+Server) is det.
%
%  Start the concurrent server in a joinable listener thread and return
%  immediately. `websocket_server_stop/1` closes the listener and waits for
%  it to terminate. Existing connection handlers are detached and finish
%  independently.

websocket_server_start(Port, Handler, websocket_running(Socket, Thread)) :-
    websocket_server_start(Port, Handler, websocket_running(Socket, Thread), []).

websocket_server_start(Port, Handler, websocket_running(Socket, Thread), Options) :-
    websocket_server_open(Port, websocket_server(Socket), Options),
    catch(thread_create(websocket_accept_loop(Socket, Handler, Options), Thread,
                        [detached(false)]),
          Error,
          ( socket_server_close(Socket), throw(Error) )).

websocket_server_stop(websocket_running(Socket, Thread)) :-
    catch(socket_server_close(Socket), _, true),
    catch(thread_cancel(Thread), _, true),
    catch(thread_join(Thread, _), _, true).

websocket_accept_loop(Socket, Handler, Options) :-
    ( catch(socket_server_accept(Socket, _, Stream, [type(binary)]), Error,
            ( format(user_error, 'websocket: accept error: ~q~n', [Error]), fail ))
    -> ( catch(thread_create(websocket_serve_connection(Stream, Handler, Options), _,
                             [detached(true)]),
               ThreadError,
               ( close(Stream), throw(ThreadError) ))
       -> true
       ;  close(Stream)
       )
    ;  true
    ),
    websocket_accept_loop(Socket, Handler, Options).

websocket_serve_connection(Stream, Handler, Options) :-
    catch(
        ( read_http_line(Stream, Request),
          request_line(Request, Path),
          read_headers(Stream, Headers),
          server_handshake_response(Stream, Headers, Options),
          ws_open(Stream, WebSocket, [role(server)]),
          call(Handler, WebSocket, Path)
        ),
        Error,
        format(user_error, 'websocket: connection error: ~q~n', [Error])
    ),
    catch(close(Stream), _, true).


                 /*******************************
                 *       OPENING HANDSHAKE      *
                 *******************************/

client_handshake(Stream, Host, Port, Path, Options) :-
    random_bytes(16, Nonce), base64_encode(Nonce, Key),
    write_http(Stream, 'GET ~w HTTP/1.1\r\n', [Path]),
    write_http(Stream, 'Host: ~w:~w\r\n', [Host, Port]),
    write_http(Stream, 'Upgrade: websocket\r\nConnection: Upgrade\r\n', []),
    write_http(Stream, 'Sec-WebSocket-Key: ~w\r\nSec-WebSocket-Version: 13\r\n', [Key]),
    write_client_subprotocol(Stream, Options),
    write_extra_headers(Stream, Options),
    write_http(Stream, '\r\n', []), flush_output(Stream),
    read_http_line(Stream, Status),
    ( status_101(Status) -> true
    ; throw(error(websocket_handshake(status(Status)), http_open_websocket/3))
    ),
    read_headers(Stream, Headers),
    require_token_header(Headers, upgrade, websocket),
    require_token_header(Headers, connection, upgrade),
    header_value(Headers, 'sec-websocket-accept', GotAccept),
    websocket_accept(Key, ExpectedAccept),
    ( GotAccept == ExpectedAccept -> true
    ; throw(error(websocket_handshake(bad_accept(GotAccept)),
                  http_open_websocket/3))
    ),
    validate_client_subprotocol(Headers, Options).

server_handshake(Stream, Path) :-
    read_http_line(Stream, Request),
    request_line(Request, Path),
    read_headers(Stream, Headers),
    server_handshake_response(Stream, Headers).

%! ws_accept(+Stream, +Headers, -WebSocket) is det.
%
%  Complete a server-side upgrade after an HTTP server has already parsed
%  the request. `Headers` is a list of lowercase `Name-Value` atom pairs.
%  This is the socket-handoff point used by a shared HTTP/WebSocket listener.

ws_accept(Stream, Headers, WebSocket) :-
    ws_accept(Stream, Headers, WebSocket, []).

ws_accept(Stream, Headers, WebSocket, Options) :-
    server_handshake_response(Stream, Headers, Options),
    ws_open(Stream, WebSocket, [role(server)]).

server_handshake_response(Stream, Headers) :-
    server_handshake_response(Stream, Headers, []).

server_handshake_response(Stream, Headers, Options) :-
    require_token_header(Headers, upgrade, websocket),
    require_token_header(Headers, connection, upgrade),
    header_value(Headers, 'sec-websocket-version', Version),
    ( Version == '13' -> true
    ; throw(error(websocket_handshake(version(Version)),
                  websocket_server_accept/3))
    ),
    header_value(Headers, 'sec-websocket-key', Key),
    ( valid_websocket_key(Key) -> true
    ; throw(error(websocket_handshake(invalid_key(Key)),
                  websocket_server_accept/3))
    ),
    websocket_accept(Key, Accept),
    write_http(Stream, 'HTTP/1.1 101 Switching Protocols\r\n', []),
    write_http(Stream, 'Upgrade: websocket\r\nConnection: Upgrade\r\n', []),
    write_http(Stream, 'Sec-WebSocket-Accept: ~w\r\n', [Accept]),
    server_subprotocol(Stream, Headers, Options),
    write_http(Stream, '\r\n', []),
    flush_output(Stream).

write_extra_headers(_, []).
write_extra_headers(Stream, [header(Name, Value)|Options]) :- !,
    write_http(Stream, '~w: ~w\r\n', [Name, Value]),
    write_extra_headers(Stream, Options).
write_extra_headers(Stream, [_|Options]) :-
    write_extra_headers(Stream, Options).

write_client_subprotocol(Stream, Options) :-
    ( memberchk(subprotocol(Protocol), Options) ->
        write_http(Stream, 'Sec-WebSocket-Protocol: ~w\r\n', [Protocol])
    ; memberchk(subprotocols(Protocols), Options), Protocols \== [] ->
        join_protocols(Protocols, Header),
        write_http(Stream, 'Sec-WebSocket-Protocol: ~w\r\n', [Header])
    ; true
    ).

validate_client_subprotocol(Headers, Options) :-
    ( memberchk(subprotocol(Expected), Options) ->
        header_value(Headers, 'sec-websocket-protocol', Selected),
        ( Selected == Expected -> true
        ; throw(error(websocket_handshake(subprotocol(Selected)),
                      http_open_websocket/3)) )
    ; memberchk(subprotocols(Offered), Options) ->
        header_value(Headers, 'sec-websocket-protocol', Selected),
        ( memberchk(Selected, Offered) -> true
        ; throw(error(websocket_handshake(subprotocol(Selected)),
                      http_open_websocket/3)) )
    ; true
    ).

server_subprotocol(Stream, Headers, Options) :-
    ( memberchk(subprotocol(Required), Options) -> Acceptable = [Required]
    ; memberchk(subprotocols(Acceptable), Options) -> true
    ; Acceptable = []
    ),
    ( Acceptable == [] -> true
    ; header_value(Headers, 'sec-websocket-protocol', OfferedHeader),
      protocol_atoms(OfferedHeader, Offered),
      select_protocol(Acceptable, Offered, Selected),
      write_http(Stream, 'Sec-WebSocket-Protocol: ~w\r\n', [Selected])
    ).

select_protocol([Protocol|_], Offered, Protocol) :-
    memberchk(Protocol, Offered), !.
select_protocol([_|Protocols], Offered, Selected) :-
    select_protocol(Protocols, Offered, Selected).
select_protocol([], _, _) :-
    throw(error(websocket_handshake(no_acceptable_subprotocol), ws_accept/4)).

protocol_atoms(Header, Protocols) :-
    atomic_list_concat(Raw, ',', Header), trim_atoms(Raw, Protocols).

join_protocols([Protocol], Protocol) :- !.
join_protocols([Protocol|Protocols], Header) :-
    join_protocols(Protocols, Rest),
    atomic_list_concat([Protocol, Rest], ', ', Header).

% Trealla intentionally rejects format/3 on binary streams. HTTP handshake
% bytes are ASCII, so format into an atom and emit its codes explicitly.
write_http(Stream, Format, Arguments) :-
    format(atom(Atom), Format, Arguments),
    atom_codes(Atom, Bytes),
    write_bytes(Stream, Bytes).

status_101(Codes) :-
    atom_codes('HTTP/1.1 101', Prefix), append(Prefix, _, Codes), !.
status_101(Codes) :-
    atom_codes('HTTP/1.0 101', Prefix), append(Prefix, _, Codes).

request_line(Codes, Path) :-
    atom_codes(Line, Codes),
    atomic_list_concat(['GET', Path0, Version], ' ', Line),
    ( Version == 'HTTP/1.1' ; Version == 'HTTP/1.0' ), !,
    Path = Path0.
request_line(Line, _) :-
    throw(error(websocket_handshake(request_line(Line)),
                websocket_server_accept/3)).

read_headers(Stream, Headers) :-
    read_http_line(Stream, Line),
    ( Line == [] -> Headers = []
    ; parse_header(Line, Header),
      Headers = [Header|Rest],
      read_headers(Stream, Rest)
    ).

parse_header(Codes, Name-Value) :-
    append(NameCodes, [0':|RawValue], Codes), !,
    trim_space(RawValue, ValueCodes),
    ascii_lower_codes(NameCodes, LowerNameCodes), atom_codes(Name, LowerNameCodes),
    atom_codes(Value, ValueCodes).
parse_header(Line, _) :-
    throw(error(websocket_handshake(header(Line)), websocket_server_accept/3)).

header_value([Name-Value|_], Name, Value) :- !.
header_value([_|Headers], Name, Value) :-
    header_value(Headers, Name, Value).
header_value([], Name, _) :-
    throw(error(websocket_handshake(missing_header(Name)), websocket/0)).

require_token_header(Headers, Name, Token) :-
    header_value(Headers, Name, Value),
    atom_codes(Value, ValueCodes), ascii_lower_codes(ValueCodes, LowerCodes),
    atom_codes(Lower, LowerCodes),
    atomic_list_concat(Parts0, ',', Lower),
    trim_atoms(Parts0, Parts),
    ( memberchk(Token, Parts) -> true
    ; throw(error(websocket_handshake(header_value(Name, Value)), websocket/0))
    ).

trim_atoms([], []).
trim_atoms([A|As], [T|Ts]) :-
    atom_codes(A, Cs), trim_space(Cs, Ds), atom_codes(T, Ds),
    trim_atoms(As, Ts).

read_http_line(Stream, Line) :-
    get_byte(Stream, B),
    ( B =:= -1 -> throw(error(websocket_handshake(unexpected_eof), websocket/0))
    ; B =:= 13 ->
        get_byte(Stream, LF),
        ( LF =:= 10 -> Line = []
        ; throw(error(websocket_handshake(bad_line_ending), websocket/0)) )
    ; Line = [B|Rest], read_http_line(Stream, Rest)
    ).

trim_space(Codes, Trimmed) :-
    drop_space(Codes, Left), reverse(Left, Rev),
    drop_space(Rev, RevTrimmed), reverse(RevTrimmed, Trimmed).

drop_space([C|Cs], Rest) :- (C =:= 32 ; C =:= 9), !, drop_space(Cs, Rest).
drop_space(Cs, Cs).

ascii_lower_codes([], []).
ascii_lower_codes([C|Cs], [L|Ls]) :-
    ( C >= 65, C =< 90 -> L is C + 32 ; L = C ),
    ascii_lower_codes(Cs, Ls).

% A canonical base64 encoding of exactly 16 bytes is 24 characters: 22
% alphabet characters followed by `==`.
valid_websocket_key(Key) :-
    atom_codes(Key, Codes),
    length(Codes, 24),
    append(Body, [0'=,0'=], Codes),
    length(Body, 22),
    base64_body(Body).

base64_body([]).
base64_body([C|Cs]) :-
    ( C >= 0'A, C =< 0'Z
    ; C >= 0'a, C =< 0'z
    ; C >= 0'0, C =< 0'9
    ; C =:= 0'+
    ; C =:= 0'/
    ),
    base64_body(Cs).


                 /*******************************
                 *            FRAMES            *
                 *******************************/

send_frame(ws(Stream, Role, _), Opcode, Payload) :-
    length(Payload, Length),
    ( Opcode >= 8, Length > 125 ->
        throw(error(domain_error(websocket_control_payload, Length), ws_send/2))
    ; true
    ),
    First is 128 \/ Opcode,
    put_byte(Stream, First),
    ( Role == client ->
        random_bytes(4, Key), Mask = 128
    ; Key = [], Mask = 0
    ),
    write_length(Stream, Mask, Length),
    write_bytes(Stream, Key),
    ( Key == [] -> Wire = Payload ; mask_bytes(Payload, Key, 0, Wire) ),
    write_bytes(Stream, Wire), flush_output(Stream).

write_length(Stream, Mask, Length) :-
    ( Length =< 125 -> Byte is Mask \/ Length, put_byte(Stream, Byte)
    ; Length =< 65535 ->
        Byte is Mask \/ 126, put_byte(Stream, Byte), put_uint(Stream, 2, Length)
    ; Length < 9223372036854775808 ->
        Byte is Mask \/ 127, put_byte(Stream, Byte), put_uint(Stream, 8, Length)
    ; throw(error(domain_error(websocket_payload_length, Length), ws_send/2))
    ).

read_frame(ws(Stream, Role, Max), Fin, Opcode, Payload) :-
    get_byte(Stream, B0),
    ( B0 =:= -1 -> Fin = eof, Opcode = eof, Payload = []
    ; get_required_byte(Stream, B1),
      ( B0 /\ 112 =:= 0 -> true
      ; protocol_error(reserved_bits) ),
      Fin is (B0 >> 7) /\ 1,
      Opcode is B0 /\ 15,
      valid_opcode(Opcode),
      Masked is (B1 >> 7) /\ 1,
      validate_mask(Role, Masked),
      Len0 is B1 /\ 127,
      read_length(Stream, Len0, Length),
      ( Length =< Max -> true ; protocol_error(payload_too_large(Length, Max)) ),
      ( Opcode >= 8, (Fin =\= 1 ; Length > 125) -> protocol_error(control_frame)
      ; true ),
      ( Masked =:= 1 -> read_n(Stream, 4, Key) ; Key = [] ),
      read_n(Stream, Length, Wire),
      ( Key == [] -> Payload = Wire ; mask_bytes(Wire, Key, 0, Payload) )
    ).

valid_opcode(O) :- memberchk(O, [0,1,2,8,9,10]), !.
valid_opcode(O) :- protocol_error(opcode(O)).

validate_mask(server, 1) :- !.
validate_mask(client, 0) :- !.
validate_mask(Role, Masked) :- protocol_error(mask(Role, Masked)).

read_length(Stream, 126, Length) :- !, read_uint(Stream, 2, Length),
    ( Length >= 126 -> true ; protocol_error(non_minimal_length) ).
read_length(Stream, 127, Length) :- !, read_uint(Stream, 8, Length),
    ( Length >= 65536, Length < 9223372036854775808 -> true
    ; protocol_error(invalid_64_bit_length) ).
read_length(_, Length, Length).

receive_message(WS, Fragment, Acc, Message) :-
    read_frame(WS, Fin, Opcode, Payload),
    receive_frame(Fin, Opcode, Payload, WS, Fragment, Acc, Message).

receive_frame(eof, eof, _, _, _, _, end_of_file) :- !.
receive_frame(_, 9, Payload, WS, Fragment, Acc, Message) :- !,
    ws_send(WS, pong(Payload)),
    receive_message(WS, Fragment, Acc, Message).
receive_frame(_, 10, _, WS, Fragment, Acc, Message) :- !,
    receive_message(WS, Fragment, Acc, Message).
receive_frame(_, 8, Payload, _, _, _, Message) :- !,
    parse_close_payload(Payload, Message).
receive_frame(1, 1, Payload, _, none, _, text(Text)) :- !,
    utf8_decode(Payload, Codes), atom_codes(Text, Codes).
receive_frame(1, 2, Payload, _, none, _, binary(Payload)) :- !.
receive_frame(0, Opcode, Payload, WS, none, _, Message) :-
    memberchk(Opcode, [1,2]), !,
    receive_message(WS, fragment(Opcode), Payload, Message).
receive_frame(Fin, 0, Payload, WS, fragment(Opcode), Acc0, Message) :- !,
    append(Acc0, Payload, Acc),
    WS = ws(_, _, Max), length(Acc, Total),
    ( Total =< Max -> true ; protocol_error(message_too_large(Total, Max)) ),
    ( Fin =:= 1 -> complete_message(Opcode, Acc, Message)
    ; receive_message(WS, fragment(Opcode), Acc, Message)
    ).
receive_frame(_, Opcode, _, _, Fragment, _, _) :-
    protocol_error(fragment(Opcode, Fragment)).

complete_message(1, Payload, text(Text)) :-
    utf8_decode(Payload, Codes), atom_codes(Text, Codes).
complete_message(2, Payload, binary(Payload)).

parse_close_payload([], close(1005, '')) :- !.
parse_close_payload([_], _) :- !, protocol_error(close_payload).
parse_close_payload([A,B|ReasonBytes], close(Code, Reason)) :-
    Code is (A << 8) \/ B,
    valid_close_code(Code),
    utf8_decode(ReasonBytes, ReasonCodes), atom_codes(Reason, ReasonCodes).

close_payload(Code, Reason, [A,B|Bytes]) :-
    valid_close_code(Code),
    text_codes(Reason, Codes), utf8_encode(Codes, Bytes),
    length(Bytes, N), N =< 123,
    A is (Code >> 8) /\ 255, B is Code /\ 255.

valid_close_code(Code) :-
    integer(Code), Code >= 1000, Code < 5000,
    \+ memberchk(Code, [1004,1005,1006,1015]),
    ( Code < 1016 ; Code >= 3000 ), !.
valid_close_code(Code) :- protocol_error(close_code(Code)).

control_payload(Payload) :-
    must_be_bytes(Payload), length(Payload, N),
    ( N =< 125 -> true
    ; throw(error(domain_error(websocket_control_payload, N), ws_send/2))
    ).

protocol_error(Reason) :-
    throw(error(websocket_protocol_error(Reason), websocket/0)).


                 /*******************************
                 *        BYTE UTILITIES        *
                 *******************************/

get_required_byte(Stream, Byte) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> protocol_error(unexpected_eof) ; true ).

read_n(_, 0, []) :- !.
read_n(Stream, N, [B|Bs]) :-
    N > 0, get_required_byte(Stream, B), N1 is N - 1,
    read_n(Stream, N1, Bs).

write_bytes(_, []).
write_bytes(Stream, [B|Bs]) :- put_byte(Stream, B), write_bytes(Stream, Bs).

read_uint(Stream, N, Value) :- read_uint(Stream, N, 0, Value).
read_uint(_, 0, Value, Value) :- !.
read_uint(Stream, N, Acc, Value) :-
    get_required_byte(Stream, B), Acc1 is (Acc << 8) \/ B,
    N1 is N - 1, read_uint(Stream, N1, Acc1, Value).

put_uint(_, 0, _) :- !.
put_uint(Stream, N, Value) :-
    Shift is (N - 1) * 8, B is (Value >> Shift) /\ 255,
    put_byte(Stream, B), N1 is N - 1, put_uint(Stream, N1, Value).

mask_bytes([], _, _, []).
mask_bytes([B|Bs], Key, I, [M|Ms]) :-
    J is I mod 4, nth0(J, Key, K), M is xor(B, K),
    I1 is I + 1, mask_bytes(Bs, Key, I1, Ms).

must_be_bytes([]).
must_be_bytes([B|Bs]) :- integer(B), B >= 0, B =< 255, must_be_bytes(Bs).

text_codes(Text, Codes) :- atom(Text), !, atom_codes(Text, Codes).
text_codes(Text, Codes) :- string(Text), !, string_codes(Text, Codes).
text_codes(Text, _) :- throw(error(type_error(text, Text), ws_send/2)).

option_value(Name, Options, Default, Value) :-
    Option =.. [Name, Found],
    ( memberchk(Option, Options) -> Value = Found ; Value = Default ).


                 /*******************************
                 *             UTF-8            *
                 *******************************/

utf8_encode([], []).
utf8_encode([C|Cs], Bytes) :-
    utf8_code(C, Head), append(Head, Rest, Bytes), utf8_encode(Cs, Rest).

utf8_code(C, [C]) :- C >= 0, C =< 127, !.
utf8_code(C, [B1,B2]) :- C >= 128, C =< 2047, !,
    B1 is 192 \/ (C >> 6), B2 is 128 \/ (C /\ 63).
utf8_code(C, [B1,B2,B3]) :- C >= 2048, C =< 65535,
    (C < 55296 ; C > 57343), !,
    B1 is 224 \/ (C >> 12), B2 is 128 \/ ((C >> 6) /\ 63),
    B3 is 128 \/ (C /\ 63).
utf8_code(C, [B1,B2,B3,B4]) :- C >= 65536, C =< 1114111, !,
    B1 is 240 \/ (C >> 18), B2 is 128 \/ ((C >> 12) /\ 63),
    B3 is 128 \/ ((C >> 6) /\ 63), B4 is 128 \/ (C /\ 63).
utf8_code(C, _) :- protocol_error(invalid_unicode(C)).

utf8_decode([], []).
utf8_decode([B|Bs], [C|Cs]) :-
    ( B =< 127 -> C = B, Rest = Bs
    ; B >= 194, B =< 223 ->
        continuation(Bs, B2, Rest), C is ((B /\ 31) << 6) \/ (B2 /\ 63)
    ; B >= 224, B =< 239 ->
        continuation(Bs, B2, R1), continuation(R1, B3, Rest),
        C is ((B /\ 15) << 12) \/ ((B2 /\ 63) << 6) \/ (B3 /\ 63),
        C >= 2048, (C < 55296 ; C > 57343)
    ; B >= 240, B =< 244 ->
        continuation(Bs, B2, R1), continuation(R1, B3, R2),
        continuation(R2, B4, Rest),
        C is ((B /\ 7) << 18) \/ ((B2 /\ 63) << 12) \/
             ((B3 /\ 63) << 6) \/ (B4 /\ 63),
        C >= 65536, C =< 1114111
    ; protocol_error(invalid_utf8)
    ), !,
    utf8_decode(Rest, Cs).
utf8_decode(_, _) :- protocol_error(invalid_utf8).

continuation([B|Bs], B, Bs) :- B >= 128, B =< 191, !.
continuation(_, _, _) :- protocol_error(invalid_utf8).


                 /*******************************
                 *       URL AND RANDOMNESS     *
                 *******************************/

ws_url(URL, Scheme, Host, Port, Path) :-
    atom(URL), websocket_scheme(URL, Scheme, Rest), !,
    ( sub_atom(Rest, Slash, 1, _, '/') ->
        sub_atom(Rest, 0, Slash, _, Authority),
        sub_atom(Rest, Slash, _, 0, Path)
    ; Authority = Rest, Path = '/'
    ),
    ( sub_atom(Authority, Colon, 1, _, ':') ->
        sub_atom(Authority, 0, Colon, _, Host),
        Start is Colon + 1, sub_atom(Authority, Start, _, 0, PortAtom),
        atom_number(PortAtom, Port)
    ; Host = Authority, websocket_default_port(Scheme, Port)
    ),
    Host \== ''.
ws_url(URL, _, _, _, _) :-
    throw(error(domain_error(websocket_url, URL), http_open_websocket/3)).

websocket_scheme(URL, ws, Rest) :- atom_concat('ws://', Rest, URL), !.
websocket_scheme(URL, wss, Rest) :- atom_concat('wss://', Rest, URL).

websocket_default_port(ws, 80).
websocket_default_port(wss, 443).

websocket_client_socket_options(ws, _, [type(binary)]).
websocket_client_socket_options(wss, Options, SocketOptions) :-
    ( memberchk(certfile(Certificate), Options) ->
        SocketOptions = [ssl(true),certfile(Certificate),type(binary)]
    ; memberchk(tls_certificate(Certificate), Options) ->
        SocketOptions = [ssl(true),certfile(Certificate),type(binary)]
    ; SocketOptions = [ssl(true),type(binary)]
    ).

websocket_server_socket_options(Options, SocketOptions) :-
    ( memberchk(ssl(true), Options) ->
        SocketOptions0 = [ssl(true)]
    ; SocketOptions0 = []
    ),
    copy_socket_option(keyfile, Options, SocketOptions0, SocketOptions1),
    copy_socket_option(certfile, Options, SocketOptions1, SocketOptions2),
    append(SocketOptions2, [type(binary)], SocketOptions).

copy_socket_option(Name, Options, Input, Output) :-
    Option =.. [Name, Value],
    ( memberchk(Option, Options) -> OutputOption =.. [Name, Value],
      append(Input, [OutputOption], Output)
    ; Output = Input
    ).

random_bytes(N, Bytes) :-
    catch(open('/dev/urandom', read, Stream, [type(binary)]), _, fail), !,
    read_n(Stream, N, Bytes), close(Stream).
random_bytes(N, Bytes) :- random_bytes_fallback(N, Bytes).

random_bytes_fallback(0, []) :- !.
random_bytes_fallback(N, [B|Bs]) :-
    B is random(256), N1 is N - 1, random_bytes_fallback(N1, Bs).


                 /*******************************
                 *       BASE64 AND SHA-1       *
                 *******************************/

websocket_accept(Key, Accept) :-
    atom_codes(Key, KeyCodes),
    atom_codes('258EAFA5-E914-47DA-95CA-C5AB0DC85B11', Guid),
    append(KeyCodes, Guid, Input), sha1(Input, Digest),
    base64_encode(Digest, Accept).

base64_encode(Bytes, Atom) :-
    base64_codes(Bytes, Codes), atom_codes(Atom, Codes).

base64_codes([], []).
base64_codes([A], [C1,C2,0'=,0'=]) :- !,
    I1 is A >> 2, I2 is (A /\ 3) << 4,
    b64_char(I1,C1), b64_char(I2,C2).
base64_codes([A,B], [C1,C2,C3,0'=]) :- !,
    I1 is A >> 2, I2 is ((A /\ 3) << 4) \/ (B >> 4),
    I3 is (B /\ 15) << 2,
    b64_char(I1,C1), b64_char(I2,C2), b64_char(I3,C3).
base64_codes([A,B,C|Rest], [C1,C2,C3,C4|Codes]) :-
    I1 is A >> 2, I2 is ((A /\ 3) << 4) \/ (B >> 4),
    I3 is ((B /\ 15) << 2) \/ (C >> 6), I4 is C /\ 63,
    b64_char(I1,C1), b64_char(I2,C2), b64_char(I3,C3), b64_char(I4,C4),
    base64_codes(Rest, Codes).

b64_char(I, C) :-
    ( I < 26 -> C is 65 + I
    ; I < 52 -> C is 97 + I - 26
    ; I < 62 -> C is 48 + I - 52
    ; I =:= 62 -> C = 43
    ; C = 47
    ).

sha1(Bytes, Digest) :-
    length(Bytes, Len), BitLen is Len * 8,
    append(Bytes, [128], P0), sha1_zero_pad(P0, P1),
    uint_bytes(8, BitLen, Tail), append(P1, Tail, Padded),
    sha1_blocks(Padded, 0x67452301, 0xEFCDAB89, 0x98BADCFE,
                0x10325476, 0xC3D2E1F0, H0,H1,H2,H3,H4),
    uint_bytes(4,H0,D0), uint_bytes(4,H1,D1), uint_bytes(4,H2,D2),
    uint_bytes(4,H3,D3), uint_bytes(4,H4,D4),
    append([D0,D1,D2,D3,D4], Digest).

sha1_zero_pad(Bytes, Padded) :-
    length(Bytes, N), ( N mod 64 =:= 56 -> Padded = Bytes
    ; append(Bytes, [0], More), sha1_zero_pad(More, Padded) ).

sha1_blocks([], A,B,C,D,E, A,B,C,D,E).
sha1_blocks(Bytes, A0,B0,C0,D0,E0, A,B,C,D,E) :-
    take_n(64, Bytes, Block, Rest), words16(Block, W16),
    extend_words(16, W16, Words),
    sha1_rounds(0, Words, A0,B0,C0,D0,E0, RA,RB,RC,RD,RE),
    add32(A0,RA,A1), add32(B0,RB,B1), add32(C0,RC,C1),
    add32(D0,RD,D1), add32(E0,RE,E1),
    sha1_blocks(Rest,A1,B1,C1,D1,E1,A,B,C,D,E).

words16([], []).
words16([A,B,C,D|Bs], [W|Ws]) :-
    W is (A<<24) \/ (B<<16) \/ (C<<8) \/ D, words16(Bs, Ws).

extend_words(80, W, W) :- !.
extend_words(I, W0, W) :-
    A is I-3, B is I-8, C is I-14, D is I-16,
    nth0(A,W0,W3), nth0(B,W0,W8), nth0(C,W0,W14), nth0(D,W0,W16),
    X is xor(W3,xor(W8,xor(W14,W16))), rol32(X,1,WN),
    append(W0,[WN],W1), I1 is I+1, extend_words(I1,W1,W).

sha1_rounds(80, _, A,B,C,D,E, A,B,C,D,E) :- !.
sha1_rounds(I, W, A0,B0,C0,D0,E0, A,B,C,D,E) :-
    sha1_fk(I,B0,C0,D0,F,K), nth0(I,W,WI), rol32(A0,5,AR),
    add32_5(AR,F,E0,K,WI,T), rol32(B0,30,BR), I1 is I+1,
    sha1_rounds(I1,W,T,A0,BR,C0,D0,A,B,C,D,E).

sha1_fk(I,B,C,D,F,0x5A827999) :- I < 20, !, F is (B /\ C) \/ ((\ B) /\ D).
sha1_fk(I,B,C,D,F,0x6ED9EBA1) :- I < 40, !, F is xor(B,xor(C,D)).
sha1_fk(I,B,C,D,F,0x8F1BBCDC) :- I < 60, !, F is (B /\ C) \/ (B /\ D) \/ (C /\ D).
sha1_fk(_,B,C,D,F,0xCA62C1D6) :- F is xor(B,xor(C,D)).

add32(A,B,R) :- R is (A+B) /\ 0xffffffff.
add32_5(A,B,C,D,E,R) :- R is (A+B+C+D+E) /\ 0xffffffff.
rol32(X,N,R) :- R is ((X<<N) \/ ((X /\ 0xffffffff)>>(32-N))) /\ 0xffffffff.

uint_bytes(N, Value, Bytes) :- uint_bytes_(N, Value, Bytes).
uint_bytes_(0, _, []) :- !.
uint_bytes_(N, Value, [B|Bs]) :-
    Shift is (N-1)*8, B is (Value>>Shift) /\ 255,
    N1 is N-1, uint_bytes_(N1,Value,Bs).

take_n(0, Rest, [], Rest) :- !.
take_n(N, [X|Xs], [X|Ys], Rest) :- N1 is N-1, take_n(N1,Xs,Ys,Rest).
