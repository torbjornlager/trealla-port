% SPDX-License-Identifier: MIT

:- module(isolation,
       [ run_actor/5,              % +Pid, +GoalModule, :Goal, +Options, +Parent
         prepare_actor/4,          % +Pid, +GoalModule, +Options, -Module
         run_actor_goal/3,         % +Module, :Goal, +Options
         cleanup_actor/1,          % +Pid
         configure_shared_db/1,    % +Files
         clear_shared_db/0,
         actor_module/2,           % +Pid, -Module
         actor_source_module/2,    % +Pid, -Module
         execution_goal/2,         % +Goal, -QualifiedGoal
         run_actor_query/2,        % +Module, +Goal
         actor_builtin_goal/1,     % +Goal
         rewrite_source_options/3, % +Options, +SourceModule, -Options
         load_options_text/3       % +SourceModule, +Options, -Text
       ]).

/** <module> Private source namespaces for Trealla actors

Each local actor receives a fresh Trealla module.  Source supplied through
`src_text/1`, `src_list/1`, or `src_predicates/1` is installed there and is
therefore invisible to other actors.  `src_predicates/1` is materialised in
the spawning process, which also makes it portable over the distribution
protocol.

Trealla v3.13.2 exposes `in_temporary_module/3`, `destroy_module/1`, and
`load_text/2`.  The complete child-side actor goal runs inside the scoped
temporary module, so cleanup follows normal success, failure, exceptions, and
actor-exit unwinds.  The actor bootstrap is loaded from memory rather than
through a per-actor file.

`src_uri/1` is resolved to inline source by the node's controlled source
policy before actor creation.
*/

:- use_module(library(error)).
:- use_module(source_policy).

:- dynamic actor_namespace/2.
:- dynamic actor_source_namespace/2.
:- dynamic shared_db_text/1.

:- catch(mutex_create(_, [alias('$isolation_listing')]),
         error(permission_error(create, mutex, '$isolation_listing'), _),
         true).

actors_library_file(ActorsFile) :-
    absolute_file_name('actors.pl', ActorsFile, []).

toplevel_library_file(ToplevelFile) :-
    absolute_file_name('toplevel_actors.pl', ToplevelFile, []).

sandbox_library_file(SandboxFile) :-
    absolute_file_name('sandbox_policy.pl', SandboxFile, []).

rpc_library_file(RpcFile) :-
    absolute_file_name('rpc.pl', RpcFile, []).

parallel_library_file(ParallelFile) :-
    absolute_file_name('parallel.pl', ParallelFile, []).

server_actor_library_file(ServerActorFile) :-
    absolute_file_name('server_actor.pl', ServerActorFile, []).

supervisor_actor_library_file(SupervisorActorFile) :-
    absolute_file_name('supervisor_actor.pl', SupervisorActorFile, []).

actor_api_library_file(ActorApiFile) :-
    absolute_file_name('actor_api.pl', ActorApiFile, []).


                /*******************************
                *       PUBLIC OPERATIONS      *
                *******************************/

%!  configure_shared_db(+Files) is det.
%
%   Load trusted node-wide source files for every subsequently created actor.
%   The source is copied into each actor namespace so ordinary actor calls and
%   nested spawns see the same database.  Actor-local source retains SWI's
%   shadowing semantics: defining a predicate locally replaces the shared
%   clauses for that predicate in that actor only.

configure_shared_db(Files) :-
    must_be(list, Files),
    shared_files_text(Files, '', Text),
    retractall(shared_db_text(_)),
    ( Text == '' -> true ; assertz(shared_db_text(Text)) ).

clear_shared_db :-
    retractall(shared_db_text(_)).

shared_files_text([], Text, Text).
shared_files_text([File0|Files], Acc, Text) :-
    shared_file_atom(File0, File),
    setup_call_cleanup(open(File, read, Stream, [type(binary)]),
                       read_stream_bytes(Stream, Bytes), close(Stream)),
    atom_codes(Source, Bytes),
    ( Acc == '' -> Next = Source
    ; atom_concat(Acc, '\n', Prefix), atom_concat(Prefix, Source, Next)
    ),
    shared_files_text(Files, Next, Text).

shared_file_atom(File, File) :- atom(File), !.
shared_file_atom(File, Atom) :- string(File), !, atom_chars(Atom, File).
shared_file_atom(File, _) :-
    throw(error(type_error(source_sink, File), configure_shared_db/1)).

read_stream_bytes(Stream, Bytes) :-
    get_byte(Stream, Byte),
    ( Byte =:= -1 -> Bytes = []
    ; Bytes = [Byte|Rest], read_stream_bytes(Stream, Rest)
    ).

run_actor(Pid, GoalModule, Goal, Options, Parent) :-
    fresh_namespace(Module),
    actors:make_ref(PrepareToken),
    catch(
        setup_call_cleanup(
            true,
            in_temporary_module(
                Module,
                isolation:prepare_actor_and_signal(
                    Pid, GoalModule, Options, Module, Parent, PrepareToken),
                isolation:run_actor_goal(Module, Goal, Options)),
            forget_actor_module(Pid, Module)),
        '$actor_prepare_error'(PrepareToken, Error),
        ( actors:actor_send(
              Parent, '$actor_started'(Pid, error(Error))),
          throw(Error)
        )).

prepare_actor_and_signal(Pid, GoalModule, Options, Module, Parent,
                         PrepareToken) :-
    catch((prepare_actor_module(Pid, GoalModule, Options, Module),
           actors:publish_spawn_name(Pid,Options),
           actors:signal_actor_started(Pid,Parent)),
          Error,
          throw('$actor_prepare_error'(PrepareToken, Error))).

% Explicit lifecycle retained for diagnostics and callers that prepare a
% module independently of an actor goal. Actor threads use run_actor/5.
prepare_actor(Pid, GoalModule, Options, Module) :-
    fresh_namespace(Module),
    catch(
        ( '$create_module'(Module),
          prepare_actor_module(Pid, GoalModule, Options, Module)
        ),
        Error,
        ( catch(call_in_module(Module, '$actor_cleanup'), _, true),
          catch(destroy_module(Module), _, true),
          forget_actor_module(Pid, Module),
          throw(Error)
        )).

prepare_actor_module(Pid, _GoalModule, Options, Module) :-
    source_options(Options, Sources),
    ( shared_db_text(SharedText)
    -> Shared = shared(SharedText)
    ; Shared = none
    ),
    prepare_actor_bootstrap(Module, Sources, Shared),
    assertz(actor_namespace(Pid, Module)),
    ( Shared = shared(SharedText)
    -> call_in_module(Module, '$actor_load_shared'(SharedText)),
       HasShared = true
    ; HasShared = false
    ),
    ( Sources == []
    -> true
    ; call_in_module(Module, '$actor_load'(Sources))
    ),
    ( Sources == [], HasShared == false -> true
    ; assertz(actor_source_namespace(Pid, Module))
    ).

prepare_actor_bootstrap(Module, [], none) :- !,
    minimal_bootstrap_text(Module, Bootstrap),
    load_text(Bootstrap, [module(Module)]).
prepare_actor_bootstrap(Module, _, _) :-
    bootstrap_text(Module, Bootstrap),
    load_text(Bootstrap, [module(Module)]).

run_actor_goal(Module, Goal0, Options) :-
    ( memberchk('$entry_context'(caller), Options)
    -> call(Goal0)
    ; strip_module(Goal0, _, Goal),
      ( actor_source_namespace(_, Module)
      -> run_actor_query(Module, Goal)
      ;  call_in_module(Module, '$actor_call'(Goal))
      )
    ).

cleanup_actor(Pid) :-
    retractall(actor_source_namespace(Pid, _)),
    forall(retract(actor_namespace(Pid, Module)),
           ( catch(call_in_module(Module, '$actor_cleanup'), _, true),
             destroy_module(Module) )).

