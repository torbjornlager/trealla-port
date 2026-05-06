:- module(toplevel_actors,
       [ offset/2,               % +N, :Goal

         toplevel_spawn/1,       % -Pid
         toplevel_spawn/2,       % -Pid, +Options
         toplevel_call/2,        % +Pid, :Goal
         toplevel_call/3,        % +Pid, :Goal, +Options
         toplevel_next/1,        % +Pid
         toplevel_next/2,        % +Pid, +Options
         toplevel_stop/1,        % +Pid
         toplevel_abort/1        % +Pid
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

slice/5 calls findnsols/4 (a Trealla built-in since v2.94.20),
which is lazy and non-deterministic: each backtrack delivers the
next batch of N solutions. Combined with offset/2 this drives the
`/call?offset=N&limit=M` paging protocol cleanly.

## Trealla port notes {#toplevel-trealla}

  - findnsols/4 and offset/2 are both Trealla built-ins; no shim
    needed.
  - Changing the batch `limit` or `target` mid-stream via
    toplevel_next/2 options is not supported because it requires
    `nb_setarg/3`, which is absent in Trealla.  The limit(NewLimit)
    and target(NewTarget) sub-options of `'$next'` are accepted for
    protocol compatibility but silently ignored.

@author Torbjorn Lager
*/


:- use_module(actors).



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
%
%   Standard spawn/3 options such as `monitor(true)` are also accepted
%   and forwarded to spawn/3.

toplevel_spawn(Pid) :-
    toplevel_spawn(Pid, []).

toplevel_spawn(Pid, Options) :-
    self(Self),
    option(target(Target), Options, Self),
    option(session(Continue), Options, false),
    spawn(session(Pid, Target, Continue), Pid, Options).


                /*******************************
                *      ANSWER SLICING         *
                *******************************/

%!  slice(+Goal, +Template, +Offset, +Limit, -Slice) is nondet.
%
%   Compute one page of solutions: skip the first Offset solutions of
%   Goal and collect at most Limit into Slice.  Non-deterministic via
%   findnsols/4: on backtracking delivers the next batch.

slice(Goal, Template, Offset, Limit, Slice) :-
    findnsols(Limit, Template, offset(Offset, Goal), Slice).


%!  answer(+Goal, +Template, +Offset, +Limit, -Answer) is det.
%
%   Compute one page and wrap it in the protocol answer term
%   (without the Pid).  The More flag is set by comparing the length
%   of the returned Slice against the integer limit N:
%
%     - `Got =:= N` means exactly N solutions were returned, so there
%       may be more (More = true).
%     - `Got < N`   means Goal was exhausted within this page
%       (More = false).
%
%   Note: Trealla's call_cleanup/2 does not fire the cleanup goal on
%   deterministic success (it only fires on cut or failure after the
%   first solution).  The original SWI implementation relied on this
%   to detect the final batch; this port uses length comparison instead.

answer(Goal, Template, Offset, Limit, Answer) :-
    catch(
        slice(Goal, Template, Offset, Limit, Slice),
        Error, true),
    (   nonvar(Error)
    ->  Answer = error(Error)
    ;   Slice == []
    ->  Answer = failure
    ;   length(Slice, Got), Got =:= Limit
    ->  Answer = success(Slice, true)
    ;   Answer = success(Slice, false)
    ).


                /*******************************
                *      PTCP STATE MACHINE     *
                *******************************/

%!  session(+Pid, +Target, +Continue) is det.
%
%   Entry point for a toplevel actor.  Wraps the state machine in a
%   catch that restarts the session from s1 if a goal is aborted via
%   toplevel_abort/1 (which signals `'$abort_goal'`).

session(Pid, Target, Continue) :-
    catch(state_1(Pid, Target, Continue),
          '$abort_goal',
          session(Pid, Target, Continue)).


%!  state_1(+Pid, +Target0, +Continue) is det.
%
%   State s1: idle.  Blocks in receive waiting for a
%   `'$call'(Goal, Options)` message.  On receipt, extracts options,
%   wraps the limit in `count/1`, calls state_2 to compute the first
%   answer slice, and sends the answer to the target.  If More=true,
%   proceeds to state_3 to handle paging.  If Continue=true, loops
%   back to s1 after the call is complete (session mode); otherwise
%   exits.

state_1(Pid, Target0, Continue) :-
    receive({
        '$call'(Goal, Options) ->
            option(template(Template), Options, Goal),
            option(offset(Offset),     Options, 0),
            option(limit(Limit),       Options, 1000000000),
            option(target(Target1),    Options, Target0),
            state_2(Goal, Template, Offset, Limit, Pid, Answer),
            Target = target(Target1),
            arg(1, Target, Out),
            Out ! Answer,
            (   arg(3, Answer, true)
            ->  state_3(Limit, Target)
            ;   true
            )
        }),
    (   Continue == false
    ->  true
    ;   state_1(Pid, Target0, Continue)
    ).


%!  state_2(+Goal, +Template, +Offset, +Limit, +Pid, -Answer) is det.
%
%   State s2: compute one answer slice and attach Pid to the answer
%   term.  This is a thin wrapper around answer/5 + add_pid/3.

state_2(Goal, Template, Offset, Limit, Pid, Answer) :-
    answer(Goal, Template, Offset, Limit, Answer0),
    add_pid(Answer0, Pid, Answer).

%!  add_pid(+Answer0, +Pid, -Answer) is det.
%
%   Attach Pid as the first argument of an answer term:
%
%     - success(Slice, More)  -->  success(Pid, Slice, More)
%     - failure               -->  failure(Pid)
%     - error(Term)           -->  error(Pid, Term)

add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).
add_pid(failure,              Pid, failure(Pid)).
add_pid(error(Term),          Pid, error(Pid, Term)).


%!  state_3(+Limit, +Target) is det.
%
%   State s3: waiting for the next paging request.  Blocks in receive
%   for either:
%
%     - `'$next'(Options)` -- backtrack into findnsols for the next
%       slice.  (Options are accepted for protocol compatibility but
%       silently ignored in this port because nb_setarg/3 is absent.)
%     - `'$stop'` -- discard remaining solutions and return (the
%       caller will send the PTCP back to s1 or let it exit).
%
%   The cut in state_3 is necessary to avoid leaking the findnsols
%   choicepoint when `'$stop'` is received.

state_3(_Limit, _Target) :-
    receive({
        '$next'(_Options2) ->
            fail ;          % backtrack into findnsols for next slice
        '$stop' ->
            true
    }),
    !.


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
%   that sent `success(_, _, true)` for the previous page).  Options
%   are accepted for protocol compatibility but silently ignored in
%   this Trealla port (limit and target cannot be changed mid-stream
%   because nb_setarg/3 is absent).

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
