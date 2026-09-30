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
            trinity_service_node/2,
            trinity_terminal_client_test/3
          ]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).

:- http_handler(root(echo),
                http_upgrade_to_websocket(echo, []),
                [spawn([])]).
:- http_handler(root(actor),
                http_upgrade_to_websocket(protocol_connection, []),
                [spawn([])]).

server(Port) :-
    http_server(http_dispatch, [port(Port)]),
    thread_get_message(stop),
    http_stop_server(Port, []).

protocol_server(Port) :-
    http_server(http_dispatch, [port(Port)]),
    thread_get_message(stop),
    http_stop_server(Port, []).

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
                             data:["swi"], more:false}) :-
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
    First.data == ["a","b"], First.more == true,
    send_json(WS, json{command:"toplevel_next", pid:Pid}),
    receive_json(WS, Second),
    Second.data == ["c"], Second.more == false,
    send_json(WS, json{command:"toplevel_halt", pid:Pid}),
    receive_type(WS, "halted", _Halted),
    ws_close(WS, 1000, done),
    format('SWI Web Prolog protocol client test: ok~n').

send_json(WS, Dict) :-
    atom_json_dict(Text, Dict, []), ws_send(WS, text(Text)).

receive_json(WS, Dict) :-
    ws_receive(WS, Message), Message.opcode == text,
    atom_json_dict(Message.data, Dict, []).

receive_type(WS, Type, Dict) :-
    receive_json(WS, Event),
    ( Event.type == Type -> Dict = Event ; receive_type(WS, Type, Dict) ).

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