forget_actor_module(Pid, Module) :-
    retractall(actor_source_namespace(Pid, Module)),
    retractall(actor_namespace(Pid, Module)).

actor_module(Pid, Module) :-
    actor_namespace(Pid, Module).

actor_source_module(Pid, Module) :-
    actor_source_namespace(Pid, Module).

execution_goal(Goal, Qualified) :-
    Goal = rpc(URI, RemoteGoal),
    !,
    Qualified = rpc:rpc(URI, RemoteGoal).
execution_goal(Goal, Qualified) :-
    Goal = rpc(URI, RemoteGoal, Options),
    !,
    Qualified = rpc:rpc(URI, RemoteGoal, Options).
execution_goal(Goal, Qualified) :-
    Goal = promise(URI, RemoteGoal, Reference),
    !,
    Qualified = rpc:promise(URI, RemoteGoal, Reference).
execution_goal(Goal, Qualified) :-
    Goal = promise(URI, RemoteGoal, Reference, Options),
    !,
    Qualified = rpc:promise(URI, RemoteGoal, Reference, Options).
execution_goal(Goal, Qualified) :-
    Goal = yield(Reference, Answer),
    !,
    Qualified = rpc:yield(Reference, Answer).
execution_goal(Goal, Qualified) :-
    Goal = yield(Reference, Answer, Options),
    !,
    Qualified = rpc:yield(Reference, Answer, Options).
execution_goal(Goal, Qualified) :-
    actors:self(Pid),
    actor_source_namespace(Pid, Module),
    !,
    % Keep the runtime goal out of a dynamically constructed Module:Goal
    % call. Trealla treats arguments nested in that form as meta-goals and can
    % qualify a catch-all receive variable, severing it from the result
    % template. The fixed isolation entry point performs module dispatch only
    % after the goal has crossed the toplevel state machine unchanged.
    Qualified = isolation:run_actor_query(Module, Goal).
execution_goal(Goal, Qualified) :-
    sourceless_worker_goal(Goal, Prepared),
    ( Goal == Prepared -> Qualified = Goal
    ; Qualified = toplevel_actors:run_worker_query(Prepared)
    ).

% Keep worker entries explicit when native control constructs change the
% meta-call context. Rebuild native controls rather than interpreting them,
% preserving variable sharing and their existing cut/exception scopes.
sourceless_worker_goal(Goal, Goal) :- var(Goal), !.
sourceless_worker_goal(parallel(Goals), toplevel_actors:parallel(Goals)) :- !.
sourceless_worker_goal(first_solution(S,Goals),
                       toplevel_actors:first_solution(S,Goals)) :- !.
sourceless_worker_goal(first_solution(S,Goals,Options),
                       toplevel_actors:first_solution(S,Goals,Options)) :- !.
sourceless_worker_goal((A0,B0), (A,B)) :- !,
    sourceless_worker_goal(A0,A), sourceless_worker_goal(B0,B).
sourceless_worker_goal((A0;B0), (A;B)) :- !,
    sourceless_worker_goal(A0,A), sourceless_worker_goal(B0,B).
sourceless_worker_goal((A0->B0), (A->B)) :- !,
    sourceless_worker_goal(A0,A), sourceless_worker_goal(B0,B).
sourceless_worker_goal(sandbox_policy:sandbox_control_catch(C,G0,E,H0),
                       sandbox_policy:sandbox_control_catch(C,G,E,H)) :- !,
    sourceless_worker_goal(G0,G), sourceless_worker_goal(H0,H).
sourceless_worker_goal(catch(G0,E,H0), catch(G,E,H)) :- !,
    sourceless_worker_goal(G0,G), sourceless_worker_goal(H0,H).
sourceless_worker_goal(call(G0), call(G)) :- !, sourceless_worker_goal(G0,G).
sourceless_worker_goal(once(G0), once(G)) :- !, sourceless_worker_goal(G0,G).
sourceless_worker_goal(ignore(G0), ignore(G)) :- !, sourceless_worker_goal(G0,G).
sourceless_worker_goal((\+G0), (\+G)) :- !, sourceless_worker_goal(G0,G).
sourceless_worker_goal(Goal, Goal).


run_actor_query(Module, Goal0) :-
    actor_query_goal(Module, Goal0, Goal),
    call(Goal).

% Preserve native Prolog control scope while preparing receive calls for the
% actor's private module. Interpreting ';'/2 recursively would run the Else
% branch after a successful If whose Then later failed. Native control terms
% and primitives stay in one call/1 scope, so !/0 can prune repeat/0.
actor_query_goal(Module, (Left0, Right0), (Left, Right)) :- !,
    actor_query_goal(Module, Left0, Left),
    actor_query_goal(Module, Right0, Right).
actor_query_goal(Module, (((Left == Right) -> Then0) ; Else0),
                 ((isolation:actor_identical(Left, Right), Then) ;
                  (isolation:actor_not_identical(Left, Right), Else))) :- !,
    actor_query_goal(Module, Then0, Then),
    actor_query_goal(Module, Else0, Else).
actor_query_goal(Module, ((If0 -> Then0) ; Else0),
                 (isolation:actor_if_choice(If, Choice),
                  ((Choice = then, Then) ; (Choice = else, Else)))) :- !,
    actor_query_goal(Module, If0, If),
    actor_query_goal(Module, Then0, Then),
    actor_query_goal(Module, Else0, Else).
actor_query_goal(Module, (Left0 ; Right0), (Left ; Right)) :- !,
    actor_query_goal(Module, Left0, Left),
    actor_query_goal(Module, Right0, Right).
actor_query_goal(Module, (If0 -> Then0), (If -> Then)) :- !,
    actor_query_goal(Module, If0, If),
    actor_query_goal(Module, Then0, Then).
actor_query_goal(Module, forall(Generate0, Test0),
                 (\+ (Generate, \+ Test))) :- !,
    actor_query_goal(Module, Generate0, Generate),
    actor_query_goal(Module, Test0, Test).
actor_query_goal(Module, (\+ Goal0), (\+ Goal)) :- !,
    actor_query_goal(Module, Goal0, Goal).
actor_query_goal(_, !, !) :- !.
actor_query_goal(Module, receive(Clauses0),
                 actors:receive_qualified(Qualified, [])) :- !,
    call_in_module(Module, '$actor_qualify_receive'(Clauses0, Clauses)),
    Qualified = Module:Clauses.
actor_query_goal(Module, receive(Clauses0, Options0),
                 actors:receive_qualified(Qualified, Options)) :- !,
    call_in_module(Module, '$actor_qualify_receive'(Clauses0, Clauses)),
    call_in_module(Module, '$actor_qualify_receive_options'(Options0, Options)),
    Qualified = Module:Clauses.
actor_query_goal(Module,toplevel_call_synch(P,G,A),toplevel_actors:toplevel_call_synch(P,Module:G,A,Module:[])) :- !.
actor_query_goal(Module,toplevel_call_synch(P,G,A,O),toplevel_actors:toplevel_call_synch(P,Module:G,A,Module:O)) :- !.
actor_query_goal(Module,toplevel_next_synch(P,A),toplevel_actors:toplevel_next_synch(P,A,Module:[])) :- !.
actor_query_goal(Module,toplevel_next_synch(P,A,O),toplevel_actors:toplevel_next_synch(P,A,Module:O)) :- !.
actor_query_goal(_, runtime_property(Property), rpc:runtime_property(Property)) :- !.
actor_query_goal(_, rpc(URI, Goal), rpc:rpc(URI, Goal)) :- !.
actor_query_goal(_, rpc(URI, Goal, Options),
                 rpc:rpc(URI, Goal, Options)) :- !.
actor_query_goal(_, promise(URI, Goal, Reference),
                 rpc:promise(URI, Goal, Reference)) :- !.
actor_query_goal(_, promise(URI, Goal, Reference, Options),
                 rpc:promise(URI, Goal, Reference, Options)) :- !.
