% SPDX-License-Identifier: MIT

:- module(supervisor_actor,
       [ supervisor_spawn/2,
         supervisor_spawn/3,
         supervisor_spawn_child/3,
         supervisor_terminate_child/3,
         supervisor_delete_child/3,
         supervisor_respawn_child/3,
         supervisor_which_children/2,
         supervisor_count_children/2,
         supervisor_halt/1,
         supervisor_stop/1
       ]).

/** <module> OTP-style actor supervisor behaviour

Supervisors start, monitor, stop, and restart child actors. Supported restart
strategies are one_for_one, one_for_all, and rest_for_one. Child starts may be
ordinary goals, generic server callbacks, or nested supervisors.
*/

:- use_module(actors).
:- use_module(server_actor).
:- use_module(supervisor_startup).
:- use_module(isolation, [actor_module/2,rewrite_source_options/3]).

:- meta_predicate(supervisor_spawn(:, -)).
:- meta_predicate(supervisor_spawn(:, -, +)).
:- meta_predicate(supervisor_spawn_child(+, :, -)).


                 /*******************************
                 *      CHILD SPECIFICATIONS     *
                 *******************************/

% Validate without copying: goal arguments and server state may share variables.
normalise_child_specs(Caller, ChildSpecs, Specs) :-
    check_child_acyclic(ChildSpecs),
    must_be(list, ChildSpecs),
    maplist(normalise_child_spec(Caller), ChildSpecs, Specs),
    unique_child_ids(Specs, []).

unique_child_ids([], _).
unique_child_ids([spec(Id,_,_,_,_)|Specs], Seen) :-
    ( memberchk(Id, Seen)
    -> throw(error(permission_error(duplicate,supervisor_child_id,Id),supervisor))
    ; unique_child_ids(Specs, [Id|Seen]) ).

check_child_acyclic(Term) :-
    ( acyclic_term(Term) -> true
    ; throw(error(representation_error(cyclic_term),supervisor)) ).

normalise_child_spec(Caller, ChildSpec,
                     spec(Id, Start, Restart, Shutdown, Type)) :-
    must_be(nonvar, ChildSpec),
    check_child_acyclic(ChildSpec),
    ( compound(ChildSpec), functor(ChildSpec,child,2)
    -> arg(1,ChildSpec,Id), arg(2,ChildSpec,Options)
    ; throw(error(type_error(supervisor_child_spec,ChildSpec),supervisor)) ),
    must_be(ground, Id),
    must_be(list, Options),
    maplist(validate_child_option(Caller,Id), Options),
    ( option(start(Start0), Options)
    -> qualify_start_term(Caller, Start0, Start)
    ; throw(error(missing_start_option(Id), supervisor))
    ),
    option(restart(Restart), Options, permanent),
    option(type(Type), Options, worker),
    default_shutdown(Type, DefaultShutdown),
    option(shutdown(Shutdown), Options, DefaultShutdown).

validate_child_option(Caller, Id, Option) :-
    must_be(nonvar, Option),
    ( compound(Option), functor(Option,Name,1),
      memberchk(Name,[start,restart,type,shutdown])
    -> arg(1,Option,Value), validate_child_value(Name,Caller,Id,Value)
    ; throw(error(domain_error(supervisor_child_option,Option),supervisor)) ).

validate_child_value(start, Caller, Id, Start) :-
    validate_child_callable(Start),
    ( Start = server(Callback, Options)
    -> must_be(atom,Id), validate_child_callable(Callback),
       must_be(list,Options),
       exclude(child_initial_state_option,Options,SpawnOptions),
       actors:validate_spawn_wrapper_options(SpawnOptions,runtime,
           supervisor_actor:supervisor_spawn/3,[name-atom])
    ; Start = start_sub_supervisor(Specs, Options)
    -> validate_nested_supervisor(Caller,Specs,Options)
    ; Start = supervisor_actor:start_sub_supervisor(Specs, Options)
    -> validate_nested_supervisor(Caller,Specs,Options)
    ; true ).
