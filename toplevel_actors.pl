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
         send/2,                 % +Pid, +Message
         send/3,                 % +Pid, +Message, +Options
         cancel/1,               % +Id
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
    catch frame as goal execution. Page values use native per-thread
    non-backtrackable state because Trealla's nb_setarg/3 accepts integer
    values only.

@author Torbjorn Lager
*/


:- use_module(actors).
:- use_module(isolation).
:- use_module(parallel, []).
:- use_module(resource_policy).
:- use_module(rpc,
              [rpc/2,rpc/3,promise/3,promise/4,promise_cleanup/1,
               yield/2,yield/3,runtime_property/1]).

% A fixed execution entry keeps rebuilt native controls out of offset/2's
% dynamically qualified goal argument, preserving their control scope.
run_worker_query(Goal) :- call(Goal).

% Source-less calls execute here; choose the actor's private module explicitly
% rather than relying on transitive meta-predicate import qualification.
parallel(Goals) :-
    worker_query_module(Module),
    parallel:parallel_in(Module, Goals).
first_solution(Solution, Goals) :-
    first_solution(Solution, Goals, [on_fail(continue),on_error(stop)]).
first_solution(Solution, Goals, Options) :-
    worker_query_module(Module),
    parallel:first_solution_in(Module, Solution, Goals, Options).
worker_query_module(Module) :-
    self(Pid),
    ( isolation:actor_module(Pid, Private) -> Module = Private
    ; Module = toplevel_actors
    ).

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
    validate_toplevel_spawn_options(Options1,runtime),
    isolation:rewrite_source_options(Options1, SourceModule, Options),
    self(Self),
    option(target(Target), Options, Self),
    option(session(Continue), Options, false),
    option(time_limit(RequestedTime), Options, infinite),
    option(idle_limit(RequestedIdle), Options, infinite),
    effective_time_limit(RequestedTime, TimeLimit),
    effective_idle_limit(RequestedIdle, IdleLimit),
    remove_lifecycle_options(Options, SpawnOptions),
    spawn_runtime(session(Pid, Target, Continue, TimeLimit, IdleLimit), Pid,
          ['$entry_context'(caller)|SpawnOptions]).

validate_toplevel_spawn_options(Options,Scope) :-
    validate_toplevel_spawn_options(Options,Scope,toplevel_actors:toplevel_spawn/2).
validate_toplevel_spawn_options(Options,Scope,Context) :-
    actors:validate_spawn_wrapper_options(Options,Scope,Context,
        [session-boolean,time_limit-seconds(time_limit),idle_limit-seconds(idle_limit)]).

remove_lifecycle_options([], []).
remove_lifecycle_options([session(_)|Options],Rest) :- !,
    remove_lifecycle_options(Options,Rest).
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
    % Input belongs to the PTCP client, which can differ from an inherited
    % browser terminal for nested toplevels. Ordinary output keeps using the
    % inherited terminal target.
    actors:set_input_target(Target),
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
            drain_stale_commands,
            set_request_reference(Options),
            option(template(Template), Options, Goal),
            option(offset(Offset),     Options, 0),
            option(limit(RequestedLimit), Options, 1000000000),
            effective_solution_limit(RequestedLimit, Limit0),
            option(once(Once),          Options, false),
            option(target(Target1),    Options, Target0),
            isolation:execution_goal(Goal, ExecutionGoal),
            once_execution_goal(Once, ExecutionGoal, RunGoal),
            run_call(Pid, RunGoal, Template, Offset, Limit0, Target1,
                     TimeLimit, IdleLimit)
        }, IdleLimit),
    (   Continue == false
    ->  true
    ;   state_1(Pid, Target0, Continue, TimeLimit, IdleLimit)
    ).

once_execution_goal(true, Goal, once(Goal)) :- !.
once_execution_goal(false, Goal, Goal) :- !.
once_execution_goal(Once, _, _) :-
    throw(error(domain_error(boolean, Once), toplevel_call/3)).

% Discard only commands skipped before the call selected above. Commands sent
% after the call are still in the native queue and remain available to the
% running query or paging state.
drain_stale_commands :-
    actors:discard_deferred(toplevel_actors:stale_command).

