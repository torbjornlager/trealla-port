% SPDX-License-Identifier: MIT
% Third-party sends to a Trealla node (cross-node-actor-0.1, XN-001..XN-004).
% A canonical SWI node and raw WebSocket clients drive the Trealla fixture,
% which accepts the bearer token below as a peer with internal_transport.
:- module(swi_third_party_send,[run/3]).
:- use_module(library(http/websocket), []).
:- dynamic test_peer/1.
:- multifile distribution:hook_transport_options/2.
distribution:hook_transport_options(URL,[request_header('Authorization'='Bearer lineage-test-peer')]) :-
    swi_third_party_send:test_peer(URL).

peer_options([request_header('Authorization'='Bearer lineage-test-peer')]).

run(HomePort,TreallaPort,NodeFile) :-
    use_module(NodeFile),
    node:node(HomePort,[profile(actor),auth(open)]),
    format(atom(URL),'http://127.0.0.1:~w',[TreallaPort]),
    atom_concat(URL,'/ws',WSURL),
    assertz(test_peer(URL)),
    qualified_export_test(URL),
    requalified_pid_test(URL),
    third_party_reply_test(WSURL),
    wire_rule_test(WSURL),
    browser_reply_export_test(WSURL,URL),
    early_close_flush_test(WSURL),
    format(atom(HomeURL),'http://127.0.0.1:~w',[HomePort]),
    sync_reply_route_test(WSURL,HomeURL),
    format('Third-party sends to Trealla: ok~n').

% A Trealla actor's own pid reaches another node as Id@URL, the same pid
% spawn/3 returned there, not as a per-connection return handle.
qualified_export_test(URL) :-
    actors:self(Client),
    actors:spawn((self(Me),send(Client,xn_me(Me))),Pid,
                 [node(URL),monitor(true),link(false)]),
    actors:receive({xn_me(Me)->true},[timeout(5),on_timeout(throw(no_exported_pid))]),
    ( Me == Pid -> true ; throw(unqualified_export(Me,Pid)) ),
    actors:receive({down(Pid,_,true)->true},[timeout(5),on_timeout(throw(no_down))]).

% A pid that is already qualified (here from a spawn on the Trealla node's own
% URL) leaves the node unchanged, never as (Id@URL)@URL.
requalified_pid_test(URL) :-
    actors:self(Client),
    actors:spawn((spawn(receive({xn_stop->true},[timeout(3),on_timeout(true)]),R,[node(URL)]),
                  send(Client,xn_r(R))),Pid,[node(URL),monitor(true),link(false)]),
    actors:receive({xn_r(R)->true},[timeout(5),on_timeout(throw(no_requalified_pid))]),
    ( R = '@'(Id,Node), integer(Id), Node == URL -> true ; throw(requalified_pid(R)) ),
    actors:send(R,xn_stop),
    actors:receive({down(Pid,_,true)->true},[timeout(5),on_timeout(throw(no_down))]).

% The SWI node replies to a Trealla actor that a different connection (a raw
% browser client) spawned: its reply arrives over SWI's own peer connection.
third_party_reply_test(WSURL) :-
    actors:self(Client),
    format(string(Goal),
           "self(Me),send(~q,xn_ping(Me)),receive({xn_pong->writeln(xn_ok)},[timeout(5),on_timeout(writeln(xn_lost))])",
           [Client]),
    setup_call_cleanup(
        websocket:http_open_websocket(WSURL,WS,[]),
        ( ws_json(WS,_{command:spawn,goal:Goal,request_id:"xn-reply"}),
          event(WS,spawned,_),
          actors:receive({xn_ping(Target)->true},[timeout(5),on_timeout(throw(no_ping))]),
          actors:send(Target,xn_pong),
          expect_output(WS,"xn_ok") ),
        catch(websocket:ws_close(WS,1000,"done"),_,true)).