validate_child_value(restart, _, _, Policy) :-
    must_be(nonvar,Policy),
    ( memberchk(Policy,[permanent,transient,temporary]) -> true
    ; throw(error(domain_error(supervisor_child_restart,Policy),supervisor)) ).
validate_child_value(type, _, _, Type) :-
    must_be(nonvar,Type),
    ( memberchk(Type,[worker,supervisor]) -> true
    ; throw(error(domain_error(supervisor_child_type,Type),supervisor)) ).
validate_child_value(shutdown, _, _, Shutdown) :-
    must_be(nonvar,Shutdown),
    ( Shutdown == brutal_kill -> true
    ; Shutdown == infinity -> true
    ; number(Shutdown), Shutdown >= 0 -> true
    ; throw(error(domain_error(supervisor_child_shutdown,Shutdown),supervisor)) ).

child_initial_state_option(Option) :-
    nonvar(Option), compound(Option), functor(Option,initial_state,1).

validate_child_callable(Goal) :-
    must_be(callable,Goal),
    ( Goal = Module:Inner
    -> must_be(atom,Module), validate_child_callable(Inner)
    ; true ).

validate_nested_supervisor(Caller, Specs0, Options) :-
    validate_supervisor_options(Options),
    child_specs_module(Specs0,Caller,Module,Specs),
    normalise_child_specs(Module,Specs,_).

child_specs_module(Specs0, Default, Module, Specs) :-
    ( nonvar(Specs0), Specs0 = Qualified:Inner
    -> must_be(atom,Qualified), child_specs_module(Inner,Qualified,Module,Specs)
    ; Module = Default, Specs = Specs0 ).

child_spec_error(Goal, Context) :-
    catch(call(Goal),error(Formal,_),
          throw(error(Formal,context(Context,'invalid child specification')))).

default_shutdown(supervisor, infinity).
default_shutdown(worker, 5).

qualify_start_term(Caller, server(Callback0, Options),
                   server(Callback, Options)) :-
    !,
    qualify_goal_term(Caller, Callback0, Callback).
qualify_start_term(Caller, start_sub_supervisor(Specs, Options),
                   start_sub_supervisor(Caller:Specs, Options)) :- !.
qualify_start_term(Caller, Goal0, Goal) :-
    qualify_goal_term(Caller, Goal0, Goal).

qualify_goal_term(_, Module:Goal, Module:Goal) :- !.
qualify_goal_term(Caller, Goal, Caller:Goal).


                 /*******************************
                 *          PUBLIC API           *
                 *******************************/

supervisor_spawn(ChildSpecs, Pid) :-
    supervisor_spawn(ChildSpecs, Pid, []).

validate_supervisor_options(Options) :-
    actors:validate_spawn_wrapper_options(Options,runtime,
        supervisor_actor:supervisor_spawn/3,
        [name-atom,strategy-oneof(supervisor_strategy,[one_for_one,one_for_all,rest_for_one]),
         intensity-nonnegative_integer,period-positive_number(supervisor_period)]).

supervisor_spawn(ChildSpecs0, Pid, Options) :-
    validate_supervisor_options(Options),
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    supervisor_source_module(Caller, SourceModule),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxRestarts), Options, 1),
    option(period(Period), Options, 5),
    child_spec_error(normalise_child_specs(SourceModule,ChildSpecs,Specs),
                     supervisor_actor:supervisor_spawn/3),
    with_spawn_name(Options,Pid,
        supervisor_actor:create_named_supervisor(SourceModule,ChildSpecs,Specs,
            Strategy,MaxRestarts,Period,Pid,Options)).

