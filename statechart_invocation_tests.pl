% SPDX-License-Identifier: MIT
:- module(statechart_invocation_tests,[run/0]).
:- use_module(actors).
:- use_module(statechart_actor).
:- use_module(sandbox_policy,[]).
:- use_module(isolation,[]).
:- use_module(statechart_actor_tests,[]).
run :- actors(Baseline),actor_child,reentry,toplevel_child,nested_child,
 timing,rollback,abort_cleanup,unrelated_monitor,policy_tests,example_fixtures,behaviour_fixtures,behaviour_sources,behaviour_policy,behaviour_cleanup,behaviour_rollback,behaviour_dynamic_admission,
 get_time(Now),Deadline is Now+2,statechart_actor_tests:wait_actors(Baseline,Deadline),
 writeln('Statechart local invocation regressions: all passed').
chart(Text,P) :- self(Self),statechart_spawn(P,[src_text(Text),trace(true),io_target(Self),monitor(true),link(false)]).
config(P,C) :- statechart_actor_tests:config(P,C).
down(P) :- statechart_actor_tests:down(P).
recv_child(P,C) :- receive({output(P,child(C)) -> true},[timeout(2),on_timeout(throw(missing_child(P)))]).
await_down(P,R,Reason) :- receive({down(P,R,Reason) -> true},[timeout(2),on_timeout(statechart_invocation_tests:missing_child_down(P))]).
actor_child :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="worker(1)" options="[monitor(true)]">worker(N) :- output(worker(N)).</spawn><go on="output(_,worker(N))">output(result(N))</go><go on="down(_,_,true)" to="f"/></state><final id="f"/></statechart>',
 chart(Text,P),receive({output(P,result(1)) -> true},[timeout(2),on_timeout(fail)]),down(P),
 writeln('actor child source, compound goal, output and monitor delivery: ok').
reentry :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="receive({never -&gt; true})" options="[link(false)]"/><go on="spawned(C)">output(child(C))</go><go on="leave" to="out"/></state><state id="out"><go on="resume" to="s"/></state></statechart>',
 chart(Text,P),recv_child(P,A),monitor(A,RA),send(P,leave),config(P,[s]),config(P,[out]),await_down(A,RA,stop),demonitor(RA,[flush]),
 send(P,resume),recv_child(P,B),A\==B,monitor(B,RB),statechart_halt(P,true,1),down(P),await_down(B,RB,stop),demonitor(RB,[flush]),
 writeln('state exit, re-entry and halt retire unlinked children: ok').
toplevel_child :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="toplevel" options="[monitor(true),link(false)]">q(a). q(b).</spawn><go on="spawned(C)">toplevel_call(C,q(X),[template(X),limit(1)])</go><go on="success(C,Slice,true)">output(page(Slice)),toplevel_next(C)</go><go on="success(_,Slice,false)">output(page(Slice))</go><go on="down(_,_,true)" to="f"/></state><final id="f"/></statechart>',
 chart(Text,P),receive({output(P,page([a])) -> true},[timeout(2),on_timeout(fail)]),
 receive({output(P,page([b])) -> true},[timeout(2),on_timeout(fail)]),down(P),
 writeln('toplevel child paging and ordinary asynchronous answers: ok').
nested_child :-
 Text='<statechart version="0.2" initial="s"><datamodel>parent_value(shared).</datamodel><state id="s"><spawn type="statechart" options="[monitor(true),link(false),trace(false),src_predicates([parent_value/1])]"><![CDATA[<statechart version="0.2" initial="w"><state id="w"><onentry>parent_value(X),output(nested(X))</onentry><go on="finish" to="f"/></state><final id="f"/></statechart>]]></spawn><go on="spawned(C)">send(C,finish)</go><go on="output(_,nested(X))">output(result(X))</go><go on="down(_,_,true)" to="f"/></state><final id="f"/></statechart>',
 chart(Text,P),receive({output(P,result(shared)) -> true},[timeout(2),on_timeout(fail)]),down(P),
 writeln('nested chart source predicates resolve in parent datamodel: ok').
