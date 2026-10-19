% SPDX-License-Identifier: MIT
% Load this file into the n5 portal scratch editor. Requires n3 on 3053 and
% a disposable Trealla peer on 39801 permitting XML fetches from n5 on 3060.
% Run reproduce_private_reentry/0 to exercise the observed forall re-entry
% failure; remote_chart_ui_checks/0 is the sequential comparison.
reproduce_private_reentry :- forall(member(URL,['http://localhost:3053','http://localhost:39801']), (ui_text_charts(URL),ui_uri_chart(URL,'http://localhost:3060/examples/statecharts/01%20pause-and-resume.xml'),ui_nested_chart(URL))).
remote_chart_ui_checks :- ui_peer_checks('http://localhost:3053'),ui_peer_checks('http://localhost:39801').
ui_peer_checks(URL) :- ui_text_charts(URL),writeln(passed(URL,text_and_private_data)),ui_uri_chart(URL,'http://localhost:3060/examples/statecharts/01%20pause-and-resume.xml'),writeln(passed(URL,uri)),ui_nested_chart(URL),writeln(passed(URL,invocation_cleanup)).
ui_xml('<statechart version="0.2" initial="s"><datamodel>:- dynamic val/1. val(initial).</datamodel><state id="s"><go on="set(X)">retractall(val(_)),assertz(val(X))</go><go on="read(To)" if="(parent_value(V),val(W))">send(To,snapshot(V,W))</go></state></statechart>').
ui_text_charts(URL) :-
 ui_xml(Text),self(Self),
 setup_call_cleanup(
  statechart_spawn(P,[node(URL),name(remote_chart_probe),src_text(Text),src_list([parent_value(shared)]),trace(true),monitor(true),link(false)]),
  (whereis(remote_chart_probe,P),monitor(P,R),
   setup_call_cleanup(
    statechart_spawn(Q,[node(URL),src_text(Text),src_list([parent_value(shared)]),trace(false),monitor(true),link(false)]),
    (send(P,set(changed)),send(P,read(Self)),receive({snapshot(shared,changed) -> true},[timeout(4),on_timeout(fail)]),
     send(Q,read(Self)),receive({snapshot(shared,initial) -> true},[timeout(4),on_timeout(fail)]),
     statechart_halt(Q,true,2),ui_down(Q,Q),
     receive({terminal_output(Q,statechart_trace(_)) -> throw(unexpected_trace(Q))},[timeout(0),on_timeout(true)])),exit(Q,kill)),
   statechart_halt(P,true,2),ui_down(P,P),ui_down(P,R),demonitor(R,[flush]),whereis(remote_chart_probe,undefined)),exit(P,kill)).
ui_uri_chart(URL,URI) :-
 setup_call_cleanup(statechart_spawn(P,[node(URL),src_uri(URI),trace(false),monitor(true),link(false)]),
   (send(P,pause),statechart_halt(P,true,2),ui_down(P,P)),exit(P,kill)).
ui_nested_chart(URL) :-
 Template='<statechart version="0.2" initial="s"><datamodel>parent_value(shared).</datamodel><state id="s"><spawn type="statechart" options="[node(\'PEER\'),trace(false),monitor(true),link(false),src_predicates([parent_value/1])]"><![CDATA[<statechart version="0.2" initial="w"><state id="w"><go on="probe(To)" if="parent_value(V)">send(To,nested(V))</go><go on="finish" to="f"/></state><final id="f"/></statechart>]]></spawn><go on="spawned(C)">output(child(C)),self(Self),send(C,probe(Self))</go><go on="nested(shared)">output(nested_ok)</go><go on="finish" to="f"/></state><final id="f"/></statechart>',atomic_list_concat(Parts,'PEER',Template),atomic_list_concat(Parts,URL,Text),
 setup_call_cleanup(statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),
   (receive({output(P,child(C)) -> true},[timeout(4),on_timeout(fail)]),monitor(C,R),
    receive({output(P,nested_ok) -> true},[timeout(4),on_timeout(fail)]),
    send(P,finish),ui_down(P,P),ui_down(C,R),demonitor(R,[flush])),exit(P,kill)).
ui_down(P,R) :- receive({down(P,R,_) -> true},[timeout(4),on_timeout(throw(missing_ui_down(P,R)))]).