create_named_supervisor(SourceModule,ChildSpecs,Specs,Strategy,MaxRestarts,Period,
                        Pid,Options,NameOptions) :-
    child_specs_pis(ChildSpecs, PIs0),
    clean_predicate_indicators(PIs0, CleanPIs),
    include(local_predicate(SourceModule), CleanPIs, LocalPIs),
    sort(LocalPIs, PIs),
    materialise_supervisor_options(SourceModule, PIs, Options, SpawnOptions),
    State = sup(Strategy, MaxRestarts, Period, [], []),
    append(NameOptions,['$entry_context'(caller)|SpawnOptions],EffectiveOptions),
    spawn_runtime(supervisor_actor:sup_init(Specs, State), Pid,EffectiveOptions).

supervisor_source_module(_Fallback, Module) :-
    self(Self),
    actor_module(Self, Module),
    !.
supervisor_source_module(Fallback, Fallback).

materialise_supervisor_options(SourceModule, PIs, Options0, Options) :-
    exclude(supervisor_private_option, Options0, PlainOptions),
    ( PIs == [] -> SourceOptions = PlainOptions
    ; clean_predicate_indicators(PIs, CopyPIs),
      SourceOptions = [src_predicates(CopyPIs)|PlainOptions]
    ),
    rewrite_source_options(SourceOptions, SourceModule, Materialized0),
    copy_term(Materialized0, Options).

supervisor_private_option(strategy(_)).
supervisor_private_option(intensity(_)).
supervisor_private_option(period(_)).
supervisor_private_option(name(_)).

supervisor_spawn_child(Supervisor, ChildSpec0, Reply) :-
    strip_module(ChildSpec0, Caller, ChildSpec),
    supervisor_source_module(Caller, SourceModule),
    child_spec_error(normalise_child_spec(SourceModule,ChildSpec,Spec),
                     supervisor_actor:supervisor_spawn_child/3),
    sup_call(Supervisor, start_child(Spec), Reply).

supervisor_terminate_child(Supervisor, Id, Reply) :-
    sup_call(Supervisor, terminate_child(Id), Reply).

supervisor_delete_child(Supervisor, Id, Reply) :-
    sup_call(Supervisor, delete_child(Id), Reply).

supervisor_respawn_child(Supervisor, Id, Reply) :-
    sup_call(Supervisor, restart_child(Id), Reply).

supervisor_which_children(Supervisor, Children) :-
    sup_call(Supervisor, which_children, Children).

supervisor_count_children(Supervisor, Counts) :-
    sup_call(Supervisor, count_children, Counts).

supervisor_halt(Supervisor) :-
    sup_halt_call(Supervisor).

supervisor_stop(Supervisor) :-
    supervisor_halt(Supervisor).


                 /*******************************
                 *       SOURCE COLLECTION       *
                 *******************************/

child_specs_pis([], []).
child_specs_pis([child(_, Options)|Specs], PIs) :-
    ( option(start(Start), Options)
    -> start_term_pis(Start, Here)
    ; Here = []
    ),
    child_specs_pis(Specs, Rest),
    append(Here, Rest, PIs).

start_term_pis(server(Callback, _), [PI]) :- !,
    strip_module(Callback, _, Plain),
    callable_pi(Plain, 4, PI).
start_term_pis(start_sub_supervisor(Specs0, _), PIs) :- !,
    strip_module(Specs0, _, Specs),
    child_specs_pis(Specs, PIs).
start_term_pis(Goal, [PI]) :-
    strip_module(Goal, _, Plain),
    callable_pi(Plain, 0, PI).

callable_pi(Callable, Extra, PI) :-
    callable(Callable),
    ( atom(Callable) -> Name = Callable, BaseArity = 0
    ; functor(Callable, Name, BaseArity)
    ),
    Arity is BaseArity + Extra,
    PI = Name/Arity.


                 /*******************************
                 *       CALL INFRASTRUCTURE     *
                 *******************************/

sup_call(Supervisor, Request, Reply) :-
    self(Self),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(Supervisor, MonitorRef),
        ( Supervisor ! '$sup'(Self, Ref, Request),
          receive({
              Ref-Reply0 -> Reply = Reply0 ;
              down(_, MonitorRef, Reason) -> throw(supervisor_down(Reason))
          }, [timeout(10),
              on_timeout(throw(supervisor_call_timeout(Supervisor,
                                                       Request)))])
        ),
        demonitor(MonitorRef, [flush])).

