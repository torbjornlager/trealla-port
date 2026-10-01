% SPDX-License-Identifier: MIT

:- module(toplevel_actors,
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
         input/2,                % +Prompt, -Answer
         input/3,                % +Prompt, -Answer, +Options
         respond/2,              % +Pid, +Answer
         output/1,               % +Term
         output/2,               % +Term, +Options
         receive/1,              % +ReceiveClauses
         receive/2,              % +ReceiveClauses, +Options
         make_ref/1,             % -Ref
         flush/0,

         offset/2,               % +N, :Goal

         toplevel_spawn/1,       % -Pid
         toplevel_spawn/2,       % -Pid, +Options
         toplevel_call/2,        % +Pid, :Goal
         toplevel_call/3,        % +Pid, :Goal, +Options
         toplevel_next/1,        % +Pid
         toplevel_next/2,        % +Pid, +Options
         toplevel_stop/1,        % +Pid
         toplevel_abort/1,       % +Pid

         op(800,  xfx, !),
         op(200,  xfx, @),
         op(1000, xfy, if)
       ]).

/** <module> Toplevel actors -- shell-style control of goal execution

This module builds a small Prolog toplevel protocol on top of the actor
primitives from actors.pl.  A toplevel actor is an ordinary actor
running a simple state machine (PTCP) that accepts commands from
another process and sends back answer terms.

## Answer terms {#toplevel-answers}

Every answer term carries the PID of the toplevel actor as its first
argument, allowing the receiver to correlate replies when multiple
toplevels are in flight:

  - `success(Pid, Slice, More)` -- Slice is a list of Template
    bindings; More is `true` if there are further solutions, `false`
    if this is the final batch.
  - `failure(Pid)` -- Goal produced no solutions.
  - `error(Pid, Error)` -- Goal threw Error.

## PTCP state machine {#toplevel-ptcp}

A toplevel actor cycles through three states:

  - **s1** -- idle, waiting for a `'$call'(Goal, Options)` message.
    After receiving one, it computes the first answer slice and sends
    it to the target.  If More=true it moves to s3; otherwise it
    either stays in s1 (session mode) or exits.
  - **s2** -- internal helper: calls answer/5 to compute one slice and
    attaches the Pid.
  - **s3** -- waiting for `'$next'(Options)` (next batch) or `'$stop'`
    (discard remaining solutions).  On `'$next'` it backtracks into
    findnsols to fetch the next slice.  On `'$stop'` it returns to s1
    (session mode) or exits.

## Paging {#toplevel-findnsols}

findnsols/4 (a Trealla built-in) is lazy and non-deterministic:
each backtrack delivers the next batch of N solutions. Combined
with offset/2 this drives the `/call?offset=N&limit=M` paging
protocol cleanly.

The first argument is a `count(N)` cell rather than a bare
integer, which makes the limit mutable via nb_setarg/3 between
batches.  This is how toplevel_next/2's `limit(NewLimit)` option
takes effect mid-enumeration -- the count cell is shared between
findnsols/4 (which re-reads it on every retry) and the receive
loop that handles `'$next'(Options)` messages.

## Trealla port notes {#toplevel-trealla}

  - findnsols/4, offset/2 and nb_setarg/3 are all Trealla built-ins
    (nb_setarg/3 since v2.99.2, findnsols/4's count(N) form since
    v2.99.6+); no shims needed.
  - The mutable `count/1` and `target/1` cells must be constructed
    inside the same catch frame as the findnsols/4 call and the
    nb_setarg/3 mutations -- otherwise the mutations do not
    propagate to findnsols/4's internal counter under Trealla's
    heap rules.  This is why all paging logic in this module lives
    inside a single catch in run_call/6.

@author Torbjorn Lager
*/


:- use_module(actors).
:- use_module(isolation).
:- use_module(resource_policy).

:- meta_predicate(toplevel_spawn(-, :)).



%!  offset(+N, :Goal) is nondet.
%
%   Skip the first N solutions of Goal, then succeed for each remaining
%   solution on backtracking.  This is a Trealla built-in; the
%   declaration here merely makes it importable from this module.


                /*******************************
                *           TOPLEVEL          *
                *******************************/

%!  toplevel_spawn(-Pid) is det.
%!  toplevel_spawn(-Pid, +Options) is det.
%
%   Spawn a new toplevel (PTCP) actor.  The actor starts in state s1
%   awaiting `'$call'` commands.  Options:
%
%     - session(+Bool)
%       If `true`, the PTCP loops back to state s1 after each
%       completed call, allowing the same actor to handle multiple
%       successive goals.  Default: `false` (actor exits after one
%       call).
%     - target(+PidOrName)
%       Actor that should receive answer, output, and prompt messages.
%       Default: the calling process.
%     - time_limit(+SecondsOrInfinite)
%       Wall-time ceiling for a call, including suspended result pages.
%       The node-owner ceiling may only be tightened by this option.
%     - idle_limit(+SecondsOrInfinite)
%       Maximum wait in the idle and paging states. The node-owner ceiling
%       may only be tightened by this option.
%
%   Standard spawn/3 options such as `monitor(true)` are also accepted
%   and forwarded to spawn/3.

