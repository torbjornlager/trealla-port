% SPDX-License-Identifier: MIT
:- module(remote_chart_tests,[unit/0,live/2,live_uri/2]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(statechart_actor).
:- use_module(remote_statechart,[]).
:- use_module(sandbox_policy,[]).
xml('<statechart version="0.2" initial="s"><datamodel>:- dynamic val/1. val(initial).</datamodel><state id="s"><go on="set(X)">retractall(val(_)),assertz(val(X))</go><go on="read(To)" if="(parent_value(V),val(W))">send(To,snapshot(V,W))</go></state></statechart>').
unit :-
 xml(Text),trace_envelopes,
 forall(member(Mode,[blacklist,whitelist]),boundaries(Mode,Text)),
 remote_statechart:prepare(blacklist,actor,true,[],_,_,no),
 remote_statechart:prepare(blacklist,actor,interpret_text(a),[src_list([interpret_text(a)])],_,_,no),
 writeln('Remote chart entry shapes, shared preparation, sandbox/profile and source boundaries: ok').
boundaries(Mode,Text) :-
 forall(member(Wire,[interpret_text(Text),interpret_text_trace(false,Text)]),
   (remote_statechart:prepare(Mode,actor,Wire,[src_list([parent_value(shared)])],Entry,Loaded,yes),
    Entry=statechart_actor:run_chart(_,Mode,actor,_,Trace),memberchk(Trace,[true,false]),memberchk(src_list([]),Loaded))),
 rejected(remote_statechart:prepare(Mode,actor,interpret_text_trace(bad,Text),[],_,_,_)),
 rejected(remote_statechart:prepare(Mode,isobase,interpret_text(Text),[],_,_,_)),
 rejected(remote_statechart:prepare(Mode,actor,interpret_text('<bad/>'),[],_,_,_)),
 rejected(remote_statechart:prepare(Mode,actor,interpret_text('<statechart version="0.2" initial="s"><state id="s"><onentry>shell(true)</onentry></state></statechart>'),[],_,_,_)),
 rejected(remote_statechart:prepare(Mode,actor,interpret_text('<statechart version="0.2" initial="s"><datamodel>bad :- shell(true).</datamodel><state id="s"/></statechart>'),[],_,_,_)),
 rejected(sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,statechart_actor:run_chart([],off,actor,[],false),[],_,_)).
:- meta_predicate rejected(0).
rejected(G) :- catch(call(G),E,true),nonvar(E).
live(Port,SourcePort) :-
 format(atom(URI),'http://localhost:~w/examples/statecharts/01%20pause-and-resume.xml',[SourcePort]),live_uri(Port,URI).
live_uri(Port,URI) :-
 format(atom(URL),'http://localhost:~w',[Port]),
 setup_call_cleanup(true,(text_charts(URL),writeln(text_and_private_data_ok),uri_chart(URL,URI),writeln(uri_ok),nested_chart(URL),writeln(invocation_cleanup_ok),admission(URL),writeln(admission_ok)),remote_drop_connection(URL)),
 format('Remote statechart text/URI, invocation, private data, halt, monitors and rejection on ~w: ok~n',[Port]).
text_charts(URL) :-
 xml(Text),self(Self),
 setup_call_cleanup(
  statechart_spawn(P,[node(URL),name(remote_chart_probe),src_text(Text),src_list([parent_value(shared)]),trace(true),monitor(true),link(false)]),
  (whereis(remote_chart_probe,P),monitor(P,R),
   setup_call_cleanup(
    statechart_spawn(Q,[node(URL),src_text(Text),src_list([parent_value(shared)]),trace(false),monitor(true),link(false)]),
    (send(P,set(changed)),send(P,read(Self)),receive({snapshot(shared,changed) -> true},[timeout(4),on_timeout(fail)]),
     send(Q,read(Self)),receive({snapshot(shared,initial) -> true},[timeout(4),on_timeout(fail)]),
     statechart_halt(Q,true,2),down(Q,Q),
     receive({terminal_output(Q,statechart_trace(_)) -> throw(unexpected_trace(Q))},[timeout(0),on_timeout(true)])),exit(Q,kill)),
   statechart_halt(P,true,2),down(P,P),down(P,R),demonitor(R,[flush]),whereis(remote_chart_probe,undefined)),exit(P,kill)).