% A normal down can overtake the acknowledgement on another connection.
% Only halt waits tolerate that ordering; retain one deadline and require ack.
sup_halt_call(Supervisor) :-
    self(Self),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(Supervisor, MonitorRef),
        ( Supervisor ! '$sup'(Self, Ref, stop),
          get_time(Now), Deadline is Now + 10,
          sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, pending)
        ),
        demonitor(MonitorRef, [flush])).

sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, Outcome) :-
    get_time(Now), Remaining is max(0, Deadline - Now),
    receive({
        Ref-_ -> true ;
        down(_, MonitorRef, Reason) ->
            ( Reason == true
            -> sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, normal_down)
            ; throw(supervisor_down(Reason)) )
    }, [timeout(Remaining),
        on_timeout(sup_halt_timeout(Supervisor, Outcome))]).

sup_halt_timeout(_, normal_down) :- !,
    throw(supervisor_down(true)).
sup_halt_timeout(Supervisor, pending) :-
    throw(supervisor_call_timeout(Supervisor, stop)).

sup_reply(To, Ref, Reply) :-
    To ! Ref-Reply.


                 /*******************************
                 *       SUPERVISOR PROCESS      *
                 *******************************/

sup_init(Specs, State0) :-
    ( with_startup_scope(start_children(Specs, State0, State))
    -> sup_loop(State)
    ; exit(init_failed)
    ).

start_sub_supervisor(ChildSpecs0, Options) :-
    validate_supervisor_options(Options),
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxRestarts), Options, 1),
    option(period(Period), Options, 5),
    normalise_child_specs(Caller, ChildSpecs, Specs),
    sup_init(Specs, sup(Strategy, MaxRestarts, Period, [], [])).

start_children([], State, State).
start_children([Spec|Specs], State0, State) :-
    do_start_child(Spec, State0, State1),
    start_children(Specs, State1, State).

sup_loop(State) :-
    receive({
        down(Pid, _, Reason) ->
            handle_exit(Pid, Reason, State, Next),
            sup_loop(Next) ;
        '$sup'(From, Ref, Request) ->
            catch((remote_supervisor_request(Request,Checked),Admission=ok),
                  Error,Admission=error(Error)),
            ( Admission=error(Why)
            -> sup_reply(From,Ref,error(Why)),Next=State
            ; handle_call(Checked, From, Ref, State, Next) ),
            sup_loop(Next) ;
        '$sup_exit' ->
            State = sup(_, _, _, Children, _),
            shutdown_children(Children)
    }).

remote_supervisor_request(Request,Checked) :-
    (nb_current('$remote_supervisor_policy',_) -> remote_supervisor:guard_request(Request,Checked)
    ; Checked=Request).


                 /*******************************
                 *       CHILD LIFECYCLE         *
                 *******************************/

do_start_child(spec(Id, Start, Restart, Shutdown, Type),
               sup(Strategy, MaxR, MaxT, Children, Log),
               sup(Strategy, MaxR, MaxT, NewChildren, Log)) :-
    \+ member(ch(Id, _, _), Children),
    Spec = spec(Id, Start, Restart, Shutdown, Type),
    supervisor_startup:start_child(Spec, Start, Id, Pid),
    monitor(Pid, Ref),
    remember_monitor(Pid, Ref),
    append(Children, [ch(Id, Pid, Spec)], NewChildren).

% Receiver-generated starts keep checked sources with their child and execute
% precompiled framework code, rather than copying runtime library predicates.
do_spawn_child(remote_supervisor:invoke_child(Goal,Sources),_,Pid) :- !,
    remote_supervisor:spawn_child(Goal,Sources,Pid).
do_spawn_child(remote_supervisor:run_nested(Children,Settings),_,Pid) :- !,
    remote_supervisor:spawn_nested(Children,Settings,Pid).