actor_query_goal(_, promise_cleanup(Reference),
                 rpc:promise_cleanup(Reference)) :- !.
actor_query_goal(_, yield(Reference, Answer),
                 rpc:yield(Reference, Answer)) :- !.
actor_query_goal(_, yield(Reference, Answer, Options),
                 rpc:yield(Reference, Answer, Options)) :- !.
actor_query_goal(Module, server_spawn(Callback, State, Pid),
                 server_actor:server_spawn(Module:Callback, State, Pid)) :- !.
actor_query_goal(Module, server_spawn(Callback, State, Pid, Options),
                 server_actor:server_spawn(Module:Callback, State, Pid, Options)) :- !.
actor_query_goal(_, server_request(To, Request, Response),
                 server_actor:server_request(To, Request, Response)) :- !.
actor_query_goal(_, server_request(To, Request, Response, Options),
                 server_actor:server_request(To, Request, Response, Options)) :- !.
actor_query_goal(_, server_promise(To, Request, Ref),
                 server_actor:server_promise(To, Request, Ref)) :- !.
actor_query_goal(_, server_promise(To, Request, Ref, MonitorRef),
                 server_actor:server_promise(To, Request, Ref, MonitorRef)) :- !.
actor_query_goal(_, server_yield(Ref, Response),
                 server_actor:server_yield(Ref, Response)) :- !.
actor_query_goal(_, server_yield(Ref, Response, Options),
                 server_actor:server_yield(Ref, Response, Options)) :- !.
actor_query_goal(_, server_yield(Ref, MonitorRef, Response, Options),
                 server_actor:server_yield(Ref, MonitorRef, Response, Options)) :- !.
actor_query_goal(Module, server_upgrade(To, Callback),
                 server_actor:server_upgrade(To, Module:Callback)) :- !.
actor_query_goal(Module, server_upgrade(To, Callback, Options),
                 server_actor:server_upgrade(To, Module:Callback, Options)) :- !.
actor_query_goal(_, server_halt(To, Reply),
                 server_actor:server_halt(To, Reply)) :- !.
actor_query_goal(_, server_stop(To, Reply),
                 server_actor:server_stop(To, Reply)) :- !.
actor_query_goal(Module, supervisor_spawn(Specs, Pid),
                 supervisor_actor:supervisor_spawn(Module:Specs, Pid)) :- !.
actor_query_goal(Module, supervisor_spawn(Specs, Pid, Options),
                 supervisor_actor:supervisor_spawn(Module:Specs, Pid,
                                                   Options)) :- !.
actor_query_goal(Module, supervisor_spawn_child(Sup, Spec, Reply),
                 supervisor_actor:supervisor_spawn_child(Sup, Module:Spec,
                                                         Reply)) :- !.
actor_query_goal(_, supervisor_terminate_child(Sup, Id, Reply),
                 supervisor_actor:supervisor_terminate_child(Sup, Id,
                                                             Reply)) :- !.
actor_query_goal(_, supervisor_delete_child(Sup, Id, Reply),
                 supervisor_actor:supervisor_delete_child(Sup, Id,
                                                          Reply)) :- !.
actor_query_goal(_, supervisor_respawn_child(Sup, Id, Reply),
                 supervisor_actor:supervisor_respawn_child(Sup, Id,
                                                           Reply)) :- !.
actor_query_goal(_, supervisor_which_children(Sup, Children),
                 supervisor_actor:supervisor_which_children(Sup,
                                                            Children)) :- !.
actor_query_goal(_, supervisor_count_children(Sup, Counts),
                 supervisor_actor:supervisor_count_children(Sup,
                                                            Counts)) :- !.
actor_query_goal(_, supervisor_halt(Sup),
                 supervisor_actor:supervisor_halt(Sup)) :- !.
actor_query_goal(_, supervisor_stop(Sup),
                 supervisor_actor:supervisor_stop(Sup)) :- !.
actor_query_goal(Module,statechart_spawn(Pid,Options),statechart_actor:statechart_spawn(Pid,Module:Options)) :- !.
actor_query_goal(_,statechart_halt(Pid,Reply),statechart_actor:statechart_halt(Pid,Reply)) :- !.
actor_query_goal(_,statechart_halt(Pid,Reply,T),statechart_actor:statechart_halt(Pid,Reply,T)) :- !.
actor_query_goal(_, Qualified:Goal, Qualified:Goal) :-
    atom(Qualified),
    !.
actor_query_goal(_, (Left == Right),
                 isolation:actor_identical(Left, Right)) :- !.
actor_query_goal(_, true, true) :- !.
actor_query_goal(_, fail, fail) :- !.
actor_query_goal(_, repeat, repeat) :- !.
actor_query_goal(_, between(Low, High, Value),
                 sandbox_policy:sandbox_between(Low, High, Value)) :- !.
actor_query_goal(_, Goal, sandbox_policy:sandbox_builtin_call(Goal)) :-
    nonvar(Goal),
    functor(Goal, Name, Arity),
    actor_direct_builtin_pi(Name/Arity),
    !.
actor_query_goal(Module, Goal, isolation:call_actor_leaf(Module, Goal)).

actor_builtin_goal(Goal) :-
    nonvar(Goal),
    functor(Goal, Name, Arity),
    actor_direct_builtin_pi(Name/Arity).

call_actor_leaf(Module, Goal) :-
    call_in_module(Module, '$actor_call'(Goal)).

actor_identical(Left, Right) :-
    Left == Right.

actor_not_identical(Left, Right) :-
    Left \== Right.

actor_if_choice(Condition, then) :-
    call(Condition),
    !.
actor_if_choice(_, else).

actor_direct_builtin_pi((=)/2). actor_direct_builtin_pi((\=)/2).
actor_direct_builtin_pi((==)/2). actor_direct_builtin_pi((\==)/2).
actor_direct_builtin_pi(true/0). actor_direct_builtin_pi(fail/0).
actor_direct_builtin_pi(repeat/0).
actor_direct_builtin_pi((@<)/2). actor_direct_builtin_pi((@=<)/2).
actor_direct_builtin_pi((@>)/2). actor_direct_builtin_pi((@>=)/2).
actor_direct_builtin_pi(compare/3). actor_direct_builtin_pi(var/1).
actor_direct_builtin_pi(nonvar/1). actor_direct_builtin_pi(atom/1).
actor_direct_builtin_pi(integer/1). actor_direct_builtin_pi(float/1).
actor_direct_builtin_pi(number/1). actor_direct_builtin_pi(atomic/1).
actor_direct_builtin_pi(compound/1). actor_direct_builtin_pi(callable/1).
actor_direct_builtin_pi(ground/1). actor_direct_builtin_pi(acyclic_term/1).
actor_direct_builtin_pi(functor/3). actor_direct_builtin_pi(arg/3).
actor_direct_builtin_pi((=..)/2). actor_direct_builtin_pi(copy_term/2).
actor_direct_builtin_pi(numbervars/3). actor_direct_builtin_pi(term_variables/2).
actor_direct_builtin_pi(term_hash/2). actor_direct_builtin_pi((is)/2).
actor_direct_builtin_pi((=:=)/2). actor_direct_builtin_pi((=\=)/2).
actor_direct_builtin_pi((<)/2). actor_direct_builtin_pi((=<)/2).
actor_direct_builtin_pi((>)/2). actor_direct_builtin_pi((>=)/2).
actor_direct_builtin_pi(between/3). actor_direct_builtin_pi(succ/2).
actor_direct_builtin_pi(length/2). actor_direct_builtin_pi(member/2).
actor_direct_builtin_pi(memberchk/2). actor_direct_builtin_pi(append/3).
actor_direct_builtin_pi(reverse/2). actor_direct_builtin_pi(select/3).
actor_direct_builtin_pi(nth0/3). actor_direct_builtin_pi(nth1/3).
actor_direct_builtin_pi(sort/2). actor_direct_builtin_pi(msort/2).
actor_direct_builtin_pi(keysort/2). actor_direct_builtin_pi(atom_length/2).
actor_direct_builtin_pi(atom_concat/3). actor_direct_builtin_pi(sub_atom/5).
actor_direct_builtin_pi(atom_chars/2). actor_direct_builtin_pi(atom_codes/2).
actor_direct_builtin_pi(char_code/2). actor_direct_builtin_pi(number_chars/2).
actor_direct_builtin_pi(number_codes/2). actor_direct_builtin_pi(atom_number/2).
actor_direct_builtin_pi(atomic_list_concat/2).
actor_direct_builtin_pi(atomic_list_concat/3).
actor_direct_builtin_pi(read_term_from_atom/3).
actor_direct_builtin_pi(random_between/3).


                /*******************************
                *        SOURCE OPTIONS       *
                *******************************/

