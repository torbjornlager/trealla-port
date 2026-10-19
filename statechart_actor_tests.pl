% SPDX-License-Identifier: MIT
:- module(statechart_actor_tests,[run/0]).
:- use_module(actors).
:- use_module(statechart_actor).
:- use_module(sandbox_policy,[]).
run :- actors(Baseline),pause_resume,isolation_test,action_bindings,timed_transition,postponed,parallel_final,deep_history,source_helpers,datamodel_tests,datamodel_computations,datamodel_shared,cleanup_tests(Baseline),negative_tests,
 writeln('Statechart execution regressions: all passed').
text_file(Name,Text) :-
 Name='01 pause-and-resume.xml',File='fixtures/statecharts/pause-and-resume.xml',
 setup_call_cleanup(open(File,read,S),read_all(S,[],Codes),close(S)),atom_codes(Text,Codes).
read_all(S,A,C) :- get_code(S,X),(X== -1 -> reverse(A,C);read_all(S,[X|A],C)).
chart(Text,P) :- self(Self),statechart_spawn(P,[src_text(Text),trace(true),io_target(Self),monitor(true),link(false)]).
config(P,C) :- receive({terminal_output(P,statechart_trace(configuration(C))) -> true},[timeout(2),on_timeout(throw(missing_configuration(P,C)))]).
down(P) :- receive({down(P,P,true) -> true},[timeout(2),on_timeout(throw(missing_down(P))) ]).
pause_resume :-
 text_file('01 pause-and-resume.xml',Text),chart(Text,P),
 config(P,[game,play,s1]),send(P,play),config(P,[game,play,s2]),
 send(P,pause),config(P,[game,interrupted]),send(P,resume),config(P,[game,play,s2]),
 send(P,reset),config(P,[game,play,s1]),send(P,stop),config(P,[final]),down(P),
 writeln('pause/resume hierarchy and shallow history: ok').
isolation_test :-
 chart('<statechart version="0.2" initial="a"><state id="a"/></statechart>',A),
 chart('<statechart version="0.2" initial="b"><state id="b"/></statechart>',B),
 config(A,[a]),config(B,[b]),statechart_halt(A,true,1),down(A),
 statechart_halt(B,true,1),down(B),writeln('concurrent chart isolation and halt: ok').
action_bindings :-
 chart('<statechart version="0.2" initial="s"><state id="s"><go on="choose(To)" if="member(X,[bound])" to="f">To ! chosen(X)</go></state><final id="f"/></statechart>',P),
 config(P,[s]),self(Self),send(P,choose(Self)),
 receive({chosen(bound) -> true},[timeout(2),on_timeout(throw(missing_binding))]),config(P,[f]),down(P),
 writeln('event/guard/action variable sharing: ok').
timed_transition :-
 chart('<statechart version="0.2" initial="s"><state id="s"><go after="0.02" to="f"/></state><final id="f"/></statechart>',P),
 config(P,[s]),config(P,[f]),down(P),writeln('timed transitions: ok').
postponed :-
 chart('<statechart version="0.2" initial="a"><state id="a"><defer on="later"/><go on="next" to="b"/></state><state id="b"><go on="later" to="f"/></state><final id="f"/></statechart>',P),
 config(P,[a]),send(P,later),send(P,next),config(P,[b]),config(P,[f]),down(P),writeln('deferred-event re-offering: ok').
parallel_final :-
 chart('<statechart version="0.2" initial="p"><parallel id="p"><state id="r1" initial="a"><state id="a"><go on="finish" to="f1"/></state><final id="f1"/></state><state id="r2" initial="b"><state id="b"><go on="finish" to="f2"/></state><final id="f2"/></state><go on="done(p)" to="f"/></parallel><final id="f"/></statechart>',P),
 config(P,[p,r1,a,r2,b]),send(P,finish),config(P,[p,r1,f1,r2,f2]),config(P,[f]),down(P),writeln('parallel regions and completion events: ok').
