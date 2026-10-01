% SPDX-License-Identifier: MIT

/** <module> SWI-Prolog side of the WebSocket interoperability tests */

:- module(swi_websocket_interop,
          [ server/1,
            client_test/1,
            client_test/2,
            concurrent_client_test/2,
            concurrent_client_test/3,
            protocol_server/1,
            protocol_client_test/1,
            source_server/1,
            source_uri_client_test/2,
            ip_policy_client_test/1,
            private_ownership_client_test/1,
            browser_io_client_test/1,
            browser_distributed_io_client_test/2,
            trinity_service_node/2,
            trinity_terminal_client_test/3
          ]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).

:- http_handler(root(echo),
                http_upgrade_to_websocket(echo, []),
                [spawn([])]).
:- http_handler(root(actor),
                http_upgrade_to_websocket(protocol_connection, []),
                [spawn([])]).
:- http_handler(root('source.pl'), source_file, []).
:- http_handler(root('source-redirect.pl'), source_redirect, []).
:- http_handler(root('source-cross-origin.pl'), source_cross_origin, []).
:- http_handler(root('source-oversize.pl'), source_oversize, []).

:- dynamic source_fixture_port/1.

server(Port) :-
    http_server(http_dispatch, [port(Port)]),
    thread_get_message(stop),
    http_stop_server(Port, []).

protocol_server(Port) :-
    http_server(http_dispatch, [port(Port)]),
    thread_get_message(stop),
    http_stop_server(Port, []).

source_server(Port) :-
    retractall(source_fixture_port(_)),
    asserta(source_fixture_port(Port)),
    http_server(http_dispatch, [port(Port)]),
    thread_get_message(stop),
    http_stop_server(Port, []).

source_file(_Request) :-
    format('Content-type: text/x-prolog; charset=UTF-8~n~n'),
    format("uri_value('hållå €').~n").

source_redirect(Request) :-
    http_redirect(see_other, root('source.pl'), Request).

source_cross_origin(Request) :-
    source_fixture_port(Port),
    format(atom(Location), 'http://localhost:~w/source.pl', [Port]),
    http_redirect(see_other, Location, Request).

source_oversize(_Request) :-
    format('Content-type: text/x-prolog; charset=UTF-8~n~n'),
    forall(between(1, 256, _), put_char(x)).

trinity_service_node(Port, NodeFile) :-
    use_module(NodeFile),
    node(Port, [profile(actor),auth(open)]),
    node:current_shared_db_module(SharedModule),
    actors:spawn(SharedModule:echo_actor, Pid, [link(false)]),
    actors:register_service(echo, Pid).

trinity_terminal_client_test(HomePort, RemoteURL, NodeFile) :-
    use_module(NodeFile),
    node(HomePort, [profile(actor),auth(open)]),
    actors:self(Parent),
    actors:spawn(swi_websocket_interop:terminal_client_worker(RemoteURL,
                                                               Parent), _,
                 [target(Parent),link(false)]),
    actors:receive({terminal_output(_Source, trealla_terminal) -> true ;
                    terminal_client_done -> fail},
                   [timeout(8),on_timeout(fail)]),
    actors:receive({terminal_client_done -> true},
                   [timeout(8),on_timeout(fail)]),
    format('SWI-to-Trealla distributed terminal test: ok~n').

terminal_client_worker(RemoteURL, Parent) :-
    actors:spawn(actors:terminal_output(trealla_terminal), Pid,
                 [node(RemoteURL),monitor(true),link(false)]),
    actors:receive({down(Pid, Pid, true) -> true},
                   [timeout(8),on_timeout(fail)]),
    actors:send(Parent, terminal_client_done).

protocol_connection(WebSocket) :-
    ws_receive(WebSocket, Message),
    ( Message.opcode == close -> true
    ; atom_json_dict(Message.data, Command, []),
      protocol_reply(Command, Reply),
      atom_json_dict(Text, Reply, []),
      ws_send(WebSocket, text(Text)),
      protocol_connection(WebSocket)
    ).

