% SPDX-License-Identifier: MIT
:- module(statechart_actor,[statechart_spawn/2,statechart_halt/2,statechart_halt/3,raise/1,in/1]).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(toplevel_actors,[]).
:- use_module(server_actor,[]).
:- use_module(supervisor_actor,[]).
:- use_module(remote_supervisor,[]).
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
 statechart_model:statechart_spawn_source(Options,Source,SpawnOptions0),
 (memberchk(trace(Trace),Options)->true;Trace=true),
 count_trace_options(Options,Count),
 (Count=<1 -> true;throw(error(permission_error(duplicate,statechart_option,trace),statechart_spawn/2))),
 exclude(local_option,SpawnOptions0,SpawnOptions),
 (memberchk(node(Node),Options),Node\==localhost ->
   with_spawn_name(Options,Pid,statechart_actor:create_remote_chart(Mode,Profile,Caller,Source,Trace,Node,SpawnOptions,Pid))
 ; with_spawn_name(Options,Pid,statechart_actor:create_chart(Mode,Profile,Caller,Source,Trace,SpawnOptions,Pid))),!.
local_option(name(_)).
local_option(node(_)).
count_trace_options([],0).
count_trace_options([O|Os],N) :- count_trace_options(Os,N0),(O=trace(_)->N is N0+1;N=N0).

create_chart(Mode,Profile,Caller,Source,Trace,Options0,Pid,NameOptions) :-
 prepare_chart(Mode,Profile,Caller,Source,Trace,Options0,Entry,Options),
 append(NameOptions,['$entry_context'(caller)|Options],Effective),
 spawn_runtime(Entry,Pid,Effective).

% Both local construction and the remote receiver prepare one interpreter
% entry. The actor created by the transport is the chart, not a proxy parent.
prepare_chart(Mode,Profile,Caller,Source,Trace,Options0,Entry,Options) :-
 must_be(boolean,Trace),
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
 copy_term(ChartModel-Prepared,Model-Loaded),
 Options=[src_list([])|Loaded],
 Entry=statechart_actor:run_chart(Model,Mode,Profile,AppPIs,Trace).

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
unsupported(to_be_invoked(_,Type,_),child_invocation(Type)) :-
 \+ memberchk(Type,[actor,toplevel,server,supervisor,statechart]).
check_invocation_options(Type,Options0,Options) :-
 % Retain remote destinations; ordinary validators check every occurrence.
 (memberchk(node(Node),Options0),Node\==localhost -> Options=Options0
 ; exclude(child_node_option,Options0,Options)),
 validate_child_options(Type,Options).
child_node_option(node(_)).
validate_child_options(actor,Options0) :-
 select(goal(_),Options0,Options),actors:validate_spawn_options(Options,public).
validate_child_options(toplevel,Options) :-
 toplevel_actors:validate_toplevel_spawn_options(Options,public).
validate_child_options(statechart,Options) :-
 actors:validate_spawn_wrapper_options(Options,public,statechart_spawn/2,[name-atom,trace-boolean]).

validate_child_options(server,Options0) :-
 select(callback(Callback),Options0,Options1),must_be(callable,Callback),
 select(state(_),Options1,Options),
 actors:validate_spawn_wrapper_options(Options,public,statechart_spawn/2,[name-atom]).
validate_child_options(supervisor,Options0) :-
 select(children(Children),Options0,Options),
 supervisor_actor:normalise_child_specs(user,Children,_),
 local_supervisor_children(Children),
 supervisor_actor:validate_supervisor_options(Options).
local_supervisor_children([]).
local_supervisor_children([child(_,Options)|Rest]) :-
 forall(member(start(Start),Options),local_supervisor_start(Start)),
 local_supervisor_children(Rest).
local_supervisor_start(Start0) :-
 remote_supervisor:local_start(Start0,Start),local_supervisor_start_(Start).
local_supervisor_start_(server(_,Options)) :- !,
 forall(member(node(Node),Options),local_child_node(Node)).
local_supervisor_start_(start_sub_supervisor(Children,Options)) :- !,
 forall(member(node(Node),Options),local_child_node(Node)),
 local_supervisor_children(Children).
