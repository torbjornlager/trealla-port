% SPDX-License-Identifier: MIT
:- module(transport_visibility_tests,[run/0,live/1]).
:- use_module(actors).
:- use_module(distribution).

run :-
    actors(Before),
    actors:spawn_scoped(transport_visibility_tests:wait,
        Worker,[link(false),monitor(true)],none,internal),
    setup_call_cleanup(true,
        (actors(After), same_actors(Before,After)),
        finish_worker(Worker)),
    % Scoped workers must also stay private in an unscoped snapshot.
    make_ref(Id), NS=ws_client(Id),
    actors:spawn_scoped(transport_visibility_tests:wait,
        Scoped,[link(false),monitor(true)],NS,internal),
    setup_call_cleanup(true,
        (actors(Global), same_actors(Before,Global),
         actors:with_actor_namespace(NS,
             transport_visibility_tests:empty_snapshot)),
        finish_worker(Scoped)),
    writeln('Internal transport worker visibility: ok').

wait :- receive({finish -> true}).
finish_worker(P) :-
    P ! finish,
    receive({down(P,_,true) -> true},[timeout(5),on_timeout(fail)]).
empty_snapshot :- actors([]).

live(URL) :-
    scenario(URL),
    writeln('Remote ping-pong: actor baseline, private transport, reuse and reconnect: ok').

scenario(URL) :-
    % A surviving user actor must remain visible; hiding all actors would
    % otherwise make an empty-baseline regression pass accidentally.
    spawn(wait,Sentinel,[link(false),monitor(true)]),
    setup_call_cleanup(true,
        transport_visibility_tests:connected_scenario(URL,Sentinel),
        finish_worker(Sentinel)).

connected_scenario(URL,Sentinel) :-
    actors(Before), memberchk(Sentinel,Before),
    setup_call_cleanup(true,
        (ping_pong(URL), actors(After), same_actors(Before,After),
         distribution:transparent_node(URL,First), private_connection(First,After),
         ping_pong(URL), actors(Again), same_actors(Before,Again),
         distribution:transparent_node(URL,Reused), First==Reused),
        remote_drop_connection(URL)),
    connection_retired(First),
    actors(Closed), same_actors(Before,Closed),
    setup_call_cleanup(true,
        (ping_pong(URL), actors(Reconnected),same_actors(Before,Reconnected),
         distribution:transparent_node(URL,New), New\==First,
         private_connection(New,Reconnected)),
        remote_drop_connection(URL)),
    connection_retired(New).

private_connection(remote_node(_,Reader,Writer),Public) :-
    \+memberchk(Reader,Public), \+memberchk(Writer,Public),
    actors:actor_thread(Reader,RT), thread_property(RT,status(running)),
    actors:actor_thread(Writer,WT), thread_property(WT,status(running)).
connection_retired(remote_node(_,Reader,Writer)) :-
    \+actors:actor_thread(Reader,_), \+actors:actor_thread(Writer,_).
same_actors(Before,After) :-
    sort(Before,B), sort(After,A),
    (A==B -> true ; throw(error(actor_baseline_changed(B,A),transport_visibility_tests))).

% The tutorial's finite ping-pong protocol: the local pinger and remote
% ponger must both report successful termination before the snapshot.
ping_pong(URL) :-
    spawn(pong,Pong,[node(URL),
        src_text('pong :- receive({finished -> true ; ping(P) -> send(P,pong),pong}).'),
        monitor(true)]),
    Pong=_@URL,
    spawn(ping(3,Pong),Ping,[
        src_text('ping(0,P) :- send(P,finished). ping(N,P) :- N>0,self(Me),send(P,ping(Me)),receive({pong -> true},[timeout(5),on_timeout(fail)]),N1 is N-1,ping(N1,P).'),
        monitor(true)]),
    receive({down(Pong,_,R) -> normal_exit(Pong,R),await_exit(Ping) ;
             down(Ping,_,R) -> normal_exit(Ping,R),await_exit(Pong)},
            [timeout(5),on_timeout(throw(ping_pong_timeout))]).
await_exit(Pid) :-
    receive({down(Pid,_,R) -> normal_exit(Pid,R)},
            [timeout(5),on_timeout(throw(ping_pong_timeout(Pid)))]).
normal_exit(_,true) :- !.
normal_exit(Pid,Reason) :- throw(actor_failed(Pid,Reason)).
