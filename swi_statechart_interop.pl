% SPDX-License-Identifier: MIT
:- module(swi_statechart_interop,[run/2,run_invocations/1]).
:- use_module(library(http/websocket)).
:- use_module(library(readutil)).
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

run_invocations(Port) :-
 format(atom(URL),'ws://127.0.0.1:~w/ws',[Port]),
 setup_call_cleanup(http_open_websocket(URL,WS,[]),invocation_checks(WS),catch(ws_close(WS,1000,"done"),_,true)).
invocation_checks(WS) :-
 ws_send(WS,json(_{command:toplevel_spawn,options:"[session(true)]",request_id:"invocation-session"})),
 next(WS,spawned,Spawn,[]),Pid=Spawn.pid,
 query(WS,Pid,"statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"><spawn type=\"actor\" goal=\"worker(1)\" options=\"[monitor(true)]\">worker(N) :- output(worker(N)).</spawn><go on=\"output(_,worker(N))\">output(result(N))</go><go on=\"down(_,_,true)\" to=\"f\"/></state><final id=\"f\"/></statechart>'),trace(false),monitor(true)]),receive({output(P,result(1)) -> true},[timeout(2),on_timeout(fail)]),receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]).",_),
 query(WS,Pid,"statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"><spawn type=\"toplevel\" options=\"[monitor(true),link(false)]\">q(a). q(b).</spawn><go on=\"spawned(C)\">toplevel_call(C,q(X),[template(X),limit(1)])</go><go on=\"success(C,Slice,true)\">output(page(Slice)),toplevel_next(C)</go><go on=\"success(_,Slice,false)\">output(page(Slice))</go><go on=\"down(_,_,true)\" to=\"f\"/></state><final id=\"f\"/></statechart>'),trace(false),monitor(true)]),receive({output(P,page([a])) -> true},[timeout(2),on_timeout(fail)]),receive({output(P,page([b])) -> true},[timeout(2),on_timeout(fail)]),receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]).",_),
 query(WS,Pid,"statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><datamodel>parent_value(shared).</datamodel><state id=\"s\"><spawn type=\"statechart\" options=\"[monitor(true),link(false),trace(false),src_predicates([parent_value/1])]\"><![CDATA[<statechart version=\"0.2\" initial=\"w\"><state id=\"w\"><onentry>parent_value(X),output(nested(X))</onentry><go on=\"finish\" to=\"f\"/></state><final id=\"f\"/></statechart>]]></spawn><go on=\"spawned(C)\">send(C,finish)</go><go on=\"output(_,nested(X))\">output(result(X))</go><go on=\"down(_,_,true)\" to=\"f\"/></state><final id=\"f\"/></statechart>'),trace(false),monitor(true)]),receive({output(P,result(shared)) -> true},[timeout(2),on_timeout(fail)]),receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]).",_),
 read_file_to_string('fixtures/statecharts/13-spawn-actor.xml',Text,[]),
 term_string(Text,TextTerm,[quoted(true)]),
 format(string(Goal),"actors(Before),statechart_spawn(P,[src_text(~s),trace(false),monitor(true)]),sleep(2.2),whereis(ponger,C),monitor(C,R),statechart_halt(P,true,2),receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),receive({down(C,R,_) -> true},[timeout(2),on_timeout(fail)]),demonitor(R,[flush]),actors(After),sort(Before,Sorted),sort(After,Sorted).",[TextTerm]),
 query(WS,Pid,Goal,_),
 writeln('Public local actor/toplevel/nested-chart invocation, ping-pong cleanup and monitors: ok').
