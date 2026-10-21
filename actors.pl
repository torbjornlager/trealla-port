% SPDX-License-Identifier: MIT

:- module(actors,
       [ spawn/1,                % :Goal
         spawn/2,                % :Goal, -Pid
         spawn/3,                % :Goal, -Pid, +Options
         with_spawn_name/3,       % internal naming-wrapper composition
         spawn_runtime/3,        % internal framework entry
         validate_spawn_options/2, % +Options, +public|runtime
         validate_spawn_wrapper_options/4, % internal constructor validation
         self/1,                 % -Pid
         monitor/2,              % +PidOrName, -Ref
         demonitor/1,            % +Ref
         demonitor/2,            % +Ref, +Options
         publish_remote_spawn_name/2, % internal remote startup
         rollback_remote_spawn_name/2,
         retire_registry_namespace/1, % internal WebSocket teardown
         remove_remote_aliases/1, % internal distribution cleanup
         register/2,             % +Name, +Pid
         unregister/1,           % +Name
         whereis/2,              % +Name, -Pid
         register_service/2,     % +Name, +Pid
         unregister_service/1,   % +Name
         whereis_service/2,      % +Name, -Pid
         exit/1,                 % +Reason
         exit/2,                 % +Pid, +Reason
         actor_terminating/0,
         send/2,                 % +Pid, +Message
         send/3,                 % +Pid, +Message, +Options
         cancel/1,               % +Id
         (!)/2,                  % +Pid, +Message
         input/2,                % +Prompt, -Answer
         input/3,                % +Prompt, -Answer, +Options
         respond/2,              % +Pid, +Answer
         output/1,               % +Term
         output/2,               % +Term, +Options
         terminal_output/1,      % +Term
         terminal_output/2,      % +Term, +Options
         current_io_target/1,    % -Target
         actors/1,              % -Pids
         live_actor_count/1,     % -Count
         actor_thread/2,         % +Pid, -NativeThread
         receive/1,              % +ReceiveClauses
         receive/2,              % +ReceiveClauses, +Options
         receive_qualified/2,    % +QualifiedClauses, +Options (runtime bridge)
         receive_empty/0,        % internal private-module bridge
         make_ref/1,             % -Ref
         flush/0,

         op(800,  xfx, !),       %
         op(200,  xfx, @),       %
         op(1000, xfy, if)       %
       ]).

/** <module> Actors --- Erlang-style concurrent processes for ISO Prolog

This library provides a minimal Erlang-style concurrency model layered
on top of the ISO Prolog `thread_*` primitives.  Processes (*actors*)
are lightweight, share no mutable state, and communicate exclusively
by asynchronous message passing.

The library is deliberately small.  Distribution remains optional: loading
`distribution.pl` installs routing
    hooks for remote `spawn/3`, `(!)/2`, `exit/2`, and monitor operations.

What it does provide:

  - spawn/1, spawn/2, spawn/3 to launch a new actor running a goal
  - self/1 to obtain the current actor's PID
  - send/2 and (!)/2 for immediate asynchronous message passing
  - send/3 and cancel/1 for cancellable delayed messages
  - receive/1, receive/2 for Erlang-style pattern-matched, guarded,
    optionally timed-out mailbox reads
  - monitor/2 / demonitor/1,2 for passive lifecycle notifications
  - A `link` option on spawn/3 for eager lifecycle coupling
  - register/2, unregister/1, whereis/2 for naming actors
  - register_service/2, unregister_service/1, whereis_service/2 for
    node-wide names that distribution peers may address
  - exit/1, exit/2 for terminating processes with a reason
  - terminal_output/1,2 with an inherited per-actor terminal target
  - private source namespaces through `src_text/1`, `src_list/1`, and
    `src_predicates/1` spawn options

## Mailboxes {#actors-mailboxes}

Every actor has an ordered mailbox.  `send(Pid, Message)` (or its operator
alias `Pid ! Message`) enqueues `Message`
and returns immediately.  receive/1,2 consumes messages in arrival
order, with pattern matching and guards selecting which message is
extracted; non-matching messages are left in the mailbox and remain
available to later receive/1,2 calls.

## Links versus monitors {#actors-links-monitors}

A *link* is directional and eager: when a parent spawns a child with
`link(true)`, termination of the parent causes the child to be sent an
exit signal, but not vice versa.  Links are set up with the `link(true)`
option on spawn/3 (currently the default) and are primarily a
supervision tool.

A *monitor* is unidirectional and passive: when the monitored actor
exits, the monitoring actor receives a `down(Pid, Ref, Reason)`
message in its mailbox.  Monitors are set up with the `monitor(true)`
option on spawn/3, or by calling monitor/2 explicitly, and are
primarily an observation tool.

## Deferred messages {#actors-deferred}

When receive/1,2 scans the mailbox and finds messages that do not
match any clause, those messages are moved to a per-thread non-backtrackable
*deferred list*. Deferred messages are re-offered to the next receive call
before the live mailbox is consulted.

## Example {#actors-example}

A simple echo server and one interaction with it:

==
echo_server :-
    receive({
        echo(From, Msg) ->
            From ! Msg,
            echo_server
    }).

?- spawn(echo_server, Pid),
   self(Me),
   Pid ! echo(Me, hello),
   receive({Reply -> true}).
Reply = hello.
==

## Trealla port notes {#actors-trealla}

  - Trealla now provides `library(debug)`; this module does not import it
    because its former SWI debug calls were unused by the port.
  - `thread_signal/2` and `thread_send_message/2` on a dead detached
    thread raise a catchable domain_error; exit/2 and send/2 use a
    bare `catch/3` and treat the error as a silent drop.
  - Public PIDs and monitor references are collision-checked random
    ten-digit integers, matching the SWI distribution layer's wire form.

@author Torbjörn Lager
*/


                /*******************************
                *             ACTOR            *
                *******************************/


:- meta_predicate(spawn(0)).
:- meta_predicate(spawn(0, -)).
:- meta_predicate(spawn(0, -, +)).
:- meta_predicate(with_spawn_name(+, -, 1)).
:- meta_predicate(spawn_runtime(0, -, +)).
:- meta_predicate(spawn_scoped(0, -, +, +, +)).
:- meta_predicate(receive(:, +)).
:- meta_predicate(discard_deferred(1)).

:- use_module(isolation).
:- use_module(resource_policy).

:- multifile
    hook_spawn/3,
    hook_send/2,
    hook_exit/2,
    hook_monitor/3,
    hook_demonitor/1,
    hook_admit_spawn/2,
    hook_spawn_reserved/2,
    hook_stop/1,
    hook_local_registration_pid/2.

:- dynamic actor_alive/1.
:- dynamic pid_thread/2.
:- dynamic thread_pid/2.
:- dynamic issued_pid/1.
:- dynamic issued_ref/1.
:- dynamic actor_namespace/2.
:- dynamic actor_public_namespace/2.
:- dynamic delayed_send/3.

