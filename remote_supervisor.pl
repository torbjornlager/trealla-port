% SPDX-License-Identifier: MIT
:- module(remote_supervisor,[prepare/7,run/2,guard_request/2,spawn_child/3,spawn_nested/3,spawn_server/7,checked_callback/8]).
:- use_module(actors).
:- use_module(supervisor_actor).
:- use_module(server_actor).
:- use_module(isolation).
:- use_module(sandbox_policy).
:- use_module(profile_policy, []).
:- catch(mutex_create(_, [alias('$remote_supervisor_start')]),
         error(permission_error(create,mutex,'$remote_supervisor_start'),_),true).

% Only this exact unqualified framework entry is intercepted at the spawn
% boundary. No private module is made generally callable by the sandbox.
prepare(Mode,Profile,Wire,Options0,Entry,Options,yes) :-
    nonvar(Wire),compound(Wire),functor(Wire,sup_init,2),
    arg(2,Wire,State),nonvar(State),compound(State),functor(State,sup,5),!,
    arg(1,Wire,WireSpecs),
    check_initial_state(State,Settings),
    profile_policy:profile_check_goal(Profile,supervisor_spawn([],_,Settings)),
    supervisor_actor:check_child_acyclic(WireSpecs),must_be(list,WireSpecs),
    maplist(wire_child,WireSpecs,Children),
    supervisor_actor:normalise_child_specs(user,Children,_),
    sandbox_policy:resolve_source_options(Options0,Resolved),
    sandbox_prepare_spawn(Mode,Profile,actor_context,
        supervisor_spawn([],_,Settings),Resolved,_,Options),
    prepare_children(Mode,Profile,Resolved,Children,Checked),
    append(Settings,['$remote_policy'(Mode,Profile,Resolved)],RuntimeSettings),
    Entry=remote_supervisor:run(Checked,RuntimeSettings).
prepare(_,_,_,_,_,_,no).

check_initial_state(State,Settings) :-
    must_be(nonvar,State),
    (compound(State),functor(State,sup,5) -> true
    ; throw(error(type_error(supervisor_initial_state,State),remote_supervisor:prepare/7))),
    State=sup(Strategy,Intensity,Period,Children,History),
    (Children==[],History==[] -> true
    ; throw(error(domain_error(fresh_supervisor_state,State),remote_supervisor:prepare/7))),
    Settings=[strategy(Strategy),intensity(Intensity),period(Period)],
    supervisor_actor:validate_supervisor_options(Settings).
wire_child(Spec,child(Id,[start(Start),restart(Restart),shutdown(Shutdown),type(Type)])) :-
    must_be(nonvar,Spec),
    (compound(Spec),functor(Spec,spec,5) -> true
    ; throw(error(type_error(supervisor_wire_child,Spec),remote_supervisor:prepare/7))),
    Spec=spec(Id,Start0,Restart,Shutdown,Type),local_start(Start0,Start).

% Sender module names are source context, not authority on the receiving node.
% Remove outer qualifications only. Qualifications inside goals are still
% checked by the normal sandbox walker.
source_goal(Goal0,Goal) :-
    must_be(callable,Goal0),
    (Goal0=M:Inner ->
        (var(M) -> true ; must_be(atom,M),check_source_module(M,Inner)),
        source_goal(Inner,Goal)
    ; Goal=Goal0).
check_source_module(supervisor_actor,Inner) :-
    nonvar(Inner),compound(Inner),functor(Inner,start_sub_supervisor,2),!.
check_source_module(Module,Goal) :-
    (sandbox_policy:permitted_qualified_module(Module),sandbox_policy:known_actor_goal(Goal) -> true
    ; runtime_module(Module) ->
        throw(error(permission_error(call,sandboxed,Module:Goal),
                    context(remote_supervisor:prepare/7,module_qualification)))
    ; true).
