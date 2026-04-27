:- module(toplevel_actors,
       [ findnsols/4,            % +N, ?Template, :Goal, -List
         offset/2,               % +N, :Goal

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

## findnsols and paging {#toplevel-findnsols}

findnsols/4 collects solutions in batches of N.  It is non-deterministic:
each call on backtracking delivers the next batch.  Internally it uses
the N+1 lookahead trick: collect N+1 solutions; if all N+1 were found,
there is at least one more batch (a choicepoint is left via clause 2 of
findnsols_batch/6); if fewer were found, the current batch is the last.

## Trealla port notes {#toplevel-trealla}

  - findnsols/4 is implemented via `asserta`/`retract` and
    exception-based early stopping rather than `nb_getval`/`nb_setval`,
    which are absent.
  - offset/2 delegates to Trealla's built-in of the same name.
  - Changing the batch `limit` or `target` mid-stream via
    toplevel_next/2 options is not supported because it requires
    `nb_setarg/3`, which is absent in Trealla.  The limit(NewLimit)
    and target(NewTarget) sub-options of `'$next'` are accepted for
    protocol compatibility but silently ignored.
  - toplevel_abort/1 uses thread_signal/2; see the caveat in actors.pl
    about signalling nearly-dead threads.

@author Torbjorn Lager
*/


:- use_module(actors).


                /*******************************
                *     SWI COMPATIBILITY SHIMS  *
                *******************************/

%!  strip_module(:Goal, -Module, -Plain) is det.
%
%   Strip a possible module qualifier from Goal, unifying Module with
%   the qualifier (or left uninstantiated) and Plain with the bare goal.

strip_module(_M:Goal, _M, Goal) :- !.
strip_module(Goal, _, Goal).



%!  offset(+N, :Goal) is nondet.
%
%   Skip the first N solutions of Goal, then succeed for each remaining
%   solution on backtracking.  This is a Trealla built-in; the
%   declaration here merely makes it importable from this module.


                /*******************************
                *          FINDNSOLS          *
                *******************************/

%!  findnsols(+N, ?Template, :Goal, -List) is nondet.
%
%   Collect at most N solutions of Goal into List.  Non-deterministic:
%   on backtracking delivers the next batch of N solutions, then the
%   batch after that, and so on until Goal is exhausted.
%
%   N may be a plain integer or a `count(N0)` compound (for
%   compatibility with the original SWI implementation that wraps the
%   limit in a `count/1` cell for nb_setarg); arg 1 is used as the
%   integer limit in both cases.
%
%   Implementation: collect N+1 solutions using asserta/catch; if N+1
%   were found there are more batches (a choicepoint is left via clause
%   2 of findnsols_batch/6); if fewer were found this is the last batch
%   (cut, deterministic).  This avoids materialising all solutions at
%   once, so infinite generators are supported.

:- dynamic(nsols_bag/2).    % nsols_bag(Thread, Template) -- collected items
:- dynamic(nsols_state/2).  % nsols_state(Thread, NextOffset) -- next batch start

findnsols(N0, Template, Goal, List) :-
    (compound(N0) -> arg(1, N0, N) ; N = N0),
    thread_self(Me),
    retractall(nsols_state(Me, _)),     % fresh start
    findnsols_batch(N, Me, 0, Template, Goal, List).


%!  findnsols_batch(+N, +Me, +Offset, +Template, :Goal, -List) is nondet.
%
%   Workhorse for findnsols/4.  Collects one batch of N solutions from
%   `offset(Offset, Goal)`.  Clause 1 handles the general case and
%   cuts on the final batch.  Clause 2 is reached on backtracking and
%   fetches the next batch using the offset stored by clause 1.

% Clause 1 -- collect one batch; cut on last, leave clause 2 otherwise.
findnsols_batch(N, Me, Offset, Template, Goal, List) :-
    N1 is N + 1,                                    % probe for one extra
    collect_n(N1, Me, Template, offset(Offset, Goal), Probe),
    length(Probe, Got),
    (   Got =:= 0
    ->  !, List = []                                % no solutions at all
    ;   Got =:= N1
    ->  NextOffset is Offset + N,
        assertz(nsols_state(Me, NextOffset)),        % remember where to resume
        take_n(N, Probe, List, _)                    % deliver first N; clause 2 is alternative
    ;   !, List = Probe                              % partial last batch; cut
    ).

% Clause 2 -- reached on backtracking; fetch the next batch.
findnsols_batch(N, Me, _Offset, Template, Goal, List) :-
    retract(nsols_state(Me, NextOffset)),
    findnsols_batch(N, Me, NextOffset, Template, Goal, List).


%!  collect_n(+N, +Me, +Template, :Goal, -List) is det.
%
%   Collect at most N solutions of Goal into List.  Uses the
%   asserta/catch pattern: Goal is called repeatedly via backtracking;
%   each solution is asserted into nsols_bag/2; after reaching N
%   solutions (or exhausting Goal), the accumulated bag is harvested
%   with gather_nsols/3.
%
%   A per-thread counter stored on the blackboard under the key
%   `'$nsols_cnt_<Me>'` tracks how many solutions have been collected.
%   When the count reaches N the `'$nsols_limit'` exception is thrown
%   to cut off further backtracking.

collect_n(N, Me, Template, Goal, List) :-
    retractall(nsols_bag(Me, _)),
    format(atom(CntKey), '$nsols_cnt_~w', [Me]),
    bb_put(CntKey, 0),
    catch(
        ( call(Goal),
          asserta(nsols_bag(Me, Template)),
          bb_get(CntKey, C), C1 is C + 1, bb_put(CntKey, C1),
          ( C1 >= N -> throw('$nsols_limit') ; fail )
        ;   true    % graceful exit when Goal is exhausted before N
        ),
        '$nsols_limit',
        true
    ),
    gather_nsols(Me, [], List).


%!  gather_nsols(+Me, +Acc, -Bag) is det.
%
%   Harvest all nsols_bag(Me, _) facts into Bag in the original
%   solution order.  `asserta` inserts in LIFO order; prepending each
%   extracted item to the accumulator reverses again, restoring FIFO
%   order.

gather_nsols(Me, SoFar, Bag) :-
    retract(nsols_bag(Me, T)), !,
    gather_nsols(Me, [T|SoFar], Bag).
gather_nsols(_, Bag, Bag).


%!  take_n(+N, +List, -Head, -Tail) is det.
%
%   Split List into the first N elements (Head) and the remainder
%   (Tail).  If List has fewer than N elements, Head = List and
%   Tail = [].

take_n(0, Rest, [], Rest) :- !.
take_n(_, [], [], []) :- !.
take_n(N, [H|T], [H|S], R) :-
    N1 is N - 1,
    take_n(N1, T, S, R).


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
    (compound(Limit) -> arg(1, Limit, N) ; N = Limit),
    catch(
        slice(Goal, Template, Offset, Limit, Slice),
        Error, true),
    (   nonvar(Error)
    ->  Answer = error(Error)
    ;   Slice == []
    ->  Answer = failure
    ;   length(Slice, Got), Got =:= N
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
            option(limit(Limit0),      Options, 1000000000),
            option(target(Target1),    Options, Target0),
            Limit = count(Limit0),
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