protocol_reply(Command, json{type:"transport_welcome",
                             protocol:"web_prolog_browser_actor",
                             io_ack:true, browser_pids:true, version:1}) :-
    Command.command == "transport_hello", !.
protocol_reply(Command, json{type:"spawned", pid:41}) :-
    Command.command == "toplevel_spawn", !.
protocol_reply(Command, json{type:"success", pid:41,
                             data:[json{'X':"swi"}], more:false}) :-
    Command.command == "toplevel_call", !.
protocol_reply(Command, json{type:"halted", pid:41, reply:"true"}) :-
    Command.command == "toplevel_halt", !.
protocol_reply(Command, json{type:"error", data:Text}) :-
    format(string(Text), "unsupported command: ~w", [Command.command]).

protocol_client_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    http_open_websocket(URL, WS, []),
    send_json(WS, json{command:"transport_hello", version:1}),
    receive_json(WS, Welcome), Welcome.type == "transport_welcome",
    send_json(WS, json{command:"toplevel_spawn", options:"[session(true)]"}),
    receive_json(WS, Spawned), Pid = Spawned.pid,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"member(X,[a,b,c])",
                       options:"[template(X),limit(2)]"}),
    receive_json(WS, First),
    First.data = [FirstA,FirstB],
    get_dict('X', FirstA, "a"),
    get_dict('X', FirstB, "b"),
    First.more == true,
    send_json(WS, json{command:"toplevel_next", pid:Pid}),
    receive_json(WS, Second),
    Second.data = [SecondC],
    get_dict('X', SecondC, "c"),
    Second.more == false,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"append([a],[b,c],Xs)",
                       options:"[limit(10)]"}),
    receive_json(WS, BoundAppend),
    BoundAppend.data = [BoundAppendRow],
    get_dict('Xs', BoundAppendRow, "[a,b,c]"),
    BoundAppend.more == false,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"append(Xs,Ys,[a,b,c])",
                       options:"[limit(10)]"}),
    receive_json(WS, SplitAppend),
    SplitAppend.data = [Split0,_Split1,_Split2,Split3],
    get_dict('Xs', Split0, "[]"),
    get_dict('Ys', Split0, "[a,b,c]"),
    get_dict('Xs', Split3, "[a,b,c]"),
    get_dict('Ys', Split3, "[]"),
    SplitAppend.more == false,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"self(Self)", options:"[limit(1)]"}),
    receive_json(WS, SelfAnswer),
    SelfAnswer.data = [SelfRow],
    get_dict('Self', SelfRow, SelfText),
    number_string(SelfId, SelfText),
    SelfId == Pid,
    SelfId >= 1000000000,
    SelfId =< 9999999999,
    SelfAnswer.more == false,
    send_json(WS, json{command:"toplevel_halt", pid:Pid}),
    receive_type(WS, "halted", _Halted),
    ws_close(WS, 1000, done),
    format('SWI Web Prolog protocol client test: ok~n').

source_uri_client_test(Port, SourcePort) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    format(atom(SourceURL),
           'http://127.0.0.1:~w/source-redirect.pl', [SourcePort]),
    format(string(SpawnOptions), '[session(true),src_uri(~q)]', [SourceURL]),
    http_open_websocket(URL, WS, []),
    send_json(WS, json{command:"transport_hello", version:1}),
    receive_type(WS, "transport_welcome", _),
    send_json(WS, json{command:"toplevel_spawn", options:SpawnOptions}),
    receive_type(WS, "spawned", Spawned),
    Pid = Spawned.pid,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"uri_value(X)", options:"[template(X)]"}),
    receive_type(WS, "success", Success),
    Success.data = [SourceBindings],
    get_dict('X', SourceBindings, SourceValue),
    atom_codes(SourceValue, SourceCodes),
    % Protocol values are quoted Prolog text; the outer 39s are apostrophes.
    SourceCodes == [39,104,229,108,108,229,32,8364,39],
    send_json(WS, json{command:"toplevel_halt", pid:Pid}),
    receive_type(WS, "halted", _),
    format(atom(CrossURL),
           'http://127.0.0.1:~w/source-cross-origin.pl', [SourcePort]),
    format(string(CrossOptions), '[src_uri(~q)]', [CrossURL]),
    send_json(WS, json{command:"toplevel_spawn", options:CrossOptions}),
    receive_type(WS, "error", CrossOriginDenied),
    event_data_contains(CrossOriginDenied, source_origin),
    format(atom(OversizeURL),
           'http://127.0.0.1:~w/source-oversize.pl', [SourcePort]),
    format(string(OversizeOptions), '[src_uri(~q)]', [OversizeURL]),
    send_json(WS, json{command:"toplevel_spawn", options:OversizeOptions}),
    receive_type(WS, "error", OversizeDenied),
    event_data_contains(OversizeDenied, input_size),
    ws_close(WS, 1000, done),
    format('SWI client -> Trealla allowlisted src_uri test: ok~n').

