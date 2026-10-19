% SPDX-License-Identifier: MIT
:- module(statechart_actor,[statechart_spawn/2,statechart_halt/2,statechart_halt/3,raise/1,in/1]).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(statechart_model,[]).
:- use_module(statechart_exec,[]).
:- use_module(statechart_runtime,[raise/1,in/1]).
:- use_module(sandbox_policy,[]).
:- use_module(source_policy,[]).
:- use_module(resource_policy,[]).
:- use_module(profile_policy,[]).
:- meta_predicate statechart_spawn(-,:).
:- thread_local((state/2,to_be_invoked/3,parallel/2,history/3,final/2,initial/1,
 transition/5,after_transition/6,defer/3,onexit/2,onentry/2,n/2,
 running/0,event/1,internal_queue/1,postponed_queue/1,macrostep_start/1,
 historyValue/2,configuration/1,states_to_invoke/1,invoked/2,after_timer/3,num/1,
 chart_policy/3,trace_disabled/0,trace_hook/1)).

statechart_spawn(Pid,Options0) :-
 strip_module(Options0,Caller,Options),
 statechart_spawn_in(blacklist,actor,Caller,Pid,Options),!.
statechart_spawn_in(Mode,Profile,Caller,Pid,Options) :-
 profile_policy:profile_check_goal(Profile,statechart_spawn(Pid,Options)),
 actors:validate_spawn_wrapper_options(Options,public,statechart_spawn/2,[name-atom,trace-boolean]),
 (memberchk(node(Node),Options),Node\==localhost ->
   throw(error(permission_error(spawn,remote_statechart,Node),statechart_spawn/2));true),
 statechart_model:statechart_spawn_source(Options,Source,SpawnOptions0),
 (memberchk(trace(Trace),Options)->true;Trace=true),
 count_trace_options(Options,Count),
 (Count=<1 -> true;throw(error(permission_error(duplicate,statechart_option,trace),statechart_spawn/2))),
 exclude(local_option,SpawnOptions0,SpawnOptions),
 with_spawn_name(Options,Pid,statechart_actor:create_chart(Mode,Profile,Caller,Source,Trace,SpawnOptions,Pid)),!.
local_option(name(_)).
local_option(node(_)).
count_trace_options([],0).
count_trace_options([O|Os],N) :- count_trace_options(Os,N0),(O=trace(_)->N is N0+1;N=N0).

create_chart(Mode,Profile,Caller,Source,Trace,Options0,Pid,NameOptions) :-
 chart_text(Source,Text),
 resource_policy:check_source_options_size([src_text(Text)]),
 statechart_model:statechart_compile_text(Text,Model0),
 validate_features(Model0),
 split_datamodel(Model0,ChartModel,Datamodel),
 chart_caller(Caller,SourceModule),
 isolation:rewrite_source_options(Options0,SourceModule,Materialized),
 source_policy:resolve_source_options(Materialized,Resolved),
 append(Resolved,[src_list(Datamodel)],ChartSources),
 resource_policy:check_source_options_size(ChartSources),
 prepare_chart_sources(Mode,Profile,ChartSources,Prepared,AppPIs),
 maplist(check_model_term(Mode,Profile,SourceModule,AppPIs),ChartModel),
 copy_term(ChartModel-Prepared,Model-Options),
 append(NameOptions,['$entry_context'(caller),src_list([])|Options],Effective),
 spawn_runtime(statechart_actor:run_chart(Model,Mode,Profile,AppPIs,Trace),Pid,Effective).

chart_caller(Caller,Module) :-
 (nonvar(Caller),Caller\==actor_context -> Module=Caller
 ; self(Self),isolation:actor_module(Self,Here) -> Module=Here
 ; var(Caller) -> Module=user
 ; throw(error(existence_error(actor_context,source_module),statechart_spawn/2))).

chart_text(statechart_actor:interpret_text(Text),Text).
chart_text(statechart_actor:interpret(URI0),Text) :-
 resolve_chart_uri(URI0,URI),source_policy:fetch_source_uri(URI,Text).
resolve_chart_uri(URI0,URI) :-
 source_policy:source_text_atom(URI0,Atom),
 (sub_atom(Atom,0,1,_,'/') ->
   (catch(web_prolog:current_node_url(Base),_,fail) ->
     source_policy:resolve_redirect_uri(Base,Atom,URI)
   ; throw(error(existence_error(node,public_url),statechart_spawn/2)))
 ; URI=Atom).
validate_features(Model) :-
 (member(Term,Model),unsupported(Term,Feature) ->
  throw(error(domain_error(trealla_statechart_feature,Feature),statechart_spawn/2));true).
