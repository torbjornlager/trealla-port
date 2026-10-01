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
         actors/1,              % -Pids
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
         toplevel_halt/1,        % +Pid
         toplevel_halt/2,        % +Pid, -Reply
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
    the goal to fetch the next slice.  On `'$stop'` it returns to s1
    (session mode) or exits.

## Paging {#toplevel-paging}

The goal itself is wrapped in `call_cleanup/2`. Trealla binds the cleanup
marker before returning a deterministic final solution, just as SWI does.
The actor can therefore mark an exact-size final page `More=false` without
speculatively executing a solution from the next page. Solutions are copied
into a mutable page accumulator, and `toplevel_next/2` resumes the original
goal choicepoint after optionally changing the page limit.

## Trealla port notes {#toplevel-trealla}

  - call_cleanup/2, offset/2 and nb_setarg/3 are Trealla built-ins.
  - Mutable `count/1` and `target/1` cells are constructed inside the same
    catch frame as goal execution. Page values use thread-local blackboard
    storage because Trealla's nb_setarg/3 accepts integer values only.

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
%       Wall-time ceiling for each active computation slice. The timer is
%       suspended while a result page waits for the next protocol command.
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
%   Drive the paged enumeration of Goal. Builds mutable `count/1`,
%   `target/1`, and page-count cells inside the catch frame.
%
%   `'$abort_goal'` is re-thrown unchanged so that session/3's outer
%   catch can restart the actor in state s1.  All other exceptions
%   are reported as `error(Pid, Error)` on the current target.

run_call(Pid, Goal, Template, Offset, Limit0, Target1,
         TimeLimit, IdleLimit) :-
    catch(
        ( % Explicit construction avoids Trealla v3.12.6 retaining an argument
          % from a compound-literal cell used by an earlier actor thread.
          functor(PageCount, count, 1),
          arg(1, PageCount, Limit0),
          functor(Target, target, 1),
          arg(1, Target, Target1),
          functor(PageState, count, 1),
          arg(1, PageState, 0),
          page_values_put([]),
          resource_timer_put(none),
          arm_call_timer(TimeLimit),
          drive(Pid, Goal, Template, Offset, PageCount, PageState, Target,
                TimeLimit, IdleLimit),
          disarm_call_timer
        ),
        Error0,
        ( disarm_call_timer,
          normalize_resource_exception(Error0, Error),
          handle_error(Pid, Target, Target1, Error) )),
    !.

arm_call_timer(TimeLimit) :-
    create_resource_timer(TimeLimit, Timer),
    resource_timer_put(Timer).

disarm_call_timer :-
    ( resource_timer_get(Timer) -> true ; Timer = none ),
    ( Timer == none -> true
    ; disarm_resource_timer(Timer),
      resource_timer_put(none)
    ).

resource_timer_key(Key) :-
    self(Pid),
    format(atom(Key), '$ptcp_resource_timer_~w', [Pid]).

resource_timer_put(Timer) :-
    resource_timer_key(Key),
    bb_put(Key, Timer).

resource_timer_get(Timer) :-
    resource_timer_key(Key),
    bb_get(Key, Timer).

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


%!  drive(+Pid, +Goal, +Template, +Offset, +PageCount, +PageState,
%!        +Target, +IdleLimit) is det.
%
%   Step through Goal one solution at a time. call_cleanup/2 binds Det on a
%   deterministic final solution, so a full final page can be reported
%   without probing the next solution. When Det remains unbound, page/5
%   suspends before backtracking into Goal.

drive(Pid, Goal, Template, Offset, PageCount, PageState, Target,
      TimeLimit, IdleLimit) :-
    ( call_cleanup(offset(Offset, Goal), Det = true),
      drive_solution(Pid, Template, Det, PageCount, PageState, Target,
                     TimeLimit, IdleLimit)
    ; drive_exhausted(Pid, PageState, Target)
    ),
    !.

drive_solution(Pid, Template, Det, PageCount, PageState, Target,
               TimeLimit, IdleLimit) :-
    copy_term(Template, Value),
    page_add(PageState, Value, Got),
    arg(1, PageCount, Limit),
    ( Got >= Limit
    -> page_values(PageState, Slice),
       arg(1, Target, Out),
       ( nonvar(Det)
       -> Out ! success(Pid, Slice, false)
       ;  disarm_call_timer,
          Out ! success(Pid, Slice, true),
          page(PageCount, PageState, Target, TimeLimit, IdleLimit)
       )
    ; nonvar(Det)
    -> page_values(PageState, Slice),
       arg(1, Target, Out),
       Out ! success(Pid, Slice, false)
    ; fail
    ).

drive_exhausted(Pid, PageState, Target) :-
    arg(1, PageState, Got),
    arg(1, Target, Out),
    ( Got =:= 0 -> Out ! failure(Pid)
    ; page_values(PageState, Slice), Out ! success(Pid, Slice, false)
    ).

page_add(PageState, Value, Count) :-
    page_values_get(Rev0),
    arg(1, PageState, Count0),
    Count is Count0 + 1,
    page_values_put([Value|Rev0]),
    nb_setarg(1, PageState, Count).

page_values(_PageState, Values) :-
    page_values_get(Reversed),
    reverse(Reversed, Values).

clear_page(PageState) :-
    page_values_put([]),
    nb_setarg(1, PageState, 0).

% Trealla's blackboard is process-wide, despite bb_* values often appearing
% thread-local in simple tests. A shell and a nested toplevel can therefore
% compute pages concurrently and overwrite a fixed key. Key the accumulator
% by logical actor PID so a child's rows can never leak into its caller's
% result page.
page_values_key(Key) :-
    self(Pid),
    format(atom(Key), '$ptcp_page_values_~w', [Pid]).

page_values_put(Values) :-
    page_values_key(Key),
    bb_put(Key, Values).

page_values_get(Values) :-
    page_values_key(Key),
    bb_get(Key, Values).


%!  page(+PageCount, +PageState, +Target, +IdleLimit) is semidet.
%
%   State s3: after a More=true slice, wait for the next protocol
%   command.  On `'$next'(Options)` apply any `limit(NewN)` or
%   `target(NewT)` updates to the mutable cells via nb_setarg/3,
%   clear the page and fail to backtrack into Goal for the next solution.
%   On `'$stop'` succeed deterministically; drive/9 then cuts the lingering
%   goal choicepoint.

page(PageCount, PageState, Target, TimeLimit, IdleLimit) :-
    receive_with_idle_limit({
        '$next'(Options) ->
            apply_next(Options, PageCount, Target),
            clear_page(PageState),
            arm_call_timer(TimeLimit),
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
%       via nb_setarg/3 on the mutable `count/1` cell.
%     - target(+Pid)
%       Switch the answer target from this batch onwards.

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    Pid ! '$next'(Options).


%!  toplevel_halt(+Pid) is det.
%!  toplevel_halt(+Pid, -Reply) is det.
%
%   Terminate a toplevel from any protocol state.  The two-argument form
%   waits for termination and retains the SWI API's historical `true` reply.

toplevel_halt(Pid) :-
    exit(Pid, true).

toplevel_halt(Pid, true) :-
    setup_call_cleanup(
        monitor(Pid, Ref),
        ( toplevel_halt(Pid),
          receive({down(Pid, Ref, _) -> true})
        ),
        demonitor(Ref, [flush])
    ).


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
    ( actors:actor_thread(Pid, Thread) ->
        catch(thread_signal(Thread, throw('$abort_goal')),
              error(existence_error(_,_), _),
              true)
    ; true
    ).