source_options([], []).
source_options([Option|Options], Sources) :-
    ( source_option(Option)
    -> Sources = [Option|Rest]
    ; Option = src_uri(URI)
    -> throw(error(permission_error(load, source_uri, URI),
                   context(isolation:prepare_actor/4,
                           'src_uri/1 must be materialized by source_policy before isolation')))
    ; Sources = Rest
    ),
    source_options(Options, Rest).

source_option(src_text(Text)) :-
    text_source(Text),
    !.
source_option(src_text(Text)) :-
    throw(error(type_error(text, Text), src_text/1)).
source_option(src_list(Terms)) :-
    must_be(list, Terms),
    !.
source_option(src_predicates(PIs)) :-
    throw(error(domain_error(rewritten_source_option, src_predicates(PIs)),
                isolation:prepare_actor/4)).

text_source(Text) :- atom(Text), !.
text_source(Text) :- string(Text), !.
text_source(Text) :- is_list(Text).

rewrite_source_options([], _, []).
rewrite_source_options([src_uri(URI)|Options], Module,
                       [src_text(Text)|Rewritten]) :-
    !,
    fetch_source_uri(URI, Text),
    rewrite_source_options(Options, Module, Rewritten).
rewrite_source_options([src_predicates(PIs)|Options], Module0,
                       [src_list(Terms)|Rewritten]) :-
    !,
    source_module(Module0, Module),
    predicates_to_terms(Module, PIs, Terms),
    rewrite_source_options(Options, Module0, Rewritten).
rewrite_source_options([Option|Options], Module, [Option|Rewritten]) :-
    rewrite_source_options(Options, Module, Rewritten).

%!  load_options_text(+SourceModule, +Options, -Text) is det.
%
%   Materialize RPC src_* options into the single src_text query parameter
%   understood by Web Prolog's HTTP endpoint.  This mirrors the SWI client:
%   list and predicate sources are serialized locally, while src_uri is
%   fetched under the node's configured source policy before being shipped.

load_options_text(Module, Options, Text) :-
    load_option_parts(Options, Module, Parts),
    append_source_parts(Parts, '', Text).

load_option_parts([], _, []).
load_option_parts([Option|Options], Module, Parts) :-
    ( load_option_text(Option, Module, Text)
    -> Parts = [Text|Rest]
    ; Parts = Rest
    ),
    load_option_parts(Options, Module, Rest).

load_option_text(src_text(Text0), _, Text) :- !,
    source_text_atom(Text0, Text).
load_option_text(src_list(Terms), _, Text) :- !,
    source_terms_text(Terms, Text).
load_option_text(src_predicates(PIs), Module, Text) :- !,
    rewrite_source_options([src_predicates(PIs)], Module, [src_list(Terms)]),
    source_terms_text(Terms, Text).
load_option_text(src_uri(URI), _, Text) :- !,
    fetch_source_uri(URI, Text).

source_text_atom(Text, Text) :- atom(Text), !.
source_text_atom(Text, Atom) :- string(Text), !, atom_chars(Atom, Text).
source_text_atom(Text, Atom) :- is_list(Text), !,
    ( Text = [C|_], integer(C) -> atom_codes(Atom, Text)
    ; atom_chars(Atom, Text)
    ).
source_text_atom(Text, _) :-
    throw(error(type_error(text, Text), src_text/1)).

source_terms_text(Terms, Text) :-
    must_be(list, Terms),
    source_terms_text_(Terms, '', Text).

source_terms_text_([], Text, Text).
source_terms_text_([Term|Terms], Acc, Text) :-
    format(atom(Line), '~q.~n', [Term]),
    atom_concat(Acc, Line, Next),
    source_terms_text_(Terms, Next, Text).

append_source_parts([], Text, Text).
append_source_parts([Part|Parts], Acc, Text) :-
    ( Acc == '' -> Next = Part
    ; Part == '' -> Next = Acc
    ; atom_concat(Acc, '\n', Prefix), atom_concat(Prefix, Part, Next)
    ),
    append_source_parts(Parts, Next, Text).

source_module(Module, user) :- var(Module), !.
source_module(Module, Module).

predicates_to_terms(Module, PIs, Terms) :-
    must_be(list, PIs),
    maplist(valid_source_predicate_indicator, PIs),
    actor_namespace(_, Module),
    !,
    call_in_module(Module, '$actor_copy_predicates'(PIs, Terms)).
predicates_to_terms(Module, PIs, Terms) :-
    must_be(list, PIs),
    maplist(valid_source_predicate_indicator, PIs),
    actors:make_ref(Id),
    with_mutex('$isolation_listing',
               listed_predicate_terms(Module, Id, PIs, Terms)).

valid_source_predicate_indicator(PI) :-
    source_predicate_indicator(PI, _, _).

listed_predicate_terms(Module, Id, PIs, Terms) :-
    fresh_listing_file(Id, File),
    setup_call_cleanup(
        true,
        ( write_predicate_listings(File, Module, PIs),
          read_source_terms(File, Terms)
        ),
        catch(delete_file(File), _, true)).

fresh_listing_file(Id, File) :-
    random_between(1000000000, 9999999999, Random),
    format(atom(Candidate), '/tmp/trealla-listing-~w-~w.pl', [Random, Id]),
    ( exists_file(Candidate)
    -> fresh_listing_file(Id, File)
    ; File = Candidate
    ).

write_predicate_listings(File, Module, PIs) :-
    setup_call_cleanup(
        open(File, write, Out),
        setup_call_cleanup(
            ( current_output(Previous), set_output(Out) ),
            write_predicate_listings_(PIs, Module),
            set_output(Previous)),
        close(Out)).

write_predicate_listings_([], _).
write_predicate_listings_([PI|PIs], Module) :-
    listing(Module:PI),
    write_predicate_listings_(PIs, Module).

read_source_terms(File, Terms) :-
    setup_call_cleanup(
        open(File, read, In),
        read_source_terms_(In, Terms),
        close(In)).

read_source_terms_(In, Terms) :-
    read_term(In, Term, []),
    ( Term == end_of_file
    -> Terms = []
    ; Terms = [Term|Rest],
      read_source_terms_(In, Rest)
    ).

% Validate the complete declaration before installing any source ownership.
discontiguous_pis(Decl, PIs) :-
    must_be(nonvar, Decl),
    ( Decl = (A,B)
    -> discontiguous_pis(A, Left), discontiguous_pis(B, Right),
       append(Left, Right, PIs)
    ; source_predicate_indicator(Decl, _, _), PIs = [Decl]
    ).

source_predicate_indicator(PI, Name, Arity) :-
    must_be(nonvar, PI),
    ( PI = Name/Arity,
      atom(Name), integer(Arity), Arity >= 0
    -> true
    ; throw(error(type_error(predicate_indicator, PI), src_predicates/1))
    ).

                /*******************************
                *       MODULE BOOTSTRAP       *
                *******************************/

fresh_namespace(Module) :-
    actors:make_ref(Id),
    format(atom(Module), '$trealla_actor_~w', [Id]).