:- catch(mutex_create(_, [alias('$actor_registry')]),
         error(permission_error(create, mutex, '$actor_registry'), _),
         true).


%!  spawn(:Goal) is det.
%!  spawn(:Goal, -Pid) is det.
%!  spawn(:Goal, -Pid, +Options) is det.
%
%   Spawn a new actor that calls Goal.  The new actor's PID is unified
%   with Pid.  spawn/1 is a convenience form that discards the PID.
%   The calling thread *blocks* until the new actor has initialised
%   (i.e. until `initialized(Pid)` has been sent back), so Pid is
%   always ground by the time spawn/3 returns.
%
%   Options:
%
%     - monitor(+Bool)
%       If `true`, the spawning actor monitors the new actor and
%       receives a `down(Pid, Ref, Reason)` message when it exits.
%       As a convenience, the monitor's Ref is the spawned Pid
%       itself, so the `down` message arrives as
%       `down(Pid, Pid, Reason)` and the monitor can be cancelled
%       with `demonitor(Pid)`.  Default: `false`.
%     - link(+Bool)
%       If `true`, the spawning actor and the new actor are linked:
%       termination of the spawning actor propagates an exit signal to
%       the new actor, but not the reverse. Default: `true`.
%     - node(+URL)
%       When `distribution.pl` is loaded and URL is not `localhost`, spawn
%       the actor on that Web Prolog node and return a canonical `Pid@URL`.
%     - src_text(+Text), src_list(+Terms), src_predicates(+PIs)
%       Load source into a fresh namespace private to the actor.  Predicate
%       indicators are copied from the spawning goal's source module.

:- dynamic(link/2).

spawn(Goal) :-
    spawn(Goal, _Pid).

spawn(Goal, Pid) :-
    spawn(Goal, Pid, []).

spawn(Goal, Pid, Options) :-
    validate_spawn_options(Options,public),
    spawn_dispatch(Goal,Pid,Options).

% The token stays local: local startup or the remote caller handshake publishes.
with_spawn_name(Options, _Pid, Create) :-
    ( option(name(Name),Options)
    -> setup_call_cleanup(reserve_spawn_name(Name,Token),
           call(Create,['$name_reservation'(Token)]),release_spawn_name(Token))
    ; call(Create,[]) ).

reserve_spawn_name(Name, Token) :-
    must_be(atom,Name), make_ref(Token), registration_namespace(Namespace),
    with_mutex('$actor_registry',
        ( ensure_registry_namespace_open(Namespace),
          ( (registered(Name,_) ; reserved_spawn_name(Name,_))
        -> throw(name_is_in_use(Name))
        ; assertz(reserved_spawn_name(Name,Token)),
          assertz(spawn_name_owner(Token,Namespace)) ))).

release_spawn_name(Token) :-
    with_mutex('$actor_registry',
        (retractall(reserved_spawn_name(_,Token)),retractall(spawn_name_owner(Token,_)),
         retractall(remote_spawn_publication(Token,_,_,_)))).

publish_spawn_name(Pid, Options) :-
    ( option('$name_reservation'(Token),Options)
    -> registration_namespace(CurrentNamespace),
       with_mutex('$actor_registry',
           ( ensure_registry_namespace_open(CurrentNamespace),
             actor_alive(Pid),
             ( registered(_,Pid) -> throw(process_already_has_a_name(Pid)) ; true ),
             ( retract(reserved_spawn_name(Name,Token))
             -> (retract(spawn_name_owner(Token,Namespace)) -> true ; Namespace=none),
                ensure_registry_namespace_open(Namespace),
                asserta(registered(Name,Pid)),assertz(registration_owner(Name,Pid,Namespace))
             ; throw(error(existence_error(name_reservation,Token),spawn/3)) )))
    ; true ).

publish_remote_spawn_name(Pid,Options) :-
    (option('$name_reservation'(Token),Options) ->
        registration_namespace(Current),
        with_mutex('$actor_registry',
            (ensure_registry_namespace_open(Current),
             (registered(_,Pid) -> throw(process_already_has_a_name(Pid)) ; true),
             (reserved_spawn_name(Name,Token),spawn_name_owner(Token,Owner) -> true
             ; throw(error(existence_error(name_reservation,Token),spawn/3))),
             ensure_registry_namespace_open(Owner),
             retractall(reserved_spawn_name(_,Token)),retractall(spawn_name_owner(Token,_)),
             asserta(registered(Name,Pid)),assertz(registration_owner(Name,Pid,Owner)),
             assertz(remote_spawn_publication(Token,Name,Pid,Owner))))
    ; true).

rollback_remote_spawn_name(Pid,Options) :-
    (option('$name_reservation'(Token),Options) ->
        with_mutex('$actor_registry',
            (retract(remote_spawn_publication(Token,Name,Pid,Owner)) ->
                (registration_owner(Name,Pid,Owner) -> remove_registrations([Name-Pid]) ; true)
            ; true))
    ; true).

spawn_runtime(Goal, Pid, Options) :-
    validate_spawn_options(Options,runtime),
    spawn_dispatch(Goal,Pid,Options).

spawn_dispatch(Goal, Pid, Options) :-
    hook_spawn(Goal, Pid, Options), !.
spawn_dispatch(Goal, Pid, Options) :-
    current_actor_namespace(Namespace),
    spawn_local(Goal,Pid,Options,Namespace,public).

validate_spawn_options(Options,Scope) :-
    validate_spawn_options(Options,Scope,actors:spawn/3).
validate_spawn_options(Options,Scope,Context) :-
    catch((must_be(list,Options),validate_spawn_option_list(Options,Scope)),
          error(Formal,_),
          throw(error(Formal,context(Context,'invalid spawn option')))).
validate_spawn_option_list([],_).
validate_spawn_option_list([Option|Options],Scope) :-
    must_be(nonvar,Option),
    (Option='$entry_context'(Value) ->
        (Scope==runtime ->
            (Value==caller -> true
            ; throw(error(domain_error(entry_context,Value),spawn/3)))
        ; throw(error(permission_error(option,internal_spawn_option,Option),spawn/3)))
    ; Option='$worker_scope'(Key) ->
        (Scope==runtime -> must_be(atom,Key)
        ; throw(error(permission_error(option,internal_spawn_option,Option),spawn/3)))
    ; Option='$name_reservation'(Token) ->
        (Scope==runtime -> must_be(integer,Token)
        ; throw(error(permission_error(option,internal_spawn_option,Option),spawn/3)))
    ; compound(Option),functor(Option,Name,1),spawn_option_type(Name,Type) ->
        arg(1,Option,Value),validate_spawn_value(Type,Value)
    ; throw(error(domain_error(spawn_option,Option),spawn/3))),
    validate_spawn_option_list(Options,Scope).
% Wrapper-only options are checked before they are consumed; everything else
% uses the same base validator, including framework metadata in runtime scope.
validate_spawn_wrapper_options(Options,Scope,Context,ExtraSpecs) :-
    catch((must_be(list,Options),validate_wrapper_option_list(Options,Scope,ExtraSpecs)),
          error(Formal,_),
          throw(error(Formal,context(Context,'invalid wrapper option')))).