ip_policy_client_test(Port) :-
    format(atom(URL), 'http://127.0.0.1:~w/call?goal=true', [Port]),
    forwarded_http_status(URL, '198.51.100.8', 403),
    forwarded_http_status(URL, '203.0.113.9', 200),
    forwarded_http_status(URL, '203.0.113.9', 429),
    forwarded_http_status(URL, '203.0.113.9', 429),
    forwarded_http_status(URL, '203.0.113.9', 403),
    format('SWI client -> Trealla IP gate and auto-ban test: ok~n').

forwarded_http_status(URL, ClientIP, Expected) :-
    Header = request_header('X-Forwarded-For'=ClientIP),
    setup_call_cleanup(
        http_open(URL, Stream, [Header,status_code(Status)]),
        read_string(Stream, _, _),
        close(Stream)),
    Status == Expected.

private_ownership_client_test(Port) :-
    private_http_rate_test(Port),
    private_observability_test(Port),
    private_token_admin_test(Port),
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    ( catch(http_open_websocket(URL, Unauthenticated, []), _, fail)
    -> catch(ws_close(Unauthenticated, 1000, done), _, true), fail
    ; true
    ),
    Auth = [request_header('Authorization'='Bearer interop-secret')],
    http_open_websocket(URL, Owner, Auth),
    http_open_websocket(URL, Stranger, Auth),
    send_json(Owner, json{command:"transport_hello", version:1}),
    receive_type(Owner, "transport_welcome", _),
    send_json(Stranger, json{command:"transport_hello", version:1}),
    receive_type(Stranger, "transport_welcome", _),
    send_json(Owner,
              json{command:"toplevel_spawn", options:"[session(true)]"}),
    receive_type(Owner, "spawned", Spawned),
    Pid = Spawned.pid,
    send_json(Stranger,
              json{command:"toplevel_call", pid:Pid,
                   goal:"true", options:"[]"}),
    receive_type(Stranger, "error", Denied),
    sub_string(Denied.data, _, _, _, "permission_error"),
    send_json(Stranger,
              json{command:"toplevel_spawn", options:"[session(true)]"}),
    receive_type(Stranger, "error", AtCapacity),
    sub_string(AtCapacity.data, _, _, _, "resource_limit_exceeded"),
    send_json(Owner, json{command:"toplevel_halt", pid:Pid}),
    receive_type(Owner, "halted", _),
    send_json(Stranger,
              json{command:"toplevel_spawn", options:"[session(true)]"}),
    receive_type(Stranger, "spawned", Replacement),
    ReplacementPid = Replacement.pid,
    send_json(Stranger,
              json{command:"toplevel_halt", pid:ReplacementPid}),
    receive_type(Stranger, "halted", _),
    ws_close(Stranger, 1000, done),
    ws_close(Owner, 1000, done),
    format('SWI private authentication and connection ownership test: ok~n').

private_http_rate_test(Port) :-
    format(atom(URL), 'http://127.0.0.1:~w/call?goal=true', [Port]),
    setup_call_cleanup(
        http_open(URL, Anonymous, [status_code(AnonymousStatus)]),
        read_string(Anonymous, _, _),
        close(Anonymous)),
    AnonymousStatus == 401,
    Auth = request_header('Authorization'='Bearer interop-secret'),
    setup_call_cleanup(
        http_open(URL, First, [Auth,status_code(FirstStatus)]),
        read_string(First, _, _),
        close(First)),
    FirstStatus == 200,
    setup_call_cleanup(
        http_open(URL, Limited, [Auth,status_code(LimitedStatus)]),
        read_string(Limited, _, _),
        close(Limited)),
    LimitedStatus == 429.