runtime_module(Module) :-
    memberchk(Module,[system,actors,actor_api,isolation,sandbox_policy,remote_supervisor,
        supervisor_actor,server_actor,node,web_prolog,distribution,rpc,toplevel_actors,
        parallel,profile_policy,resource_policy,source_policy,governance_policy,observability,ip_policy]).
local_start(Start0,Start) :-
    source_goal(Start0,Plain),
    (Plain=server(CB,Opts) -> source_goal(CB,Local),Start=server(Local,Opts)
    ; Plain=start_sub_supervisor(Specs0,Opts) ->
        supervisor_actor:child_specs_module(Specs0,user,_,Specs),
        must_be(list,Specs),maplist(local_child,Specs,LocalSpecs),
        Start=start_sub_supervisor(LocalSpecs,Opts)
    ; Start=Plain).
local_child(Child,child(Id,Options)) :-
    must_be(nonvar,Child),
    (compound(Child),functor(Child,child,2) -> Child=child(Id,Raw)
    ; throw(error(type_error(supervisor_child_spec,Child),remote_supervisor:prepare/7))),
    must_be(list,Raw),maplist(local_option,Raw,Options).
local_option(Option,Checked) :-
    (nonvar(Option),Option=start(S) -> local_start(S,T),Checked=start(T) ; Checked=Option).

prepare_children(_,_,_,[],[]).
prepare_children(M,P,Sources,[child(Id,Options)|Children],[child(Id,Checked)|Rest]) :-
    maplist(prepare_option(M,P,Sources),Options,Checked),
    prepare_children(M,P,Sources,Children,Rest).
prepare_option(M,P,Sources,start(Start),start(Checked)) :- !,
    prepare_start(M,P,Sources,Start,Checked).
prepare_option(_,_,_,Option,Option).
prepare_start(M,P,Sources,server(CB,Options),server(Guard,ServerOptions)) :- !,
    must_be(list,Options),exclude(supervisor_actor:child_initial_state_option,Options,ValidateOptions),
    actors:validate_spawn_wrapper_options(ValidateOptions,public,remote_supervisor:prepare/7,[name-atom]),
    exclude(server_private,Options,SpawnOptions),append(Sources,SpawnOptions,AllSources),
    callback_goal(CB,Head,PI),profile_policy:profile_check_goal(P,Head),
    sandbox_prepare_spawn(M,P,actor_context,Head,AllSources,_,Prepared),
    include(server_private,Options,Private),append(Private,Prepared,ServerOptions),
    Guard=remote_supervisor:checked_callback(M,P,[PI],CB).
prepare_start(M,P,Sources,start_sub_supervisor(Children,Options),
                            remote_supervisor:run_nested(Checked,RuntimeSettings)) :- !,
    actors:validate_spawn_wrapper_options(Options,public,remote_supervisor:prepare/7,
        [name-atom,strategy-oneof(supervisor_strategy,[one_for_one,one_for_all,rest_for_one]),
         intensity-nonnegative_integer,period-positive_number(supervisor_period)]),
    exclude(supervisor_private,Options,SpawnOptions),append(Sources,SpawnOptions,AllSources),
    sandbox_prepare_spawn(M,P,actor_context,supervisor_spawn([],_),AllSources,_,_),
    prepare_children(M,P,AllSources,Children,Checked),
    option(strategy(Strategy),Options,one_for_one),option(intensity(Intensity),Options,1),option(period(Period),Options,5),
    RuntimeSettings=[strategy(Strategy),intensity(Intensity),period(Period),'$remote_policy'(M,P,AllSources)].
prepare_start(M,P,Sources,Start,remote_supervisor:invoke_child(Checked,PreparedSources)) :-
    profile_policy:profile_check_goal(P,Start),
    sandbox_prepare_spawn(M,P,actor_context,Start,Sources,Checked,Loaded),
    include(source_option,Loaded,PreparedSources).
server_private(Option) :- nonvar(Option),
    (Option=name(_) ; Option=initial_state(_)).