validate_wrapper_option_list([],_,_).
validate_wrapper_option_list([Option|Options],Scope,Specs) :-
    must_be(nonvar,Option),
    (compound(Option),functor(Option,Name,1),memberchk(Name-Type,Specs) ->
        arg(1,Option,Value),validate_spawn_value(Type,Value)
    ; validate_spawn_option_list([Option],Scope)),
    validate_wrapper_option_list(Options,Scope,Specs).

spawn_option_type(link,boolean).
spawn_option_type(monitor,boolean).
spawn_option_type(target,nonvar).
spawn_option_type(io_target,nonvar).
spawn_option_type(node,node).
spawn_option_type(src_text,text).
spawn_option_type(src_uri,text).
spawn_option_type(src_list,list).
spawn_option_type(src_predicates,predicate_indicators).
validate_spawn_value(seconds(Kind),Value) :- !,
    must_be(nonvar,Value),resource_policy:normalize_seconds(Kind,Value,_).
validate_spawn_value(nonnegative_integer,Value) :- !,
    must_be(integer,Value),
    (Value>=0 -> true ; throw(error(domain_error(not_less_than_zero,Value),spawn/3))).
validate_spawn_value(positive_number(Domain),Value) :- !,
    must_be(nonvar,Value),
    (number(Value),Value>0 -> true ; throw(error(domain_error(Domain,Value),spawn/3))).
validate_spawn_value(oneof(Domain,Values),Value) :- !,
    must_be(nonvar,Value),
    (memberchk(Value,Values) -> true ; throw(error(domain_error(Domain,Value),spawn/3))).

validate_spawn_value(node,Node) :- !,
    must_be(nonvar,Node),
    (atom(Node) -> true
    ; is_list(Node) -> atom_chars(_,Node)
    ; throw(error(type_error(atom_or_string,Node),spawn/3))).
validate_spawn_value(text,Text) :- !,
    must_be(nonvar,Text),isolation:source_text_atom(Text,_).
validate_spawn_value(predicate_indicators,PIs) :- !,
    must_be(list,PIs),validate_spawn_pis(PIs).
validate_spawn_value(Type,Value) :- must_be(Type,Value).
validate_spawn_pis([]).
validate_spawn_pis([PI|PIs]) :-
    isolation:source_predicate_indicator(PI,_,_),validate_spawn_pis(PIs).

% Internal entry point used by connection runtimes.  An internal actor still
% carries Namespace so actors that it spawns inherit the browser session's
% scope, but it is deliberately omitted from actors/1 in that scope.
spawn_scoped(Goal, Pid, Options, Namespace, Visibility) :-
    validate_spawn_options(Options,runtime),
    valid_actor_visibility(Visibility),
    spawn_local(Goal, Pid, Options, Namespace, Visibility).

valid_actor_visibility(public).
valid_actor_visibility(internal).

spawn_local(Goal, Pid, Options0, Namespace, Visibility) :-
    strip_module(Goal, GoalModule, _),
    isolation:rewrite_source_options(Options0, GoalModule, Options1),
    inherit_spawn_io_target(Options1, Options),
    self(Self),
    with_mutex('$actor_registry',
        spawn_local_locked(Self, GoalModule, Goal, Options, Namespace,
                           Visibility, Pid)),
    thread_get_message('$actor_started'(Pid, StartResult)),
    ( StartResult == ok
    -> true
    ; StartResult = error(Error),
      throw(Error)
    ).

spawn_local_locked(Self, GoalModule, Goal, Options, Namespace, Visibility,
                   Pid) :-
    live_actor_count_unlocked(LiveCount),
    forall(hook_admit_spawn(LiveCount, Options), true),
    make_pid_unlocked(Pid),
    % Scope ownership precedes thread creation: setup_call_cleanup/3 does not
    % mask signals during setup on Trealla. An interrupted startup is owned.
    forall(hook_spawn_reserved(Pid, Options), true),
    actor_thread_options([
        detached(true),
        at_exit(stop(Pid, Self))
    ], ThreadOptions),
    % Install lifecycle relations before the child thread exists.  If the
    % parent dies during startup its stop hook removes the link; start/5 then
    % observes the missing relation and exits instead of becoming an orphan.
    assertz(actor_alive(Pid)),
    remember_actor_namespace(Visibility, Pid, Namespace),
    install_spawn_relations(Self, Pid, Options),
    catch(thread_create(start(Self, Pid, GoalModule, Goal, Options), _Thread,
                        ThreadOptions),
          Error,
          ( rollback_spawn(Self, Pid), throw(Error) )).

install_spawn_relations(Parent, Pid, Options) :-
    option(link(Link), Options, true),
    ( Link == true -> assertz(link(Parent, Pid)) ; true ),
    option(monitor(Monitor), Options, false),
    ( Monitor == true -> assertz(monitor(Parent, Pid, Pid)) ; true ).

rollback_spawn(Parent, Pid) :-
    retractall(link(Parent, Pid)),
    retractall(monitor(Parent, Pid, Pid)),
    retractall(actor_alive(Pid)),
    retractall(actor_namespace(Pid, _)),
    retractall(actor_public_namespace(Pid, _)).

current_actor_namespace(Namespace) :-
    thread_self(Thread),
    thread_pid(Thread, Pid),
    actor_namespace(Pid, Namespace),
    !.
current_actor_namespace(none).

remember_actor_namespace(Visibility, Pid, Namespace) :-
    Namespace \== none,
    !,
    assertz(actor_namespace(Pid, Namespace)),
    remember_public_actor_namespace(Visibility, Pid, Namespace).
remember_actor_namespace(_, _, _).

remember_public_actor_namespace(public, Pid, Namespace) :- !,
    assertz(actor_public_namespace(Pid, Namespace)).
remember_public_actor_namespace(_, _, _).

inherit_spawn_io_target(Options, Options) :-
    ( memberchk(io_target(_), Options) ; memberchk(target(_), Options) ),
    !.
inherit_spawn_io_target(Options0, [io_target(Target)|Options0]) :-
    current_io_target(Target),
    !.
inherit_spawn_io_target(Options, Options).



%!  start(+Parent, +Pid, +GoalModule, :Goal, +Options) is det.
%
%   Internal entry point for a newly created actor thread.  Sets up
%   any link/monitor, signals the parent that initialisation is
%   complete, then calls Goal. Explicit exit/1 reasons are recorded when the
%   actor commits to termination; ordinary success, failure, and exceptions
%   are read from Trealla's final thread status by stop/2.