timing :-
 % A transient state is exited before invocation; pending internal events also
 % take priority over invocation, matching SWI's run-to-completion loop.
 Text='<statechart version="0.2" initial="s"><state id="s"><onentry>raise(skip)</onentry><spawn type="actor" goal="throw(should_not_start)"/><go on="skip" to="f"/></state><final id="f"/></statechart>',
 chart(Text,P),config(P,[s]),config(P,[f]),down(P),
 receive({terminal_output(P,statechart_trace(invoked(_,_,_))) -> fail},[timeout(0),on_timeout(true)]),
 writeln('internal events precede invocation of stable states: ok').
rollback :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="wait" options="[link(false)]">wait :- output(started),receive({never -&gt; true}).</spawn><spawn type="actor" goal="true">bad :- shell(true).</spawn></state></statechart>',
 chart(Text,P),
 receive({terminal_output(P,statechart_trace(invoked(actor,C,s))) -> true},[timeout(2),on_timeout(fail)]),
 monitor(C,R),receive({down(P,P,Reason) -> true},[timeout(2),on_timeout(fail)]),Reason\==true,
 await_down(C,R,_),demonitor(R,[flush]),
 writeln('partial invocation failure rolls back earlier unlinked children: ok').
abort_cleanup :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="receive({never -&gt; true})" options="[link(false)]"/><go on="spawned(C)">output(child(C))</go></state></statechart>',
 chart(Text,P),recv_child(P,C),monitor(C,R),exit(P,kill),await_down(P,P,kill),await_down(C,R,stop),demonitor(R,[flush]),
 writeln('aborted chart cleans unlinked invoked children: ok').