stale_command('$next'(_)).
stale_command('$stop').
stale_command('$input'(_, _)).

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
        ( % Compound-literal cells still retain cross-thread state in v3.13.10;
          % explicit construction is covered by the paging regression suite.
          functor(PageCount, count, 1),
          arg(1, PageCount, Limit0),
          functor(Target, target, 1),
          arg(1, Target, Target1),
          nb_setval('$ptcp_answer_target', Target1),
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

resource_timer_put(Timer) :-
    nb_setval('$ptcp_resource_timer', Timer).

resource_timer_get(Timer) :-
    nb_current('$ptcp_resource_timer', Timer).

handle_error(_Pid, _Target, _Orig, '$abort_goal') :- !,
    throw('$abort_goal').
handle_error(_Pid, _Target, _Orig, '$resource_idle') :- !,
    throw('$resource_idle').
handle_error(Pid, Target, Orig, Error) :-
    (   nonvar(Target), Target = target(_)
    ->  answer_target(Target, Out)
    ;   Out = Orig
    ),
    send_answer(Out, error(Pid, Error)).


%!  drive(+Pid, +Goal, +Template, +Offset, +PageCount, +PageState,
%!        +Target, +IdleLimit) is det.
%
%   Step through Goal one solution at a time. call_cleanup/2 binds Det on a
%   deterministic final solution, so a full final page can be reported
%   without probing the next solution. When Det remains unbound, page/5
%   suspends before backtracking into Goal.

drive(Pid, Goal, Template, Offset, PageCount, PageState, Target,
      TimeLimit, IdleLimit) :-
    ( call_cleanup(call_with_policy_inference_limit(offset(Offset, Goal)),
                   Det = true),
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
       answer_target(Target, Out),
       ( nonvar(Det)
       -> send_answer(Out, success(Pid, Slice, false))
       ;  disarm_call_timer,
          send_answer(Out, success(Pid, Slice, true)),
          page(PageCount, PageState, Target, TimeLimit, IdleLimit)
       )
    ; nonvar(Det)
    -> page_values(PageState, Slice),
       answer_target(Target, Out),
       send_answer(Out, success(Pid, Slice, false))
    ; fail
    ).

drive_exhausted(Pid, PageState, Target) :-
    arg(1, PageState, Got),
    answer_target(Target, Out),
    ( Got =:= 0 -> send_answer(Out, failure(Pid))
    ; page_values(PageState, Slice), send_answer(Out, success(Pid, Slice, false))
    ).

set_request_reference(Options) :-
    option('$request_ref'(Ref), Options, none),
    nb_setval('$ptcp_request_ref', Ref).

send_answer(Target, Answer) :-
    ( nb_current('$ptcp_request_ref', Ref), Ref \== none
    -> Target ! '$toplevel_reply'(Ref, Answer)
    ; Target ! Answer ).

% Trealla's nb_setarg/3 accepts integers only. Browser reply endpoints are
% compound terms, so retain target updates in actor-local nonbacktrackable state.
answer_target(Target, Value) :-
    ( nb_current('$ptcp_answer_target', Current) -> Value = Current
    ; arg(1, Target, Value) ).

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

page_values_put(Values) :-
    nb_setval('$ptcp_page_values', Values).

page_values_get(Values) :-
    nb_current('$ptcp_page_values', Values).


%!  page(+PageCount, +PageState, +Target, +IdleLimit) is semidet.
%
%   State s3: after a More=true slice, wait for the next protocol
%   command.  On `'$next'(Options)` apply any `limit(NewN)` or
%   `target(NewT)` updates using actor-local nonbacktrackable state,
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

apply_next(Options, Count, _Target) :-
    set_request_reference(Options),
    (   memberchk(limit(NewLim), Options),
        integer(NewLim), NewLim > 0
    ->  effective_solution_limit(NewLim, EffectiveLimit),
        nb_setarg(1, Count, EffectiveLimit)
    ;   true
    ),
    (   memberchk(target(NewT), Options),
        nonvar(NewT)
    ->  nb_setval('$ptcp_answer_target', NewT)
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
    remote_toplevel_route(Pid,Node),!,
    distribution:remote_toplevel_call_routed(Node,Pid,Goal0,Options).
toplevel_call(Pid, Goal0, Options) :-
    ( nonvar(Goal0), Goal0 = Qualified:_Goal, atom(Qualified)
    -> Goal = Goal0
    ; strip_module(Goal0, _, Goal)
    ),
    Pid ! '$call'(Goal, Options).

% A registered remote route uses the checked WebSocket query command rather
% than sending sender-private execution helpers as a raw actor message.
remote_toplevel_route(Pid,remote_node(URL,_,Writer)) :-
    nonvar(Pid),Pid=_@URL,
    current_predicate(distribution:remote_pid_writer/3),
    distribution:remote_pid_writer(Pid,Writer,_).


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
