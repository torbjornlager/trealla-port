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
:- use_module(isolation, [actor_module/2,rewrite_source_options/3]).

:- meta_predicate(supervisor_spawn(:, -)).
:- meta_predicate(supervisor_spawn(:, -, +)).
:- meta_predicate(supervisor_spawn_child(+, :, -)).


                 /*******************************
                 *      CHILD SPECIFICATIONS     *
                 *******************************/

normalise_child_spec(Caller, child(Id, Options),
                     spec(Id, Start, Restart, Shutdown, Type)) :-
    ( option(start(Start0), Options)
    -> qualify_start_term(Caller, Start0, Start)
    ; throw(error(missing_start_option(Id), supervisor))
    ),
    option(restart(Restart), Options, permanent),
    option(type(Type), Options, worker),
    default_shutdown(Type, DefaultShutdown),
    option(shutdown(Shutdown), Options, DefaultShutdown).

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

supervisor_spawn(ChildSpecs0, Pid, Options) :-
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    supervisor_source_module(Caller, SourceModule),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxRestarts), Options, 1),
    option(period(Period), Options, 5),
    maplist(normalise_child_spec(SourceModule), ChildSpecs, Specs),
    child_specs_pis(ChildSpecs, PIs0),
    clean_predicate_indicators(PIs0, CleanPIs),
    include(local_predicate(SourceModule), CleanPIs, LocalPIs),
    sort(LocalPIs, PIs),
    materialise_supervisor_options(SourceModule, PIs, Options, SpawnOptions),
    State = sup(Strategy, MaxRestarts, Period, [], []),
    spawn(supervisor_actor:sup_init(Specs, State), Pid,
          ['$entry_context'(caller)|SpawnOptions]),
    ( option(name(Name), Options) -> register(Name, Pid) ; true ).

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
    normalise_child_spec(SourceModule, ChildSpec, Spec),
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
    sup_call(Supervisor, stop, _).

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

sup_reply(To, Ref, Reply) :-
    To ! Ref-Reply.


                 /*******************************
                 *       SUPERVISOR PROCESS      *
                 *******************************/

sup_init(Specs, State0) :-
    ( start_children(Specs, State0, State)
    -> sup_loop(State)
    ; exit(init_failed)
    ).

start_sub_supervisor(ChildSpecs0, Options) :-
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxRestarts), Options, 1),
    option(period(Period), Options, 5),
    maplist(normalise_child_spec(Caller), ChildSpecs, Specs),
    sup_init(Specs, sup(Strategy, MaxRestarts, Period, [], [])).

start_children([], State, State).
start_children([Spec|Specs], State0, State) :-
    ( do_start_child(Spec, State0, State1)
    -> start_children(Specs, State1, State)
    ; State0 = sup(_, _, _, Children, _),
      shutdown_children(Children),
      fail
    ).

sup_loop(State) :-
    receive({
        down(Pid, _, Reason) ->
            handle_exit(Pid, Reason, State, Next),
            sup_loop(Next) ;
        '$sup'(From, Ref, Request) ->
            handle_call(Request, From, Ref, State, Next),
            sup_loop(Next) ;
        '$sup_exit' ->
            State = sup(_, _, _, Children, _),
            shutdown_children(Children)
    }).


                 /*******************************
                 *       CHILD LIFECYCLE         *
                 *******************************/

do_start_child(spec(Id, Start, Restart, Shutdown, Type),
               sup(Strategy, MaxR, MaxT, Children, Log),
               sup(Strategy, MaxR, MaxT, NewChildren, Log)) :-
    \+ member(ch(Id, _, _), Children),
    Spec = spec(Id, Start, Restart, Shutdown, Type),
    do_spawn_child(Start, Id, Pid),
    monitor(Pid, _),
    append(Children, [ch(Id, Pid, Spec)], NewChildren).

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
    spawn(supervisor_actor:nested_supervisor_entry(SourceModule:PlainSpecs,
                                                   Options), Pid,
          ['$entry_context'(caller),link(true)|SourceOptions]).
do_spawn_child(Goal0, _Name, Pid) :-
    child_goal(Goal0, SourceModule:Plain, SourceOptions0),
    materialize_child_options(SourceModule, SourceOptions0, SourceOptions),
    spawn(supervisor_actor:child_entry(Plain), Pid,
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
       -> check_intensity(MaxR, MaxT, Log0, Log),
          replace_child(Id, ch(Id, undefined, Spec), Children, Marked),
          apply_strategy(Strategy, Id, Spec, Marked,
                         MaxR, MaxT, Log, State)
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
    ( Count >= MaxR -> exit(shutdown)
    ; Log = [Now|Recent]
    ).

recent_restart(Cutoff, Time) :- Time > Cutoff.

apply_strategy(one_for_one, Id, Spec, Children, MaxR, MaxT, Log,
               sup(one_for_one, MaxR, MaxT, NewChildren, Log)) :-
    Spec = spec(_, Start, _, _, _),
    do_spawn_child(Start, Id, Pid),
    monitor(Pid, _),
    replace_child(Id, ch(Id, Pid, Spec), Children, NewChildren).
apply_strategy(one_for_all, _, _, Children, MaxR, MaxT, Log,
               sup(one_for_all, MaxR, MaxT, NewChildren, Log)) :-
    shutdown_running(Children),
    restart_all(Children, [], NewChildren).
apply_strategy(rest_for_one, Id, _, Children, MaxR, MaxT, Log,
               sup(rest_for_one, MaxR, MaxT, NewChildren, Log)) :-
    split_at_child(Id, Children, Before, FromCrashed),
    shutdown_running(FromCrashed),
    restart_all(FromCrashed, [], Restarted),
    append(Before, Restarted, NewChildren).

restart_all([], Acc, Children) :- reverse(Acc, Children).
restart_all([ch(Id, _, Spec)|Children], Acc, Restarted) :-
    Spec = spec(_, Start, _, _, _),
    do_spawn_child(Start, Id, Pid),
    monitor(Pid, _),
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

handle_call(start_child(Spec), From, Ref, State0, State) :-
    Spec = spec(Id, _, _, _, _),
    State0 = sup(_, _, _, Children, _),
    ( member(ch(Id, _, _), Children)
    -> sup_reply(From, Ref, error(already_present)), State = State0
    ; do_start_child(Spec, State0, State)
    -> sup_reply(From, Ref, ok)
    ; sup_reply(From, Ref, error(start_failed)), State = State0
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
    -> Spec = spec(_, Start, _, _, _),
       ( do_spawn_child(Start, Id, Pid)
       -> monitor(Pid, _),
          replace_child(Id, ch(Id, Pid, Spec), Children, NewChildren),
          sup_reply(From, Ref, ok(Pid)),
          State = sup(Str, MR, MT, NewChildren, Log)
       ; sup_reply(From, Ref, error(start_failed)),
         State = sup(Str, MR, MT, Children, Log)
       )
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
