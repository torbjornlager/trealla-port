% SPDX-License-Identifier: MIT
:- module(swi_lineage_compat,[run/3]).
:- use_module(library(http/websocket), []).
:- use_module(library(option)).
:- use_module(library(sgml)).
:- dynamic test_peer/1.
:- multifile distribution:hook_transport_options/2.
distribution:hook_transport_options(URL,[request_header('Authorization'='Bearer lineage-test-peer')]) :-
    swi_lineage_compat:test_peer(URL).

run(HomePort,PeerPort,NodeFile) :-
    use_module(NodeFile),
    node:node(HomePort,[profile(actor),auth(open)]),
    format(atom(URL),'http://127.0.0.1:~w',[PeerPort]),
    atom_concat(URL,'/ws',WSURL),
    setup_call_cleanup(
        websocket:http_open_websocket(WSURL,Observer,[]),
        swi_lineage_compat:checks(URL,WSURL,Observer),
        catch(websocket:ws_close(Observer,1000,"done"),_,true)).

peer_options([request_header('Authorization'='Bearer lineage-test-peer')]).
a("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").
b("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").
checks(URL,WSURL,Observer) :-
    send(Observer,_{command:toplevel_spawn,options:"[session(true)]"}),
    event(Observer,spawned,O),
    % Ordinary anonymous callers cannot supply transport lineage.
    a(A),send(Observer,_{command:spawn,goal:"true",lineage:A,request_id:"denied"}),
    event(Observer,error,Denied),Denied.request_id=="denied",
    sub_string(Denied.data,_,_,_,"permission"),
    peer_options(Opts),
    setup_call_cleanup(websocket:http_open_websocket(WSURL,WS,Opts),
        swi_lineage_compat:wire_checks(WS,Observer,O.pid),
        catch(websocket:ws_close(WS,1000,"done"),_,true)),
    eventually_query(Observer,O.pid,"whereis(lineage_child_b,undefined),whereis(lineage_root_b,undefined)",50),
    native_checks(URL,Observer,O.pid),
    writeln('Native SWI -> Trealla delegated lineage compatibility: all checks passed').

wire_checks(WS,Observer,O) :-
    a(A),b(B),
    spawn_family(WS,A,"a",RootA),spawn_family(WS,B,"b",RootB),
    send(WS,_{command:spawn,goal:"self(Me),register(lineage_legacy,Me),receive({finish -> true})",request_id:"legacy"}),
    event(WS,spawned,Legacy),
    eventually_query(Observer,O,"whereis(lineage_child_a,A),A\\==undefined,whereis(lineage_child_b,B),B\\==undefined,whereis(lineage_legacy,L),L\\==undefined",50),
    send(WS,_{command:exit,pid:RootB,lineage:A,reason:"kill"}),
    event(WS,error,Cross),sub_string(Cross.data,_,_,_,"permission"),
    send(WS,_{command:exit,pid:RootA,reason:"kill"}),
    event(WS,error,Unscoped),sub_string(Unscoped.data,_,_,_,"permission"),
    send(WS,_{command:monitor,pid:RootB,lineage:B,ref:"kept(b)"}),
    % A must not remove B's monitor, even with its exact reference.
    send(WS,_{command:demonitor,lineage:A,ref:"kept(b)"}),
    send(WS,_{command:lineage_close,lineage:A}),
    down(WS,RootA,_),
    eventually_query(Observer,O,"whereis(lineage_root_a,undefined),whereis(lineage_child_a,undefined),whereis(lineage_root_b,B),B\\==undefined,whereis(lineage_legacy,L),L\\==undefined",50),
    send(WS,_{command:lineage_close,lineage:A}),
    send(WS,_{command:spawn,lineage:A,goal:"true",request_id:"late"}),
    event(WS,error,Late),Late.request_id=="late",sub_string(Late.data,_,_,_,"closed_namespace"),
    send(WS,_{command:exit,lineage:B,pid:RootB,reason:"kill"}),
    down_ref(WS,RootB,"kept(b)"),
    send(WS,_{command:lineage_close,lineage:B}),
    eventually_query(Observer,O,"whereis(lineage_child_b,undefined),whereis(lineage_legacy,L),L\\==undefined",50),
    % Closing either lineage did not end the legacy actor.
    send(WS,_{command:send,pid:Legacy.pid,message:"finish"}),down(WS,Legacy.pid,_),
    % Reopen a different lineage to test connection-wide cleanup too.
    spawn_family(WS,"cccccccccccccccccccccccccccccccc","b",_),
    eventually_query(Observer,O,"whereis(lineage_child_b,B),B\\==undefined",50),
    writeln('Wire authority, multiplexing, late admission, legacy and monitor isolation: ok').