uri_chart(URL,URI) :-
 setup_call_cleanup(statechart_spawn(P,[node(URL),src_uri(URI),trace(false),monitor(true),link(false)]),
   (send(P,pause),statechart_halt(P,true,2),down(P,P)),exit(P,kill)).
nested_chart(URL) :-
 format(atom(Text),'<statechart version="0.2" initial="s"><datamodel>parent_value(shared).</datamodel><state id="s"><spawn type="statechart" options="[node(\'~w\'),trace(false),monitor(true),link(false),src_predicates([parent_value/1])]"><![CDATA[<statechart version="0.2" initial="w"><state id="w"><go on="probe(To)" if="parent_value(V)">send(To,nested(V))</go><go on="finish" to="f"/></state><final id="f"/></statechart>]]></spawn><go on="spawned(C)">output(child(C)),self(Self),send(C,probe(Self))</go><go on="nested(shared)">output(nested_ok)</go><go on="finish" to="f"/></state><final id="f"/></statechart>',[URL]),
 setup_call_cleanup(statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),
   (receive({output(P,child(C)) -> true},[timeout(4),on_timeout(fail)]),monitor(C,R),
    receive({output(P,nested_ok) -> true},[timeout(4),on_timeout(fail)]),
    send(P,finish),down(P,P),down(C,R),demonitor(R,[flush])),exit(P,kill)).
admission(URL) :-
 catch(statechart_spawn(Missing,[node(URL),name(remote_chart_failed),src_uri('http://127.0.0.1:1/missing.xml'),trace(false),monitor(true),link(false)]),E,true),
 (nonvar(E) -> var(Missing)
 ; receive({down(Missing,Missing,Failure) -> Failure\==true},[timeout(4),on_timeout(fail)])),
 whereis(remote_chart_failed,undefined),
 Bad='<statechart version="0.2" initial="s"><state id="s"><onentry>shell(true)</onentry></state></statechart>',
 catch(statechart_actor:statechart_spawn_in(off,actor,user,Pid,[node(URL),src_text(Bad),trace(false),monitor(true),link(false)]),Rejected,true),
 (nonvar(Rejected) -> var(Pid)
 ; receive({down(Pid,Pid,Why) -> Why\==true},[timeout(0.2),on_timeout((statechart_halt(Pid,_,2),down(Pid,Pid)))])).
down(P,R) :- receive({down(P,R,_) -> true},[timeout(4),on_timeout(throw(missing_down(P,R))) ]).

trace_envelopes :-
 self(Self),
 web_prolog:object([type-string_atom(statechart_trace),pid-number(7),data-string_atom('execution(send(1@localhost,hello))')],Event),
 web_prolog:object([type-string_atom(io_request),request_id-string_atom(probe),event-Event],Envelope),
 distribution:dispatch_remote_type(io_request,Envelope,'http://peer',Self),
 receive({'$wire_event'(7,statechart_trace,terminal_output(7@'http://peer',statechart_trace(execution(send(1@localhost,hello))))) -> true},[timeout(0),on_timeout(fail)]),
 receive({'$wire_io_ack'(Ack) -> true},[timeout(0),on_timeout(fail)]),
 web_prolog:json_atom_field(Ack,status,ok),
 % A spawn wait must service an acknowledgement without consuming unrelated
 % messages or issuing the spawn request twice.
 send(Self,unrelated_trace_probe),send(Self,'$wire_io_ack'(Ack)),send(Self,'$wire_spawn_error'(probe_failed)),
 setup_call_cleanup(open('/dev/null',write,S,[type(binary)]),
   distribution:writer_wait_spawn(Self,transparent,[],Self,Self,ws(S,server,1024),'http://peer',true),close(S)),
 receive({'$remote_spawn_error'(Self,probe_failed) -> true},[timeout(0),on_timeout(fail)]),
 receive({unrelated_trace_probe -> true},[timeout(0),on_timeout(fail)]),
 web_prolog:object([type-string_atom(io_request),request_id-string_atom(bad),event-pairs([])],Malformed),
 distribution:dispatch_remote_type(io_request,Malformed,'http://peer',Self),
 receive({'$wire_io_ack'(Rejected) -> true},[timeout(0),on_timeout(fail)]),web_prolog:json_atom_field(Rejected,status,error).