bootstrap_text(Module, Text) :-
    actors_library_file(ActorsFile),
    toplevel_library_file(ToplevelFile),
    sandbox_library_file(SandboxFile),
    rpc_library_file(RpcFile),
    parallel_library_file(ParallelFile),
    server_actor_library_file(ServerActorFile),
    supervisor_actor_library_file(SupervisorActorFile),
    phrase(bootstrap_lines(Module, ActorsFile, ToplevelFile,
                           SandboxFile, RpcFile, ParallelFile,
                           ServerActorFile, SupervisorActorFile), Lines),
    atomic_list_concat(Lines, Text).

minimal_bootstrap_text(_Module, Text) :-
    actors_library_file(ActorsFile),
    actor_api_library_file(ActorApiFile),
    format(atom(Text),
           ':- use_module(~q).~n:- use_module(~q).~n\'$actor_call\'(Goal) :- call(Goal).~n',
           [ActorsFile, ActorApiFile]).

% Each fragment is formatted into a query-local atom. Trealla's
% with_output_to/2 captures the shared current-output stream across threads.
bootstrap_line(Format, Args) -->
    { format(atom(Line), Format, Args) },
    [Line].

bootstrap_lines(Module, ActorsFile, ToplevelFile,
                SandboxFile, RpcFile, ParallelFile, ServerActorFile,
                SupervisorActorFile) -->
    bootstrap_line( '%% SPDX-License-Identifier: MIT~n', []),
    { absolute_file_name('statechart_actor.pl',StatechartFile,[]) },
    bootstrap_line( ':- use_module(~q).~n',[StatechartFile]),
    bootstrap_line( ':- use_module(~q).~n', [ActorsFile]),
    bootstrap_line( ':- use_module(~q, [toplevel_spawn/1,toplevel_spawn/2,toplevel_call/2,toplevel_call/3,toplevel_call_synch/3,toplevel_call_synch/4,toplevel_next_synch/2,toplevel_next_synch/3,toplevel_next/1,toplevel_next/2,toplevel_halt/1,toplevel_halt/2,toplevel_stop/1,toplevel_abort/1]).~n', [ToplevelFile]),
    bootstrap_line( ':- use_module(~q, [rpc/2,rpc/3,promise/3,promise/4,promise_cleanup/1,yield/2,yield/3,runtime_property/1]).~n', [RpcFile]),
    bootstrap_line( ':- use_module(~q, [server_spawn/3,server_spawn/4,server_request/3,server_request/4,server_promise/3,server_promise/4,server_yield/2,server_yield/3,server_yield/4,server_upgrade/2,server_upgrade/3,server_halt/2,server_stop/2]).~n', [ServerActorFile]),
    bootstrap_line( ':- use_module(~q, [supervisor_spawn/2,supervisor_spawn/3,supervisor_spawn_child/3,supervisor_terminate_child/3,supervisor_delete_child/3,supervisor_respawn_child/3,supervisor_which_children/2,supervisor_count_children/2,supervisor_halt/1,supervisor_stop/1]).~n', [SupervisorActorFile]),
    bootstrap_line( ':- use_module(~q, []).~n', [ParallelFile]),
    bootstrap_line( 'parallel(Goals) :- parallel:parallel_in(~q,Goals).~n', [Module]),
    bootstrap_line( 'first_solution(Solution,Goals) :- parallel:first_solution_in(~q,Solution,Goals,[on_fail(continue),on_error(stop)]).~n', [Module]),
    bootstrap_line( 'first_solution(Solution,Goals,Options) :- parallel:first_solution_in(~q,Solution,Goals,Options).~n', [Module]),
    bootstrap_line( ':- use_module(~q, [sandbox_call/5,sandbox_call/6,sandbox_call/7,sandbox_call/8,sandbox_call/9,sandbox_call/10,sandbox_call/11,sandbox_call/12,sandbox_spawn/7,sandbox_toplevel_call/7,sandbox_toplevel_synch/9,sandbox_control_catch/4,sandbox_format/2,sandbox_sleep/1,sandbox_between/3,sandbox_atom_string/2,sandbox_clause/6,sandbox_assert/5,sandbox_assert/6,sandbox_asserta/5,sandbox_asserta/6,sandbox_assertz/5,sandbox_assertz/6,sandbox_retract/5,sandbox_retractall/5,sandbox_abolish/5,sandbox_abolish/6]).~n', [SandboxFile]),
    bootstrap_line( ':- dynamic \'$actor_source_pi\'/1.~n', []),
    bootstrap_line( ':- dynamic \'$actor_dynamic_pi\'/1.~n', []),
    bootstrap_line( ':- dynamic \'$actor_discontiguous_pi\'/1.~n', []),
    bootstrap_line( ':- dynamic \'$actor_shared_pi\'/1.~n', []),
    bootstrap_line( ':- dynamic \'$actor_loading_shared\'/0.~n', []),
    bootstrap_line( '\'$actor_load_shared\'(Text) :- setup_call_cleanup(assertz(\'$actor_loading_shared\'), \'$actor_text\'(Text), retractall(\'$actor_loading_shared\')).~n', []),
    bootstrap_line( '\'$actor_load\'([]).~n', []),
    bootstrap_line( '\'$actor_load\'([src_text(Text)|Rest]) :- !, \'$actor_text\'(Text), \'$actor_load\'(Rest).~n', []),
    bootstrap_line( '\'$actor_load\'([src_list(Terms)|Rest]) :- !, \'$actor_terms\'(Terms), \'$actor_load\'(Rest).~n', []),
    bootstrap_line( '\'$actor_load\'([Bad|_]) :- throw(error(domain_error(source_option, Bad), \'$actor_load\'/1)).~n', []),
    bootstrap_line( '\'$actor_text\'(Text0) :- \'$actor_source_atom\'(Text0, Text), open_string(Text, In), setup_call_cleanup(true, \'$actor_read\'(In), close(In)).~n', []),
    bootstrap_line( '\'$actor_source_atom\'(Text, Text) :- atom(Text), !.~n', []),
    bootstrap_line( '\'$actor_source_atom\'(Text, Atom) :- string(Text), !, atom_chars(Atom, Text).~n', []),
    bootstrap_line( '\'$actor_source_atom\'(Text, Atom) :- Text = [C|_], integer(C), !, atom_codes(Atom, Text).~n', []),
    bootstrap_line( '\'$actor_source_atom\'(Text, Atom) :- atom_chars(Atom, Text).~n', []),
    bootstrap_line( '\'$actor_read\'(In) :- read_term(In, Term, []), ( Term == end_of_file -> true ; \'$actor_term\'(Term), \'$actor_read\'(In) ).~n', []),
    bootstrap_line( '\'$actor_terms\'([]).~n', []),
    bootstrap_line( '\'$actor_terms\'([Term|Terms]) :- \'$actor_term\'(Term), \'$actor_terms\'(Terms).~n', []),
    bootstrap_line( '\'$actor_term\'(Term0) :- expand_term(Term0, Term1), \'$actor_qualify_source\'(Term1, Term), \'$actor_expanded\'(Term).~n', []),
    bootstrap_line( '\'$actor_qualify_source\'([], []) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_source\'([Term0|Terms0], [Term|Terms]) :- !, \'$actor_qualify_source\'(Term0, Term), \'$actor_qualify_source\'(Terms0, Terms).~n', []),
    bootstrap_line( '\'$actor_qualify_source\'((Head :- Body0), (Head :- Body)) :- !, \'$actor_qualify_goal\'(Body0, Body).~n', []),
    bootstrap_line( '\'$actor_qualify_source\'(Term, Term).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'((A0,B0), (A,B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'((A0;B0), (A;B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'((A0->B0), (A->B)) :- !, \'$actor_qualify_goal\'(A0,A), \'$actor_qualify_goal\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'((\\+ A0), (\\+ A)) :- !, \'$actor_qualify_goal\'(A0,A).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(between(Low,High,Value), sandbox_policy:sandbox_between(Low,High,Value)) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(sandbox_policy:sandbox_spawn(M,P,C,A,Goal0,Pid,Options), \'$actor_sandbox_spawn\'(M,P,C,A,Goal,Pid,Options)) :- !, \'$actor_qualify_goal\'(Goal0,Goal).~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(toplevel_spawn(Pid), \'$actor_toplevel_spawn\'(Pid,[])) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(toplevel_spawn(Pid,Options), \'$actor_toplevel_spawn\'(Pid,Options)) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(supervisor_spawn(Specs,Pid), supervisor_actor:supervisor_spawn(~q:Specs,Pid)) :- !.~n', [Module]),
    bootstrap_line( '\'$actor_qualify_goal\'(supervisor_spawn(Specs,Pid,Options), supervisor_actor:supervisor_spawn(~q:Specs,Pid,Options)) :- !.~n', [Module]),
    bootstrap_line( '\'$actor_qualify_goal\'(supervisor_spawn_child(Sup,Spec,Reply), supervisor_actor:supervisor_spawn_child(Sup,~q:Spec,Reply)) :- !.~n', [Module]),
    % A clause-set variable is qualified when its value is available, in the
    % receiving actor's module. The local bridge also survives source copying.
    bootstrap_line( '\'$actor_qualify_goal\'(receive(Clauses), \'$actor_receive\'(Clauses,[])) :- var(Clauses), !.~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(receive(Clauses,Options), \'$actor_receive\'(Clauses,Options)) :- var(Clauses), !.~n', []),
    bootstrap_line( '\'$actor_receive\'(Clauses0,Options0) :- \'$actor_qualify_receive\'(Clauses0,Clauses), \'$actor_qualify_receive_options\'(Options0,Options), actors:receive_qualified(~q:Clauses,Options).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_goal\'(receive({}), actors:receive_empty) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_goal\'(receive(Clauses0), receive(~q:Clauses)) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_goal\'(receive(Clauses0,Options0), receive(~q:Clauses,Options)) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses), \'$actor_qualify_receive_options\'(Options0,Options).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_goal\'(Goal, Goal).~n', []),
    bootstrap_line( '\'$actor_qualify_receive\'(Clauses, Clauses) :- var(Clauses), !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive\'({Clauses0}, {Clauses}) :- !, \'$actor_qualify_receive\'(Clauses0, Clauses).~n', []),
    bootstrap_line( '\'$actor_qualify_receive\'((A0;B0), (A;B)) :- !, \'$actor_qualify_receive\'(A0,A), \'$actor_qualify_receive\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive\'((Head0->Body0), (Head->Body)) :- !, \'$actor_qualify_receive_head\'(Head0,Head), \'$actor_qualify_receive_body\'(Body0,Body).~n', []),
    bootstrap_line( '\'$actor_qualify_receive\'(Clause, Clause).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_head\'(Head0, Head) :- nonvar(Head0), Head0 = if(Pattern,Guard0), !, Head = if(Pattern,Guard), \'$actor_qualify_receive_guard\'(Guard0,Guard).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_head\'(Head, Head).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'((A0,B0), (A,B)) :- !, \'$actor_qualify_receive_guard\'(A0,A), \'$actor_qualify_receive_guard\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'((A0;B0), (A;B)) :- !, \'$actor_qualify_receive_guard\'(A0,A), \'$actor_qualify_receive_guard\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'((A0->B0), (A->B)) :- !, \'$actor_qualify_receive_guard\'(A0,A), \'$actor_qualify_receive_guard\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'((\\+ A0), (\\+ A)) :- !, \'$actor_qualify_receive_guard\'(A0,A).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'(Qualified:Goal, Qualified:Goal) :- atom(Qualified), !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'(between(Low,High,Value), sandbox_policy:sandbox_between(Low,High,Value)) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'(Goal, sandbox_policy:sandbox_builtin_call(Goal)) :- isolation:actor_builtin_goal(Goal), !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_guard\'(Goal, ~q:Goal).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_receive_options\'(Options, Options) :- var(Options), !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_options\'([], []) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_options\'([on_timeout(Goal0)|Options0], [on_timeout(Goal)|Options]) :- !, \'$actor_qualify_receive_body\'(Goal0,Goal), \'$actor_qualify_receive_options\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_options\'([Option|Options0], [Option|Options]) :- \'$actor_qualify_receive_options\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'((A0,B0), (A,B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'((A0;B0), (A;B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'((A0->B0), (A->B)) :- !, \'$actor_qualify_receive_body\'(A0,A), \'$actor_qualify_receive_body\'(B0,B).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'((\\+ A0), (\\+ A)) :- !, \'$actor_qualify_receive_body\'(A0,A).~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'(Qualified:Goal, Qualified:Goal) :- atom(Qualified), !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'(receive(Clauses0), actors:receive(~q:Clauses)) :- !, \'$actor_qualify_receive\'(Clauses0,Clauses).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_receive_body\'(receive(Clauses0,Options0), actors:receive(~q:Clauses,Options)) :- !, \'$actor_qualify_receive\'(Clauses0,Clauses), \'$actor_qualify_receive_options\'(Options0,Options).~n', [Module]),
    bootstrap_line( '\'$actor_qualify_receive_body\'(between(Low,High,Value), sandbox_policy:sandbox_between(Low,High,Value)) :- !.~n', []),
    bootstrap_line( '\'$actor_qualify_receive_body\'(Goal, ~q:Goal).~n', [Module]),
    bootstrap_line( '\'$actor_expanded\'([]) :- !.~n', []),
    bootstrap_line( '\'$actor_expanded\'([Term|Terms]) :- !, \'$actor_expanded\'(Term), \'$actor_expanded\'(Terms).~n', []),
    bootstrap_line( '\'$actor_expanded\'((:- module(Name, Exports))) :- !, throw(error(permission_error(load, module, module(Name, Exports)), \'$actor_load\'/1)).~n', []),
    % Clauses are installed with assertz/1 and are therefore mutable already.
    % Handle dynamic/discontiguous directives while loading, rather than as
    % ordinary goals. Retain their metadata and create an empty predicate by
    % asserting/erasing a private temporary clause before actor startup.
    % Merely remembering the PI leaves a call to an empty predicate undefined.
    bootstrap_line( '\'$actor_expanded\'((:- dynamic(PI))) :- !, \'$actor_remember_pi\'(PI), \'$actor_remember_dynamic_pi\'(PI).~n', []),
    bootstrap_line( '\'$actor_expanded\'((:- discontiguous(PI))) :- !, isolation:discontiguous_pis(PI,PIs), maplist(\'$actor_remember_pi\',PIs), maplist(\'$actor_remember_discontiguous_pi\',PIs).~n', []),
    bootstrap_line( '\'$actor_expanded\'((:- Directive)) :- !, call(Directive).~n', []),
    bootstrap_line( '\'$actor_expanded\'((Head :- Body)) :- !, \'$actor_remember\'(Head), assertz((Head :- Body)).~n', []),
    bootstrap_line( '\'$actor_expanded\'(Head) :- \'$actor_remember\'(Head), assertz(Head).~n', []),
    bootstrap_line( '\'$actor_remember\'(Head) :- callable(Head), functor(Head, Name, Arity), PI = Name/Arity, \'$actor_prepare_pi\'(PI,Head).~n', []),
    bootstrap_line( '\'$actor_remember_pi\'((A,B)) :- !, \'$actor_remember_pi\'(A), \'$actor_remember_pi\'(B).~n', []),
    bootstrap_line( '\'$actor_remember_pi\'(Name/Arity) :- functor(Head,Name,Arity), \'$actor_prepare_pi\'(Name/Arity,Head).~n', []),
    bootstrap_line( '\'$actor_prepare_pi\'(PI,_Head) :- \'$actor_loading_shared\', !, ( \'$actor_source_pi\'(PI) -> true ; assertz(\'$actor_source_pi\'(PI)) ), ( \'$actor_shared_pi\'(PI) -> true ; assertz(\'$actor_shared_pi\'(PI)) ).~n', []),
    bootstrap_line( '\'$actor_prepare_pi\'(Name/Arity,_Head) :- PI = Name/Arity, ( retract(\'$actor_shared_pi\'(PI)) -> functor(SharedHead,Name,Arity), retractall(SharedHead) ; true ), ( \'$actor_source_pi\'(PI) -> true ; assertz(\'$actor_source_pi\'(PI)) ).~n', []),
    bootstrap_line( '\'$actor_remember_dynamic_pi\'((A,B)) :- !, \'$actor_remember_dynamic_pi\'(A), \'$actor_remember_dynamic_pi\'(B).~n', []),
    bootstrap_line( '\'$actor_remember_dynamic_pi\'(PI) :- ( \'$actor_dynamic_pi\'(PI) -> true ; assertz(\'$actor_dynamic_pi\'(PI)) ), \'$actor_ensure_empty_pi\'(PI).~n', []),
    bootstrap_line( '\'$actor_remember_discontiguous_pi\'((A,B)) :- !, \'$actor_remember_discontiguous_pi\'(A), \'$actor_remember_discontiguous_pi\'(B).~n', []),
    bootstrap_line( '\'$actor_remember_discontiguous_pi\'(PI) :- ( \'$actor_discontiguous_pi\'(PI) -> true ; assertz(\'$actor_discontiguous_pi\'(PI)) ), \'$actor_ensure_empty_pi\'(PI).~n', []),
    bootstrap_line( '\'$actor_ensure_empty_pi\'(Name/Arity) :- functor(Head,Name,Arity), setup_call_cleanup(assertz(Head,Ref),true,erase(Ref)).~n', []),
    % Trealla does not preserve imports when an arbitrary term is passed
    % through call/1 here. Route the flat Web Prolog surface explicitly,
    % matching the actor_api re-export used by the SWI implementation.
    bootstrap_line( '\'$actor_call\'(sandbox_policy:sandbox_toplevel_call(M,P,C,A,Pid,Goal,Options)) :- !, sandbox_policy:sandbox_toplevel_call(M,P,C,A,Pid,Goal,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(sandbox_toplevel_call(M,P,C,A,Pid,Goal,Options)) :- !, sandbox_policy:sandbox_toplevel_call(M,P,C,A,Pid,Goal,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_spawn(Pid)) :- !, toplevel_actors:toplevel_spawn(Pid).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_spawn(Pid,Options0)) :- !, \'$actor_materialize_source_predicates\'(Options0,Options), toplevel_actors:toplevel_spawn(Pid,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_next(Pid)) :- !, toplevel_actors:toplevel_next(Pid).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_next(Pid,Options)) :- !, toplevel_actors:toplevel_next(Pid,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_halt(Pid)) :- !, toplevel_actors:toplevel_halt(Pid).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_halt(Pid,Wait)) :- !, toplevel_actors:toplevel_halt(Pid,Wait).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_stop(Pid)) :- !, toplevel_actors:toplevel_stop(Pid).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_abort(Pid)) :- !, toplevel_actors:toplevel_abort(Pid).~n', []),
    bootstrap_line( '\'$actor_call\'(toplevel_call_synch(P,G,A)) :- !, toplevel_actors:toplevel_call_synch(P,~q:G,A,~q:[]).~n', [Module,Module]),
    bootstrap_line( '\'$actor_call\'(toplevel_call_synch(P,G,A,O)) :- !, toplevel_actors:toplevel_call_synch(P,~q:G,A,~q:O).~n', [Module,Module]),
    bootstrap_line( '\'$actor_call\'(toplevel_next_synch(P,A)) :- !, toplevel_actors:toplevel_next_synch(P,A,~q:[]).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(toplevel_next_synch(P,A,O)) :- !, toplevel_actors:toplevel_next_synch(P,A,~q:O).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(runtime_property(Property)) :- !, rpc:runtime_property(Property).~n', []),
    bootstrap_line( '\'$actor_call\'(rpc(URI,Goal)) :- !, rpc:rpc(URI,Goal).~n', []),
    bootstrap_line( '\'$actor_call\'(rpc(URI,Goal,Options)) :- !, rpc:rpc(URI,Goal,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(promise(URI,Goal,Reference)) :- !, rpc:promise(URI,Goal,Reference).~n', []),
    bootstrap_line( '\'$actor_call\'(promise(URI,Goal,Reference,Options)) :- !, rpc:promise(URI,Goal,Reference,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(yield(Reference,Answer)) :- !, rpc:yield(Reference,Answer).~n', []),
    bootstrap_line( '\'$actor_call\'(yield(Reference,Answer,Options)) :- !, rpc:yield(Reference,Answer,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(promise_cleanup(Reference)) :- !, rpc:promise_cleanup(Reference).~n', []),
    bootstrap_line( '\'$actor_call\'(server_spawn(Callback,State,Pid)) :- !, server_actor:server_spawn(~q:Callback,State,Pid).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(server_spawn(Callback,State,Pid,Options)) :- !, server_actor:server_spawn(~q:Callback,State,Pid,Options).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(server_request(To,Request,Response)) :- !, server_actor:server_request(To,Request,Response).~n', []),
    bootstrap_line( '\'$actor_call\'(server_request(To,Request,Response,Options)) :- !, server_actor:server_request(To,Request,Response,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(server_promise(To,Request,Ref)) :- !, server_actor:server_promise(To,Request,Ref).~n', []),
    bootstrap_line( '\'$actor_call\'(server_promise(To,Request,Ref,MonitorRef)) :- !, server_actor:server_promise(To,Request,Ref,MonitorRef).~n', []),
    bootstrap_line( '\'$actor_call\'(server_yield(Ref,Response)) :- !, server_actor:server_yield(Ref,Response).~n', []),
    bootstrap_line( '\'$actor_call\'(server_yield(Ref,Response,Options)) :- !, server_actor:server_yield(Ref,Response,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(server_yield(Ref,MonitorRef,Response,Options)) :- !, server_actor:server_yield(Ref,MonitorRef,Response,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(server_upgrade(To,Callback)) :- !, server_actor:server_upgrade(To,~q:Callback).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(server_upgrade(To,Callback,Options)) :- !, server_actor:server_upgrade(To,~q:Callback,Options).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(server_halt(To,Reply)) :- !, server_actor:server_halt(To,Reply).~n', []),
    bootstrap_line( '\'$actor_call\'(server_stop(To,Reply)) :- !, server_actor:server_stop(To,Reply).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_spawn(Specs,Pid)) :- !, supervisor_actor:supervisor_spawn(~q:Specs,Pid).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(supervisor_spawn(Specs,Pid,Options)) :- !, supervisor_actor:supervisor_spawn(~q:Specs,Pid,Options).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(supervisor_spawn_child(Sup,Spec,Reply)) :- !, supervisor_actor:supervisor_spawn_child(Sup,~q:Spec,Reply).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(supervisor_terminate_child(Sup,Id,Reply)) :- !, supervisor_actor:supervisor_terminate_child(Sup,Id,Reply).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_delete_child(Sup,Id,Reply)) :- !, supervisor_actor:supervisor_delete_child(Sup,Id,Reply).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_respawn_child(Sup,Id,Reply)) :- !, supervisor_actor:supervisor_respawn_child(Sup,Id,Reply).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_which_children(Sup,Children)) :- !, supervisor_actor:supervisor_which_children(Sup,Children).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_count_children(Sup,Counts)) :- !, supervisor_actor:supervisor_count_children(Sup,Counts).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_halt(Sup)) :- !, supervisor_actor:supervisor_halt(Sup).~n', []),
    bootstrap_line( '\'$actor_call\'(supervisor_stop(Sup)) :- !, supervisor_actor:supervisor_stop(Sup).~n', []),
    bootstrap_line( '\'$actor_call\'(sandbox_policy:sandbox_spawn(M,P,C,A,Goal,Pid,Options)) :- !, \'$actor_sandbox_spawn\'(M,P,C,A,Goal,Pid,Options).~n', []),
    bootstrap_line( '\'$actor_call\'(receive({})) :- !, actors:receive_empty.~n', []),
    bootstrap_line( '\'$actor_call\'(parallel(Goals)) :- !, parallel:parallel_in(~q,Goals).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(first_solution(Solution,Goals)) :- !, parallel:first_solution_in(~q,Solution,Goals,[on_fail(continue),on_error(stop)]).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(first_solution(Solution,Goals,Options)) :- !, parallel:first_solution_in(~q,Solution,Goals,Options).~n', [Module]),
    bootstrap_line( '\'$actor_call\'(Goal) :- call(Goal).~n', []),
    bootstrap_line( '\'$actor_materialize_source_predicates\'([], []).~n', []),
    bootstrap_line( '\'$actor_materialize_source_predicates\'([src_predicates(PIs)|Options0], [src_list(Terms)|Options]) :- !, \'$actor_copy_predicates\'(PIs,Terms), \'$actor_materialize_source_predicates\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_materialize_source_predicates\'([Option|Options0], [Option|Options]) :- \'$actor_materialize_source_predicates\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_sandbox_spawn\'(M,P,C,A,Goal,Pid,Options0) :- \'$actor_materialize_source_predicates\'(Options0,Options), sandbox_policy:sandbox_spawn(M,P,C,A,Goal,Pid,Options).~n', []),
    bootstrap_line( '\'$actor_toplevel_spawn\'(Pid,Options0) :- \'$actor_materialize_source_predicates\'(Options0,Options), toplevel_actors:toplevel_spawn(Pid,Options).~n', []),
    bootstrap_line( '\'$actor_copy_predicates\'([], []).~n', []),
    bootstrap_line( '\'$actor_copy_predicates\'([Name/Arity|PIs], Terms) :- PI = Name/Arity, \'$actor_source_pi\'(PI), !, functor(Head,Name,Arity), \'$actor_dynamic_terms\'(PI,Declarations), findall(Term, (clause(Head,Body0), \'$actor_strip_source_module\'(Body0,Body), \'$actor_clause_term\'(Head,Body,Term)), Here), append(Declarations,Here,Current), \'$actor_copy_predicates\'(PIs,Rest), append(Current,Rest,Terms).~n', []),
    bootstrap_line( '\'$actor_copy_predicates\'([PI|_], _) :- throw(error(existence_error(procedure,PI), src_predicates/1)).~n', []),
    bootstrap_line( '\'$actor_dynamic_terms\'(PI, Terms) :- ( \'$actor_dynamic_pi\'(PI) -> Dynamic=[(:- dynamic(PI))] ; Dynamic=[] ), ( \'$actor_discontiguous_pi\'(PI) -> append(Dynamic,[(:- discontiguous(PI))],Terms) ; Terms=Dynamic ).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(Term, Term) :- var(Term), !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_clause(_M,_P,_C,_A,Head0,Body0), clause(Head,Body)) :- !, \'$actor_strip_source_module\'(Head0,Head), \'$actor_strip_source_module\'(Body0,Body).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_sleep(Seconds), sleep(Seconds)) :- !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_atom_string(Atom,String), atom_string(Atom,String)) :- !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_random_member(Element,List), random_member(Element,List)) :- !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_time(_Context,Goal0), time(Goal)) :- !, \'$actor_strip_source_module\'(Goal0,Goal).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:Call0, Call) :- nonvar(Call0), functor(Call0,sandbox_call,Arity), Arity >= 5, Arity =< 12, !, Call0 =.. [sandbox_call,_M,_P,_C,_A,Closure0|Extra0], \'$actor_strip_source_module\'(Closure0,Closure), \'$actor_strip_source_args\'(Extra0,Extra), Call =.. [call,Closure|Extra].~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_toplevel_synch(_M,_P,_C,_A,call,Pid,G0,R,O0), toplevel_call_synch(Pid,G,R,O)) :- !, \'$actor_strip_source_module\'(G0,G), \'$actor_strip_source_module\'(O0,O).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_toplevel_synch(_M,_P,_C,_A,next,Pid,_G,R,O0), toplevel_next_synch(Pid,R,O)) :- !, \'$actor_strip_source_module\'(O0,O).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_yield(_M,_P,_C,_A,R,A,O0), yield(R,A,O)) :- !, \'$actor_strip_source_module\'(O0,O).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_control_catch(_Module,Goal0,Catcher,Recover0), catch(Goal,Catcher,Recover)) :- !, \'$actor_strip_source_module\'(Goal0,Goal), \'$actor_strip_source_module\'(Recover0,Recover).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(actors:receive_empty, receive({})) :- !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(\'$actor_sandbox_spawn\'(_M,_P,_C,_A,Goal0,Pid,Options0), spawn(Goal,Pid,Options)) :- !, \'$actor_strip_source_module\'(Goal0,Goal), \'$actor_strip_source_module\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(\'$actor_toplevel_spawn\'(Pid,Options0), toplevel_spawn(Pid,Options)) :- !, \'$actor_strip_source_module\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(supervisor_actor:supervisor_spawn(_Source:Specs0,Pid), supervisor_spawn(Specs,Pid)) :- !, \'$actor_strip_source_module\'(Specs0,Specs).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(supervisor_actor:supervisor_spawn(_Source:Specs0,Pid,Options0), supervisor_spawn(Specs,Pid,Options)) :- !, \'$actor_strip_source_module\'(Specs0,Specs), \'$actor_strip_source_module\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(supervisor_actor:supervisor_spawn_child(Sup,_Source:Spec0,Reply), supervisor_spawn_child(Sup,Spec,Reply)) :- !, \'$actor_strip_source_module\'(Spec0,Spec).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(sandbox_policy:sandbox_spawn(_M,_P,_C,_A,Goal0,Pid,Options0), spawn(Goal,Pid,Options)) :- !, \'$actor_strip_source_module\'(Goal0,Goal), \'$actor_strip_source_module\'(Options0,Options).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(actors:input(\'|:\',Term0), read(Term)) :- !, \'$actor_strip_source_module\'(Term0,Term).~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(Source:Inner0, Inner) :- Source == ~q, !, \'$actor_strip_source_module\'(Inner0,Inner).~n', [Module]),
    bootstrap_line( '\'$actor_strip_source_module\'(Term, Term) :- atomic(Term), !.~n', []),
    bootstrap_line( '\'$actor_strip_source_module\'(Term0, Term) :- Term0 =.. [Functor|Args0], \'$actor_strip_source_args\'(Args0,Args), Term =.. [Functor|Args].~n', []),
    bootstrap_line( '\'$actor_strip_source_args\'([], []).~n', []),
    bootstrap_line( '\'$actor_strip_source_args\'([Arg0|Args0], [Arg|Args]) :- \'$actor_strip_source_module\'(Arg0,Arg), \'$actor_strip_source_args\'(Args0,Args).~n', []),
    bootstrap_line( '\'$actor_clause_term\'(Head, true, Head) :- !.~n', []),
    bootstrap_line( '\'$actor_clause_term\'(Head, Body, (Head :- Body)).~n', []),
    bootstrap_line( '\'$actor_cleanup\' :- forall(retract(\'$actor_source_pi\'(Name/Arity)), (functor(Head, Name, Arity), retractall(Head))), retractall(\'$actor_dynamic_pi\'(_)), retractall(\'$actor_discontiguous_pi\'(_)), retractall(\'$actor_shared_pi\'(_)), retractall(\'$actor_loading_shared\').~n', []).

call_in_module(Module, Goal) :-
    Qualified = Module:Goal,
    call(Qualified).
