% SPDX-License-Identifier: MIT

/** <module> Tests for the native Trealla WebSocket transport

Run the self-contained tests with:

  tpl -g "consult(websocket_tests),websocket_tests,halt"

The `trealla_client_test/1` and `trealla_server_once/1` predicates are used by
the cross-runtime test commands documented in README.md.
*/

:- use_module(websocket).
:- use_module(node).
:- use_module(web_prolog).

:- op(200, xfx, @).

websocket_tests :-
    handshake_vector,
    utf8_vector,
    close_vector,
    web_prolog_json_vector,
    web_prolog_binding_json_vector,
    named_variable_json_vectors,
    web_prolog_pid_binding_vector,
    profile_advertisement_vector,
    web_prolog_variable_sharing_vector,
    web_prolog_named_binding_vector,
    multiline_quoted_source_vector,
    browser_io_state_vectors,
    format('WebSocket unit tests: ok~n').

handshake_vector :-
    websocket:websocket_accept('dGhlIHNhbXBsZSBub25jZQ==', Accept),
    Accept == 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='.

utf8_vector :-
    Codes = [0,97,229,8364,128512,1114111],
    websocket:utf8_encode(Codes, Bytes),
    websocket:utf8_decode(Bytes, Codes).

close_vector :-
    websocket:close_payload(1000, 'klart', Bytes),
    websocket:parse_close_payload(Bytes, close(1000, 'klart')).

web_prolog_json_vector :-
    web_prolog:event_json(success(7, [a,b], true), JSON),
    web_prolog:json_atom(JSON, Text),
    Text == '{"type":"success","pid":7,"data":["a","b"],"more":true}'.

web_prolog_binding_json_vector :-
    web_prolog:event_json(
        success(7,
                [json_bindings(['Xs'=[b,c]]),
                 json_bindings(['Xs'=[a,b,c],'Ys'=[]])],
                false),
        JSON),
    web_prolog:json_atom(JSON, Text),
    Text == '{"type":"success","pid":7,"data":[{"Xs":"[b,c]"},{"Xs":"[a,b,c]","Ys":"[]"}],"more":false}'.

named_variable_json_vectors :-
    Bindings = ['X'=Shared,'Y'=Shared,'Term'=f(Shared, _Anonymous)],
    web_prolog:event_json(
        success(7, [json_bindings(Bindings)], false), WebSocketJSON),
    web_prolog:json_atom(WebSocketJSON, WebSocketText),
    WebSocketText == '{"type":"success","pid":7,"data":[{"X":"X","Y":"X","Term":"f(X,_)"}],"more":false}',
    node:answer_json(success([json_bindings(Bindings)], false), HTTPJSON),
    web_prolog:json_atom(HTTPJSON, HTTPText),
    HTTPText == '{"type":"success","data":[{"X":"X","Y":"X","Term":"f(X,_)"}],"more":false}'.

web_prolog_pid_binding_vector :-
    RuntimePid = '$thread'(39),
    WirePid = 1234567890,
    Node = 'https://n5.example.org',
    setup_call_cleanup(
        ( retractall(web_prolog:node_public_url(_)),
          assertz(web_prolog:node_public_url(Node)),
          web_prolog:relay_set_actors([actor(WirePid, RuntimePid, session)])
        ),
        ( web_prolog:wire_event(
              ignored,
              success(RuntimePid, [json_bindings(['Self'=RuntimePid])], false),
              Event),
          web_prolog:event_json(Event, JSON),
          once(web_prolog:json_atom(JSON, Text)),
          Text == '{"type":"success","pid":1234567890,"data":[{"Self":"1234567890@\'https:\\/\\/n5.example.org\'"}],"more":false}',
          web_prolog:import_browser_pids(WirePid@Node, ignored, Imported),
          Imported == RuntimePid
        ),
        ( web_prolog:relay_set_actors([]),
          retractall(web_prolog:node_public_url(_))
        )).

profile_advertisement_vector :-
    web_prolog:event_json(transport_welcome(1, actor, blacklist), JSON),
    web_prolog:json_atom_field(JSON, type, transport_welcome),
    web_prolog:json_atom_field(JSON, profile, actor),
    web_prolog:json_atom_field(JSON, sandbox, blacklist).

web_prolog_variable_sharing_vector :-
    web_prolog:read_goal_options('member(X,[a,b])', '[template(X),limit(1)]',
                                 Goal, Options),
    Goal = member(GoalX, _),
    memberchk(template(json_bindings(['X'=TemplateX])), Options),
    GoalX == TemplateX.

web_prolog_named_binding_vector :-
    web_prolog:read_goal_options(
        'append(Xs,Ys,[a,b,c])', '[limit(10)]', Goal, Options),
    Goal = append(GoalXs, GoalYs, _),
    memberchk(template(json_bindings(Bindings)), Options),
    Bindings = ['Xs'=TemplateXs,'Ys'=TemplateYs],
    GoalXs == TemplateXs,
    GoalYs == TemplateYs.

multiline_quoted_source_vector :-
    format(atom(GoalText),
           'spawn(local_value(X),_,[src_text("~nlocal_value(ok).~n")])',
           []),
    web_prolog:read_goal_options(GoalText, '[]', Goal, _Options),
    Goal = spawn(local_value(_), _, [src_text(Source)]),
    quoted_source_atom(Source, SourceAtom),
    sub_atom(SourceAtom, _, _, _, '\n'),
    read_term_from_atom(SourceAtom, local_value(ok), []),
    format(atom(CommentGoal), '% ignored "~nX = "~nvalue~n"', []),
    web_prolog:read_goal_options(CommentGoal, '[]', (_ = Quoted), _),
    quoted_source_atom(Quoted, QuotedAtom),
    QuotedAtom == '\nvalue\n'.

