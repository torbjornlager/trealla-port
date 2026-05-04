:- module(actors,
       [ spawn/1,                % :Goal
         spawn/2,                % :Goal, -Pid
         spawn/3,                % :Goal, -Pid, +Options
         self/1,                 % -Pid
         monitor/2,              % +PidOrName, -Ref
         demonitor/1,            % +Ref
         demonitor/2,            % +Ref, +Options
         register/2,             % +Name, +Pid
         unregister/1,           % +Name
         whereis/2,              % +Name, -Pid
         exit/1,                 % +Reason
         exit/2,                 % +Pid, +Reason
         (!)/2,                  % +Pid, +Message
         send/2,                 % +Pid, +Message
         input/2,                % +Prompt, -Answer
         input/3,                % +Prompt, -Answer, +Options
         respond/2,              % +Pid, +Answer
         output/1,               % +Term
         output/2,               % +Term, +Options
         receive/1,              % +ReceiveClauses
         receive/2,              % +ReceiveClauses, +Options
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

The library is deliberately small.  Compared with a more complete
Erlang-on-Prolog implementation, it omits:

  - *Goal isolation*: there is no `load_*` option to sandbox a spawned
    goal; spawned code runs in the caller's module space.
  - *Distribution*: all actors run in the same Prolog process; there
    is no `node` option and no network transport.

What it does provide:

  - spawn/1, spawn/2, spawn/3 to launch a new actor running a goal
  - self/1 to obtain the current actor's PID
  - (!)/2 / send/2 for asynchronous message passing
  - receive/1, receive/2 for Erlang-style pattern-matched, guarded,
    optionally timed-out mailbox reads
  - monitor/2 / demonitor/1,2 for passive lifecycle notifications
  - A `link` option on spawn/3 for eager lifecycle coupling
  - register/2, unregister/1, whereis/2 for naming actors
  - exit/1, exit/2 for terminating processes with a reason

## Mailboxes {#actors-mailboxes}

Every actor has an ordered mailbox.  `Pid ! Message` enqueues `Message`
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
match any clause, those messages are moved to a per-thread *deferred
list* stored on the thread-local blackboard under the key
`'$actor_deferred'`.  Deferred messages are re-offered to the next
receive call before the live mailbox is consulted.  Trealla's
`bb_put/2` and `bb_get/2` are thread-local, so the deferred list is
private to each actor.

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

  - `library(debug)` is absent and has been dropped (it was unused).
  - `thread_get_message/3` exists in v2.94.20 and accepts a
    `timeout(Float)` option, but its granularity is far too coarse
    to use directly: a request for 0.05 s actually returns after
    ~0.93 s; 0.1 s after ~2 s. Non-zero timeouts in receive/2 are
    therefore still emulated by spawning a short-lived *timer actor*
    that sleeps for the requested duration via `sleep/1` (which is
    accurate) and then sends a unique `'$actor_timeout'(Ref)`
    sentinel to the receiver.
  - `thread_local/1` is absent.  Per-thread state (deferred message
    list, parent PID) is stored on the thread-local blackboard via
    `bb_put/2` and `bb_get/2`.
  - `thread_signal/2` on a completed detached thread raises a
    domain_error in Trealla.  Both exit/2 and send/2 guard against
    this with the `actor_alive/1` table.
  - make_ref/1 uses `random_between/3` rather than a true monotone
    counter.  In a busy system, 8-digit random refs could (rarely)
    collide; use with care in protocols that rely on ref uniqueness.

@author Torbjörn Lager
*/


                /*******************************
                *             ACTOR            *
                *******************************/


:- meta_predicate(spawn(0)).
:- meta_predicate(spawn(0, -)).
:- meta_predicate(spawn(0, -, +)).
:- meta_predicate(receive(:, +)).


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

:- dynamic(link/2).

spawn(Goal) :-
    spawn(Goal, _Pid).

spawn(Goal, Pid) :-
    spawn(Goal, Pid, []).

spawn(Goal, Pid, Options) :-
    thread_self(Self),
    thread_create(start(Self, Pid, Goal, Options), Pid, [
        detached(true),
        at_exit(stop(Pid, Self))
    ]),
    thread_get_message(initialized(Pid)).



:- dynamic(actor_alive/1).

% Every actor we can safely signal or send to must be in actor_alive/1.
% Register the top-level thread at load time so messages from within
% the library can reach it.
:- initialization((thread_self(Me), assertz(actor_alive(Me)))).

%!  start(+Parent, +Pid, :Goal, +Options) is det.
%
%   Internal entry point for a newly created actor thread.  Registers
%   the actor as alive, sets up any link/monitor, signals the parent
%   that initialisation is complete, then calls Goal.  The exit reason
%   is recorded explicitly in exit_reason/2 because Trealla's
%   at_exit hook runs while `thread_property/2` still reports
%   `status(running)`, making the usual SWI approach of reading the
%   status in stop/2 unreliable.

start(Parent, Pid, Goal, Options) :-
    assertz(actor_alive(Pid)),
    set_parent(Parent),
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(link(Parent, Pid))
    ;   true
    ),
    option(monitor(Monitor), Options, false),
    (   Monitor == true
    ->  assertz(monitor(Parent, Pid, Pid))
    ;   true
    ),
    thread_send_message(Parent, initialized(Pid)),
    % Record outcome explicitly: Trealla's thread_property/2 still
    % reports status(running) inside the at_exit hook, so we can't
    % read the outcome from it the way SWI does.
    catch(
        ( call(Goal)
        ->  assertz(exit_reason(Pid, true))
        ;   assertz(exit_reason(Pid, false))
        ),
        E,
        ( E == actor_exit
        ->  true                % exit/1 already asserted the reason
        ;   assertz(exit_reason(Pid, exception(E)))
        )
    ).


%!  stop(+Pid, +Parent) is det.
%
%   at_exit hook called when actor Pid terminates.  Tears down all
%   bookkeeping: removes the actor from actor_alive/1, retracts the
%   link, kills any actors linked to Pid, and delivers down/3 messages
%   to any monitors.

stop(Pid, Parent) :-
    % Retract actor_alive first, so concurrent exit/2 and send/2 on
    % this Pid stop trying to deliver through the now-dead thread.
    retractall(actor_alive(Pid)),
    % No thread_detach here: the thread was spawned with detached(true)
    % because calling thread_detach from inside at_exit hangs the
    % hook on Trealla.
    retractall(link(Parent, Pid)),
    retractall(registered(_Name, Pid)),
    forall(retract(link(Pid, ChildPid)),
           exit(ChildPid, linked)),
    down_reason(Pid, Reason),
    forall(retract(monitor(Other, Pid, Ref)),
           Other ! down(Pid, Ref, Reason)).


%!  down_reason(+Pid, -Reason) is det.
%
%   Retrieve and retract the recorded exit reason for Pid.  Falls back
%   to `noproc` if no reason was recorded (e.g. the thread was
%   terminated externally before it could call assertz).

down_reason(Pid, Reason) :-
    retract(exit_reason(Pid, Reason)),
    !.
down_reason(_, noproc).




%!  self(-Pid) is det.
%
%   Unify Pid with the calling actor's own identifier (its thread ID).

self(Self) :-
    thread_self(Self).


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
    whereis(Name, Pid),
    !,
    monitor(Pid, Ref).
monitor(Pid, Ref) :-
    self(Self),
    make_ref(Ref),
    assertz(monitor(Self, Pid, Ref)).


demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    retractall(monitor(_, _, Ref)),
    (   option(flush, Options)
    ->  receive({
            down(_, Ref, _) ->
                true
        }, [timeout(0)])
    ;   true
    ).


%!  register(+Name, +Pid) is det.
%
%   Register the given Pid under the atom Name.  Throws
%   `process_already_has_a_name(Pid)` if Pid is already registered
%   under any name, or `name_is_in_use(Name)` if Name is already
%   taken by another Pid.

:- dynamic(registered/2).

register(Name, Pid) :-
    must_be(atom, Name),
    (   registered(_, Pid)
    ->  throw(process_already_has_a_name(Pid))
    ;   registered(Name, _)
    ->  throw(name_is_in_use(Name))
    ;   asserta(registered(Name, Pid))
    ).

%!  unregister(+Name) is det.
%
%   Remove any registration under Name.  Succeeds even if Name was not
%   registered.

unregister(Name) :-
    retractall(registered(Name, _)).

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
    asserta(exit_reason(Self, Reason)),
    throw(actor_exit).


%!  exit(+Pid, +Reason) is det.
%
%   Send an exit signal with Reason to the actor identified by Pid.
%   If Pid does not exist (or has already exited), succeeds silently.
%
%   Implementation note: in Trealla v2.94.16 thread_signal/2 raises a
%   catchable domain_error on a dead detached thread, so the catch is
%   the safety net. We still consult actor_alive/1 to skip the signal
%   in the common case where the target is already gone (mostly to
%   stay symmetrical with send/2, where thread_send_message errors
%   are still uncatchable).

exit(Pid, Reason) :-
    (   actor_alive(Pid)
    ->  catch(thread_signal(Pid, actors:exit(Reason)), _, true)
    ;   true
    ).


%!  !(+PidOrName, +Message) is det.
%!  send(+PidOrName, +Message) is det.
%
%   Asynchronously send Message to the actor identified by PidOrName.
%   PidOrName may be either a raw PID (thread ID) or an atom previously
%   bound with register/2.  Returns immediately; delivery is reliable
%   within a single Prolog process.  If the target actor does not exist
%   (not in actor_alive/1), the message is silently dropped.

Pid ! Message :-
    send(Pid, Message).

send(Name, Message) :-
    registered(Name, Pid),
    !,
    send(Pid, Message).
send(Pid, Message) :-
    % Same liveness guard as exit/2.
    (   actor_alive(Pid)
    ->  catch(thread_send_message(Pid, Message), _, true)
    ;   true
    ).


%!  receive(+ReceiveClauses) is semidet.
%!  receive(+ReceiveClauses, +Options) is semidet.
%
%   Erlang-style mailbox read.  Blocks until a message in the mailbox
%   matches one of the clauses in ReceiveClauses, then executes the
%   corresponding body.  Messages that do not match any clause are
%   moved to the per-thread deferred list and remain available to
%   subsequent receive calls.
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
%       Guard succeeds.  Guard is called deterministically via once/1;
%       any error causes the clause not to match.
%
%   Clauses are tried top-to-bottom against each mailbox message, with
%   the mailbox scanned in arrival order.
%
%   Options (receive/2 only):
%
%     - timeout(+Seconds)
%       Maximum time in seconds to wait for a matching message.
%       `timeout(0)` makes the call a non-blocking poll.  Positive
%       numeric values are emulated via a short-lived timer actor
%       (see Trealla port notes above).  When the timeout expires
%       with no match, the goal given by on_timeout/1 is called.
%       Default: wait indefinitely.
%     - on_timeout(:Goal)
%       Goal called when the timeout expires.  Default: `true`.
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
%   ==
%
%   Trealla port note: deferred messages live on the per-thread
%   blackboard as a list under the key `'$actor_deferred'`.  Trealla's
%   `bb_put/2` and `bb_get/2` are thread-local, so the deferred list
%   is private to each actor.  Positive timeouts are emulated with a
%   helper timer actor (see the module-level Trealla port notes).

receive(Clauses) :-
    receive(Clauses, []).

receive(Clauses, Options) :-
    thread_self(Mailbox),
    deferred_list(Deferred),
    (   select_deferred(Deferred, Clauses, Body, Rest)
    ->  deferred_put(Rest),
        call(Body)
    ;   receive_loop(Mailbox, Clauses, Options, Deferred)
    ).

%!  receive_loop(+Mailbox, +Clauses, +Options, +Deferred) is semidet.
%
%   Dispatcher for the three timeout regimes:
%
%     - `timeout(0)`     -- non-blocking poll (receive_loop_poll/4).
%     - `timeout(T)`, T>0 -- blocking with deadline, emulated via a
%       timer actor (receive_loop_timed/5).
%     - no timeout / `infinite` -- block forever (receive_loop_blocking/4).

receive_loop(Mailbox, Clauses, Options, Deferred) :-
    option(timeout(T), Options, infinite),
    (   T == 0
    ->  receive_loop_poll(Mailbox, Clauses, Options, Deferred)
    ;   T == infinite
    ->  receive_loop_blocking(Mailbox, Clauses, Options, Deferred)
    ;   number(T), T > 0
    ->  receive_loop_timed(Mailbox, Clauses, Options, Deferred, T)
    ;   throw(error(domain_error(timeout, T), receive/2))
    ).

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
%   Positive timeout, emulated because Trealla has no
%   thread_get_message/3.  Spawn a timer actor that sleeps T seconds
%   then sends `'$timeout'(TimerPid)` to us; block in
%   thread_get_message/2 and treat the sentinel as a timeout.
%
%   The TimerPid is unique per call, so the sentinel cannot collide
%   with any user message.  After the loop exits (whether by match or
%   timeout) cancel_timer/2 attempts to kill the timer and drain any
%   pending sentinel from the front of the mailbox.  Stale sentinels
%   that arrived behind other messages are filtered out by
%   prune_stale/2 the next time the deferred list is read.

receive_loop_timed(Mailbox, Clauses, Options, Deferred, T) :-
    self(Self),
    make_ref(Ref),
    spawn(timer_actor(Self, T, Ref), TimerPid, [link(false)]),
    catch(
        % Cancel only on the match path -- on the timeout path the
        % timer is already exiting and signalling it would race with
        % its own at_exit hook.
        ( timed_loop(Mailbox, Clauses, Options, Deferred, Ref),
          cancel_timer(TimerPid, Self, Ref) ),
        '$receive_timeout'(Ref),
        ( deferred_put(Deferred),
          option(on_timeout(Goal), Options, true),
          call(Goal) )
    ).

%!  timer_actor(+Target, +T, +Ref) is det.
%
%   Helper actor body: sleep T seconds then send
%   `'$actor_timeout'(Ref)` to Target.  Ref is a fresh atom generated
%   by make_ref/1; it discriminates this timer's sentinel from any
%   other message and (crucially) is an atom so it survives Trealla's
%   throw/catch round-trip cleanly.  (Compound terms containing
%   `$thread'(N)' opaque cells lose identity through throw/catch in
%   Trealla, which is why we cannot use TimerPid directly here.)

timer_actor(Target, T, Ref) :-
    sleep(T),
    Target ! '$actor_timeout'(Ref).

%!  timed_loop(+Mailbox, +Clauses, +Options, +Deferred, +Ref) is semidet.
%
%   Inner loop for receive_loop_timed/5.  Each retrieved message is
%   first checked against the timeout sentinel; if it matches, throw
%   `'$receive_timeout'(Ref)` to exit the catch in the caller.

timed_loop(Mailbox, Clauses, Options, Deferred, Ref) :-
    thread_get_message(Mailbox, Msg),
    (   Msg == '$actor_timeout'(Ref)
    ->  throw('$receive_timeout'(Ref))
    ;   select_body(Clauses, Msg, Body)
    ->  deferred_put(Deferred),
        call(Body)
    ;   append(Deferred, [Msg], Deferred1),
        timed_loop(Mailbox, Clauses, Options, Deferred1, Ref)
    ).

%!  cancel_timer(+TimerPid, +Self, +Ref) is det.
%
%   Match-path teardown for a still-running timer.  Sends `cancelled`
%   to TimerPid via exit/2 -- thread_signal/2 in Trealla does not
%   interrupt sleep/1, so the timer will still run to its natural
%   end, but enqueueing the exit ensures the thread is reaped cleanly
%   on Prolog halt (without it, the still-sleeping timer triggers a
%   segfault during halt).  Trealla prints a brief diagnostic line
%   ("*** signals...") for the queued signal; that noise is harmless.
%
%   Then peek the front of the mailbox once for an already-arrived
%   `'$actor_timeout'(Ref)` sentinel and discard it.  Sentinels that
%   arrived behind other messages remain briefly in the mailbox;
%   they are filtered by prune_stale/2 on the next receive call.

cancel_timer(TimerPid, Self, Ref) :-
    exit(TimerPid, cancelled),
    (   thread_peek_message(Self, '$actor_timeout'(Ref))
    ->  thread_get_message(Self, '$actor_timeout'(Ref))
    ;   true
    ).

%!  handle_incoming(+Mailbox, +Clauses, +Options, +Deferred, +Msg) is semidet.
%
%   Attempt to match Msg against Clauses.  On success, restore the
%   deferred list and run the body.  On failure, append Msg to Deferred
%   and loop.

handle_incoming(Mailbox, Clauses, Options, Deferred, Msg) :-
    (   select_body(Clauses, Msg, Body)
    ->  deferred_put(Deferred),
        call(Body)
    ;   append(Deferred, [Msg], Deferred1),
        receive_loop(Mailbox, Clauses, Options, Deferred1)
    ).

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
%   Read/write the per-thread deferred message list from/to the
%   thread-local blackboard.  deferred_list/1 also prunes stale
%   `'$timeout'(P)` sentinels (timers that have already exited) so
%   the deferred list does not grow unboundedly across many timed
%   receive calls.

deferred_list(L) :-
    (   bb_get('$actor_deferred', Raw) -> true ; Raw = [] ),
    prune_stale(Raw, L).

deferred_put(L) :-
    bb_put('$actor_deferred', L).

%!  prune_stale(+Raw, -Pruned) is det.
%
%   Drop `'$actor_timeout'(_)` sentinels from the deferred list.  Any
%   such sentinel sitting in the deferred list at the entry of a
%   receive call is by definition stale: receive/2 is synchronous, so
%   the timer that produced it has already exited and its receive has
%   already returned (otherwise the sentinel would have been consumed
%   inside timed_loop/5).  This GC step prevents the deferred list
%   from growing unboundedly across many timed receive calls in
%   high-message-rate scenarios where cancel_timer/3's best-effort
%   peek-and-drain misses the sentinel.

prune_stale([], []).
prune_stale(['$actor_timeout'(_)|T0], T) :- !,
    prune_stale(T0, T).
prune_stale([H|T0], [H|T]) :-
    prune_stale(T0, T).


%!  select_body(+Clauses, +Message, -Body) is semidet.
%
%   Try to match Message against the first applicable clause in the
%   brace-wrapped clause set Clauses.  Accepts both module-qualified
%   `M:{...}` forms (produced by meta_predicate expansion) and plain
%   `{...}` forms (used when the calling module re-exports receive/1
%   without copying the meta_predicate declaration, as happens in
%   Trealla's module system).

select_body(_M:{Clauses}, Message, Body) :-
    select_body_aux(Clauses, Message, Body).
select_body({Clauses}, Message, Body) :-
    select_body_aux(Clauses, Message, Body).

%!  select_body_aux(+Clauses, +Message, -Body) is semidet.
%
%   Recursively try each clause in the disjunction.  For a guarded
%   clause `Pattern if Guard -> Body`, the guard is called via once/1
%   and any error is treated as a non-match.

select_body_aux((Clause ; Clauses), Message, Body) :-
    (   select_body_aux(Clause,  Message, Body)
    ;   select_body_aux(Clauses, Message, Body)
    ).
select_body_aux((Head -> Body), Message, Body) :-
    (   subsumes_term(if(Pattern, Guard), Head)
    ->  if(Pattern, Guard) = Head,
        subsumes_term(Pattern, Message),
        Pattern = Message,
        catch(once(Guard), _, fail)
    ;   subsumes_term(Head, Message),
        Head = Message
    ).


                /*******************************
                *      VARIOUS UTILITIES       *
                *******************************/


%!  flush is det.
%
%   Drain the calling actor's mailbox, printing each message to the
%   current output stream.  Intended as a debugging aid at the toplevel;
%   not for use inside normal actor code.  Uses `timeout(0)` so it
%   returns immediately once the mailbox is empty.

flush :-
    receive({
       Message ->
          format("Shell got ~q~n",[Message]),
          flush
    },[ timeout(0)]).


%!  make_ref(-Ref) is det.
%
%   Generate a fresh reference atom by drawing a random 8-digit integer.
%   Useful for correlating request/reply pairs (see the rpc pattern).
%
%   Caveat: because this uses random_between/3 rather than a monotone
%   counter or a UUID library, there is a small but non-zero probability
%   of two refs colliding in a busy system.  For typical interactive
%   use the collision risk is negligible.

make_ref(Ref) :-
    random_between(10000000, 99999999, Num),
    % atom_number/2 in Trealla only works in the parse direction
    % (atom -> number), so use format/3 to build the atom from Num.
    format(atom(Ref), '~w', [Num]).


                /*******************************
                *     OUTPUT / INPUT / RESPOND *
                *******************************/

% Parent is tracked per-thread via the bb blackboard.
% The key is made thread-specific so that each actor has its own parent.

set_parent(Parent) :-
    thread_self(Me),
    format(atom(Key), '$actor_parent_~w', [Me]),
    bb_put(Key, Parent).

get_parent(Parent) :-
    thread_self(Me),
    format(atom(Key), '$actor_parent_~w', [Me]),
    (bb_get(Key, Parent) -> true ; Parent = Me).


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


%!  input(+Prompt, -Answer) is det.
%!  input(+Prompt, -Answer, +Options) is det.
%
%   Request input from the target process.  Sends `prompt(Self, Prompt)`
%   to the target, then blocks until the target replies with
%   `'$input'(Target, Answer)`.  Options:
%
%     - target(+Pid)
%       Override the default target (the actor's parent).

input(Prompt, Answer) :-
    input(Prompt, Answer, []).

input(Prompt, Answer, Options) :-
    self(Self),
    get_parent(Parent),
    option(target(Target), Options, Parent),
    Target ! prompt(Self, Prompt),
    receive({
        '$input'(Target, Answer) -> true
    }).


%!  respond(+Pid, +Answer) is det.
%
%   Reply to an actor Pid that is blocked in input/2,3.  Sends
%   `'$input'(Self, Answer)` to Pid.

respond(Pid, Answer) :-
    self(Self),
    Pid ! '$input'(Self, Answer).