do_spawn_child(server(remote_supervisor:checked_callback(M,P,App,Closure),Options),Name,Pid) :- !,
    remote_supervisor:spawn_server(M,P,App,Closure,Name,Options,Pid).
do_spawn_child(server(Callback, ServerOptions), Name, Pid) :- !,
    option(initial_state(State), ServerOptions, []),
    exclude(initial_state_option, ServerOptions, Options),
    child_callback(Callback, EffectiveCallback, SourceOptions),
    append([name(Name),link(true)|SourceOptions], Options, SpawnOptions),
    call(server_actor:server_spawn(EffectiveCallback, State, Pid,
                                   SpawnOptions)).
do_spawn_child(start_sub_supervisor(Specs, Options), _Name, Pid) :- !,
    nested_supervisor_start(Specs, Options, SourceModule, PlainSpecs,
                            SourceOptions0),
    materialize_child_options(SourceModule, SourceOptions0, SourceOptions),
    spawn_runtime(supervisor_actor:nested_supervisor_entry(SourceModule:PlainSpecs,
                                                   Options), Pid,
          ['$entry_context'(caller),link(true)|SourceOptions]).
do_spawn_child(Goal0, _Name, Pid) :-
    child_goal(Goal0, SourceModule:Plain, SourceOptions0),
    materialize_child_options(SourceModule, SourceOptions0, SourceOptions),
    spawn_runtime(supervisor_actor:child_entry(Plain), Pid,
          ['$entry_context'(caller),link(true)|SourceOptions]).

initial_state_option(initial_state(_)).

child_callback(Callback0, SourceModule:Plain, SourceOptions) :-
    strip_module(Callback0, Fallback, Plain),
    child_source_module(Fallback, Plain, 4, SourceModule, SourceOptions).

child_goal(Goal0, SourceModule:Plain, SourceOptions) :-
    strip_module(Goal0, Fallback, Plain),
    child_source_module(Fallback, Plain, 0, SourceModule, SourceOptions).

child_source_module(Fallback, Plain, Extra, SourceModule, SourceOptions) :-
    callable_pi(Plain, Extra, PI0),
    clean_predicate_indicator(PI0, PI),
    ( self(Self), actor_module(Self, ActorModule),
      local_predicate(ActorModule, PI)
    -> SourceModule = ActorModule
    ; predicate_definition_module(Fallback, Plain, Extra, SourceModule)
    ),
    ( local_predicate(SourceModule, PI)
    -> SourceOptions = [src_predicates([PI])]
    ; SourceOptions = []
    ).

local_predicate(Module, Name/Arity) :-
    functor(Head, Name, Arity),
    predicate_property(Module:Head, number_of_clauses(Count)),
    Count > 0,
    \+ predicate_property(Module:Head, imported_from(_)).

predicate_definition_module(Module0, Plain, Extra, Module) :-
    callable_pi(Plain, Extra, Name/Arity),
    functor(Head, Name, Arity),
    predicate_property(Module0:Head, imported_from(Imported)),
    !,
    Module = Imported.
predicate_definition_module(Module, _, _, Module).

nested_supervisor_start(Specs0, _Options, SourceModule, Specs,
                        SourceOptions) :-
    strip_module(Specs0, Fallback, Specs),
    ( self(Self), actor_module(Self, ActorModule)
    -> SourceModule = ActorModule
    ; SourceModule = Fallback
    ),
    child_specs_pis(Specs, PIs0),
    clean_predicate_indicators(PIs0, CleanPIs),
    include(local_predicate(SourceModule), CleanPIs, LocalPIs),
    sort(LocalPIs, PIs),
    ( PIs == [] -> SourceOptions = []
    ; clean_predicate_indicators(PIs, Copy),
      SourceOptions = [src_predicates(Copy)]
    ).

clean_predicate_indicators([], []).
clean_predicate_indicators([PI0|PIs0], [PI|PIs]) :-
    clean_predicate_indicator(PI0, PI),
    clean_predicate_indicators(PIs0, PIs).

