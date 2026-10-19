% SPDX-License-Identifier: MIT

:- module(server_actor,
       [ server_spawn/3,
         server_spawn/4,
         server_request/3,
         server_request/4,
         server_promise/3,
         server_promise/4,
         server_yield/2,
         server_yield/3,
         server_yield/4,
         server_upgrade/2,
         server_upgrade/3,
         server_halt/2,
         server_stop/2
       ]).

/** <module> Generic stateful server actor behaviour

The callback predicate has four arguments:

  `Callback(Request, OldState, Response, NewState)`.

Callbacks are copied into the server actor's private Trealla module. Source
options supplied to server_spawn/4 are resolved relative to the callback's
source module, not to this implementation module. A successful upgrade
replaces the callback without changing the server state.
*/

:- use_module(actors).
:- use_module(isolation, [actor_module/2,rewrite_source_options/3]).

:- meta_predicate(server_spawn(:, +, -)).
:- meta_predicate(server_spawn(:, +, -, +)).
:- meta_predicate(server_upgrade(+, :)).
:- meta_predicate(server_upgrade(+, :, +)).


%!  server_spawn(:Callback, +State, -Pid) is det.
%!  server_spawn(:Callback, +State, -Pid, +Options) is det.

server_spawn(Callback, State, Pid) :-
    server_spawn(Callback, State, Pid, []).

server_spawn(Callback0, State, Pid, Options) :-
    actors:validate_spawn_wrapper_options(Options,runtime,
        server_actor:server_spawn/4,[name-atom]),
    with_spawn_name(Options,Pid,
        server_actor:create_named_server(Callback0,State,Pid,Options)).

create_named_server(Callback0, State, Pid, Options, NameOptions) :-
    normalize_server_callback(Callback0, Callback),
    strip_module(Callback, CallbackModule, PlainCallback),
    server_callback_source_module(CallbackModule, PlainCallback, SourceModule),
    callback_pi(PlainCallback, PI0),
    % Trealla retains module-call provenance on a compound returned through a
    % qualified call.  Copying the indicator makes it acceptable to listing/1
    % and the src_predicates materialiser.
    copy_term(PI0, PI),
    rewrite_source_options([src_predicates([PI])|Options], SourceModule,
                           Materialized0),
    copy_term(Materialized0, MaterializedOptions),
    server_spawn_options(MaterializedOptions, SpawnOptions),
    append(NameOptions,SpawnOptions,EffectiveOptions),
    spawn_runtime(server_actor:server_loop(SourceModule:PlainCallback, State),
          Pid, EffectiveOptions).

server_spawn_options(Options, SpawnOptions) :-
    non_server_options(Options, PlainOptions),
    SpawnOptions = ['$entry_context'(caller)|PlainOptions].

non_server_options([], []).
non_server_options([Option|Options], Rest) :-
    server_private_option(Option),
    !,
    non_server_options(Options, Rest).
non_server_options([Option|Options], [Option|Rest]) :-
    non_server_options(Options, Rest).

server_private_option(name(_)).

normalize_server_callback(Callback0, Callback) :-
    strip_module(Callback0, Module1, Plain0),
    innermost_callback_module(Plain0, Module1, Module0, PlainCallback),
    callback_definition_module(Module0, PlainCallback, Module),
    Callback = Module:PlainCallback.

innermost_callback_module(Module:Callback0, _Fallback,
                          EffectiveModule, Callback) :-
    atom(Module),
    !,
    innermost_callback_module(Callback0, Module,
                              EffectiveModule, Callback).
innermost_callback_module(Callback, Module, Module, Callback).

callback_definition_module(Module0, PlainCallback, Module) :-
    callback_head(PlainCallback, Head),
    predicate_property(Module0:Head, imported_from(Module1)),
    !,
    Module = Module1.
callback_definition_module(Module, _, Module).

callback_pi(PlainCallback, PI) :-
    callable(PlainCallback),
    atom(PlainCallback),
    !,
    PI = PlainCallback/4.
callback_pi(PlainCallback, PI) :-
    callable(PlainCallback),
    functor(PlainCallback, Name, ExtraArity),
    Arity is ExtraArity + 4,
    PI = Name/Arity.

callback_head(PlainCallback, Head) :-
    callback_pi(PlainCallback, Name/Arity),
    functor(Head, Name, Arity).

server_callback_source_module(_Fallback, PlainCallback, Module) :-
    self(Self),
    actor_module(Self, ActorModule),
    callback_head(PlainCallback, Head),
    predicate_property(ActorModule:Head, number_of_clauses(Count)),
    Count > 0,
    \+ predicate_property(ActorModule:Head, imported_from(_)),
    !,
    Module = ActorModule.
server_callback_source_module(Fallback, _, Fallback).


%!  server_loop(+Callback, +State) is det.

server_loop(Callback, State0) :-
    receive({
        '$call'(From, Ref, Request) ->
            ( call_server_callback(Callback, Request, State0,
                                   Response, State)
            -> From ! Ref-Response,
               server_loop(Callback, State)
            ;  exit(false)
            ) ;
        '$upgrade'(From, Ref, PlainCallback, Sources) ->
            catch(prepare_server_upgrade(PlainCallback, Sources, NewCallback),
                  Error, true),
            ( var(Error)
            -> From ! Ref-ok,
               server_loop(NewCallback, State0)
            ;  From ! Ref-error(Error),
               server_loop(Callback, State0)
            ) ;
        '$stop'(From, Ref) ->
            From ! Ref-true
    }).

call_server_callback(Callback, Request, State0, Response, State) :-
    strip_module(Callback, _, PlainCallback),
    self(Self),
    actor_module(Self, Module),
    callback_head(PlainCallback, Head),
    ( predicate_property(Module:Head, number_of_clauses(Count)), Count > 0
    -> EffectiveCallback = Module:PlainCallback
    ; EffectiveCallback = Callback
    ),
    call(EffectiveCallback, Request, State0, Response, State).