private_observability_test(Port) :-
    format(atom(MetricsURL), 'http://127.0.0.1:~w/metrics', [Port]),
    setup_call_cleanup(
        http_open(MetricsURL, Metrics, [status_code(MetricsStatus)]),
        read_string(Metrics, _, MetricsText),
        close(Metrics)),
    MetricsStatus == 200,
    sub_string(MetricsText, _, _, _, "web_prolog_requests_total"),
    format(atom(RuntimeURL), 'http://127.0.0.1:~w/admin/runtime', [Port]),
    UserAuth = request_header('Authorization'='Bearer interop-secret'),
    setup_call_cleanup(
        http_open(RuntimeURL, Denied, [UserAuth,status_code(DeniedStatus)]),
        read_string(Denied, _, _),
        close(Denied)),
    DeniedStatus == 403,
    AdminAuth = request_header('Authorization'='Bearer admin-secret'),
    setup_call_cleanup(
        http_open(RuntimeURL, Runtime, [AdminAuth,status_code(RuntimeStatus)]),
        read_string(Runtime, _, RuntimeText),
        close(Runtime)),
    RuntimeStatus == 200,
    atom_json_dict(RuntimeText, RuntimeJSON, []),
    _ = RuntimeJSON.governance,
    _ = RuntimeJSON.activity_summary,
    _ = RuntimeJSON.rate_limits,
    _ = RuntimeJSON.recent_events.

private_token_admin_test(Port) :-
    format(atom(TokensURL), 'http://127.0.0.1:~w/admin/tokens', [Port]),
    AdminAuth = request_header('Authorization'='Bearer admin-secret'),
    setup_call_cleanup(
        http_open(TokensURL, Invalid,
                  [AdminAuth,post(atom('{}')),status_code(InvalidStatus)]),
        read_string(Invalid, _, _),
        close(Invalid)),
    InvalidStatus == 400,
    Body = '{"principal":"issued","capabilities":["execute"],"label":"interop"}',
    setup_call_cleanup(
        http_open(TokensURL, Issued,
                  [AdminAuth,post(atom(Body)),status_code(IssueStatus)]),
        read_string(Issued, _, IssueText),
        close(Issued)),
    IssueStatus == 200,
    atom_json_dict(IssueText, IssueJSON, []),
    Token = IssueJSON.token,
    Id = IssueJSON.id,
    [Listed|_] = IssueJSON.tokens,
    \+ get_dict(hash, Listed, _),
    format(atom(CallURL), 'http://127.0.0.1:~w/call?goal=true', [Port]),
    TokenAuth = request_header('Authorization'=BearerHeader),
    format(atom(BearerHeader), 'Bearer ~w', [Token]),
    setup_call_cleanup(
        http_open(CallURL, Authorized, [TokenAuth,status_code(AuthorizedStatus)]),
        read_string(Authorized, _, _),
        close(Authorized)),
    AuthorizedStatus == 200,
    format(atom(RevokeURL), '~w?id=~w', [TokensURL,Id]),
    setup_call_cleanup(
        http_open(RevokeURL, Revoked,
                  [AdminAuth,method(delete),status_code(RevokeStatus)]),
        read_string(Revoked, _, RevokeText),
        close(Revoked)),
    RevokeStatus == 200,
    atom_json_dict(RevokeText, RevokeJSON, []),
    RevokeJSON.revoked == true,
    setup_call_cleanup(
        http_open(CallURL, Rejected, [TokenAuth,status_code(RejectedStatus)]),
        read_string(Rejected, _, _),
        close(Rejected)),
    RejectedStatus == 401.

