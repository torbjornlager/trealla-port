% SPDX-License-Identifier: MIT
:- module(remote_statechart_invocation_tests,[unit/0,live/1]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(statechart_actor).
:- use_module(remote_server,[]).
:- use_module(sandbox_policy,[]).
unit :-
 remote_server:prepare(blacklist,actor,true,[],_,_,no),
 remote_server:prepare(blacklist,actor,server_loop(a,b),[src_list([server_loop(a,b)])],_,_,no),
 forall(member(M,[blacklist,whitelist]),server_policy(M)),
 writeln('Remote server adapter validates source, callback and profile: ok').
server_policy(M) :-
 remote_server:prepare(M,actor,server_loop(cb,[]),[src_list([cb(X,S,X,S)])],remote_server:run(_,[]),_,yes),
 rejected(remote_server:prepare(M,actor,server_loop(cb,[]),[src_list([(cb(_,S,S,S):-shell(true))])],_,_,_)),
 rejected(remote_server:prepare(M,actor,server_loop(system:shell,[]),[],_,_,_)),
 rejected(remote_server:prepare(M,isobase,server_loop(cb,[]),[],_,_,_)),
 rejected(sandbox_policy:sandbox_prepare_spawn(M,actor,actor_context,remote_server:run(foo,[]),[],_,_)).
:- meta_predicate rejected(0).
rejected(G) :- catch(call(G),E,true),nonvar(E).
live(Port) :-
 format(atom(URL),'http://localhost:~w',[Port]),
 actors(Before),
 setup_call_cleanup(true,
   (forall(member(Type,[actor,toplevel,server,supervisor]),check(Type,URL)),
    remote_targets(URL),remote_errors(URL)),
   remote_drop_connection(URL)),
 get_time(Now),Deadline is Now+3,wait_baseline(Before,Deadline),
 format('Remote chart invocation actor/toplevel/server/supervisor on ~w: ok~n',[Port]).
check(Type,URL) :-
 model(Type,Body),
 format(atom(XML),'<statechart version="0.2" initial="s"><datamodel>value(shared). :- dynamic remote_child/1.</datamodel><state id="s">~w</state><final id="f"/></statechart>',[Body]),
 % The placeholder is replaced only in fixture XML, never in source terms.
 replace_node(XML,URL,Text),
 statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),
 receive({output(P,child(C)) -> true},[timeout(5),on_timeout(throw(missing_child(Type,P)))]),
 check_alias(Type,C),
 monitor(C,R),
 receive({output(P,result(Type)) -> true},[timeout(5),on_timeout(throw(missing_result(Type,P)))]),
 (memberchk(Type,[server,supervisor]) -> send(P,finish);true),
 receive({down(P,P,true) -> true},[timeout(5),on_timeout(throw(missing_chart_down(Type,P)))]),
 receive({down(C,R,_) -> true},[timeout(5),on_timeout(throw(missing_remote_cleanup(Type,C)))]),
 demonitor(R,[flush]),check_alias(Type,undefined),
 format('~w replies, complete monitor references and state-exit cleanup: ok~n',[Type]).
replace_node(XML,URL,Text) :- atomic_list_concat(Parts,'PEER',XML),atomic_list_concat(Parts,URL,Text).
model(actor,'<spawn type="actor" goal="worker" options="[node(\'PEER\'),monitor(true),link(false),src_predicates([value/1])]"><![CDATA[worker :- receive({probe(Target) -> true}),value(shared),send(Target,result(actor)),receive({finish -> true}).]]></spawn><go on="spawned(C)">output(child(C)),assertz(remote_child(C)),self(Self),send(C,probe(Self))</go><go on="result(actor)" if="remote_child(C)">output(result(actor)),send(C,finish)</go><go on="down(_,_,true)" to="f"/>').
model(toplevel,'<spawn type="toplevel" options="[node(\'PEER\'),monitor(true),link(false),src_predicates([value/1])]"><![CDATA[q(X) :- value(X).]]></spawn><go on="spawned(C)">output(child(C)),toplevel_call(C,(sleep(0.01),q(X)),[template(X-X)])</go><go on="success(_, [shared-shared],false)">output(result(toplevel))</go><go on="down(_,_,true)" to="f"/>').
model(server,'<spawn type="server" callback="cb" state="0" options="[name(remote_chart_server),node(\'PEER\'),monitor(true),link(false),src_predicates([value/1])]"><![CDATA[cb(get,S,X,S) :- value(X).]]></spawn><go on="spawned(C)">output(child(C)),server_request(C,get,shared),output(result(server))</go><go on="finish" to="f"/>').
model(supervisor,'<spawn type="supervisor" children="[child(w,[start(worker),restart(temporary)])]" options="[name(remote_chart_supervisor),node(\'PEER\'),monitor(true),link(false),src_predicates([value/1])]"><![CDATA[worker :- value(shared),receive({finish -> true}).]]></spawn><go on="spawned(C)">output(child(C)),supervisor_count_children(C,Counts),memberchk(active-1,Counts),output(result(supervisor))</go><go on="finish" to="f"/>').
wait_baseline(Before,Deadline) :-
 actors(After),sort(Before,B),sort(After,A),
 (A==B -> true;get_time(Now),Now<Deadline,sleep(0.01),wait_baseline(Before,Deadline)).

