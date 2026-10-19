% SPDX-License-Identifier: MIT
:- module(swi_statechart_interop,[run/2]).
:- use_module(library(http/websocket)).
run(Port,SourcePort) :-
 format(atom(URL),'ws://127.0.0.1:~w/ws',[Port]),
 setup_call_cleanup(http_open_websocket(URL,WS,[]),checks(WS,SourcePort),catch(ws_close(WS,1000,"done"),_,true)).
checks(WS,SourcePort) :-
 ws_send(WS,json(_{command:toplevel_spawn,options:"[session(true)]",request_id:"chart-session"})),
 next(WS,spawned,Spawn,[]),Pid=Spawn.pid,
 Goal="statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"/></statechart>'),trace(false),monitor(true)]),statechart_halt(P,true,1),receive({down(P,P,true) -> true},[timeout(1),on_timeout(fail)]).",
 query(WS,Pid,Goal,_),
 format(string(URI),'http://127.0.0.1:~w/chart.xml',[SourcePort]),
 format(string(G2),"statechart_spawn(P,[src_uri('~w'),monitor(true)]),statechart_halt(P,true,1),receive({down(P,P,true) -> true},[timeout(1),on_timeout(fail)]).",[URI]),
 query(WS,Pid,G2,Traces),member(Trace,Traces),sub_string(Trace,_,_,_,"configuration([s])"),
 query(WS,Pid,"catch(statechart_spawn(P,[src_uri('http://not-allowed.invalid/chart.xml')]),E,true),nonvar(E),var(P).",_),
 query(WS,Pid,"statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><datamodel>x(ok).</datamodel><state id=\"s\"/></statechart>'),trace(false),monitor(true)]),statechart_halt(P,true,1),receive({down(P,P,true) -> true},[timeout(1),on_timeout(fail)]).",_),
 query(WS,Pid,"catch(statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><datamodel>:- shell(true).</datamodel><state id=\"s\"/></statechart>')]),E,true),nonvar(E),var(P).",_),
 writeln('Public statechart text/URI startup, trace, halt, monitors and fetch restrictions: ok').
query(WS,Pid,Goal,Traces) :-
 (string_concat(Clean,".",Goal)->true;Clean=Goal),
 ws_send(WS,json(_{command:toplevel_call,pid:Pid,goal:Clean,options:"[limit(1)]"})),
 next(WS,success,Reply,Traces),Reply.more==false.
next(WS,Type,Reply,Traces) :-
 ws_receive(WS,F,[format(json)]),
 (F.opcode==close -> throw(closed(F))
 ; atom_string(Type,F.data.type) -> Reply=F.data,Traces=[]
 ; F.data.type=="error" -> throw(query_error(F.data))
 ; F.data.type=="statechart_trace" -> Traces=[F.data.data|Rest],next(WS,Type,Reply,Rest)
 ; next(WS,Type,Reply,Traces)).