start(Parent, Pid, GoalModule, Goal, Options) :-
    thread_self(Thread),
    with_mutex('$actor_registry',
        ( assertz(pid_thread(Pid, Thread)),
          assertz(thread_pid(Thread, Pid))
        )),
    set_parent(Parent),
    set_spawn_io_target(Parent, Options),
    option(link(Link), Options, true),
    ( Link == true, \+ link(Parent, Pid) -> exit(kill) ; true ),
    % exit/1 records the public reason before throwing this private unwind.
    % Swallow only that control token; all ordinary exceptions must reach
    % Trealla's final thread status for monitor delivery. run_actor/5 signals
    % startup only after its scoped temporary module has been prepared.
    catch(isolation:run_actor(Pid, GoalModule, Goal, Options, Parent),
          actor_exit, true).

set_spawn_io_target(_Parent, Options) :-
    option(io_target(Target), Options),
    !,
    nb_setval('$actor_io_target', Target).
set_spawn_io_target(_Parent, Options) :-
    option(target(Target), Options),
    !,
    nb_setval('$actor_io_target', Target).
set_spawn_io_target(Parent, _) :-
    nb_setval('$actor_io_target', Parent).


%!  stop(+Pid, +Parent) is det.
%
%   at_exit hook called when actor Pid terminates.  Tears down all
%   bookkeeping: removes the actor from actor_alive/1, retracts the
%   link, kills any actors linked to Pid, and delivers down/3 messages
%   to any monitors.

stop(Pid, Parent) :-
    % No thread_detach here: the thread was spawned with detached(true)
    % because Trealla refuses self-detach from inside at_exit.
    down_reason(Pid, Reason),
    with_mutex('$actor_registry',
        ( retractall(link(Parent, Pid)),
          remove_local_registrations(Pid),
          retractall(registered_service(_Name, Pid)),
          retractall(actor_alive(Pid)),
          retractall(actor_namespace(Pid, _)),
          retractall(actor_public_namespace(Pid, _)),
          retractall(delayed_send(_Owner, _Id, Pid)),
          retractall(pid_thread(Pid, _)),
          retractall(thread_pid(_, Pid)),
          findall(ChildPid, retract(link(Pid, ChildPid)), ChildPids),
          findall(Other-Ref, retract(monitor(Other, Pid, Ref)), Watchers)
        )),
    isolation:cleanup_actor(Pid),
    exit_linked_children(ChildPids),
    forall(hook_stop(Pid), true),
    deliver_downs(Watchers, Pid, Reason).

exit_linked_children([]).
exit_linked_children([Pid|Pids]) :-
    exit(Pid, kill),
    exit_linked_children(Pids).

deliver_downs([], _, _).
deliver_downs([Other-Ref|Watchers], Pid, Reason) :-
    Other ! down(Pid, Ref, Reason),
    deliver_downs(Watchers, Pid, Reason).


%!  live_actor_count(-Count) is det.
%
%   Number of actors whose at_exit cleanup has not begun. Actor creation and
%   removal are serialized so admission checks cannot race each other.

live_actor_count(Count) :-
    with_mutex('$actor_registry', live_actor_count_unlocked(Count)).

live_actor_count_unlocked(Count) :-
    findall(Pid, actor_alive(Pid), Pids),
    length(Pids, Count).

%!  actors(-Pids) is det.
%
%   Return a snapshot of live public actor PIDs.  Inside a WebSocket actor,
%   the snapshot is restricted to that connection's namespace and omits the
%   internal relay.  Outside a scoped runtime it retains the local diagnostic
%   behaviour of returning every actor.  Non-actor threads that merely
%   acquired an identity through self/1 are always excluded.

actors(Pids) :-
    current_actor_namespace(Namespace),
    with_mutex('$actor_registry', actors_unlocked(Namespace, Pids)),
    !.

actors_unlocked(none, Pids) :-
    findall(Pid, actor_alive(Pid), Pids).
actors_unlocked(Namespace, Pids) :-
    findall(Pid,
            ( actor_alive(Pid),
              actor_public_namespace(Pid, Namespace)
            ),
            Pids).


%!  down_reason(+Pid, -Reason) is det.
%
%   Retrieve an explicit exit/1 reason, or use the final native thread status
%   for ordinary success, failure, and exceptions. Falls back to `noproc` if
%   the thread disappeared before either form became observable.

down_reason(Pid, Reason) :-
    retract(exit_reason(Pid, Reason)),
    !.
down_reason(Pid, Reason) :-
    pid_thread(Pid, Thread),
    catch(thread_property(Thread, status(Reason)), _, fail),
    !.
down_reason(_, noproc).




%!  self(-Pid) is det.
%
%   Unify Pid with the calling actor's stable ten-digit logical identifier.
%   Non-actor threads (notably the REPL and WebSocket reader) are registered
%   lazily the first time they enter the actor API.

self(Self) :-
    thread_self(Thread),
    with_mutex('$actor_registry', self_for_thread(Thread, Self)),
    !.

self_for_thread(Thread, Self) :-
    ( thread_pid(Thread, Existing) -> Self = Existing
    ; make_pid_unlocked(Self),
      assertz(pid_thread(Self, Thread)),
      assertz(thread_pid(Thread, Self))
    ).

%!  actor_thread(+Pid, -NativeThread) is semidet.
%
%   Resolve a public logical actor PID to Trealla's private thread handle.

actor_thread(Pid, Thread) :-
    with_mutex('$actor_registry', pid_thread(Pid, Thread)),
    !.


%!  monitor(+PidOrName, -Ref) is det.
%
%   Start monitoring the actor identified by PidOrName.  Ref is unified
%   with a fresh reference that identifies this monitor.  When the
%   monitored actor exits, a `down(Pid, Ref, Reason)` message is
%   delivered to the calling actor's mailbox.
%
%   Note: when a monitor is set up via the `monitor(true)` option of
%   spawn/3 instead of by calling monitor/2, the monitored Pid is
%   reused as the Ref.  See spawn/3.

%!  demonitor(+Ref) is det.
%!  demonitor(+Ref, +Options) is det.
%
%   Remove the monitor identified by Ref.  For monitors installed via
%   spawn/3's `monitor(true)` option, pass the spawned Pid as Ref.
%   Options:
%
%     - flush
%       If present, and a matching `down(_, Ref, _)` message has
%       already been delivered to the mailbox, discard it.

:- dynamic(monitor/3).

monitor(Name, Ref) :-
    atom(Name),
    whereis(Name, Pid),
    !,
    monitor(Pid, Ref).
monitor(Pid, Ref) :-
    self(Self),
    make_ref(Ref),
    ( with_mutex('$actor_registry', install_local_monitor(Self, Pid, Ref))
    -> true
    ; hook_monitor(Self, Pid, Ref)
    -> with_mutex('$actor_registry', assertz(monitor(Self, Pid, Ref)))
    ; Self ! down(Pid, Ref, no_process)
    ),
    !.

install_local_monitor(Self, Pid, Ref) :-
    actor_alive(Pid),
    assertz(monitor(Self, Pid, Ref)).


demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    self(Self),
    with_mutex('$actor_registry',
        (monitor(Self, _, Ref) -> Owned=true ; Owned=false)),
    % Distribution may wait for the manager/writer, whose replies also need
    % this registry. Never hold its mutex across that communication.
    ( Owned == true ->
        forall(actors:hook_demonitor(Ref), true),
        with_mutex('$actor_registry', retractall(monitor(Self, _, Ref)))
    ; true ),
    (   option(flush, Options)
    ->  flush_monitor_messages(Ref)
    ;   true
    ).

flush_monitor_messages(Ref) :-
    receive({
        down(_, ActualRef, _) if ActualRef == Ref ->
            actors:flush_monitor_messages(Ref)
    }, [timeout(0)]).


%!  register(+Name, +Pid) is det.
%
%   Register the given Pid under the atom Name.  Throws
%   `process_already_has_a_name(Pid)` if Pid is already registered
%   under any name, or `name_is_in_use(Name)` if Name is already
%   taken by another Pid. Missing or terminating local PIDs raise
%   error(existence_error(process, Pid), context(actors:register/2, _)).

:- dynamic(registered/2).
:- dynamic(registered_service/2).
:- dynamic reserved_spawn_name/2.
:- dynamic spawn_name_owner/2.
:- dynamic remote_spawn_publication/4.
:- dynamic registration_owner/3.
:- dynamic closed_registry_namespace/1.

register(Name, Pid) :-
    must_be(atom, Name),registration_namespace(Namespace),
    with_mutex('$actor_registry',
        ( ensure_registry_namespace_open(Namespace),
          ( registered(_, Pid)
        -> throw(process_already_has_a_name(Pid))
        ; (registered(Name, _) ; reserved_spawn_name(Name,_))
        -> throw(name_is_in_use(Name))
        ; ensure_registerable_local_pid(Pid),
          asserta(registered(Name, Pid)),
          assertz(registration_owner(Name,Pid,Namespace)) ))).

% Ownership is separate from node-wide lookup/uniqueness. Only WebSocket
% scopes participate in this batch; HTTP and trusted standalone use stay open.
registration_namespace(Namespace) :-
    current_actor_namespace(Scope),
    ( nonvar(Scope), Scope=ws_client(_), ground(Scope) -> Namespace=Scope
    ; Namespace=none ).

ensure_registry_namespace_open(Namespace) :-
    ( closed_registry_namespace(Namespace)
    -> throw(error(permission_error(register,closed_namespace,Namespace),
                   context(actors:register/2,'client namespace has ended')))
    ; true ).

retire_registry_namespace(Namespace) :-
    must_be(ground,Namespace),
    ( Namespace=ws_client(_) -> true
    ; throw(error(domain_error(websocket_namespace,Namespace),retire_registry_namespace/1)) ),
    with_mutex('$actor_registry',
        ( (closed_registry_namespace(Namespace) -> true
          ; assertz(closed_registry_namespace(Namespace))),
          findall(Name-Pid,registration_owner(Name,Pid,Namespace),Owned),
          remove_registrations(Owned),
          findall(Token,spawn_name_owner(Token,Namespace),Tokens),
          retire_spawn_names(Tokens),
          retractall(remote_spawn_publication(_,_,_,Namespace)) )).
retire_spawn_names([]).
retire_spawn_names([Token|Tokens]) :-
    retractall(reserved_spawn_name(_,Token)),retractall(spawn_name_owner(Token,_)),
    retire_spawn_names(Tokens).

% Called with the registry mutex held: do not reacquire it via actor_thread/2.
% Qualified local aliases retain their original term; distribution identifies
% them without probing remote nodes.
local_registration_pid(Target, Local) :-
    integer(Target), !, Local=Target.
local_registration_pid(Target, Local) :-
    nonvar(Target), hook_local_registration_pid(Target,Local).

ensure_registerable_local_pid(Target) :-
    ( local_registration_pid(Target,Local)
    -> ( \+ exit_reason(Local,_), pid_thread(Local,Thread),
         catch(thread_property(Thread,status(running)),_,fail)
       -> true
       ; throw(error(existence_error(process,Target),
                     context(actors:register/2,'local actor no longer exists'))) )
    ; true ).

remove_local_registrations(Pid) :-
    findall(Name-Target,
        (registered(Name,Target),local_registration_pid(Target,Local),Local==Pid),
        Registrations),
    remove_registrations(Registrations).
remove_registrations([]).
remove_registrations([Name-Target|Rest]) :-
    retractall(registered(Name,Target)),
    retractall(registration_owner(Name,Target,_)),remove_registrations(Rest).

% Remove only exact, known remote PID identities. Do not touch local/service
% names or infer that every alias for the same node belongs to one connection.
remove_remote_aliases(Pids) :-
    with_mutex('$actor_registry',
        ( findall(Name-Target,
              (registered(Name,Target),member(Pid,Pids),Target==Pid),Aliases),
          remove_registrations(Aliases) )).

%!  unregister(+Name) is det.
%
%   Remove any registration under Name.  Succeeds even if Name was not
%   registered.

unregister(Name) :-
    with_mutex('$actor_registry',
        (retractall(registered(Name,_)),retractall(registration_owner(Name,_,_)))).

%!  whereis(+Name, -Pid) is det.
%
%   Look up the PID registered under Name.  If no such registration
%   exists, Pid is unified with the atom `undefined` (rather than
%   failing), consistent with Erlang's whereis/1 semantics.

whereis(Name, Pid) :-
    must_be(atom, Name),
    registered(Name, Pid),
    !.
whereis(_Name, undefined).

%!  register_service(+Name, +Pid) is det.
%
%   Publish a live local actor under a node-wide service name.  Unlike an
%   ordinary registration, a published service may be addressed by remote
%   peers as `Name@Node`.

register_service(Name, Pid) :-
    must_be(atom, Name),
    ( actor_thread(Pid, Thread),
      catch(thread_property(Thread, status(running)), _, fail) -> true
    ; throw(error(existence_error(process, Pid), register_service/2))
    ),
    ( registered_service(Name, _) ->
        throw(error(permission_error(register, service, Name),
                    register_service/2))
    ; asserta(registered_service(Name, Pid))
    ).

%!  unregister_service(+Name) is det.

unregister_service(Name) :-
    must_be(atom, Name),
    retractall(registered_service(Name, _)).

%!  whereis_service(+Name, -Pid) is det.

whereis_service(Name, Pid) :-
    must_be(atom, Name),
    registered_service(Name, Pid),
    !.
whereis_service(_, undefined).

published_service_target(Name, Pid) :-
    atom(Name),
    registered_service(Name, Pid).

send_service(Name, Message) :-
    ( published_service_target(Name, Pid) -> actor_send(Pid, Message)
    ; true
    ).


%!  exit(+Reason) is det.
%
%   Terminate the calling actor with exit reason Reason.  Records the
%   reason in exit_reason/2, then throws the internal `actor_exit`
%   exception, which is caught by start/4's top-level catch and causes
%   clean actor teardown.

:- dynamic(exit_reason/2).

exit(Reason) :-
    var(Reason),
    instantiation_error(Reason).
