/** <module> Integration drivers for native Web Prolog distribution */

:- use_module(distribution).
:- use_module(actors).
:- use_module(websocket).

:- op(200, xfx, @).

distribution_toplevel_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    remote_node_open(URL, Node),
    remote_toplevel_spawn(Node, Pid, [session(true)]),
    remote_toplevel_call(Node, Pid, member(X, [a,b,c]),
                         [template(X),limit(2)]),
    receive({success(Pid, [a,b], true) -> true},
            [timeout(2),on_timeout(fail)]),
    remote_toplevel_next(Node, Pid),
    receive({success(Pid, [c], false) -> true},
            [timeout(2),on_timeout(fail)]),
    remote_toplevel_halt(Node, Pid),
    receive_halted(Pid),
    remote_node_close(Node),
    format('Trealla distributed toplevel test: ok~n').

receive_halted(Pid) :-
    receive({
        halted(Pid, true) -> true ;
        down(Pid, _, _) -> user:receive_halted(Pid)
    }, [timeout(2),on_timeout(fail)]).

distribution_actor_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    remote_node_open(URL, Node),
    remote_spawn(Node,
                 receive({hello -> output(got)}),
                 Pid, []),
    remote_send(Node, Pid, hello),
    receive({output(Pid, got) -> true}, [timeout(2),on_timeout(fail)]),
    receive({down(Pid, _, true) -> true}, [timeout(2),on_timeout(fail)]),
    remote_node_close(Node),
    format('Trealla distributed actor test: ok~n').

distribution_actor_return_test(Port) :-
    distribution_url(Port, URL),
    remote_node_open(URL, Node),
    self(Self),
    remote_spawn(Node, receive({ping(From) -> From ! pong}), Pid, []),
    remote_send(Node, Pid, ping(Self)),
    receive({pong -> true}, [timeout(5),on_timeout(fail)]),
    receive({down(Pid, _, true) -> true},
            [timeout(5),on_timeout(fail)]),
    remote_node_close(Node),
    format('Explicit return-message test: ok~n').

distribution_terminal_test(HomePort, RemotePort) :-
    format(atom(HomeURL), 'http://127.0.0.1:~w', [HomePort]),
    spawn(web_prolog:web_prolog_node(HomePort, [node_url(HomeURL)]), _,
          [link(false)]),
    sleep(0.1),
    distribution_url(RemotePort, RemoteURL),
    self(Parent),
    spawn(distributed_terminal_worker(RemoteURL, Parent, remote_terminal), _,
          [target(Parent),link(false)]),
    receive({terminal_output(_Source, remote_terminal) -> true ;
             distributed_terminal_done(remote_terminal) -> fail},
            [timeout(8),on_timeout(fail)]),
    receive({distributed_terminal_done(remote_terminal) -> true},
            [timeout(8),on_timeout(fail)]),
    format('Trealla distributed terminal acknowledgement test: ok~n').

distribution_swi_terminal_test(HomePort, SWIPort) :-
    format(atom(HomeURL), 'http://127.0.0.1:~w', [HomePort]),
    spawn(web_prolog:web_prolog_node(HomePort, [node_url(HomeURL)]), _,
          [link(false)]),
    sleep(0.1),
    format(atom(RemoteURL), 'http://127.0.0.1:~w', [SWIPort]),
    self(Parent),
    spawn(distributed_terminal_worker(RemoteURL, Parent, swi_terminal), _,
          [target(Parent),link(false)]),
    receive({terminal_output(_Source, swi_terminal) -> true ;
             distributed_terminal_done(swi_terminal) -> fail},
            [timeout(8),on_timeout(fail)]),
    receive({distributed_terminal_done(swi_terminal) -> true},
            [timeout(8),on_timeout(fail)]),
    format('Trealla-to-SWI distributed terminal test: ok~n').