clean_predicate_indicator(PI0, PI) :-
    term_to_atom(PI0, Text),
    atom_to_term(Text, PI, _).

materialize_child_options(SourceModule, Options0, Options) :-
    rewrite_source_options(Options0, SourceModule, Materialized),
    copy_term(Materialized, Options).

child_entry(Goal) :-
    self(Self),
    actor_module(Self, Module),
    isolation:call_in_module(Module, '$actor_call'(Goal)).

nested_supervisor_entry(Specs, Options) :-
    start_sub_supervisor(Specs, Options).


                 /*******************************
                 *       RESTART POLICIES        *
                 *******************************/

handle_exit(Pid, Reason,
            sup(Strategy, MaxR, MaxT, Children, Log0), State) :-
    ( select(ch(Id, Pid, Spec), Children, _)
    -> Spec = spec(_, _, Restart, _, _),
       ( should_restart(Restart, Reason)
       -> replace_child(Id, ch(Id, undefined, Spec), Children, Marked),
          ( check_intensity(MaxR, MaxT, Log0, Log)
          -> restart_attempt(Strategy, Id, Spec, Marked,
                             MaxR, MaxT, Log, State)
          ; intensity_exhausted(Marked)
          )
       ; ( Restart == temporary
         -> select(ch(Id, Pid, _), Children, Remaining)
         ; replace_child(Id, ch(Id, undefined, Spec), Children, Remaining)
         ),
         State = sup(Strategy, MaxR, MaxT, Remaining, Log0)
       )
    ; State = sup(Strategy, MaxR, MaxT, Children, Log0)
    ).

should_restart(permanent, _).
should_restart(transient, Reason) :- Reason \= true.

check_intensity(MaxR, MaxT, Log0, Log) :-
    get_time(Now),
    Cutoff is Now - MaxT,
    include(recent_restart(Cutoff), Log0, Recent),
    length(Recent, Count),
    Count < MaxR,
    Log = [Now|Recent].

% Exhaustion is decided before replacement startup. Retain the normal reason,
% but apply each remaining child's policy while our mailbox is still usable.
intensity_exhausted(Children) :-
    supervisor_startup:cleanup_children(Children),
    (actor_terminating -> throw(actor_exit);exit(shutdown)).

recent_restart(Cutoff, Time) :- Time > Cutoff.

restart_attempt(Strategy, Id, Spec, Children, MaxR, MaxT, Log, State) :-
    catch((with_startup_scope(
              apply_strategy(Strategy,Id,Spec,Children,MaxR,MaxT,Log,State))
           -> true ; throw(restart_failed(Id,start_failed))),
          Error,restart_attempt_failed(Id,Children,Error)).

restart_attempt_failed(_,_,Error) :-
    actors:guard_control_exception(Error),!,throw(Error).
restart_attempt_failed(_,_,_) :- actor_terminating,!,throw(actor_exit).
restart_attempt_failed(Id,Children,Error) :-
    supervisor_startup:cleanup_children(Children),
    (actor_terminating -> throw(actor_exit);true),
    (Error=restart_failed(_,_) -> Reason=Error
    ; Reason=restart_failed(Id,Error)),
    exit(Reason).

start_replacement(Spec,Pid) :-
    Spec=spec(Id,Start,_,_,_),
    supervisor_startup:start_child(Spec,Start,Id,Pid),
    monitor(Pid,Ref),remember_monitor(Pid,Ref).

restart_child_record(Id,Spec,Pid) :-
    catch((start_replacement(Spec,Pid)->true;throw(start_failed)),
          Error,restart_child_error(Id,Error)).
restart_child_error(_,Error) :-
    actors:guard_control_exception(Error),!,throw(Error).
restart_child_error(Id,Error) :- throw(restart_failed(Id,Error)).

