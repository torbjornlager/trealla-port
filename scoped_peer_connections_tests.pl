% SPDX-License-Identifier: MIT
:- module(scoped_peer_connections_tests,[live/1]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(toplevel_actors,[toplevel_call/3]).

live(URL) :-
    make_ref(A),make_ref(B),NA=ws_client(A),NB=ws_client(B),
    remote_node_open(URL,Observer),
    setup_call_cleanup(true,checks(URL,NA,NB,Observer),
      (retire_registry_namespace(NA),retire_registry_namespace(NB),remote_node_close(Observer))),
    writeln('Scoped peer connections: alias reuse, client isolation, authenticated retirement and socket/actor reclamation passed').

checks(URL,NA,NB,Observer) :-
    atom_concat(URL,'/',Slash),
    actors:with_actor_namespace(NA,distribution:transparent_node(URL,NodeA)),
    actors:with_actor_namespace(NA,distribution:transparent_node(Slash,SameA)),
    SameA==NodeA,
    actors:with_actor_namespace(NB,distribution:transparent_node(Slash,NodeB)),
    NodeA=remote_node(_,ReaderA,WriterA),NodeB=remote_node(_,ReaderB,WriterB),
    WriterA\==WriterB,
    remote_spawn(NodeA,receive({stop->true}),PA,[]),
    remote_spawn(NodeB,(receive({probe(Who)->send(Who,alive_b)}),receive({stop->true})),PB,[]),
    % Protocol-level control monitors are connection-owned on Trealla.
    % A separate retained observer uses the public language monitor/2 API,
    % which can observe these actors without owning their control connection.
    remote_toplevel_spawn(Observer,Top,[session(true)]),
    PA=IdA@_,PB=IdB@_,self(Caller),
    % Monitor and receive in one query: Trealla executes each toplevel call
    % in a fresh worker, so a later query cannot receive its predecessor's mail.
    toplevel_call(Top,
      (monitor(IdA,A),monitor(IdB,B),send(Caller,peer_observer_ready),
       receive({down(_,A,_) -> true},
               [timeout(8),on_timeout(throw(peer_a_not_reclaimed))]),
       send(Caller,peer_a_reclaimed),
       receive({down(_,B,_) -> true},
               [timeout(8),on_timeout(throw(peer_b_not_reclaimed))])),
      [target(Caller),template(reclaimed_b)]),
    receive({peer_observer_ready -> true},
            [timeout(3),on_timeout(throw(peer_observer_not_ready))]),
    % Raw public sends, including a variable-key envelope, cannot retire a
    % context through the manager's private host alias.
    send('$distribution_manager','$namespace_closed'(NA)),
    send('$distribution_manager','$distribution_control'(_,'$namespace_closed'(NA))),
    % A valid lookup is the ordered manager barrier after those forged messages.
    actors:with_actor_namespace(NA,distribution:transparent_node(URL,StillA)),StillA==NodeA,
    actors:actor_thread(ReaderA,_),actors:actor_thread(WriterA,_),
    retire_registry_namespace(NA),
    wait_stopped(ReaderA,200),wait_stopped(WriterA,200),
    receive({peer_a_reclaimed -> true},
            [timeout(8),on_timeout(throw(peer_a_not_reclaimed))]),
    actors:actor_thread(ReaderB,_),actors:actor_thread(WriterB,_),
    self(Self),remote_send(NodeB,PB,probe(Self)),
    receive({alive_b -> true},[timeout(3),on_timeout(throw(peer_b_was_affected))]),
    catch(actors:with_actor_namespace(NA,distribution:transparent_node(URL,_)),E,true),
    nonvar(E),E=error(permission_error(register,closed_namespace,NA),_),
    retire_registry_namespace(NA),
    actors:actor_thread(ReaderB,_),actors:actor_thread(WriterB,_),
    retire_registry_namespace(NB),
    receive({success(Top,[reclaimed_b],false) -> true},
            [timeout(8),on_timeout(throw(peer_b_not_reclaimed))]),
    remote_toplevel_halt(Observer,Top),
    wait_stopped(ReaderB,200),wait_stopped(WriterB,200).

wait_stopped(Pid,Attempts) :-
    (actors:actor_thread(Pid,_) ->
      (Attempts>0 -> sleep(0.01),Next is Attempts-1,wait_stopped(Pid,Next)
      ; throw(peer_connection_thread_survived(Pid)))
    ; true).