% Wire rules: a peer may send to an actor another connection owns; a browser
% may not; exit and monitor stay owner-only, even for a peer.
wire_rule_test(WSURL) :-
    peer_options(PeerOptions),
    Goal = "receive({xn_hello->writeln(xn_got)},[timeout(4),on_timeout(writeln(xn_missing))])",
    setup_call_cleanup(
        ( websocket:http_open_websocket(WSURL,Owner,[]),
          websocket:http_open_websocket(WSURL,Peer,PeerOptions),
          websocket:http_open_websocket(WSURL,Browser,[]) ),
        ( ws_json(Owner,_{command:spawn,goal:Goal,request_id:"xn-a"}),
          event(Owner,spawned,A),
          ws_json(Peer,_{command:send,pid:A.pid,message:"xn_hello",request_id:"xn-peer-send"}),
          expect_output(Owner,"xn_got"),
          ws_json(Owner,_{command:spawn,goal:Goal,request_id:"xn-b"}),
          event(Owner,spawned,B),
          refused(Browser,_{command:send,pid:B.pid,message:"xn_hello",request_id:"xn-browser-send"}),
          refused(Peer,_{command:exit,pid:B.pid,reason:"kill",request_id:"xn-peer-exit"}),
          refused(Peer,_{command:monitor,pid:B.pid,ref:"xn_ref",request_id:"xn-peer-monitor"}),
          expect_output(Owner,"xn_missing") ),
        ( catch(websocket:ws_close(Owner,1000,"done"),_,true),
          catch(websocket:ws_close(Peer,1000,"done"),_,true),
          catch(websocket:ws_close(Browser,1000,"done"),_,true) )).

% A Trealla actor that replies to a browser connection's virtual address sends
% its own pid qualified, as on a peer connection (N7's browser shells reach
% Trealla this way), not as a bare integer.
browser_reply_export_test(WSURL,URL) :-
    setup_call_cleanup(
        websocket:http_open_websocket(WSURL,WS,[]),
        ( ws_json(WS,_{command:transport_hello,version:1,browser_pids:true}),
          event(WS,transport_welcome,_),
          ws_json(WS,_{command:spawn,goal:"self(Me),send(1234567890@localhost,xn_me(Me))",
                       request_id:"xn-browser-reply"}),
          event(WS,spawned,Spawned),
          event(WS,actor_message,Reply),
          format(string(Expected),"xn_me(~w@'~w')",[Spawned.pid,URL]),
          ( Reply.message == Expected -> true ; throw(unqualified_browser_reply(Reply.message,Expected)) ) ),
        catch(websocket:ws_close(WS,1000,"done"),_,true)).

% An actor's send to another node is delivered even when the connection that
% owns the actor closes as soon as the actor ends, before the new outbound
% connection has seen the receiving node's welcome (N7 closes this way).
early_close_flush_test(WSURL) :-
    actors:self(Client),
    forall(between(1,5,I),
           ( format(string(Goal),"send(~q,xn_flushed(~w))",[Client,I]),
             websocket:http_open_websocket(WSURL,WS,[]),
             ws_json(WS,_{command:spawn,goal:Goal,request_id:"xn-flush"}),
             event(WS,spawned,_),
             event(WS,down,_),
             catch(websocket:ws_close(WS,1000,"done"),_,true),
             actors:receive({xn_flushed(I)->true},[timeout(5),on_timeout(throw(send_lost_on_close(I)))]) )).

% A synchronous call from a Trealla actor to a toplevel on another node gets
% its reply on the calling connection: the reply route stays a return handle
% while the actor's other pids leave qualified (interop-actor IX-001, IX-003).
sync_reply_route_test(WSURL,HomeURL) :-
    format(string(Goal),
           "toplevel_spawn(P,[node(~q),session(true)]),toplevel_call_synch(P,true,A,[timeout(3)]),(A==success(P,[true],false)->writeln(xn_sync_ok);writeln(xn_sync_bad)),toplevel_halt(P)",
           [HomeURL]),
    setup_call_cleanup(
        websocket:http_open_websocket(WSURL,WS,[]),
        ( ws_json(WS,_{command:spawn,goal:Goal,request_id:"xn-sync"}),
          event(WS,spawned,_),
          expect_output(WS,"xn_sync_ok") ),
        catch(websocket:ws_close(WS,1000,"done"),_,true)).

refused(WS,Command) :-
    ws_json(WS,Command),
    event(WS,error,Reply),
    ( sub_string(Reply.data,_,_,_,"permission") -> true
    ; throw(unexpected_refusal(Command.command,Reply)) ).

expect_output(WS,Expected) :-
    event(WS,output,Reply),
    ( sub_string(Reply.data,_,_,_,Expected) -> true
    ; throw(unexpected_output(Expected,Reply)) ).

ws_json(WS,Dict) :- websocket:ws_send(WS,json(Dict)).

event(WS,Type,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    ( Frame.opcode==close -> throw(unexpected_close(Frame))
    ; atom_string(Type,Frame.data.type) -> Reply=Frame.data
    ; Frame.data.type=="error" -> throw(unexpected_error(Type,Frame.data))
    ; event(WS,Type,Reply) ).