% Datamodel code follows supplemental sources, as in the SWI interpreter.
% The ordinary actor loader appends local clauses and shadows shared predicates.
split_datamodel([],[],[]).
split_datamodel([datamodel(Text)|Terms],Model,Code) :- !,
 sandbox_policy:source_text_terms(Text,Here),
 split_datamodel(Terms,Model,Rest),append(Here,Rest,Code).
split_datamodel([Term|Terms],[Term|Model],Code) :-
 split_datamodel(Terms,Model,Code).
prepare_chart_sources(off,_,Sources,Sources,[]) :- !.
prepare_chart_sources(Mode,Profile,Sources,Prepared,AppPIs) :-
 sandbox_policy:materialize_source_options(Sources,Plain,Terms0),
 sandbox_policy:normalize_source_terms(Terms0,Terms),
 sandbox_policy:source_predicate_indicators(Terms,Defined),
 % Empty dynamic predicates are also part of the chart's application database.
 findall(PI,(member((:- dynamic(Decl)),Terms),
             sandbox_policy:check_mutable_pi(Decl),declared_pi(Decl,PI)),Declared),
 append(Defined,Declared,All),sort(All,AppPIs),
 sandbox_policy:validate_rewrite_source_terms(Mode,Profile,actor_context,AppPIs,Terms,Checked),
 Prepared=[src_list(Checked)|Plain].
declared_pi((A,B),PI) :- !,(declared_pi(A,PI);declared_pi(B,PI)).
declared_pi(PI,PI).
unsupported(to_be_invoked(_,_,_),child_invocation).
check_model_term(M,P,C,A,transition(_,_,Guard,_,Actions)) :- !,
 check_with_policy(M,P,C,A,Guard),maplist(check_action(M,P,C,A),Actions).
check_model_term(M,P,C,A,after_transition(_,_,_,Guard,_,Actions)) :- !,
 check_with_policy(M,P,C,A,Guard),maplist(check_action(M,P,C,A),Actions).
check_model_term(M,P,C,A,defer(_,_,Guard)) :- !,check_with_policy(M,P,C,A,Guard).
check_model_term(M,P,C,A,onentry(_,Actions)) :- !,maplist(check_action(M,P,C,A),Actions).
check_model_term(M,P,C,A,onexit(_,Actions)) :- !,maplist(check_action(M,P,C,A),Actions).
check_model_term(_,_,_,_,_).
check_action(M,P,C,A,script(Goal)) :- check_with_policy(M,P,C,A,Goal).
check_with_policy(M,P,C,A,G) :-
 profile_policy:profile_check_goal(P,G),
 (M==off -> true;sandbox_policy:sandbox_check_goal_(M,P,C,A,G)).

run_chart(Model,Mode,Profile,AppPIs,Trace) :-
 setup_call_cleanup(
   (statechart_runtime:clean,
    assertz(chart_policy(Mode,Profile,AppPIs)),
    (Trace==false -> assertz(trace_disabled);true),
    maplist(install_term,Model)),
   statechart_exec:interpret_parsed(_),
   (statechart_runtime:clean,retractall(chart_policy(_,_,_)),retractall(trace_disabled),retractall(trace_hook(_)))).
install_term(Term) :- assertz(Term).
check_goal(Goal) :-
 chart_policy(M,P,A),self(Self),isolation:actor_module(Self,Module),
 check_with_policy(M,P,Module,A,Goal).
call_goal(Goal) :-
 chart_policy(M,P,A),self(Self),isolation:actor_module(Self,Module),
 (M==off -> isolation:run_actor_query(Module,Goal)
 ; sandbox_policy:sandbox_call(M,P,Module,A,Goal)).
emit_trace(Event) :-
 (trace_disabled -> true
 ; (trace_hook(Hook) -> call(Hook,Event);true),terminal_output(statechart_trace(Event))).

statechart_halt(To,Reply) :- halt_wait(To,Reply,infinite),!.
statechart_halt(To,Reply,Timeout) :-
 must_be(number,Timeout),(Timeout>=0 -> true;throw(error(domain_error(not_less_than_zero,Timeout),statechart_halt/3))),
 halt_wait(To,Reply,Timeout),!.
halt_wait(To,Reply,Timeout) :-
 self(Self),
 setup_call_cleanup(monitor(To,Ref),
  (send(To,'$stop'(Self)),
   halt_options(Timeout,To,Ref,Reply,Options),
   receive({reply(Value) -> Reply=Value; down(_,Ref,_) -> Reply=killed},Options)),
  demonitor(Ref,[flush])).
halt_options(infinite,_,_,_,[]) :- !.
halt_options(T,To,Ref,Reply,[timeout(T),on_timeout(statechart_actor:force_halt(To,Ref,Reply))]).
force_halt(To,Ref,Reply) :- exit(To,kill),receive({down(_,Ref,_) -> Reply=killed}).