exit(Reason) :-
    self(Self),
    with_mutex('$actor_registry', commit_exit(Self, Reason, Committed)),
    ( Committed == true -> throw(actor_exit) ; true ).

commit_exit(Self, Reason, Committed) :-
    ( exit_reason(Self, _) -> Committed = false
    ; assertz(exit_reason(Self, Reason)), Committed = true
    ).

%!  actor_terminating is semidet.
%
%   True after the calling actor has committed its first exit reason.

actor_terminating :-
    self(Self),
    with_mutex('$actor_registry', exit_reason(Self, _)),
    !.


%!  exit(+Pid, +Reason) is det.
%
%   Send an exit signal with Reason to the actor identified by Pid.
%   If Pid does not exist (or has already exited), succeeds silently.
%
%   Implementation note: thread_signal/2 raises a catchable
%   domain_error on a dead detached thread, so the catch is the
%   safety net.

exit(Pid, Reason) :-
    hook_exit(Pid, Reason),
    !.
exit(Pid, Reason) :-
    ( actor_thread(Pid, Thread) ->
        catch(thread_signal(Thread, actors:exit(Reason)), _, true)
    ; logical_pid(Pid) ->
        true
    ; catch(thread_signal(Pid, actors:exit(Reason)), _, true)
    ).


%!  !(+PidOrName, +Message) is det.
%
%   Asynchronously send Message to the actor identified by PidOrName.
%   PidOrName may be either a logical PID or an atom previously bound with
%   register/2.  Native handles remain accepted only for internal runtime
%   aliases and queues. Returns immediately; delivery is reliable
%   within a single Prolog process.  If the target actor does not
%   exist (or has already exited), the message is silently dropped.

Pid ! Message :-
    send(Pid, Message).

%!  send(+PidOrName, +Message) is det.

send(Pid, Message) :-
    actor_send(Pid, Message).

%!  send(+PidOrName, +Message, +Options) is det.
%
%   Schedule Message for asynchronous delivery after delay(Seconds), which
%   defaults to zero.  If Options contains id(Id), the calling actor may
%   withdraw every one of its pending sends carrying Id with cancel/1.

send(Pid, Message, Options) :-
    option(delay(Delay), Options, 0),
    self(Owner),
    spawn(send_with_delay(Pid, Message, Delay), DelayPid),
    ( option(id(Id), Options) -> assertz(delayed_send(Owner, Id, DelayPid))
    ; true
    ).

%!  cancel(+Id) is det.
%
%   Cancel every pending delayed send tagged Id by the calling actor.  Tags
%   are actor-scoped, so another actor may use the same tag independently.

cancel(Id) :-
    self(Owner),
    forall(retract(delayed_send(Owner, Id, DelayPid)),
           send(DelayPid, '$cancel')).

send_with_delay(Pid, Message, Delay) :-
    receive({
        '$cancel' -> true
    }, [
        timeout(Delay),
        on_timeout(send(Pid, Message))
    ]),
    self(Self),
    retractall(delayed_send(_, _, Self)).

actor_send(Name, Message) :-
    registered(Name, Pid),
    !,
    actor_send(Pid, Message).
actor_send(Name, Message) :-
    registered_service(Name, Pid),
    !,
    actor_send(Pid, Message).
actor_send(Pid, Message) :-
    hook_send(Pid, Message),
    !.
actor_send(Pid, Message) :-
    ( actor_thread(Pid, Thread) ->
        catch(thread_send_message(Thread, Message), _, true)
    ; logical_pid(Pid) ->
        true
    ; catch(thread_send_message(Pid, Message), _, true)
    ).

logical_pid(Pid) :-
    integer(Pid),
    Pid >= 1000000000,
    Pid =< 9999999999.


%!  receive(+ReceiveClauses) is nondet.
%!  receive(+ReceiveClauses, +Options) is nondet.
%
%   Erlang-style mailbox read with committed, one-sided message selection.
%   A pattern may bind its own variables but never variables in the receiver's
%   copy of the message. One invocation consumes at most one message; its
%   ordinary Prolog body may nevertheless yield multiple logical solutions.
%   Backtracking through the body never selects another message or clause.
%
%   ReceiveClauses is a brace-wrapped disjunction of clauses:
%
%   ==
%   receive({
%       Pattern1 -> Body1 ;
%       Pattern2 if Guard -> Body2 ;
%       ...
%   })
%   ==
%
%   Each clause has one of two forms:
%
%     - `Pattern -> Body`
%       Matches any message subsumed by Pattern.  On match, Pattern is
%       unified with the message and Body is called.
%     - `Pattern if Guard -> Body`
%       Matches only if the message is subsumed by Pattern *and*
%       Guard succeeds. Guard is called deterministically via once/1. Ordinary
%       guard exceptions reject the candidate; actor lifecycle and resource
%       control exceptions propagate.
%
%   Clauses are tried top-to-bottom against each mailbox message, with
%   the mailbox scanned in arrival order.
%
%   Options (receive/2 only):
%
%     - timeout(+Seconds)
%       Maximum time in seconds to wait for a matching message.
%       `timeout(0)` makes the call a non-blocking poll. A positive value is
%       converted once to an absolute deadline, so skipped messages do not
%       restart the timeout. When the timeout expires with no match, the goal
%       given by on_timeout/1 is called. Default: wait indefinitely.
%     - deadline(+AbsoluteTime)
%       Absolute deadline, in the same time scale as get_time/1. This is
%       useful when several operations must share one time budget. A deadline
%       that has already passed times out immediately. If both timeout/1 and
%       deadline/1 are present, timeout/1 takes precedence.
%     - on_timeout(:Goal)
%       Goal called when timeout/1 or deadline/1 expires. Default: `true`.
%
%   Examples:
%
%   ==
%   % Wait for either a success or an error reply.
%   receive({
%       ok(Result) -> handle(Result) ;
%       error(E)   -> handle_error(E)
%   })
%
%   % Select only high-priority messages using a guard.
%   receive({
%       priority(P, Msg) if P > 10 -> urgent(Msg)
%   })
%
%   % Non-blocking poll; do nothing if nothing is waiting.
%   receive({ Msg -> use(Msg) }, [timeout(0), on_timeout(true)])
%
%   % Share an absolute deadline with other operations.
%   get_time(Now),
%   Deadline is Now + 5,
%   receive({ Reply -> use(Reply) },
%           [deadline(Deadline), on_timeout(handle_timeout)])
%   ==
%
%   Deferred messages live in a native per-thread non-backtrackable value.

%!  discard_deferred(:Test) is det.
%
%   Remove already-deferred messages for which call(Test, Message) succeeds.
%   Messages still in the native thread queue are untouched. This lets the
%   toplevel discard commands skipped before a new call without discarding a
%   command sent immediately after it.

discard_deferred(Test) :-
    deferred_list(Deferred),
    discard_deferred_(Deferred, Test, Kept),
    deferred_put(Kept).