%!  server_request(+To, +Request, -Response) is det.
%!  server_request(+To, +Request, -Response, +Options) is det.

server_request(To, Request, Response) :-
    server_request(To, Request, Response, []).

server_request(To, Request, Response, Options) :-
    server_promise(To, Request, Ref, MonitorRef),
    server_yield(Ref, MonitorRef, Response, Options).


%!  server_promise(+To, +Request, -Ref) is det.
%!  server_promise(+To, +Request, -Ref, -MonitorRef) is det.

server_promise(To, Request, Ref) :-
    self(Self),
    make_ref(Ref),
    To ! '$call'(Self, Ref, Request).

server_promise(To, Request, Ref, MonitorRef) :-
    self(Self),
    monitor(To, MonitorRef),
    make_ref(Ref),
    To ! '$call'(Self, Ref, Request).


%!  server_yield(+Ref, -Response) is det.
%!  server_yield(+Ref, -Response, +Options) is det.
%!  server_yield(+Ref, +MonitorRef, -Response, +Options) is det.
%
%   Select the reply by Ref before unifying Response. A conflicting output
%   consumes that reply and fails; timeout callbacks retain their own results.

server_yield(Ref, Response) :-
    server_yield(Ref, Response, []).

server_yield(Ref, Response, Options) :-
    receive({ Ref-Reply -> Response = Reply }, Options).

server_yield(Ref, MonitorRef, Response, Options) :-
    call_cleanup(
        receive({
            Ref-Response0 ->
                Response = Response0 ;
            down(_Pid, MonitorRef, Reason) ->
                throw(server_down(Reason))
        }, Options),
        demonitor(MonitorRef, [flush])).


%!  server_upgrade(+To, :Callback) is det.
%!  server_upgrade(+To, :Callback, +SourceOptions) is det.

server_upgrade(To, Callback0) :-
    normalize_server_callback(Callback0, Callback),
    strip_module(Callback, _, PlainCallback),
    server_upgrade_source(To, PlainCallback, []).

server_upgrade(To, Callback0, Options) :-
    normalize_server_callback(Callback0, Callback),
    strip_module(Callback, CallbackModule, PlainCallback),
    server_callback_source_module(CallbackModule, PlainCallback, SourceModule),
    rewrite_source_options(Options, SourceModule, Sources0),
    upgrade_source_options(Sources0, Sources),
    server_upgrade_source(To, PlainCallback, Sources).

upgrade_source_options([], []).
upgrade_source_options([src_list(Terms)|Options], Sources) :-
    !,
    source_term_options(Terms, TermSources),
    upgrade_source_options(Options, Rest),
    append(TermSources, Rest, Sources).
upgrade_source_options([Option0|Options], [Option|Rest]) :-
    copy_term(Option0, Option),
    upgrade_source_options(Options, Rest).

source_term_options([], []).
source_term_options([Term0|Terms], [src_text(Text)|Sources]) :-
    copy_term(Term0, Term),
    format(atom(Text), '~q.~n', [Term]),
    source_term_options(Terms, Sources).

server_upgrade_source(To, PlainCallback, Sources) :-
    self(Self),
    make_ref(Ref),
    To ! '$upgrade'(Self, Ref, PlainCallback, Sources),
    receive({
        Ref-ok -> true ;
        Ref-error(Error) -> throw(Error)
    }).

prepare_server_upgrade(PlainCallback, Sources, Callback) :-
    self(Self),
    ( actor_module(Self, Module) -> true
    ; throw(error(existence_error(actor_module, Self),
                  server_actor:server_upgrade/3))
    ),
    load_upgrade_sources(Sources, Module, PlainCallback),
    ensure_server_callback(Module, PlainCallback),
    Callback = Module:PlainCallback.

load_upgrade_sources([], _, _) :- !.
load_upgrade_sources(Sources, Module, PlainCallback) :-
    abolish_local_callback(Module, PlainCallback),
    isolation:call_in_module(Module, '$actor_load'(Sources)).

abolish_local_callback(Module, PlainCallback) :-
    callback_head(PlainCallback, Head),
    ( predicate_property(Module:Head, number_of_clauses(Count)), Count > 0
    -> isolation:call_in_module(Module, retractall(Head))
    ; true
    ).

ensure_server_callback(Module, PlainCallback) :-
    callback_head(PlainCallback, Head),
    callback_pi(PlainCallback, Name/Arity),
    ( predicate_property(Module:Head, number_of_clauses(Count)), Count > 0
    -> true
    ; throw(error(existence_error(procedure, Module:Name/Arity),
                  context(server_actor:server_upgrade/3,
                          'upgrade callback is not loaded in the server')))
    ).


%!  server_halt(+To, -Reply) is det.
%!  server_stop(+To, -Reply) is det.

server_halt(To, Reply) :-
    self(Self),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(To, MonitorRef),
        ( To ! '$stop'(Self, Ref),
          receive({
              Ref-Reply0 ->
                  Reply = Reply0,
                  % The acknowledgement is sent immediately before the
                  % server exits.  Trealla may enqueue the resulting down/3
                  % just after demonitor/2's zero-time flush, so consume this
                  % behaviour-owned monitor explicitly while preserving any
                  % monitor installed by the caller.
                  receive({down(_Pid, MonitorRef, _) -> true},
                          [timeout(1)]) ;
              down(_Pid, MonitorRef, Reason) -> throw(server_down(Reason))
          })
        ),
        demonitor(MonitorRef, [flush])).

server_stop(To, Reply) :-
    server_halt(To, Reply).