rejects(G) :- catch(call(G),E,true),nonvar(E).
:- meta_predicate rejects(0).
policy_tests :-
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><state id="s"><spawn type="unsupported"/></state></statechart>')])),
 rejects(statechart_spawn(_,[node(42),src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><state id="s"><spawn type="toplevel" options="[time_limit(0)]"/></state></statechart>')])),
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="safe" options="[monitor(true),node(localhost)]">safe :- true.</spawn><go on="down(_,_,true)" to="f"/></state><final id="f"/></statechart>',
 sandbox_policy:sandbox_prepare_goal(whitelist,actor,user,statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),Safe),call(Safe),down(P),
 Unsafe='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="shell(true)"/></state></statechart>',
 chart(Unsafe,Bad),receive({down(Bad,Bad,Error) -> true},[timeout(2),on_timeout(fail)]),Error\==true,
 writeln('unsupported types, destinations, options and inherited sandbox policy: ok').

unrelated_monitor :-
 spawn(receive({finish -> true}),Other,[link(false)]),monitor(Other,R),
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="receive({never -&gt; true})" options="[link(false)]"/><go on="spawned(C)">output(child(C))</go></state></statechart>',
 chart(Text,P),recv_child(P,_),statechart_halt(P,true,1),down(P),
 send(Other,finish),await_down(Other,R,true),demonitor(R,[flush]),
 writeln('child cleanup preserves unrelated monitors: ok').

fixture(Name,Text) :-
 atom_concat('fixtures/statecharts/',Name,File),
 setup_call_cleanup(open(File,read,S),statechart_actor_tests:read_all(S,[],Codes),close(S)),atom_codes(Text,Codes).
example_fixtures :-
 fixture('14-spawn-toplevel.xml',Toplevel),chart(Toplevel,T),down(T),
 fixture('17-spawn-statechart.xml',Nested),chart(Nested,N),down(N),
 fixture('13-spawn-actor.xml',Actor),chart(Actor,A),
 receive({terminal_output(A,'Received Pong') -> true; terminal_io_output(A,'Received Pong') -> true},[timeout(3),on_timeout(fail)]),
 whereis(ponger,C),C\==undefined,monitor(C,R),
 statechart_halt(A,true,2),down(A),await_down(C,R,_),demonitor(R,[flush]),whereis(ponger,undefined),
 writeln('unchanged examples 13, 14 and 17 terminate and reclaim children: ok').

missing_child_down(P) :-
 (actors:actor_thread(P,T) -> (thread_property(T,status(S))->true;S=unknown);S=unregistered),
 (actors:exit_reason(P,R) -> true;R=not_exiting),
 throw(missing_child_down(P,S,R)).

behaviour_fixtures :-
 wait_fixture_name(counter_server,behaviour_fixtures),
 fixture('15-spawn-server.xml',Server),chart(Server,S),
 receive({terminal_output(S,reply(1)) -> true;terminal_io_output(S,reply(1)) -> true},[timeout(3),on_timeout(fail)]),down(S),
 fixture('16-spawn-supervisor.xml',Supervisor),chart(Supervisor,U),
 receive({terminal_output(U,[specs-1,active-1,supervisors-0,workers-1]) -> true;terminal_io_output(U,[specs-1,active-1,supervisors-0,workers-1]) -> true},[timeout(3),on_timeout(fail)]),down(U),
 writeln('unchanged server and supervisor examples: ok').

behaviour_sources :-
 Server='<statechart version="0.2" initial="s"><datamodel>value(7).</datamodel><state id="s"><spawn type="server" callback="cb" state="0" options="[link(false),src_predicates([value/1])]"><![CDATA[cb(get,S,X,S) :- value(X).]]></spawn><go on="spawned(C)">server_request(C,get,X),output(result(X)),raise(done)</go><go on="done" to="f"/></state><final id="f"/></statechart>',
 chart(Server,S),receive({output(S,result(7)) -> true},[timeout(2),on_timeout(fail)]),down(S),
 Supervisor='<statechart version="0.2" initial="s"><datamodel>value(9).</datamodel><state id="s"><spawn type="supervisor" children="[child(w,[start(worker),restart(temporary)])]" options="[link(false),src_predicates([value/1])]"><![CDATA[worker :- value(X),send(invocation_probe,observed(X)),receive({never -> true}).]]></spawn><go on="spawned(C)">supervisor_which_children(C,Children),output(children(Children))</go><go on="finish" to="f"/></state><final id="f"/></statechart>',
 % Observe the worker directly as well as the supervisor reply.
 self(Self),register(invocation_probe,Self),
 chart(Supervisor,U),receive({observed(9) -> true},[timeout(2),on_timeout(throw(missing_copied_value))]),unregister(invocation_probe),
 receive({output(U,children([info(w,W,worker,temporary)])) -> true},[timeout(2),on_timeout(fail)]),
 monitor(W,R),send(U,finish),down(U),await_down(W,R,_),demonitor(R,[flush]),
 ParentCallback='<statechart version="0.2" initial="s"><datamodel>value(11). cb(tag,get,S,X,S) :- value(X).</datamodel><state id="s"><spawn type="server" callback="cb(tag)" state="0" options="[src_predicates([value/1])]"/><go on="spawned(C)">server_request(C,get,X),output(result(X)),raise(done)</go><go on="done" to="f"/></state><final id="f"/></statechart>',
 chart(ParentCallback,C),receive({output(C,result(11)) -> true},[timeout(2),on_timeout(fail)]),down(C),
 writeln('behaviour inline source, parent callbacks and predicate copying: ok').
behaviour_policy :-
 forall(member(Mode,[blacklist,whitelist]),behaviour_policy_mode(Mode)),
 writeln('server and supervisor inherit sandbox policy and reject unsafe source: ok').
behaviour_policy_mode(Mode) :-
 wait_fixture_name(counter_server,behaviour_policy(Mode)),
 self(Self),fixture('15-spawn-server.xml',Server),
 sandbox_policy:sandbox_prepare_goal(Mode,actor,user,statechart_spawn(S,[src_text(Server),trace(false),monitor(true),link(false),io_target(Self)]),Safe),call(Safe),down(S),
 Unsafe='<statechart version="0.2" initial="s"><state id="s"><spawn type="server" callback="cb" state="0"><![CDATA[cb(_,S,S,S) :- shell(true).]]></spawn></state></statechart>',
 sandbox_policy:sandbox_prepare_goal(Mode,actor,user,statechart_spawn(B,[src_text(Unsafe),trace(false),monitor(true),link(false)]),Bad),call(Bad),
 await_down(B,B,Error),Error\==true,
 UnsafeSup='<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[child(w,[start(shell(true))])]"/></state></statechart>',
 sandbox_policy:sandbox_prepare_goal(Mode,actor,user,statechart_spawn(U,[src_text(UnsafeSup),trace(false),monitor(true),link(false)]),BadSup),call(BadSup),
 await_down(U,U,Why),Why\==true.

% Chart termination confirms that child shutdown was requested, not that the
% child's at_exit hook has already retired its node-wide name. Reusing fixture
% 15 must wait for that cleanup; never unregister the name on the child's behalf.
% Keep this separate from the unchanged two-second down/3 assertions.
wait_fixture_name(Name,Stage) :-
 get_time(Now),Deadline is Now+2,
 fixture_name_snapshot(Name,State),
 (State==names([],[]) -> true
 ;writeq(fixture_cleanup_wait(Stage,Name,State)),nl,
  wait_fixture_name_(Name,Stage,Deadline),
  writeq(fixture_cleanup_complete(Stage,Name)),nl).
wait_fixture_name_(Name,Stage,Deadline) :-
 fixture_name_snapshot(Name,State),
 (State==names([],[]) -> true
 ;get_time(Now),
  (Now<Deadline -> sleep(0.005),wait_fixture_name_(Name,Stage,Deadline)
  ;throw(fixture_cleanup_timeout(Stage,Name,State)))).
fixture_name_snapshot(Name,State) :-
 (mutex_trylock('$actor_registry') ->
  setup_call_cleanup(true,
    (findall(Pid,actors:registered(Name,Pid),Registered),
     findall(Token,actors:reserved_spawn_name(Name,Token),Reserved),
     State=names(Registered,Reserved)),
    mutex_unlock('$actor_registry'))
 ;State=registry_busy).
behaviour_cleanup :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[child(w,[start(receive({never -&gt; true})),restart(temporary)])]" options="[link(false)]"/><go on="spawned(C)">supervisor_which_children(C,Children),output(children(C,Children))</go></state></statechart>',
 chart(Text,P),receive({output(P,children(S,[info(w,W,worker,temporary)])) -> true},[timeout(2),on_timeout(fail)]),
 monitor(S,RS),monitor(W,RW),exit(P,kill),await_down(P,P,kill),await_down(S,RS,stop),await_down(W,RW,_),
 demonitor(RS,[flush]),demonitor(RW,[flush]),
 writeln('aborted chart reclaims unlinked supervisor and its worker: ok').

behaviour_rollback :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[child(w,[start(receive({never -&gt; true})),restart(temporary)])]" options="[link(false)]"/><spawn type="server" callback="cb" state="0"><![CDATA[cb(_,S,S,S) :- shell(true).]]></spawn></state></statechart>',
 chart(Text,P),receive({terminal_output(P,statechart_trace(invoked(supervisor,S,s))) -> true},[timeout(2),on_timeout(fail)]),
 monitor(S,R),await_down(P,P,Reason),Reason\==true,await_down(S,R,_),demonitor(R,[flush]),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[child(w,[])]"/></state></statechart>')])),
 rejects(statechart_spawn(_,[node(42),src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')])),
 writeln('behaviour startup rollback, child validation and invalid-destination rejection: ok').

behaviour_dynamic_admission :-
 Text='<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[]" options="[link(false)]"/><go on="spawned(C)">output(ready(C))</go></state></statechart>',
 chart(Text,P),receive({output(P,ready(C)) -> true},[timeout(2),on_timeout(fail)]),
 supervisor_actor:supervisor_spawn_child(C,child(bad,[start(shell(true))]),Reply),
 Reply=error(Error),nonvar(Error),
 statechart_halt(P,true,1),down(P),
 writeln('dynamic supervisor additions retain sandbox admission: ok').