toplevel_spawn(Pid) :-
    toplevel_spawn(Pid, []).

toplevel_spawn(Pid, Options0) :-
    strip_module(Options0, SourceModule, Options1),
    isolation:rewrite_source_options(Options1, SourceModule, Options),
    self(Self),
    option(target(Target), Options, Self),
    option(session(Continue), Options, false),
    option(time_limit(RequestedTime), Options, infinite),
    option(idle_limit(RequestedIdle), Options, infinite),
    effective_time_limit(RequestedTime, TimeLimit),
    effective_idle_limit(RequestedIdle, IdleLimit),
    remove_lifecycle_options(Options, SpawnOptions),
    spawn(session(Pid, Target, Continue, TimeLimit, IdleLimit), Pid,
          ['$entry_context'(caller)|SpawnOptions]).

remove_lifecycle_options([], []).
remove_lifecycle_options([time_limit(_)|Options], Rest) :- !,
    remove_lifecycle_options(Options, Rest).
remove_lifecycle_options([idle_limit(_)|Options], Rest) :- !,
    remove_lifecycle_options(Options, Rest).
remove_lifecycle_options([Option|Options], [Option|Rest]) :-
    remove_lifecycle_options(Options, Rest).


                /*******************************
                *      PTCP STATE MACHINE     *
                *******************************/

%!  session(+Pid, +Target, +Continue, +TimeLimit, +IdleLimit) is det.
%
%   Entry point for a toplevel actor.  Wraps the state machine in a
%   catch that restarts the session from s1 if a goal is aborted via
%   toplevel_abort/1 (which signals `'$abort_goal'`).

session(Pid, Target, Continue, TimeLimit, IdleLimit) :-
    catch(session_running(Pid, Target, Continue, TimeLimit, IdleLimit),
          '$resource_idle',
          true).

session_running(Pid, Target, Continue, TimeLimit, IdleLimit) :-
    catch(state_1(Pid, Target, Continue, TimeLimit, IdleLimit),
          '$abort_goal',
          session_running(Pid, Target, Continue, TimeLimit, IdleLimit)).


%!  state_1(+Pid, +Target0, +Continue) is det.
%
%   State s1: idle.  Blocks in receive waiting for a
%   `'$call'(Goal, Options)` message.  On receipt, extracts options
%   and dispatches to run_call/6 which drives the paged enumeration.
%   In session mode loops back to s1 after the call completes.

state_1(Pid, Target0, Continue, TimeLimit, IdleLimit) :-
    receive_with_idle_limit({
        '$call'(Goal, Options) ->
            option(template(Template), Options, Goal),
            option(offset(Offset),     Options, 0),
            option(limit(RequestedLimit), Options, 1000000000),
            effective_solution_limit(RequestedLimit, Limit0),
            option(target(Target1),    Options, Target0),
            isolation:execution_goal(Goal, ExecutionGoal),
            run_call(Pid, ExecutionGoal, Template, Offset, Limit0, Target1,
                     TimeLimit, IdleLimit)
        }, IdleLimit),
    (   Continue == false
    ->  true
    ;   state_1(Pid, Target0, Continue, TimeLimit, IdleLimit)
    ).

receive_with_idle_limit(Clauses, infinite) :- !, receive(Clauses).
receive_with_idle_limit(Clauses, IdleLimit) :-
    receive(Clauses, [timeout(IdleLimit),
                      on_timeout(throw('$resource_idle'))]).


%!  run_call(+Pid, +Goal, +Template, +Offset, +Limit0, +Target1) is det.
%
%   Drive the paged enumeration of Goal.  Builds the mutable
%   `count/1` and `target/1` cells inside the catch frame so that
%   findnsols/4 and the nb_setarg/3 mutations performed in page/2
%   share the same heap context -- without that, the mutations do
%   not propagate to findnsols/4's internal counter.
%
%   `'$abort_goal'` is re-thrown unchanged so that session/3's outer
%   catch can restart the actor in state s1.  All other exceptions
%   are reported as `error(Pid, Error)` on the current target.

run_call(Pid, Goal, Template, Offset, Limit0, Target1,
         TimeLimit, IdleLimit) :-
    catch(
        ( Count  = count(Limit0),
          Target = target(Target1),
          create_resource_timer(TimeLimit, Timer),
          drive(Pid, Goal, Template, Offset, Count, Target, IdleLimit),
          disarm_resource_timer(Timer)
        ),
        Error0,
        ( ( nonvar(Timer) -> disarm_resource_timer(Timer) ; true ),
          normalize_resource_exception(Error0, Error),
          handle_error(Pid, Target, Target1, Error) )),
    !.

handle_error(_Pid, _Target, _Orig, '$abort_goal') :- !,
    throw('$abort_goal').