:- meta_predicate rejects(0).
rejects(Goal) :- catch(call(Goal),E,true),nonvar(E).
negative_tests :-
 rejects(statechart_spawn(_,[src_text('<bad/>')])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="a"><state id="a"/></statechart>'),'$name_reservation'(123)])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="a"><spawn/><state id="a"/></statechart>')])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="a"><state id="a"><onentry>shell(true)</onentry></state></statechart>')])),
 sandbox_policy:sandbox_prepare_goal(whitelist,actor,user,statechart_spawn(SafePid,[src_text('<statechart version="0.2" initial="a"><state id="a"/></statechart>'),trace(false),link(false)]),Safe),
 call(Safe),statechart_halt(SafePid,true,1),
 rejects(sandbox_policy:sandbox_prepare_goal(blacklist,isobase,user,statechart_spawn(_,[]),_)),
 rejects(sandbox_policy:sandbox_prepare_goal(blacklist,actor,actor_context,statechart_actor:statechart_spawn_in(off,actor,actor_context,_,[]),_)),
 sandbox_policy:sandbox_prepare_goal(blacklist,actor,actor_context,statechart_actor:statechart_spawn_in(blacklist,actor,actor_context,_,[]),_),
 writeln('source, unsupported features, sandbox and profile checks: ok').

deep_history :-
 chart('<statechart version="0.2" initial="p"><state id="p" initial="c"><history id="h" type="deep"><go to="c"/></history><state id="c" initial="a"><state id="a"><go on="next" to="b"/></state><state id="b"/></state><go on="pause" to="out"/></state><state id="out"><go on="resume" to="h"/></state></statechart>',P),
 config(P,[p,c,a]),send(P,next),config(P,[p,c,b]),send(P,pause),config(P,[out]),
 send(P,resume),config(P,[p,c,b]),statechart_halt(P,true,1),down(P),
 writeln('deep history: ok').
source_helpers :-
 Text='<statechart version="0.2" initial="a"><state id="a"><go on="go(To)" if="local_value(X)" to="f">To ! value(X)</go></state><final id="f"/></statechart>',
 self(Self),
 statechart_spawn(P,[src_text(Text),src_list([local_value(private)]),trace(false),monitor(true),link(false)]),
 send(P,go(Self)),receive({value(private) -> true},[timeout(2),on_timeout(fail)]),down(P),
 rejects(statechart_spawn(_,[src_text(Text),src_list([(local_value(_) :- shell(true))])])),
 writeln('private supplemental sources and admission guards: ok').

cleanup_tests(Before) :-
 chart('<statechart version="0.2" initial="s"><state id="s"><go after="60" to="f"/></state><final id="f"/></statechart>',P),
 config(P,[s]),statechart_halt(P,true,1),down(P),
 get_time(Now),Deadline is Now+1,wait_actors(Before,Deadline),
 self(Self),
 statechart_spawn(Blocked,[src_text('<statechart version="0.2" initial="s"><state id="s"><onentry>receive({never -> true})</onentry></state></statechart>'),monitor(true),link(false),trace(false)]),
 statechart_halt(Blocked,killed,0.02),
 receive({down(Blocked,Blocked,_) -> true},[timeout(1),on_timeout(fail)]),
 \+actors:monitor(Self,Blocked,_),
 writeln('timer cancellation, forced halt and monitor cleanup: ok').
wait_actors(Before,Deadline) :-
 actors(After),sort(Before,B),sort(After,A),
 (A==B -> true;get_time(Now),Now<Deadline,sleep(0.005),wait_actors(Before,Deadline)).