discard_deferred_([], _, []).
discard_deferred_([Message|Messages], Test, Kept) :-
    ( call(Test, Message) -> Kept = Rest ; Kept = [Message|Rest] ),
    discard_deferred_(Messages, Test, Rest).

receive(Clauses) :-
    receive(Clauses, []).

receive(Clauses, Options) :-
    receive_qualified(Clauses, Options).

% Private source modules use this bridge for receive({}).  Constructing a
% module-qualified empty-brace term in generated source triggers Trealla's
% parser (`Module:{}`), whereas the ordinary term compiled here is valid.
receive_empty :-
    receive({}).

% Non-meta entry point for actor-private modules executing a receive term
% supplied at runtime.  Calling the meta-predicate receive/2 through call/1
% makes Trealla qualify a variable catch-all head as a goal, which can yield
% spurious solutions and lose the caller's binding.  The isolation trampoline
% constructs the exact Module:{Clauses} term and enters here instead.
receive_qualified(Clauses, Options) :-
    thread_self(Mailbox),
    deferred_list(Deferred),
    (   select_deferred(Deferred, Clauses, Body, Rest)
    ->  deferred_put(Rest),
        call(Body)
    ;   receive_loop(Mailbox, Clauses, Options, Deferred)
    ).

%!  receive_loop(+Mailbox, +Clauses, +Options, +Deferred) is semidet.
%
%   Dispatcher for the four wait regimes:
%
%     - `timeout(0)`     -- non-blocking poll (receive_loop_poll/4).
%     - `timeout(T)`, T>0 -- block using thread_get_message/3's native
%       absolute deadline (receive_loop_timed/5).
%     - `deadline(D)`    -- block until caller-supplied absolute time D
%       (receive_loop_timed_/5).
%     - no timeout / `infinite` -- block forever (receive_loop_blocking/4).

receive_loop(Mailbox, Clauses, Options, Deferred) :-
    (   option(timeout(T), Options)
    ->  receive_loop_timeout(T, Mailbox, Clauses, Options, Deferred)
    ;   option(deadline(Deadline), Options)
    ->  (   number(Deadline)
        ->  receive_loop_timed_(Mailbox, Clauses, Options, Deferred, Deadline)
        ;   throw(error(type_error(number, Deadline), receive/2))
        )
    ;   receive_loop_blocking(Mailbox, Clauses, Options, Deferred)
    ).

receive_loop_timeout(0, Mailbox, Clauses, Options, Deferred) :-
    !,
    receive_loop_poll(Mailbox, Clauses, Options, Deferred).
receive_loop_timeout(T, Mailbox, Clauses, Options, Deferred) :-
    number(T),
    T > 0,
    !,
    receive_loop_timed(Mailbox, Clauses, Options, Deferred, T).
receive_loop_timeout(T, _, _, _, _) :-
    throw(error(domain_error(timeout, T), receive/2)).

%!  receive_loop_poll(+Mailbox, +Clauses, +Options, +Deferred) is semidet.
%
%   timeout(0): peek the mailbox; if non-empty, get one message and
%   try to match it.  If empty, run on_timeout immediately.

receive_loop_poll(Mailbox, Clauses, Options, Deferred) :-
    (   thread_peek_message(Mailbox, _)
    ->  thread_get_message(Mailbox, Msg),
        handle_incoming(Mailbox, Clauses, Options, Deferred, Msg)
    ;   deferred_put(Deferred),
        option(on_timeout(Goal), Options, true),
        call(Goal)
    ).

%!  receive_loop_blocking(+Mailbox, +Clauses, +Options, +Deferred) is semidet.
%
%   No timeout: block on thread_get_message/2 until a message arrives.

receive_loop_blocking(Mailbox, Clauses, Options, Deferred) :-
    thread_get_message(Mailbox, Msg),
    handle_incoming(Mailbox, Clauses, Options, Deferred, Msg).

%!  receive_loop_timed(+Mailbox, +Clauses, +Options, +Deferred, +T) is semidet.
%
%   Positive timeout. Convert it once to an absolute deadline so draining a
%   non-matching message cannot reset or extend the requested wait.  Trealla
%   v3.13.10 implements the SWI-compatible deadline/1 option natively.

receive_loop_timed(Mailbox, Clauses, Options, Deferred, T) :-
    get_time(T0),
    Deadline is T0 + T,
    receive_loop_timed_(Mailbox, Clauses, Options, Deferred, Deadline).

receive_loop_timed_(Mailbox, Clauses, Options, Deferred, Deadline) :-
    (   thread_get_message(Mailbox, Msg, [deadline(Deadline)])
    ->  copy_term(Msg, SavedMsg),
        (   catch(select_body(Clauses, Msg, Body), Error,
                  preserve_control_exception(Deferred, SavedMsg, Error))
        ->  deferred_put(Deferred),
            call(Body)
        ;   remember_incoming(Deferred, SavedMsg, Pending),
            receive_loop_timed_(Mailbox, Clauses, Options, Pending, Deadline)
        )
    ;   % timeout fired
        deferred_put(Deferred),
        option(on_timeout(Goal), Options, true),
        call(Goal)
    ).

%!  handle_incoming(+Mailbox, +Clauses, +Options, +Deferred, +Msg) is semidet.
%
%   Attempt to match Msg against Clauses.  On success, restore the
%   deferred list and run the body.  On failure, append Msg to Deferred
%   and loop.

handle_incoming(Mailbox, Clauses, Options, Deferred, Msg) :-
    copy_term(Msg, SavedMsg),
    (   catch(select_body(Clauses, Msg, Body), Error,
              preserve_control_exception(Deferred, SavedMsg, Error))
    ->  deferred_put(Deferred),
        call(Body)
    ;   remember_incoming(Deferred, SavedMsg, Pending),
        receive_loop(Mailbox, Clauses, Options, Pending)
    ).

% Keep a pristine copy before evaluating guards. Trealla's mutable per-thread
% store cannot safely hold the live message term during matching, so the copy
% is committed to the deferred list on rejection or before rethrowing a
% reserved control exception. This has the same observable mailbox semantics
% as SWI's pre-guard deferred fact.
remember_incoming(Deferred, SavedMsg, Pending) :-
    append(Deferred, [SavedMsg], Pending),
    deferred_put(Pending).

preserve_control_exception(Deferred, SavedMsg, Error) :-
    remember_incoming(Deferred, SavedMsg, _),
    throw(Error).

%!  select_deferred(+Deferred, +Clauses, -Body, -Rest) is semidet.
%
%   Find the first message in the Deferred list that matches Clauses,
%   returning its Body and the remainder of the deferred list.

select_deferred([Msg|Rest], Clauses, Body, Rest) :-
    select_body(Clauses, Msg, Body), !.
select_deferred([Msg|Rest0], Clauses, Body, [Msg|Rest]) :-
    select_deferred(Rest0, Clauses, Body, Rest).

%!  deferred_list(-L) is det.
%!  deferred_put(+L) is det.
%
%   Read/write the native thread-local deferred message list.