distribution_toplevel_terminal_test(HomePort, RemotePort) :-
    format(atom(HomeURL), 'http://127.0.0.1:~w', [HomePort]),
    spawn(web_prolog:web_prolog_node(HomePort, [node_url(HomeURL)]), _,
          [link(false)]),
    sleep(0.1),
    distribution_url(RemotePort, RemoteURL),
    self(Parent),
    spawn(distributed_toplevel_terminal_worker(RemoteURL, Parent), _,
          [target(Parent),link(false)]),
    receive({terminal_output(_Source, toplevel_terminal) -> true ;
             distributed_toplevel_terminal_done -> fail},
            [timeout(8),on_timeout(fail)]),
    receive({distributed_toplevel_terminal_done -> true},
            [timeout(8),on_timeout(fail)]),
    format('Distributed toplevel terminal acknowledgement test: ok~n').

distribution_terminal_input_test(HomePort, RemotePort) :-
    format(atom(HomeURL), 'http://127.0.0.1:~w', [HomePort]),
    spawn(web_prolog:web_prolog_node(HomePort, [node_url(HomeURL)]), _,
          [link(false)]),
    sleep(0.1),
    distribution_url(RemotePort, RemoteURL),
    self(Parent),
    spawn(distributed_terminal_input_worker(RemoteURL, Parent), _,
          [target(Parent),link(false)]),
    receive({prompt(Source, remote_prompt) -> respond(Source, hello)},
            [timeout(8),on_timeout(fail)]),
    receive({terminal_output(_Source, answer(hello)) -> true ;
             distributed_terminal_input_done -> fail},
            [timeout(8),on_timeout(fail)]),
    receive({distributed_terminal_input_done -> true},
            [timeout(8),on_timeout(fail)]),
    format('Distributed terminal input roundtrip test: ok~n').

distributed_terminal_worker(RemoteURL, Parent, Tag) :-
    spawn(actors:terminal_output(Tag), Pid,
          [node(RemoteURL),monitor(true),link(false)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(8),on_timeout(fail)]),
    Parent ! distributed_terminal_done(Tag).

distributed_toplevel_terminal_worker(RemoteURL, Parent) :-
    remote_node_open(RemoteURL, Node),
    remote_toplevel_spawn(Node, Pid, [session(false)]),
    remote_toplevel_call(Node, Pid, terminal_output(toplevel_terminal), []),
    receive({success(Pid, _, false) -> true},
            [timeout(8),on_timeout(fail)]),
    remote_node_close(Node),
    Parent ! distributed_toplevel_terminal_done.

distributed_terminal_input_worker(RemoteURL, Parent) :-
    spawn((input(remote_prompt, Answer),
           terminal_output(answer(Answer))), Pid,
          [node(RemoteURL),monitor(true),link(false)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(8),on_timeout(fail)]),
    Parent ! distributed_terminal_input_done.

distribution_service_test(Port) :-
    distribution_url(Port, URL),
    self(Self),
    Service = echo@URL,
    Service ! echo(Self, first),
    receive({echo(first) -> true}, [timeout(5),on_timeout(fail)]),
    format('Published service routing test: ok~n').