supervisor_private(Option) :- nonvar(Option),
    (Option=name(_) ; Option=strategy(_) ; Option=intensity(_) ; Option=period(_)).
source_option(src_text(_)).
source_option(src_list(_)).
callback_goal(CB,Head,Name/Arity) :-
    CB=..[Name|Args],append(Args,[_,_,_,_],Full),Head=..[Name|Full],length(Full,Arity).

run(Children,Settings) :-
    option('$remote_policy'(Mode,Profile,Sources),Settings),
    nb_setval('$remote_supervisor_policy',policy(Mode,Profile,Sources)),
    self(Self),actor_module(Self,Module),
    supervisor_actor:normalise_child_specs(Module,Children,Specs),
    option(strategy(Strategy),Settings),option(intensity(Intensity),Settings),option(period(Period),Settings),
    supervisor_actor:sup_init(Specs,sup(Strategy,Intensity,Period,[],[])).
checked_callback(M,P,App,Closure,Request,State,Reply,Next) :-
    self(Self),actor_module(Self,Module),
    sandbox_policy:sandbox_call(M,P,Module,App,Closure,Request,State,Reply,Next).

% Dynamic additions must cross the same boundary as initial children. This
% hook is active only in actors created by this receiver adapter.
guard_request(start_child(Spec),start_child(Checked)) :-
    nb_current('$remote_supervisor_policy',policy(M,P,Sources)),!,
    wire_child(Spec,Child),supervisor_actor:normalise_child_specs(user,[Child],_),
    prepare_children(M,P,Sources,[Child],Children),
    actors:self(Self),isolation:actor_module(Self,Module),
    supervisor_actor:normalise_child_specs(Module,Children,[Checked]).
guard_request(Request,Request).

% These three entries are called only by the supervisor's trusted-start
% dispatcher. Sources were validated/rewritten before the actor was allocated.
spawn_child(Goal,Sources,Pid) :-
    with_mutex('$remote_supervisor_start',remote_supervisor:spawn_child_locked(Goal,Sources,Pid)).
spawn_child_locked(Goal,Sources,Pid) :-
    copy_term(Goal-Sources,CleanGoal-CleanSources),
    spawn_runtime(remote_supervisor:run_child(CleanGoal),Pid,
        ['$entry_context'(caller),link(true),src_list([])|CleanSources]).
run_child(Goal) :-
    self(Self),actor_module(Self,Module),isolation:run_actor_query(Module,Goal).
spawn_nested(Children,Settings,Pid) :-
    with_mutex('$remote_supervisor_start',remote_supervisor:spawn_nested_locked(Children,Settings,Pid)).
spawn_nested_locked(Children,Settings,Pid) :-
    copy_term(Children-Settings,CleanChildren-CleanSettings),
    spawn_runtime(remote_supervisor:run(CleanChildren,CleanSettings),Pid,
        ['$entry_context'(caller),link(true)]).
spawn_server(M,P,App,Closure,Name,Options,Pid) :-
    with_mutex('$remote_supervisor_start',remote_supervisor:spawn_server_locked(M,P,App,Closure,Name,Options,Pid)).
spawn_server_locked(M,P,App,Closure,Name,Options,Pid) :-
    option(initial_state(State),Options,[]),exclude(server_private,Options,Plain),
    copy_term(Closure-State-Plain,CleanClosure-CleanState-CleanOptions),
    with_spawn_name([name(Name)],Pid,
        remote_supervisor:create_server(M,P,App,CleanClosure,CleanState,Pid,CleanOptions)).
create_server(M,P,App,Closure,State,Pid,Options,NameOptions) :-
    append(NameOptions,['$entry_context'(caller),link(true)|Options],SpawnOptions),
    spawn_runtime(server_actor:server_loop(remote_supervisor:checked_callback(M,P,App,Closure),State),Pid,SpawnOptions).