apply_strategy(one_for_one, Id, Spec, Children, MaxR, MaxT, Log,
               sup(one_for_one, MaxR, MaxT, NewChildren, Log)) :-
    restart_child_record(Id, Spec, Pid),
    replace_child(Id, ch(Id, Pid, Spec), Children, NewChildren).
apply_strategy(one_for_all, _, _, Children, MaxR, MaxT, Log,
               sup(one_for_all, MaxR, MaxT, NewChildren, Log)) :-
    supervisor_startup:stop_children(Children),
    restart_all(Children, [], NewChildren).
apply_strategy(rest_for_one, Id, _, Children, MaxR, MaxT, Log,
               sup(rest_for_one, MaxR, MaxT, NewChildren, Log)) :-
    split_at_child(Id, Children, Before, FromCrashed),
    supervisor_startup:stop_children(FromCrashed),
    restart_all(FromCrashed, [], Restarted),
    append(Before, Restarted, NewChildren).

restart_all([], Acc, Children) :- reverse(Acc, Children).
restart_all([ch(Id, _, Spec)|Children], Acc, Restarted) :-
    restart_child_record(Id, Spec, Pid),
    restart_all(Children, [ch(Id, Pid, Spec)|Acc], Restarted).


                 /*******************************
                 *           SHUTDOWN            *
                 *******************************/

shutdown_children(Children) :-
    reverse(Children, Reverse),
    maplist(shutdown_one, Reverse).

shutdown_running([]).
shutdown_running([ch(_, undefined, _)|Children]) :- !,
    shutdown_running(Children).
shutdown_running([Child|Children]) :-
    shutdown_one(Child),
    shutdown_running(Children).

shutdown_one(ch(_, undefined, _)) :- !.
shutdown_one(ch(_, Pid, spec(_, Start, _, Shutdown, _))) :-
    do_shutdown(Pid, Shutdown, Start).

do_shutdown(Pid, brutal_kill, _) :- !,
    exit(Pid, kill),
    wait_down(Pid).
do_shutdown(Pid, Shutdown, Start) :-
    ( request_stop(Pid, Start, Ref)
    -> ( Shutdown == infinity
       -> wait_down(Pid)
       ; number(Shutdown), wait_down_timeout(Pid, Shutdown)
       -> true
       ; exit(Pid, shutdown), wait_down(Pid)
       ),
       flush_stop_reply(Ref)
    ; exit(Pid, shutdown),
      wait_down(Pid)
    ).

request_stop(Pid, server(_, _), Ref) :-
    self(Self),
    make_ref(Ref),
    Pid ! '$stop'(Self, Ref).

flush_stop_reply(Ref) :-
    receive({Ref-_ -> true}, [timeout(0)]).

wait_down(Pid) :-
    receive({down(Pid, _, _) -> true}).

wait_down_timeout(Pid, Timeout) :-
    receive({down(Pid, _, _) -> true},
            [timeout(Timeout), on_timeout(fail)]).


                 /*******************************
                 *       DYNAMIC OPERATIONS      *
                 *******************************/

startup_error_reply(_, _) :- actor_terminating,!,throw(actor_exit).
startup_error_reply(Error, _) :-
    actors:guard_control_exception(Error),!,throw(Error).
startup_error_reply(Error, error(Error)).

handle_call(start_child(Spec), From, Ref, State0, State) :-
    Spec = spec(Id, _, _, _, _),
    State0 = sup(_, _, _, Children, _),
    ( member(ch(Id, _, _), Children)
    -> sup_reply(From, Ref, error(already_present)), State = State0
    ; catch((with_startup_scope(do_start_child(Spec, State0, NewState))
             -> Result=ok ; Result=error(start_failed)),
            Error,startup_error_reply(Error,Result)),
      (Result==ok -> State=NewState ; State=State0),
      sup_reply(From, Ref, Result)
    ).