spawn_family(WS,Lineage,Suffix,Pid) :-
    format(string(Goal),'self(Me),register(lineage_root_~s,Me),spawn((self(C),register(lineage_child_~s,C),receive({finish -> true})),_,[link(false)]),receive({finish -> true})',[Suffix,Suffix]),
    send(WS,_{command:spawn,lineage:Lineage,goal:Goal,request_id:Suffix}),
    event(WS,spawned,Reply),Reply.request_id==Suffix,Pid=Reply.pid.

native_checks(URL,Observer,O) :-
    % Use native distribution's normal encoder and reader, not hand-built JSON.
    asserta(test_peer(URL),Hook),
    setup_call_cleanup(true,swi_lineage_compat:native_owned_spawn(URL,Observer,O),
        (erase(Hook),distribution:remote_drop_connection(URL))).
native_owned_spawn(URL,Observer,O) :-
    a(A),atom_string(Token,A),
    Context=ctx(global,delegated(peer,Token),Token,false,none),
    node_lifetime:with_context(Context,
        actors:spawn((self(Me),register(native_lineage_root,Me),receive({finish -> true})),
                     Pid,[node(URL),link(false),monitor(true)])),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_spawn(Top,[node(URL),session(true),monitor(true),link(false)])),
    node_lifetime:with_context(Context,
        toplevel_actors:toplevel_call_synch(Top,member(X,[a,b]),Answer,
                                           [template(X),limit(1),timeout(3)])),
    (Answer=success(Top,[a],true),var(X) -> true
    ; throw(unexpected_native_toplevel_answer(Answer,X,Top))),
    eventually_query(Observer,O,"whereis(native_lineage_root,P),P\\==undefined",50),
    node_lifetime:with_context(Context,
        distribution:remote_send_command(URL,_{command:lineage_close})),
    actors:receive({down(Pid,Pid,_) -> true},[timeout(5),on_timeout(fail)]),
    actors:receive({down(Top,Top,_) -> true},[timeout(5),on_timeout(fail)]),
    eventually_query(Observer,O,"whereis(native_lineage_root,undefined)",50),
    writeln('Native distribution encoding, spawn-time monitor and lineage_close: ok').

send(WS,Dict) :- websocket:ws_send(WS,json(Dict)).
event(WS,Type,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    (Frame.opcode==close -> throw(unexpected_close(Frame))
    ; atom_string(Type,Frame.data.type) -> Reply=Frame.data
    ; event(WS,Type,Reply)).
down(WS,Pid,Reply) :- event(WS,down,R),(R.pid==Pid -> Reply=R ; down(WS,Pid,Reply)).
down_ref(WS,Pid,Ref) :- down(WS,Pid,R),(R.ref==Ref -> true ; down_ref(WS,Pid,Ref)).
eventually_query(WS,Pid,Goal,N) :-
    send(WS,_{command:toplevel_call,pid:Pid,goal:Goal,options:"[template(ok),limit(1)]"}),
    query_result(WS,Reply),
    (Reply.type=="success" -> true
    ; N>0,sleep(0.02),Next is N-1,eventually_query(WS,Pid,Goal,Next)).
query_result(WS,Reply) :-
    websocket:ws_receive(WS,Frame,[format(json)]),
    (memberchk(Frame.data.type,["success","failure","error"]) -> Reply=Frame.data
    ; query_result(WS,Reply)).
