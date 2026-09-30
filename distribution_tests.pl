/** <module> Integration drivers for native Web Prolog distribution */

:- use_module(distribution).
:- use_module(actors).
:- use_module(websocket).

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

disconnect_during_spawn(WS, '/drop') :-
    ws_receive(WS, text(_)),
    ws_close(WS, 1001, disconnect_test).

distributed_actor_caller(Port, Parent) :-
    format(atom(URL), 'ws://127.0.0.1:~w/ws', [Port]),
    remote_node_open(URL, Node),
    remote_toplevel_spawn(Node, Pid, [session(true)]),
    remote_toplevel_call(Node, Pid, member(X, [inside_actor]), [template(X)]),
    receive({success(Pid, [inside_actor], false) -> true},
            [timeout(2),on_timeout(fail)]),
    remote_node_close(Node),
    Parent ! distributed_actor_caller_ok.