handle_call(terminate_child(Id), From, Ref,
            sup(Str, MR, MT, Children, Log), State) :-
    ( member(ch(Id, Pid, Spec), Children), Pid \= undefined
    -> Spec = spec(_, Start, _, Shutdown, _),
       do_shutdown(Pid, Shutdown, Start),
       replace_child(Id, ch(Id, undefined, Spec), Children, NewChildren),
       sup_reply(From, Ref, ok),
       State = sup(Str, MR, MT, NewChildren, Log)
    ; member(ch(Id, undefined, _), Children)
    -> sup_reply(From, Ref, ok), State = sup(Str, MR, MT, Children, Log)
    ; sup_reply(From, Ref, error(not_found)),
      State = sup(Str, MR, MT, Children, Log)
    ).

handle_call(delete_child(Id), From, Ref,
            sup(Str, MR, MT, Children, Log), State) :-
    ( select(ch(Id, undefined, _), Children, Rest)
    -> sup_reply(From, Ref, ok), State = sup(Str, MR, MT, Rest, Log)
    ; member(ch(Id, Pid, _), Children), Pid \= undefined
    -> sup_reply(From, Ref, error(running)),
       State = sup(Str, MR, MT, Children, Log)
    ; sup_reply(From, Ref, error(not_found)),
      State = sup(Str, MR, MT, Children, Log)
    ).

handle_call(restart_child(Id), From, Ref,
            sup(Str, MR, MT, Children, Log), State) :-
    ( member(ch(Id, undefined, Spec), Children)
    -> catch((with_startup_scope(start_replacement(Spec,NewPid))
              -> Result=ok(NewPid);Result=error(start_failed)),
             Error,startup_error_reply(Error,Result)),
       (Result=ok(Pid)
       -> replace_child(Id,ch(Id,Pid,Spec),Children,NewChildren),
          State=sup(Str,MR,MT,NewChildren,Log)
       ; State=sup(Str,MR,MT,Children,Log)),
       sup_reply(From,Ref,Result)
    ; member(ch(Id, Pid, _), Children), Pid \= undefined
    -> sup_reply(From, Ref, error(running)),
       State = sup(Str, MR, MT, Children, Log)
    ; sup_reply(From, Ref, error(not_found)),
      State = sup(Str, MR, MT, Children, Log)
    ).

handle_call(which_children, From, Ref, State, State) :-
    State = sup(_, _, _, Children, _),
    maplist(child_info, Children, Infos),
    sup_reply(From, Ref, Infos).

handle_call(count_children, From, Ref, State, State) :-
    State = sup(_, _, _, Children, _),
    length(Children, Specs),
    include(running_child, Children, Running),
    length(Running, Active),
    include(supervisor_child, Children, Supervisors0),
    length(Supervisors0, Supervisors),
    Workers is Active - Supervisors,
    sup_reply(From, Ref,
              [specs-Specs,active-Active,
               supervisors-Supervisors,workers-Workers]).

handle_call(stop, From, Ref, State, State) :-
    sup_reply(From, Ref, ok),
    self(Self),
    Self ! '$sup_exit'.

child_info(ch(Id, Pid, spec(_, _, Restart, _, Type)),
           info(Id, Pid, Type, Restart)).
running_child(ch(_, Pid, _)) :- Pid \= undefined.
supervisor_child(ch(_, _, spec(_, _, _, _, supervisor))).


                 /*******************************
                 *           UTILITIES           *
                 *******************************/

replace_child(_, _, [], []).
replace_child(Id, New, [ch(Id, _, _)|Children], [New|Children]) :- !.
replace_child(Id, New, [Child|Children], [Child|Rest]) :-
    replace_child(Id, New, Children, Rest).

split_at_child(Id, Children, Before, [Crashed|After]) :-
    split_at_child_(Id, Children, [], Before, Crashed, After).

split_at_child_(Id, [ch(Id, Pid, Spec)|After], Acc, Before,
                ch(Id, Pid, Spec), After) :- !,
    reverse(Acc, Before).
split_at_child_(Id, [Child|Children], Acc, Before, Crashed, After) :-
    split_at_child_(Id, Children, [Child|Acc], Before, Crashed, After).
