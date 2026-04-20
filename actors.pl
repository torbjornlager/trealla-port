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
on top of the ISO Prolog `thread_*` primitives. Processes (*actors*)
are lightweight, share no mutable state, and communicate exclusively
by asynchronous message passing.

The library is deliberately small. Compared with a more complete
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

Every actor has an ordered mailbox. `Pid ! Message` enqueues `Message`
and returns immediately. receive/1,2 consumes messages in arrival
order, with pattern matching and guards selecting which message is
extracted; non-matching messages are left in the mailbox and remain
available to later receive/1,2 calls.

## Links versus monitors {#actors-links-monitors}

A *link* is bidirectional and eager: when a linked actor exits, its
peer is sent an exit signal. Links are set up with the `link(true)`
option on spawn/3 (currently the default) and are primarily a
supervision tool.

A *monitor* is unidirectional and passive: when the monitored actor
exits, the monitoring actor receives a `down(Pid, Ref, Reason)`
message in its mailbox. Monitors are set up with the `monitor(true)`
option on spawn/3, or by calling monitor/2 explicitly, and are
primarily an observation tool.

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

@author Torbjörn Lager
*/

                /*******************************
                *             ACTOR            *
                *******************************/


% --- Trealla compatibility shims -------------------------------------
% library(debug) dropped (unused here).
% library(option) absent on Trealla; minimal option/2,3 provided below.

option(Opt, Options, _Default) :-
    memberchk(Opt, Options), !.
option(Opt, _, Default) :-
    functor(Opt, _, 1),
    arg(1, Opt, Default).

option(Opt, Options) :-
    memberchk(Opt, Options).

% is_thread/1 absent on Trealla; emulate via thread_property/2.
is_thread(Id) :-
    catch(thread_property(Id, status(_)), _, fail).
% ---------------------------------------------------------------------

:- meta_predicate(spawn(0)).
:- meta_predicate(spawn(0, -)).
:- meta_predicate(spawn(0, -, +)).
:- meta_predicate(receive(:, +)).


%!  spawn(:Goal) is det.
%!  spawn(:Goal, -Pid) is det.
%!  spawn(:Goal, -Pid, +Options) is det.
%
%   Spawn a new actor that calls Goal. The new actor's PID is unified
%   with Pid. Options:
%
%     - monitor(+Bool)
%       If `true`, the spawning actor monitors the new actor and
%       receives a `down(Pid, Ref, Reason)` message when it exits.
%       As a convenience, the monitor's Ref is the spawned Pid
%       itself, so the `down` message arrives as
%       `down(Pid, Pid, Reason)` and the monitor can be cancelled
%       with `demonitor(Pid)`. Default: `false`.
%     - link(+Bool)
%       If `true`, the spawning actor and the new actor are linked:
%       either exiting will propagate an exit signal to the other.
%       Default: `true`.

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

start(Parent, Pid, Goal, Options) :-
    assertz(actor_alive(Pid)),
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


down_reason(Pid, Reason) :-
    retract(exit_reason(Pid, Reason)),
    !.
down_reason(_, noproc).

           
   


%!  self(-Pid) is det.
%
%   Find who we are.

self(Self) :-
    thread_self(Self).


%!  monitor(+PidOrName, -Ref) is det.
%
%   Start monitoring the actor identified by PidOrName. Ref is unified
%   with a fresh reference that identifies this monitor. When the
%   monitored actor exits, a `down(Pid, Ref, Reason)` message is
%   delivered to the calling actor's mailbox.
%
%   Note: when a monitor is set up via the `monitor(true)` option of
%   spawn/3 instead of by calling monitor/2, the monitored Pid is
%   reused as the Ref. See spawn/3.

%!  demonitor(+Ref) is det.
%!  demonitor(+Ref, +Options) is det.
%
%   Remove the monitor identified by Ref. For monitors installed via
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
%   Register the given Pid under the name Name.

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
%   Remove any registration under Name. Succeeds even if Name was not
%   registered.

unregister(Name) :-
    retractall(registered(Name, _)).
    
%!  whereis(+Name, -Pid) is det.
%
%   Look up the PID registered under Name. If no such registration
%   exists, Pid is unified with the atom `undefined` (rather than
%   failing).

whereis(Name, Pid) :-
    must_be(atom, Name),
    registered(Name, Pid),
    !.
whereis(_Name, undefined).


%!  exit(+Reason)
%
%   Exit the calling process.

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
%   If Pid does not exist, succeeds silently.

exit(Pid, Reason) :-
    % Trealla's thread_signal on a detached, completed thread raises
    % an uncatchable domain_error. So we guard with our own liveness
    % table (actor_alive/1): we only try to signal if the actor has
    % not yet run its at_exit hook.
    %
    % We inject '$do_exit'(Pid, Reason) as a ground term rather than
    % exit(Reason), because calling thread_self/1 inside a goal
    % delivered by thread_signal raises uninstantiation_error on
    % Trealla. Passing Pid in directly side-steps that.
    (   actor_alive(Pid)
    ->  catch(thread_signal(Pid, actors:'$do_exit'(Pid, Reason)), _, true)
    ;   true
    ).