local_supervisor_start_(_).
local_child_node(Node) :-
 (Node==localhost -> true;
 throw(error(permission_error(spawn,remote_statechart_child,Node),statechart_spawn/2))).

% Source predicates are materialized at invocation, after the parent datamodel
% has been installed. Child code keeps the parent's policy, not this module's.
start_invoked_child(Type,Options0,Pid) :-
 chart_policy(Mode,Profile,_),self(Self),isolation:actor_module(Self,Module),
 check_invocation_options(Type,Options0,Options),
 (memberchk(node(Node),Options),Node\==localhost ->
   start_remote_child(Type,Mode,Profile,Module,Node,Options,Pid)
 ; start_invoked_child(Type,Mode,Profile,Module,Options,Pid)).
start_invoked_child(actor,Mode,Profile,Module,Options0,Pid) :-
 select(goal(Goal),Options0,Options),
 sandbox_policy:sandbox_spawn(Mode,Profile,Module,[],Goal,Pid,Options).
start_invoked_child(toplevel,Mode,Profile,Module,Options0,Pid) :-
 isolation:rewrite_source_options(Options0,Module,Materialized),
 sandbox_policy:sandbox_prepare_options(Mode,Profile,Module,Materialized,Options),
 toplevel_actors:toplevel_spawn(Pid,Module:Options).
start_invoked_child(statechart,Mode,Profile,Module,Options,Pid) :-
 statechart_spawn_in(Mode,Profile,Module,Pid,Options).
% Reuse the receiver's policy-aware behaviour preparation locally. It keeps
% child source and runtime callback guards together, without installing inline
% code in the parent chart or making private framework entries public.
start_invoked_child(server,M,P,Module,Options0,Pid) :-
 select(callback(Callback0),Options0,Options1),select(state(State),Options1,Options),
 remote_supervisor:source_goal(Callback0,Callback),
 remote_supervisor:callback_goal(Callback,_,PI),
 behaviour_sources(Module,[PI],Options,Sources),
 remote_supervisor:prepare_start(M,P,Sources,server(Callback,[initial_state(State)]),
                                server(Guard,Prepared0)),
 exclude(initial_state_option,Prepared0,Prepared),
 with_spawn_name(Options,Pid,statechart_actor:create_server_child(Guard,State,Prepared,Pid)).
start_invoked_child(supervisor,M,P,Module,Options0,Pid) :-
 select(children(Children),Options0,Options),
 supervisor_actor:child_specs_pis(Children,PIs),
 behaviour_sources(Module,PIs,Options,Sources),
 maplist(remote_supervisor:local_child,Children,LocalChildren),
 remote_supervisor:prepare_children(M,P,Sources,LocalChildren,Checked),
 option(strategy(Strategy),Options,one_for_one),
 option(intensity(Intensity),Options,1),option(period(Period),Options,5),
 Settings=[strategy(Strategy),intensity(Intensity),period(Period),'$remote_policy'(M,P,Sources)],
 sandbox_policy:sandbox_prepare_options(M,P,Module,Sources,Prepared),
 with_spawn_name(Options,Pid,statechart_actor:create_supervisor_child(Checked,Settings,Prepared,Pid)).
initial_state_option(initial_state(_)).
behaviour_private_option(name(_)).
behaviour_private_option(strategy(_)).
behaviour_private_option(intensity(_)).
behaviour_private_option(period(_)).
behaviour_sources(Module,PIs0,Options,Sources) :-
 supervisor_actor:clean_predicate_indicators(PIs0,PIs),
 include(supervisor_actor:local_predicate(Module),PIs,Local),sort(Local,Copy),
 exclude(behaviour_private_option,Options,Plain),
 isolation:rewrite_source_options([src_predicates(Copy)|Plain],Module,Sources).
create_server_child(Guard,State,Options,Pid,NameOptions) :-
 append(NameOptions,['$entry_context'(caller)|Options],Effective),
 spawn_runtime(server_actor:server_loop(Guard,State),Pid,Effective).
create_supervisor_child(Children,Settings,Options,Pid,NameOptions) :-
 append(NameOptions,['$entry_context'(caller)|Options],Effective),
 spawn_runtime(remote_supervisor:run(Children,Settings),Pid,Effective).