remote_errors(URL) :-
 self(Self),spawn(receive({finish -> true}),Other,[link(false)]),monitor(Other,Unrelated),
 % Name conflicts are detected before a remote actor can be created.
 register(remote_chart_taken,Self),
 format(atom(Text),'<statechart version="0.2" initial="s"><state id="s"><spawn type="server" callback="cb" state="0" options="[node(\'~w\'),name(remote_chart_taken)]">cb(_,S,S,S).</spawn></state></statechart>',[URL]),
 statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),
 receive({down(P,P,Why) -> true},[timeout(5),on_timeout(fail)]),Why\==true,
 whereis(remote_chart_taken,Self),unregister(remote_chart_taken),
 % A failed second invocation must retire a preceding detached remote child.
 format(atom(Bad),'<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="receive({never -&gt; true})" options="[node(\'~w\'),link(false)]"/><spawn type="server" callback="cb" state="0" options="[node(\'~w\')]"><![CDATA[cb(_,S,S,S) :- shell(true).]]></spawn></state></statechart>',[URL,URL]),
 statechart_spawn(B,[src_text(Bad),trace(true),monitor(true),link(false),io_target(Self)]),
 receive({terminal_output(B,statechart_trace(invoked(actor,C,s))) -> true},[timeout(5),on_timeout(fail)]),
 monitor(C,R),receive({down(B,B,Reason) -> true},[timeout(5),on_timeout(fail)]),Reason\==true,
 receive({down(C,R,_) -> true},[timeout(5),on_timeout(fail)]),demonitor(R,[flush]),
 % Even a trusted sandbox-off sender cannot weaken the peer's sandbox.
 format(atom(PeerBad),'<statechart version="0.2" initial="s"><state id="s"><spawn type="server" callback="cb" state="0" options="[node(\'~w\')]"><![CDATA[cb(_,S,S,S) :- shell(true).]]></spawn></state></statechart>',[URL]),
 statechart_actor:statechart_spawn_in(off,actor,user,PB,[src_text(PeerBad),trace(false),monitor(true),link(false)]),
 receive({down(PB,PB,PeerReason) -> true},[timeout(5),on_timeout(fail)]),PeerReason\==true,
 send(Other,finish),receive({down(Other,Unrelated,true) -> true},[timeout(2),on_timeout(fail)]),demonitor(Unrelated,[flush]),
 writeln('name conflict, sender/peer sandbox checks, rollback and unrelated monitor: ok').

remote_targets(URL) :-
 self(Parent),
 spawn((receive({Message -> send(Parent,forwarded(Message))}),receive({finish -> true})),Other,[link(false)]),
 setup_call_cleanup(monitor(Other,Own),
   (distribution:transparent_node(URL,Node),
    distribution:remote_toplevel_spawn_mode(Node,Top,user:[session(true),target(Other),link(false),monitor(true)],transparent),
    setup_call_cleanup(true,
      (toplevel_actors:toplevel_call(Top,member(X,[a]),[template(X-X)]),
       receive({forwarded(success(Top,[a-a],false)) -> true},[timeout(5),on_timeout(fail)]),
       toplevel_actors:toplevel_call(Top,member(Y,[b]),[template(Y-Y),target(Parent)]),
       receive({success(Top,[b-b],false) -> true},[timeout(5),on_timeout(fail)])),
      exit(Top,kill)),
    receive({down(Top,Top,_) -> true},[timeout(5),on_timeout(fail)])),
   (send(Other,finish),receive({down(Other,Own,_) -> true},[timeout(2),on_timeout(fail)]),demonitor(Own,[flush]))),
 writeln('remote toplevel spawn/call targets and template sharing: ok').

check_alias(server,Pid) :- !,whereis(remote_chart_server,Pid).
check_alias(supervisor,Pid) :- !,whereis(remote_chart_supervisor,Pid).
check_alias(_,_).