handle_error(_Pid, _Target, _Orig, '$resource_idle') :- !,
    throw('$resource_idle').
handle_error(Pid, Target, Orig, Error) :-
    (   nonvar(Target), Target = target(_)
    ->  arg(1, Target, Out)
    ;   Out = Orig
    ),
    Out ! error(Pid, Error).


%!  drive(+Pid, +Goal, +Template, +Offset, +Count, +Target) is det.
%
%   Step through successive findnsols/4 slices.  After every slice
%   we read the *current* limit from Count and target from Target,
%   so any mid-stream nb_setarg/3 mutations performed by page/2 in
%   response to a previous `'$next'(Options)` are honoured before
%   the next slice is computed and sent.
%
%   The More flag is set by comparing slice length against the
%   current limit: Got =:= Limit means a full page (More=true,
%   suspend in page/2), Got < Limit means the goal was exhausted
%   within this batch (More=false, terminate).
%
%   When findnsols/4 has no solutions at all on the first call it
%   fails outright; the second clause handles this by sending a
%   single `failure(Pid)`.

drive(Pid, Goal, Template, Offset, Count, Target, IdleLimit) :-
    findnsols(Count, Template, offset(Offset, Goal), Slice),
    arg(1, Target, Out),
    arg(1, Count, Lim),
    length(Slice, Got),
    (   Got =:= Lim
    ->  Out ! success(Pid, Slice, true),
        page(Count, Target, IdleLimit),
        !                       % '$stop' -- cut findnsols choicepoint
    ;   Out ! success(Pid, Slice, false), !
    ).
drive(Pid, _Goal, _Template, _Offset, _Count, Target, _IdleLimit) :-
    arg(1, Target, Out),
    Out ! failure(Pid).


%!  page(+Count, +Target) is semidet.
%
%   State s3: after a More=true slice, wait for the next protocol
%   command.  On `'$next'(Options)` apply any `limit(NewN)` or
%   `target(NewT)` updates to the mutable cells via nb_setarg/3,
%   then fail to backtrack into findnsols/4 for the next batch.
%   On `'$stop'` succeed deterministically; the caller (drive/6)
%   cuts the lingering findnsols choicepoint.

page(Count, Target, IdleLimit) :-
    receive_with_idle_limit({
        '$next'(Options) ->
            apply_next(Options, Count, Target),
            fail ;
        '$stop' ->
            true
    }, IdleLimit).

apply_next(Options, Count, Target) :-
    (   memberchk(limit(NewLim), Options),
        integer(NewLim), NewLim > 0
    ->  effective_solution_limit(NewLim, EffectiveLimit),
        nb_setarg(1, Count, EffectiveLimit)
    ;   true
    ),
    (   memberchk(target(NewT), Options),
        nonvar(NewT)
    ->  nb_setarg(1, Target, NewT)
    ;   true
    ).


                /*******************************
                *           PUBLIC API        *
                *******************************/

%!  toplevel_call(+Pid, :Goal) is det.
%!  toplevel_call(+Pid, :Goal, +Options) is det.
%
%   Ask the toplevel actor Pid to evaluate Goal.  The answer is sent
%   asynchronously to the target (default: the calling process).
%   Options:
%
%     - template(+Template)
%       Term whose bindings are collected in the answer Slice.
%       Default: Goal itself.
%     - offset(+N)
%       Skip the first N solutions.  Default: 0.
%     - limit(+N)
%       Maximum solutions per page.  Default: a very large number.
%     - target(+Pid)
%       Override the answer target.  Default: the caller.

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal0, Options) :-
    strip_module(Goal0, _, Goal),
    Pid ! '$call'(Goal, Options).


%!  toplevel_next(+Pid) is det.
%!  toplevel_next(+Pid, +Options) is det.
%
%   Request the next batch of solutions from a suspended PTCP (one
%   that sent `success(_, _, true)` for the previous page).  Options:
%
%     - limit(+N)
%       Change the per-page limit from this batch onwards.  Applied
%       via nb_setarg/3 on the mutable `count/1` cell shared with
%       findnsols/4 (requires Trealla v2.99.6+).
%     - target(+Pid)
%       Switch the answer target from this batch onwards.

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    Pid ! '$next'(Options).


%!  toplevel_stop(+Pid) is det.
%
%   Discard remaining solutions and return the PTCP to state s1
%   (if it was spawned with session(true)).  Sends `'$stop'` to Pid.

toplevel_stop(Pid) :-
    Pid ! '$stop'.


%!  toplevel_abort(+Pid) is det.
%
%   Abort the goal currently running inside the toplevel.  Sends the
%   `'$abort_goal'` exception to Pid via thread_signal/2, causing the
%   PTCP to unwind its current goal and restart in state s1.  If Pid
%   no longer exists the call succeeds silently.

toplevel_abort(Pid) :-
    catch(thread_signal(Pid, throw('$abort_goal')),
          error(existence_error(_,_), _),
          true).