'$do_exit'(Pid, Reason) :-
    asserta(exit_reason(Pid, Reason)),
    throw(actor_exit).


%!  !(+PidOrName, +Message) is det.
%!  send(+PidOrName, +Message) is det.
%
%   Asynchronously send Message to the actor identified by PidOrName.
%   PidOrName may be either a raw PID or an atom previously bound with
%   register/2. Returns immediately; delivery is reliable within a
%   single Prolog process. If the target actor does not exist, the
%   message is silently dropped.

Pid ! Message :-
    send(Pid, Message).

send(Name, Message) :-
    registered(Name, Pid),
    !,
    send(Pid, Message).
send(Pid, Message) :-
    % Same issue as exit/2: guard with actor_alive/1.
    (   actor_alive(Pid)
    ->  catch(thread_send_message(Pid, Message), _, true)
    ;   true
    ).


%!  receive(+ReceiveClauses) is semidet.
%!  receive(+ReceiveClauses, +Options) is semidet.
%
%   Erlang-style mailbox read. Blocks until a message in the mailbox
%   matches one of the clauses in ReceiveClauses, then executes the
%   corresponding body. Messages that do not match any clause are
%   left in the mailbox in their original order and remain available
%   to subsequent calls.
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
%       Matches any message subsumed by Pattern. On match, Pattern is
%       unified with the message and Body is called.
%     - `Pattern if Guard -> Body`
%       Matches only if the message is subsumed by Pattern *and*
%       Guard succeeds. Guard is a Prolog goal that may refer to
%       variables in Pattern; it is called deterministically (via
%       once/1) and any error causes the clause not to match.
%
%   Clauses are tried top-to-bottom against each mailbox message, and
%   the mailbox is scanned in arrival order.
%
%   Options (receive/2 only):
%
%     - timeout(+Seconds)
%       Maximum time in seconds to wait for a matching message.
%       A timeout of `0` makes the call non-blocking (poll). When
%       the timeout expires with no match, the goal given by
%       on_timeout/1 is called. Default: wait indefinitely.
%     - on_timeout(:Goal)
%       Goal called on timeout. Default: `true`.
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
%   % Wait up to five seconds, then retry.
%   receive({
%       reply(R) -> use(R)
%   }, [ timeout(5), on_timeout(retry) ])
%
%   % Non-blocking poll: fail immediately if nothing is waiting.
%   receive({ Msg -> use(Msg) },
%           [ timeout(0), on_timeout(fail) ])
%   ==

% Trealla port note: deferred messages live on the per-thread
% blackboard as a list under key '$actor_deferred', because Trealla has
% no thread_local/1. Trealla also has no thread_get_message/3, so
% non-zero timeouts are not supported here — timeout(0) (poll) works
% via thread_peek_message/2.

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

receive_loop(Mailbox, Clauses, Options, Deferred) :-
    (   option(timeout(T), Options, infinite),
        T == 0
    ->  (   thread_peek_message(Mailbox, _)
        ->  thread_get_message(Mailbox, Msg),
            handle_incoming(Mailbox, Clauses, Options, Deferred, Msg)
        ;   deferred_put(Deferred),
            option(on_timeout(Goal), Options, true),
            call(Goal)
        )
    ;   option(timeout(T), Options, infinite),
        T \== infinite
    ->  throw(error(unsupported_option(timeout(T)),
                    'Trealla port: only timeout(0) is supported'))
    ;   thread_get_message(Mailbox, Msg),
        handle_incoming(Mailbox, Clauses, Options, Deferred, Msg)
    ).

handle_incoming(Mailbox, Clauses, Options, Deferred, Msg) :-
    (   select_body(Clauses, Msg, Body)
    ->  deferred_put(Deferred),
        call(Body)
    ;   append(Deferred, [Msg], Deferred1),
        receive_loop(Mailbox, Clauses, Options, Deferred1)
    ).

select_deferred([Msg|Rest], Clauses, Body, Rest) :-
    select_body(Clauses, Msg, Body), !.
select_deferred([Msg|Rest0], Clauses, Body, [Msg|Rest]) :-
    select_deferred(Rest0, Clauses, Body, Rest).

deferred_list(L) :-
    (   bb_get('$actor_deferred', L) -> true ; L = [] ).

deferred_put(L) :-
    bb_put('$actor_deferred', L).

    
select_body(_M:{Clauses}, Message, Body) :-
    select_body_aux(Clauses, Message, Body).

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
%   current output stream. Intended as a debugging aid at the
%   toplevel; not for use inside normal actor code.

flush :-
    receive({
       Message ->
          format("Shell got ~q~n",[Message]),
          flush
    },[ timeout(0)]).


    

%!  make_ref(-Ref) is det.
%
%   Generate a fresh reference atom, useful for correlating request
%   and reply messages (see the rpc pattern).

make_ref(Ref) :-
    random_between(10000000, 99999999, Num),
    atom_number(Ref, Num).
   
   