distribution_service_reconnect_test(Port) :-
    distribution_url(Port, URL),
    self(Self),
    Service = echo@URL,
    Service ! echo(Self, before_drop),
    receive({echo(before_drop) -> true}, [timeout(5),on_timeout(fail)]),
    remote_drop_connection(URL),
    Service ! echo(Self, after_reconnect),
    receive({echo(after_reconnect) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Published service reconnect test: ok~n').

start_echo_service :-
    spawn(service_echo_loop, Pid, [link(false)]),
    register_service(echo, Pid).

service_echo_loop :-
    receive({
        echo(From, Tag) ->
            From ! echo(Tag),
            service_echo_loop
    }).

distribution_swi_fixture_test(Port) :-
    format(atom(URL), 'ws://127.0.0.1:~w/actor', [Port]),
    remote_node_open(URL, Node),
    remote_toplevel_spawn(Node, Pid, [session(true)]),
    remote_toplevel_call(Node, Pid, true, []),
    receive({success(Pid, [swi], false) -> true},
            [timeout(2),on_timeout(fail)]),
    remote_node_close(Node),
    format('Trealla-to-SWI distribution test: ok~n').

distribution_actor_caller_test(Port) :-
    self(Parent),
    spawn(distributed_actor_caller(Port, Parent), _, [link(false)]),
    receive({distributed_actor_caller_ok -> true},
            [timeout(3),on_timeout(fail)]),
    format('Actor-owned distributed connection test: ok~n').

distribution_spawn_disconnect_test(Port) :-
    websocket_server_start(Port, disconnect_during_spawn, Server),
    sleep(0.05),
    format(atom(URL), 'ws://127.0.0.1:~w/drop', [Port]),
    remote_node_open(URL, Node),
    catch(remote_spawn(Node, true, _, []), Error, true),
    Error = error(remote_connection_closed(URL, _), remote_spawn/4),
    remote_node_close(Node),
    websocket_server_stop(Server),
    format('Disconnect-during-spawn test: ok~n').

transparent_connection_drop_test(Port) :-
    websocket_server_start(Port, spawn_then_disconnect, Server),
    sleep(0.05),
    format(atom(URL), 'ws://127.0.0.1:~w/drop', [Port]),
    spawn(receive({wait -> true}), Pid,
          [node(URL),monitor(true),link(false)]),
    receive({down(Pid, Pid, connection_closed) -> true},
            [timeout(5),on_timeout(fail)]),
    websocket_server_stop(Server),
    format('Transparent connection-drop test: ok~n').

spawn_then_disconnect(WS, '/drop') :-
    accept_transport_hello(WS),
    ws_receive(WS, text(_Spawn)),
    web_prolog:object([type-string_atom(spawned),pid-number(51)], JSON),
    web_prolog:web_prolog_send(WS, JSON).

transparent_actor_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({hello -> output(got)}), Pid,
          [node(URL),monitor(true)]),
    Pid ! hello,
    receive({output(Pid, got) -> true}, [timeout(5),on_timeout(fail)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent spawn/send test: ok~n').

transparent_send_completion_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({hello -> true}), Pid,
          [node(URL),monitor(true),link(false)]),
    Pid ! hello,
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent send/completion test: ok~n').

transparent_return_message_test(Port) :-
    distribution_url(Port, URL),
    self(Self),
    spawn(receive({ping(From) -> From ! pong}), Pid,
          [node(URL),monitor(true),link(false)]),
    Pid ! ping(Self),
    receive({pong -> true}, [timeout(5),on_timeout(fail)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent return-message test: ok~n').

transparent_spawn_return_test(Port) :-
    distribution_url(Port, URL),
    self(Self),
    spawn((Self ! spawned_reply, receive({finish -> true})), Pid,
          [node(URL),monitor(true),link(false)]),
    receive({spawned_reply -> true}, [timeout(5),on_timeout(fail)]),
    Pid ! finish,
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent spawn return-message test: ok~n').

transparent_actor_return_test(Port) :-
    self(Parent),
    spawn(actor_return_roundtrip(Port, Parent), _, [link(false)]),
    receive({actor_return_ok -> true}, [timeout(8),on_timeout(fail)]),
    format('Actor-owned return-message test: ok~n').

actor_return_roundtrip(Port, Parent) :-
    distribution_url(Port, URL),
    self(Self),
    spawn(receive({ping(From) -> From ! pong}), Pid,
          [node(URL),monitor(true),link(false)]),
    Pid ! ping(Self),
    receive({pong -> true}, [timeout(5),on_timeout(fail)]),
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    Parent ! actor_return_ok.

transparent_http_node_test(Port) :-
    format(atom(NodeURL), 'http://127.0.0.1:~w', [Port]),
    spawn(true, Pid, [node(NodeURL),monitor(true),link(false)]),
    Pid = _@NodeURL,
    receive({down(Pid, Pid, true) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent HTTP node URL test: ok~n').

transparent_monitor_exit_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({wait -> true}), Pid, [node(URL),link(false)]),
    monitor(Pid, Ref),
    exit(Pid, transparent_exit),
    receive({down(Pid, Ref, transparent_exit) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent monitor/exit test: ok~n').

transparent_demonitor_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({wait -> true}), Pid, [node(URL),link(false)]),
    monitor(Pid, Ref),
    demonitor(Ref, [flush]),
    exit(Pid, demonitor_test),
    receive({down(Pid, Ref, _) -> fail},
            [timeout(0.2),on_timeout(true)]),
    format('Transparent demonitor test: ok~n').

transparent_link_test(Port) :-
    self(Parent),
    spawn(transparent_link_parent(Port, Parent), LocalParent, [link(false)]),
    receive({linked_remote(Pid) -> true}, [timeout(5),on_timeout(fail)]),
    monitor(Pid, Ref),
    LocalParent ! finish,
    receive({down(Pid, Ref, linked) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent remote-link test: ok~n').

transparent_multi_monitor_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({wait -> true}), Pid, [node(URL),link(false)]),
    self(Parent),
    spawn(transparent_watcher(Pid, Parent), _, [link(false)]),
    spawn(transparent_watcher(Pid, Parent), _, [link(false)]),
    receive({watching(Pid, Ref1) -> true}, [timeout(5),on_timeout(fail)]),
    receive({watching(Pid, Ref2) -> true}, [timeout(5),on_timeout(fail)]),
    Ref1 \== Ref2,
    exit(Pid, watched_exit),
    receive({watched_down(Pid, Ref1, watched_exit) -> true},
            [timeout(5),on_timeout(fail)]),
    receive({watched_down(Pid, Ref2, watched_exit) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Transparent multiple-monitor test: ok~n').

transparent_spawn_and_explicit_monitor_test(Port) :-
    distribution_url(Port, URL),
    spawn(receive({wait -> true}), Pid,
          [node(URL),monitor(true),link(false)]),
    self(Parent),
    spawn(transparent_watcher(Pid, Parent), _, [link(false)]),
    receive({watching(Pid, Ref) -> true}, [timeout(5),on_timeout(fail)]),
    exit(Pid, combined_monitor_exit),
    receive({down(Pid, Pid, combined_monitor_exit) -> true},
            [timeout(5),on_timeout(fail)]),
    receive({watched_down(Pid, Ref, combined_monitor_exit) -> true},
            [timeout(5),on_timeout(fail)]),
    format('Spawn plus explicit remote-monitor test: ok~n').

transparent_watcher(Pid, Parent) :-
    monitor(Pid, Ref),
    Parent ! watching(Pid, Ref),
    receive({down(Pid, Ref, Reason) -> Parent ! watched_down(Pid, Ref, Reason)},
            [timeout(5),on_timeout(fail)]).

transparent_link_parent(Port, Parent) :-
    distribution_url(Port, URL),
    spawn(receive({never -> true}), Pid, [node(URL)]),
    Parent ! linked_remote(Pid),
    receive({finish -> true}).

distribution_url(Port, URL) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]).

disconnect_during_spawn(WS, '/drop') :-
    accept_transport_hello(WS),
    ws_receive(WS, text(_Spawn)).

accept_transport_hello(WS) :-
    ws_receive(WS, text(_Hello)).

distributed_actor_caller(Port, Parent) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    remote_node_open(URL, Node),
    remote_toplevel_spawn(Node, Pid, [session(true)]),
    remote_toplevel_call(Node, Pid, member(X, [inside_actor]), [template(X)]),
    receive({success(Pid, [inside_actor], false) -> true},
            [timeout(2),on_timeout(fail)]),
    remote_node_close(Node),
    Parent ! distributed_actor_caller_ok.