% Validate locally but send portable source/entries: each peer applies its own
% sandbox and profile instead of receiving sender-specific guarded closures.
start_remote_child(actor,M,P,Module,_,Options0,Pid) :-
 select(goal(Goal),Options0,Options),
 isolation:rewrite_source_options(Options,Module,Materialized),
 source_policy:resolve_source_options(Materialized,Resolved),
 sandbox_policy:sandbox_prepare_spawn(M,P,Module,Goal,Resolved,_,_),
 spawn(Goal,Pid,Resolved).
start_remote_child(toplevel,M,P,Module,URL,Options0,Pid) :-
 isolation:rewrite_source_options(Options0,Module,Materialized),
 source_policy:resolve_source_options(Materialized,Resolved),
 sandbox_policy:sandbox_prepare_options(M,P,Module,Resolved,_),
 with_spawn_name(Options0,Pid,statechart_actor:create_remote_toplevel(URL,Module,Resolved,Pid)).
start_remote_child(server,M,P,Module,_,Options0,Pid) :-
 select(callback(Callback0),Options0,Options1),select(state(State),Options1,Options),
 remote_supervisor:source_goal(Callback0,Callback),
 remote_supervisor:callback_goal(Callback,_,PI),
 behaviour_sources(Module,[PI],Options,Sources0),
 source_policy:resolve_source_options(Sources0,Sources),
 remote_supervisor:prepare_start(M,P,Sources,server(Callback,[initial_state(State)]),_),
 with_spawn_name(Options,Pid,statechart_actor:create_remote_behaviour(server_loop(Callback,State),Sources,Pid)).
start_remote_child(supervisor,M,P,Module,_,Options0,Pid) :-
 select(children(Children0),Options0,Options),
 supervisor_actor:child_specs_pis(Children0,PIs),
 behaviour_sources(Module,PIs,Options,Sources0),
 source_policy:resolve_source_options(Sources0,Sources),
 maplist(remote_supervisor:local_child,Children0,Children),
 remote_supervisor:prepare_children(M,P,Sources,Children,_),
 supervisor_actor:normalise_child_specs(user,Children,Specs),
 option(strategy(Strategy),Options,one_for_one),
 option(intensity(Intensity),Options,1),option(period(Period),Options,5),
 with_spawn_name(Options,Pid,statechart_actor:create_remote_behaviour(sup_init(Specs,sup(Strategy,Intensity,Period,[],[])),Sources,Pid)).
start_remote_child(statechart,M,P,Module,_,Options,Pid) :-
 statechart_spawn_in(M,P,Module,Pid,Options).

create_remote_chart(M,P,Caller,Source,Trace,Node,Options0,Pid,NameOptions) :-
 chart_caller(Caller,Module),
 isolation:rewrite_source_options(Options0,Module,Materialized),
 source_policy:resolve_source_options(Materialized,Sources),
 sandbox_policy:sandbox_prepare_options(M,P,Module,Sources,_),
 % URI XML belongs to the destination's fetch policy. Text can also be
 % checked locally without changing the portable payload sent to the peer.
 (Source=statechart_actor:interpret_text(_) ->
   prepare_chart(M,P,Module,Source,Trace,Sources,_,_);true),
 traced_source_entry(Source,Trace,Entry),
 append(NameOptions,[node(Node)|Sources],Effective),
 spawn_runtime(Entry,Pid,Effective).
traced_source_entry(statechart_actor:interpret(URI),Trace,interpret_trace(Trace,URI)).
traced_source_entry(statechart_actor:interpret_text(Text),Trace,interpret_text_trace(Trace,Text)).

create_remote_behaviour(Entry,Options,Pid,NameOptions) :-
 append(NameOptions,Options,Effective),spawn_runtime(Entry,Pid,Effective).
create_remote_toplevel(URL,Module,Options,Pid,NameOptions) :-
 distribution:node_url_atom(URL,Atom),distribution:transparent_node(Atom,Node),
 append(NameOptions,Options,Effective),
 distribution:remote_toplevel_spawn_mode(Node,Pid,Module:Effective,transparent).

check_model_term(_,_,_,_,to_be_invoked(_,Type,Options)) :- !,
 check_invocation_options(Type,Options,_).
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