deferred_list(L) :-
    ( nb_current('$actor_deferred', L) -> true ; L = [] ).

deferred_put(L) :-
    nb_setval('$actor_deferred', L).


%!  select_body(+Clauses, +Message, -Body) is semidet.
%
%   Try to match Message against the first applicable clause in the
%   brace-wrapped clause set Clauses.  Receives the module-qualified
%   form `M:{...}` produced by meta_predicate expansion.

select_body(_M:{Clauses}, Message, Body) :-
    select_body_aux(Clauses, Message, Body).

%!  select_body_aux(+Clauses, +Message, -Body) is semidet.
%
%   Recursively try each clause in the disjunction. Matching is one-sided: the
%   pattern must subsume the message. For a guarded clause, ordinary errors are
%   non-matches while reserved control exceptions propagate.

select_body_aux((Clause ; Clauses), Message, Body) :-
    (   select_body_aux(Clause,  Message, Body)
    ;   select_body_aux(Clauses, Message, Body)
    ).
select_body_aux((Head -> Body), Message, Body) :-
    (   nonvar(Head),
        Head = if(Pattern, Guard)
    ->  match_message(Pattern, Message),
        catch(once(Guard), Error, guard_exception(Error))
    ;   match_message(Head, Message)
    ).

match_message(Pattern, Message) :-
    subsumes_term(Pattern, Message),
    Pattern = Message.

guard_exception(Error) :-
    guard_control_exception(Error),
    !,
    throw(Error).
guard_exception(_) :-
    fail.

% Reserved transfers used by the Trealla actor and PTCP layers, plus the SWI
% forms accepted on shared source paths.
guard_control_exception(actor_exit).
guard_control_exception('$abort_goal').
guard_control_exception('$resource_idle').
guard_control_exception('$ptcp_time_limit').
guard_control_exception(time_limit_exceeded).
guard_control_exception(error(time_limit_exceeded(_, _), _)).
guard_control_exception(unwind(_)).


                /*******************************
                *      VARIOUS UTILITIES       *
                *******************************/


%!  flush is det.
%
%   Drain the calling actor's mailbox, sending each message through the
%   inherited terminal target. This matches the SWI implementation and keeps
%   flush output visible to browser and remote terminals. Uses `timeout(0)`
%   so it returns immediately once the mailbox is empty.

flush :-
    receive({
       Message ->
          term_to_atom(Message, Atom),
          atom_concat('Shell got ', Atom, Text),
          terminal_output(Text),
          flush
    },[timeout(0), on_timeout(true)]).


%!  make_ref(-Ref) is det.
%
%   Generate a process-lifetime unique ten-digit reference.  Public Trealla
%   nodes use the same representation for references and PIDs as the SWI
%   distribution layer.  The two allocation sets are checked together so a
%   reference cannot be confused with a PID minted by this process.

make_ref(Ref) :-
    flag('$actor_ref', Offset, Offset + 1),
    Candidate is 1000000000 + Offset,
    ( Candidate =< 9999999999 -> true
    ; throw(error(resource_error(actor_references), actors:make_ref/1))
    ),
    with_mutex('$actor_registry', reserve_ref(Candidate, Reserved)),
    ( Reserved == true -> Ref = Candidate ; make_ref(Ref) ).

reserve_ref(Candidate, Reserved) :-
    ( issued_pid(Candidate) -> Reserved = false
    ; assertz(issued_ref(Candidate)), Reserved = true
    ).

%!  make_pid(-Pid) is det.
%
%   Mint a process-unique ten-digit logical actor identifier. Allocation and
%   registry insertion share '$actor_registry', so concurrent self/spawn
%   calls cannot claim the same candidate.

make_pid(Pid) :-
    with_mutex('$actor_registry', make_pid_unlocked(Pid)).

make_pid_unlocked(Pid) :-
    random_between(1000000000, 9999999999, Candidate),
    ( issued_pid(Candidate) -> make_pid_unlocked(Pid)
    ; issued_ref(Candidate) -> make_pid_unlocked(Pid)
    ; assertz(issued_pid(Candidate)),
      Pid = Candidate
    ).


                /*******************************
                *     OUTPUT / INPUT / RESPOND *
                *******************************/

set_parent(Parent) :-
    nb_setval('$actor_parent', Parent).

get_parent(Parent) :-
    ( nb_current('$actor_parent', Parent) -> true ; self(Parent) ).


%!  output(+Term) is det.
%!  output(+Term, +Options) is det.
%
%   Send `output(Self, Term)` to the target process (default: this
%   actor's parent).  Options:
%
%     - target(+Pid)
%       Override the default target.

output(Term) :-
    output(Term, []).

output(Term, Options) :-
    self(Self),
    get_parent(Parent),
    option(target(Target), Options, Parent),
    Target ! output(Self, Term).


%!  terminal_output(+Term) is det.
%!  terminal_output(+Term, +Options) is det.
%
%   Send textual terminal output.  Unlike output/1, the default target is
%   inherited independently of the actor parent, allowing an actor tree to
%   share one terminal even when descendants run on another node.

terminal_output(Term) :-
    terminal_output(Term, []).

terminal_output(Term, Options) :-
    self(Self),
    ( option(target(Target), Options) -> true
    ; current_io_target(Target) -> true
    ; get_parent(Target)
    ),
    ( memberchk(source(io), Options) ->
        Target ! terminal_io_output(Self, Term)
    ; Target ! terminal_output(Self, Term)
    ).

%!  current_io_target(-Target) is semidet.

current_io_target(Target) :-
    nb_current('$actor_io_target', Target).


%!  input(+Prompt, -Answer) is det.
%!  input(+Prompt, -Answer, +Options) is det.
%
%   Request input from the target process.  Sends `prompt(Self, Prompt)`
%   to the target, then blocks until the target replies with
%   `'$input'(From, Answer)`.  The sender is intentionally not required to be
%   identical to the terminal target: distributed terminal endpoints return a
%   connection-scoped actor capability.  Options:
%
%     - target(+Pid)
%       Override the default target (the actor's parent).

input(Prompt, Answer) :-
    input(Prompt, Answer, []).

input(Prompt, Answer, Options) :-
    self(Self),
    ( option(target(Target), Options) -> true
    ; actor_input_target(Self, Target) -> true
    ; current_io_target(Target) -> true
    ; get_parent(Target)
    ),
    Target ! prompt(Self, Prompt),
    receive({
        '$input'(_From, Answer) -> true
    }).

actor_input_target(_Self, Target) :-
    nb_current('$actor_input_target', Target).

set_input_target(Target) :-
    nb_setval('$actor_input_target', Target).



%!  respond(+Pid, +Answer) is det.
%
%   Reply to an actor Pid that is blocked in input/2,3.  Sends
%   `'$input'(Self, Answer)` to Pid.

respond(Pid, Answer) :-
    self(Self),
    Pid ! '$input'(Self, Answer).