browser_io_client_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    http_open_websocket(URL, WS, []),
    send_json(WS, json{command:"transport_hello", version:1,
                       browser_pids:true, io_ack:true}),
    receive_json(WS, Welcome),
    Welcome.type == "transport_welcome",
    Welcome.io_ack == true,
    send_json(WS, json{command:"toplevel_spawn",
                       options:"[session(true)]"}),
    receive_type(WS, "spawned", Spawned),
    Pid = Spawned.pid,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"writeln(hello)",
                       options:"[]"}),
    receive_type(WS, "io_request", Request),
    Request.event.type == "output",
    Request.event.pid == Pid,
    Request.event.data == "hello",
    send_json(WS, json{command:"browser_io_reply",
                       request_id:Request.request_id, status:"ok"}),
    receive_type(WS, "success", Success),
    Success.more == false,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"self(Self);writeln(later)",
                       options:"[template(Self),limit(1)]"}),
    receive_json(WS, FirstPage),
    FirstPage.type == "success",
    FirstPage.more == true,
    FirstPage.data = [FirstRow],
    get_dict('Self', FirstRow, FirstSelfText),
    number_string(FirstSelf, FirstSelfText),
    FirstSelf == Pid,
    send_json(WS, json{command:"toplevel_next", pid:Pid}),
    receive_type(WS, "io_request", LaterRequest),
    LaterRequest.event.type == "output",
    LaterRequest.event.data == "later",
    send_json(WS, json{command:"browser_io_reply",
                       request_id:LaterRequest.request_id, status:"ok"}),
    receive_type(WS, "success", LastPage),
    LastPage.more == false,
    LastPage.data = [LastRow],
    get_dict('Self', LastRow, "Self"),
    format(string(SelfSend), "~w ! hello", [Pid]),
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:SelfSend, options:"[]"}),
    receive_type(WS, "success", SentToSelf),
    SentToSelf.more == false,
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"receive({Message->true})",
                       options:"[]"}),
    receive_type(WS, "success", ReceivedFromSelf),
    ReceivedFromSelf.more == false,
    ReceivedFromSelf.data = [ReceivedRow],
    get_dict('Message', ReceivedRow, "hello"),
    send_json(WS, json{command:"toplevel_call", pid:Pid,
                       goal:"input(browser_prompt,X)",
                       options:"[template(X)]"}),
    receive_type(WS, "prompt", Prompt),
    Prompt.pid == Pid,
    send_json(WS, json{command:"toplevel_respond", pid:Pid,
                       input:"browser_answer"}),
    receive_responded_and_success(WS, false, false),
    send_json(WS, json{command:"toplevel_halt", pid:Pid}),
    receive_type(WS, "halted", _Halted),
    ws_close(WS, 1000, done),
    format('SWI browser terminal acknowledgement test: ok~n').

browser_distributed_io_client_test(Port, RemoteURL) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    http_open_websocket(URL, WS, []),
    send_json(WS, json{command:"transport_hello", version:1,
                       browser_pids:true, io_ack:true}),
    receive_type(WS, "transport_welcome", _Welcome),
    format(string(OutputGoal),
           "spawn(terminal_output(remote_hello),_,[node(~q),link(false)])",
           [RemoteURL]),
    send_json(WS, json{command:"spawn", goal:OutputGoal, options:"[]"}),
    receive_type(WS, "spawned", _Spawned),
    receive_type(WS, "io_request", Output),
    Output.event.type == "output",
    Output.event.data == "remote_hello",
    acknowledge_browser_output(WS, Output),
    format(string(InputGoal),
           "spawn(input(remote_prompt,browser_answer),InputPid,[node(~q),link(false),monitor(true)]),receive({down(InputPid,InputPid,true)->true},[timeout(20),on_timeout(fail)]),terminal_output(remote_prompt_answered)",
           [RemoteURL]),
    send_json(WS, json{command:"spawn", goal:InputGoal, options:"[]"}),
    receive_type(WS, "spawned", _InputSpawned),
    receive_type(WS, "prompt", Prompt),
    Prompt.data == "remote_prompt",
    send_json(WS, json{command:"toplevel_respond", pid:Prompt.pid,
                       input:"browser_answer"}),
    receive_responded_and_io_request(WS, false, none, Answer),
    Answer.event.type == "output",
    Answer.event.data == "remote_prompt_answered",
    acknowledge_browser_output(WS, Answer),
    ws_close(WS, 1000, done),
    format('SWI browser-to-remote-Trealla terminal test: ok~n').

