% SPDX-License-Identifier: MIT
:- module(swi_remote_chart_interop,[run/4,run_uri/4]).
run(HomePort,PeerPort,SourcePort,NodeFile) :-
 format(atom(URI),'http://localhost:~w/examples/statecharts/01%20pause-and-resume.xml',[SourcePort]),
 run_uri(HomePort,PeerPort,URI,NodeFile).
run_uri(HomePort,PeerPort,URI,NodeFile) :-
 use_module(NodeFile),file_directory_name(NodeFile,Dir),
 directory_file_path(Dir,'statechart_actor.pl',ChartFile),use_module(ChartFile,[]),
 node:node(HomePort,[profile(actor),auth(open)]),
 format(atom(URL),'http://localhost:~w',[PeerPort]),
 thread_create(swi_remote_chart_interop:exercise(URL,URI),T,[]),thread_join(T,Status),
 (Status==true -> true;throw(compatibility_check_failed(Status))).
exercise(URL,URI) :-
 actors:self(Self),
 Text='<statechart version="0.2" initial="s"><state id="s"><go on="read(To)" if="value(V)">send(To,value(V))</go></state></statechart>',
 setup_call_cleanup(statechart_actor:statechart_spawn(P,[node(URL),src_text(Text),src_list([value(shared)]),trace(false),monitor(true),link(false)]),
  (actors:send(P,read(Self)),actors:receive({value(shared) -> true},[timeout(4),on_timeout(fail)]),stop(P),Done=true),(var(Done)->actors:exit(P,kill);true)),
 setup_call_cleanup(statechart_actor:statechart_spawn(Q,[node(URL),src_uri(URI),trace(false),monitor(true),link(false)]),(stop(Q),DoneQ=true),(var(DoneQ)->actors:exit(Q,kill);true)),
 writeln('Native SWI constructor -> Trealla text/URI, sources, halt and monitors: ok').
stop(P) :-
 statechart_actor:statechart_halt(P,Reply,2),memberchk(Reply,[true,killed]),
 actors:receive({down(P,P,_) -> true},[timeout(4),on_timeout(fail)]).
