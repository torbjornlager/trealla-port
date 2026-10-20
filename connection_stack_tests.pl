% SPDX-License-Identifier: MIT
:- module(connection_stack_tests,[run/1,websocket_live/1]).
:- use_module(actors).
:- use_module(node).
:- use_module(resource_policy).
:- use_module(library(http)).
:- use_module(library(json)).
:- use_module(websocket).
:- dynamic produced/2.
:- multifile actors:hook_spawn_reserved/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),thread_self(Thread),
    assertz(connection_stack_tests:produced(Thread,Pid)).

run(Port) :-
    option_preservation,
    collector_exhaustion,
    live_connections(Port,http),
    writeln('Connection-thread stack limits: all regressions passed').

% HTTP and WebSocket client checks run independently against finite-limit
% accepted workers. Complete the close handshake before stopping the listener.
websocket_live(Port) :- live_connections(Port,websocket).

option_preservation :-
    Base=[detached(true),at_exit(true)],
    configure_resource_policy([stack_limit(unlimited)],_),
    actor_thread_options(Base,Base),
    configure_resource_policy([stack_limit(4000000)],_),
    actor_thread_options(Base,[stack_limit(4000000)|Base]),
    reset_resource_policy,
    writeln('finite/unlimited stack policy preserves lifecycle thread options: ok').

collector_exhaustion :-
    setup_call_cleanup(
      configure_resource_policy([stack_limit(4000000),time_limit(5)],_),
      (self(Parent),
       actor_thread_options([],Options),
       % Isolate the collector ceiling: its producer is deliberately unlimited.
       configure_resource_policy([stack_limit(unlimited),time_limit(5)],_),
       thread_create(connection_stack_tests:collect_until_full(Parent),Thread,Options),
       receive({collector_result(Thread,Error) -> true},[timeout(8),on_timeout(fail)]),
       Error=error(resource_error(space),_),
       thread_join(Thread,true),
       findall(P,produced(Thread,P),Pids),Pids=[_|_],
       forall(member(Pid,Pids),\+actors:actor_thread(Pid,_))),
      reset_resource_policy),
    writeln('small answers exhaust the collector stack; producer is reclaimed before reporting: ok').

collect_until_full(Parent) :-
    thread_self(Thread),
    catch(node:compute_answer(repeat,small,0,1000000,_),Raw,true),
    normalize_resource_exception(Raw,Error),
    send(Parent,collector_result(Thread,Error)).

live_connections(Port,Mode) :-
    format(atom(URL),'http://127.0.0.1:~w',[Port]),
    thread_create(node:node(Port,connection_stack_tests:echo,
      [bind_address('127.0.0.1'),node_url(URL),profile(actor),auth(open),
       stack_limit(4000000),time_limit(5)]),Listener,[]),
    setup_call_cleanup(wait_listening(Port,100),
      (Mode==http ->
       http_page(URL,0,success([a,b],true)),
       http_page(URL,2,success([c],false)),
       http_exhaustion(URL),
       thread_create(connection_stack_tests:http_json_exhaustion(URL),JSONClient,[]),
       thread_join(JSONClient,true),
       http_page(URL,0,success([a,b],true)),
       http_page(URL,2,success([c],false))
      ; websocket_echo(Port)),
      (stop_node(Port),thread_join(Listener,Status),
       (Status==true;Status==false))),
    node_connection_count(Port,0),
    forall(produced(_,Pid),\+actors:actor_thread(Pid,_)),
    format('finite-limit accepted ~w connections preserve replies and retire their registrations: ok~n',[Mode]).

wait_listening(Port,N) :-
    (node_running(Port) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_listening(Port,Next)).

http_page(URL,Offset,Answer) :-
    format(atom(Request),
      '~w/call?goal=member%28X%2C%5Ba%2Cb%2Cc%5D%29&template=X&limit=2&offset=~w&format=prolog',
      [URL,Offset]),
    setup_call_cleanup(http_open(Request,Stream,[]),read_term(Stream,Answer,[]),close(Stream)).

http_exhaustion(URL) :-
    atom_concat(URL,'/call?goal=repeat&template=small&limit=1000000&format=prolog',Request),
    setup_call_cleanup(http_open(Request,Stream,[timeout(8)]),
      read_term(Stream,Answer,[]),close(Stream)),
    Answer=error(error(resource_error(space),_)),
    writeln('accepted HTTP worker reports normalized stack exhaustion: ok').

http_json_exhaustion(URL) :-
    atom_concat(URL,'/call?goal=repeat&template=small&limit=1000000&format=json',Request),
    setup_call_cleanup(http_open(Request,Stream,[timeout(8)]),
      getline(Stream,Chars),close(Stream)),
    phrase(json_chars(pairs(Pairs)),Chars),
    member(string([t,y,p,e])-string([e,r,r,o,r]),Pairs),
    member(string([d,a,t,a])-string(ErrorChars),Pairs),
    atom_chars(Error,ErrorChars),sub_atom(Error,_,_,_,'resource_error(space)'),
    writeln('JSON stack errors retain the public error envelope: ok').

websocket_echo(Port) :-
    format(atom(URL),'ws://127.0.0.1:~w/ws',[Port]),
    http_open_websocket(URL,WS,[]),
    setup_call_cleanup(true,
      once((ws_send(WS,text('small unicode: \u00e5 \u20ac')),ws_receive(WS,Text),Text==text('small unicode: \u00e5 \u20ac'),
       ws_send(WS,binary([0,1,127,128,255])),ws_receive(WS,Binary),Binary==binary([0,1,127,128,255]),
       ws_send(WS,close(1000,done)),ws_receive(WS,Close),Close==close(1000,done))),
      ws_close(WS,1000,done)).

echo(WS,_) :-
    ws_receive(WS,Text),ws_send(WS,Text),
    ws_receive(WS,Binary),ws_send(WS,Binary),
    ws_receive(WS,close(Code,Reason)),ws_send(WS,close(Code,Reason)),!.