% Private mutable data, supplemental source ordering, and admission failures.
datamodel_tests :-
 self(Self),
 Text='<statechart version="0.2" initial="s"><datamodel>:- dynamic value/1. answer(X) :- value(X).</datamodel><state id="s"><go on="set(X)" >assertz(value(X))</go><go on="get(To)" if="answer(X)">To ! answer(X)</go></state></statechart>',
 statechart_spawn(A,[src_text(Text),trace(false),monitor(true),link(false)]),
 statechart_spawn(B,[src_text(Text),trace(false),monitor(true),link(false)]),
 send(A,set(a)),send(B,set(b)),send(A,get(Self)),send(B,get(Self)),
 receive({answer(a) -> true},[timeout(2),on_timeout(fail)]),
 receive({answer(b) -> true},[timeout(2),on_timeout(fail)]),
 statechart_halt(A,true,1),down(A),statechart_halt(B,true,1),down(B),
 Ordered='<statechart version="0.2" initial="s"><datamodel>value(xml). result(X) :- findall(V,value(V),X).</datamodel><state id="s"><go on="get(To)" if="result(X)" to="f">To ! values(X)</go></state><final id="f"/></statechart>',
 statechart_spawn(P,[src_text(Ordered),src_list([value(supplemental)]),trace(false),monitor(true),link(false)]),
 send(P,get(Self)),receive({values([supplemental,xml]) -> true},[timeout(2),on_timeout(fail)]),down(P),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><datamodel>:- shell(true).</datamodel><state id="s"/></statechart>')])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><datamodel>bad :- shell(true).</datamodel><state id="s"/></statechart>')])),
 rejects(statechart_spawn(_,[src_text('<statechart version="0.2" initial="s"><datamodel>broken(.</datamodel><state id="s"/></statechart>')])),
 sandbox_policy:sandbox_prepare_goal(whitelist,actor,user,statechart_spawn(W,[src_text(Text),trace(false),monitor(true),link(false)]),Safe),
 call(Safe),send(W,set(whitelisted)),send(W,get(Self)),
 receive({answer(whitelisted) -> true},[timeout(2),on_timeout(fail)]),statechart_halt(W,true,1),down(W),
 writeln('datamodel isolation, dynamic declarations, ordering and sandbox: ok').

datamodel_computations :-
 self(Self),
 GCD='<statechart version="0.2" initial="init"><datamodel>:- dynamic int/1. :- dynamic reply_to/1.</datamodel><state id="init"><go on="integers(To,List)" to="run">assertz(reply_to(To)),forall(member(X,List),asserta(int(X)))</go></state><state id="run"><go if="int(X),int(Y),X &gt; Y">Z is X-Y,retract(int(X)),assert(int(Z))</go><go if="int(X),reply_to(To)" to="stop">To ! gcd(X)</go></state><final id="stop"/></statechart>',
 chart(GCD,P),config(P,[init]),send(P,integers(Self,[25,10,15,30])),
 receive({gcd(5) -> true},[timeout(2),on_timeout(fail)]),config(P,[run]),config(P,[stop]),down(P),
 Closure='<statechart version="0.2" initial="s"><datamodel>p(a,b). p(b,c). p(c,d).</datamodel><state id="s"><go if="p(X,Y),p(Y,Z),\\+p(X,Z)">assert(p(X,Z))</go><go on="get(To)" if="findall(X-Y,p(X,Y),Pairs)" to="f">To ! closure(Pairs)</go></state><final id="f"/></statechart>',
 statechart_spawn(C,[src_text(Closure),trace(false),monitor(true),link(false)]),send(C,get(Self)),
 receive({closure(Pairs) -> true},[timeout(2),on_timeout(fail)]),
 sort(Pairs,[a-b,a-c,a-d,b-c,b-d,c-d]),down(C),
 DCG='<statechart version="0.2" initial="s"><datamodel>token --&gt; [a].</datamodel><state id="s"><go on="get(To)" if="phrase(token,[a])" to="f">To ! dcg_ok</go></state><final id="f"/></statechart>',
 statechart_spawn(D,[src_text(DCG),trace(false),monitor(true),link(false)]),send(D,get(Self)),
 receive({dcg_ok -> true},[timeout(2),on_timeout(fail)]),down(D),
 writeln('datamodel GCD, transitive closure and DCG expansion: ok').
datamodel_shared :-
 setup_call_cleanup(isolation:configure_shared_db(['fixtures/statecharts/shared.pl']),
  datamodel_shared_check,isolation:clear_shared_db).
datamodel_shared_check :-
 self(Self),
 Text='<statechart version="0.2" initial="s"><datamodel>local_label(chart). summary(N,L) :- shared_fact(N),local_label(L).</datamodel><state id="s"><go on="get(To)" if="summary(N,L)" to="f">To ! summary(N,L)</go></state><final id="f"/></statechart>',
 statechart_spawn(P,[src_text(Text),trace(false),monitor(true),link(false)]),send(P,get(Self)),
 receive({summary(node,chart) -> true},[timeout(2),on_timeout(fail)]),down(P),
 spawn((local_label(L),Self ! shared_label(L)),Probe,[monitor(true),link(false),src_list([])]),
 receive({shared_label(shared) -> true},[timeout(2),on_timeout(fail)]),down(Probe),
 writeln('datamodel shadows shared predicates without modifying shared data: ok').