quoted_source_atom(Source, Source) :- atom(Source), !.
quoted_source_atom(Source, Atom) :-
    ( Source = [C|_], integer(C) -> atom_codes(Atom, Source)
    ; atom_chars(Atom, Source)
    ).

browser_io_state_vectors :-
    message_queue_create(ReplyQueue),
    setup_call_cleanup(
        true,
        ( web_prolog:set_browser_io_enabled(relay_a, true),
          web_prolog:register_browser_io_request(relay_a, request_1,
                                                 ReplyQueue),
          web_prolog:browser_io_reply(relay_b, request_1, ok),
          \+ thread_get_message(ReplyQueue, _, [timeout(0)]),
          web_prolog:browser_io_reply(relay_a, request_1, ok),
          thread_get_message(ReplyQueue, ok, [timeout(0)]),
          web_prolog:remember_browser_prompt(relay_a, 41, remote_prompt_pid),
          \+ web_prolog:take_browser_prompt(relay_b, 41, _),
          web_prolog:take_browser_prompt(relay_a, 41, remote_prompt_pid),
          \+ web_prolog:take_browser_prompt(relay_a, 41, _),
          web_prolog:register_browser_io_request(relay_a, request_2,
                                                 ReplyQueue),
          web_prolog:close_browser_io(relay_a),
          thread_get_message(ReplyQueue, connection_closed, [timeout(0)])
        ),
        ( web_prolog:close_browser_io(relay_a),
          web_prolog:close_browser_io(relay_b),
          catch(message_queue_destroy(ReplyQueue), _, true)
        )
    ).

trealla_client_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/echo', [Port]),
    http_open_websocket(URL, WS, []),
    ws_send(WS, ping([112,105,110,103])),
    ws_send(WS, text('Trealla says: hållå € 😀')),
    ws_receive(WS, text(Reply)),
    Reply == 'Trealla says: hållå € 😀',
    ws_send(WS, binary([0,1,2,127,128,255])),
    ws_receive(WS, binary([0,1,2,127,128,255])),
    length(Large, 66000), fill_bytes(Large, 90),
    ws_send(WS, binary(Large)),
    ws_receive(WS, binary(Large)),
    ws_close(WS, 1000, done),
    format('Trealla client interoperability test: ok~n').

trealla_server_once(Port) :-
    websocket_server_open(Port, Server),
    websocket_server_accept(Server, WS, '/echo'),
    ws_receive(WS, First), ws_send(WS, First),
    ws_receive(WS, Second), ws_send(WS, Second),
    ws_receive(WS, Third), ws_send(WS, Third),
    ws_receive(WS, close(Code, Reason)),
    ws_send(WS, close(Code, Reason)),
    WS = ws(Stream, _, _), close(Stream),
    websocket_server_close(Server),
    format('Trealla server interoperability test: ok~n').

fill_bytes([], _).
fill_bytes([Byte|Bytes], Byte) :- fill_bytes(Bytes, Byte).

% Trealla client against a version-1 Web Prolog endpoint.  The SWI fixture
% returns a fixed result, so this checks wire compatibility independently of
% the Trealla actor engine.
trealla_protocol_client_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/actor', [Port]),
    web_prolog_connect(URL, WS),
    web_prolog:object([command-string_atom(transport_hello),version-number(1)], Hello),
    web_prolog_send(WS, Hello),
    web_prolog_receive(WS, Welcome),
    web_prolog:json_atom_field(Welcome, type, transport_welcome),
    web_prolog:object([command-string_atom(toplevel_spawn),
                       options-string_atom('[session(true)]')], Spawn),
    web_prolog_send(WS, Spawn),
    web_prolog_receive(WS, Spawned),
    web_prolog:json_integer_field(Spawned, pid, Pid),
    web_prolog:object([command-string_atom(toplevel_call),pid-number(Pid),
                       goal-string_atom('member(X,[a,b,c])'),
                       options-string_atom('[template(X),limit(2)]')], Call),
    web_prolog_send(WS, Call),
    web_prolog_receive(WS, Success),
    web_prolog:json_atom_field(Success, type, success),
    web_prolog:json_field(
        Success, data,
        list([pairs([string(['X'])-string([s,w,i])])])),
    ws_close(WS, 1000, done),
    format('Trealla Web Prolog protocol client test: ok~n').

% Start the high-level concurrent server and stop it after Count clients have
% completed a close handshake. This is an integration-test driver rather than
% part of the WebSocket API.
trealla_concurrent_server(Port, Count) :-
    thread_self(Parent),
    websocket_server_start(Port, concurrent_echo(Parent), Server),
    await_clients(Count),
    websocket_server_stop(Server),
    format('Trealla concurrent server test (~w clients): ok~n', [Count]).

concurrent_echo(Parent, WS, '/echo') :-
    echo_messages(WS),
    thread_send_message(Parent, websocket_client_done).

echo_messages(WS) :-
    ws_receive(WS, Message),
    ( Message == end_of_file -> true
    ; Message = close(Code, Reason) -> ws_send(WS, close(Code, Reason))
    ; ws_send(WS, Message), echo_messages(WS)
    ).

await_clients(0) :- !.
await_clients(N) :-
    thread_get_message(websocket_client_done),
    N1 is N - 1,
    await_clients(N1).

% Mixed-protocol test server: `/call` remains ordinary HTTP while `/ws`
% upgrades on the same listening socket.
trealla_shared_node(Port) :-
    node(Port, shared_node_echo).

shared_node_echo(WS, '/ws') :-
    echo_messages(WS).