acknowledge_browser_output(WS, Request) :-
    send_json(WS, json{command:"browser_io_reply",
                       request_id:Request.request_id, status:"ok"}).

receive_responded_and_io_request(_, true, some(Request), Request) :- !.
receive_responded_and_io_request(WS, Responded0, Request0, Request) :-
    receive_json(WS, Event),
    ( Event.type == "responded" -> Responded = true ; Responded = Responded0 ),
    ( Event.type == "io_request" -> Request1 = some(Event) ; Request1 = Request0 ),
    receive_responded_and_io_request(WS, Responded, Request1, Request).

receive_responded_and_success(_, true, true) :- !.
receive_responded_and_success(WS, Responded0, Success0) :-
    receive_json(WS, Event),
    ( Event.type == "responded" -> Responded = true ; Responded = Responded0 ),
    ( Event.type == "success" -> Success = true ; Success = Success0 ),
    receive_responded_and_success(WS, Responded, Success).

send_json(WS, Dict) :-
    atom_json_dict(Text, Dict, []), ws_send(WS, text(Text)).

receive_json(WS, Dict) :-
    ws_receive(WS, Message), Message.opcode == text,
    atom_json_dict(Message.data, Dict, []).

receive_type(WS, Type, Dict) :-
    receive_json(WS, Event),
    ( Event.type == Type -> Dict = Event ; receive_type(WS, Type, Dict) ).

event_data_contains(Event, Needle) :-
    Data0 = Event.data,
    ( string(Data0) -> atom_string(Data, Data0) ; Data = Data0 ),
    sub_atom(Data, _, _, _, Needle).

echo(WebSocket) :-
    ws_receive(WebSocket, Message),
    ( Message.opcode == close -> true
    ; Message.opcode == text -> ws_send(WebSocket, text(Message.data)), echo(WebSocket)
    ; Message.opcode == binary -> ws_send(WebSocket, binary(Message.data)), echo(WebSocket)
    ; echo(WebSocket)
    ).

client_test(Port) :-
    client_test(Port, '/echo').

client_test(Port, Path) :-
    format(atom(URL), 'ws://127.0.0.1:~w~w', [Port, Path]),
    http_open_websocket(URL, WS, []),
    ws_send(WS, ping("ping")),
    ws_receive(WS, Pong),
    Pong.opcode == pong,
    ws_send(WS, text('SWI says: hållå € 😀')),
    ws_receive(WS, Text),
    Text.opcode == text,
    Text.data == "SWI says: hållå € 😀",
    string_codes(BinaryPayload, [0,1,2,127,128,255]),
    ws_send(WS, binary(BinaryPayload)),
    ws_receive(WS, Binary),
    Binary.opcode == binary,
    string_codes(Binary.data, [0,1,2,127,128,255]),
    length(LargeCodes, 66000), maplist(=(90), LargeCodes),
    string_codes(Large, LargeCodes),
    ws_send(WS, binary(Large)),
    ws_receive(WS, LargeReply),
    LargeReply.opcode == binary,
    string_codes(LargeReply.data, LargeCodes),
    ws_close(WS, 1000, done),
    format('SWI client interoperability test: ok~n').

concurrent_client_test(Port, Count) :-
    concurrent_client_test(Port, '/echo', Count).

concurrent_client_test(Port, Path, Count) :-
    create_clients(Count, Port, Path, Threads),
    join_clients(Threads),
    format('SWI concurrent client test (~w clients): ok~n', [Count]).

create_clients(0, _, _, []) :- !.
create_clients(N, Port, Path, [Thread|Threads]) :-
    thread_create(client_test(Port, Path), Thread, []),
    N1 is N - 1,
    create_clients(N1, Port, Path, Threads).

join_clients([]).
join_clients([Thread|Threads]) :-
    thread_join(Thread, true),
    join_clients(Threads).
