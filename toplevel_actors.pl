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
primitives from actors.pl.  A toplevel actor is an ordinary actor running
a simple state machine (PTCP) that accepts commands from another process
and sends back answer terms:

  - `success(Pid, Slice, More)`
  - `failure(Pid)`
  - `error(Pid, Error)`

## Trealla port notes

  - `findnsols/4` is implemented in pure Prolog via `findall/3` followed
    by non-deterministic batch delivery using `between/3`.  The full
    solution list is materialised upfront; infinite generators are not
    supported.
  - `offset/2` is implemented with an assertz/retract counter keyed by
    thread-ID, so it is thread-safe and its side-effects survive
    backtracking inside `findall`.
  - Changing the batch `limit` or `target` via `toplevel_next/2` options
    is not supported (requires `nb_setarg/3`, absent in Trealla).

@author Torbjorn Lager
*/


:- use_module(actors).


                /*******************************
                *     SWI COMPATIBILITY SHIMS  *
                *******************************/

%!  strip_module(:Goal, -Module, -Plain) is det.

strip_module(_M:Goal, _M, Goal) :- !.
strip_module(Goal, _, Goal).


%!  offset(+N, :Goal) is nondet.
%
%   Like call(Goal) but skips the first N solutions.  Works inside
%   findall/3 because the skip counter is stored via assertz/retract
%   (a persistent side effect) rather than in a Prolog variable.

:- dynamic(offset_counter/2).   % offset_counter(Thread, Count)

offset(0, Goal) :- !, call(Goal).
offset(N, Goal) :-
    N > 0,
    thread_self(Me),
    (retract(offset_counter(Me, _)) -> true ; true),
    assertz(offset_counter(Me, N)),
    call(Goal),
    retract(offset_counter(Me, C)),
    (   C > 0
    ->  C1 is C - 1,
        assertz(offset_counter(Me, C1)),
        fail
    ;   true
    ).


%!  findnsols(+N, ?Template, :Goal, -List) is nondet.
%
%   Collect at most N solutions of Goal into List.  Non-deterministic:
%   on backtracking delivers the next batch of N solutions.  The last
%   (possibly partial) batch is deterministic so that call_cleanup/2
%   can detect it.
%
%   N may also be a count(N0) compound (for compatibility with the
%   original state machine that uses nb_setarg on such a cell); arg 1
%   is used as the integer limit.
%
%   Trealla note: all solutions are materialised by findall/3 on the
%   first call; infinite generators are not supported.

findnsols(N0, Template, Goal, List) :-
    (compound(N0) -> arg(1, N0, N) ; N = N0),
    findall(Template, Goal, All),
    length(All, Total),
    (   Total =:= 0
    ->  !, List = []       % no solutions; deterministic empty result
    ;   NumBatches is (Total + N - 1) // N,
        between(1, NumBatches, Batch),
        Start is (Batch - 1) * N,
        skip_n(Start, All, Rest),
        take_n(N, Rest, List, _),
        (Batch =:= NumBatches -> ! ; true)  % cut on last batch: deterministic
    ).


%!  skip_n(+N, +List, -Rest) is det.

skip_n(0, L, L) :- !.
skip_n(_, [], []) :- !.
skip_n(N, [_|T], R) :-
    N1 is N - 1,
    skip_n(N1, T, R).


%!  take_n(+N, +List, -Head, -Tail) is det.

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
%   Spawn a new toplevel actor.  Options:
%
%     - session(+Bool)
%       If `true`, the PTCP loops back to its ready state after each
%       completed call.  Default: `false`.
%     - target(+PidOrName)
%       Actor that should receive answer, output, and prompt messages.
%       Default: the calling process.
%
%   Ordinary spawn/3 options such as `monitor(true)` are also accepted.

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

% Compute one slice of solutions via findnsols, using offset/2 to skip
% the first Offset solutions.

slice(Goal, Template, Offset, Limit, Slice) :-
    findnsols(Limit, Template, offset(Offset, Goal), Slice).


% Turn one slice into a protocol-level answer term (without the Pid).

answer(Goal, Template, Offset, Limit, Answer) :-
    catch(
        call_cleanup(slice(Goal, Template, Offset, Limit, Slice),
                     Det = true),
        Error, true),
    (   Slice == []
    ->  Answer = failure
    ;   nonvar(Error)
    ->  Answer = error(Error)
    ;   var(Det)
    ->  Answer = success(Slice, true)
    ;   Det = true
    ->  Answer = success(Slice, false)
    ).


                /*******************************
                *      PTCP STATE MACHINE     *
                *******************************/

% Restart from s1 after '$abort_goal'.

session(Pid, Target, Continue) :-
    catch(state_1(Pid, Target, Continue),
          '$abort_goal',
          session(Pid, Target, Continue)).


% State s1: wait for a '$call' request, compute one answer, send it.

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


% State s2: compute one answer slice and attach Pid.

state_2(Goal, Template, Offset, Limit, Pid, Answer) :-
    answer(Goal, Template, Offset, Limit, Answer0),
    add_pid(Answer0, Pid, Answer).

add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).
add_pid(failure,              Pid, failure(Pid)).
add_pid(error(Term),          Pid, error(Pid, Term)).


% State s3: after a partial success, wait for '$next' or '$stop'.
%
% Trealla note: nb_setarg is not available, so limit and target cannot
% be changed between batches.  The limit(NewLimit) and target(NewTarget)
% sub-options of '$next' are accepted for protocol compatibility but
% silently ignored.

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
%   Ask the toplevel actor to evaluate Goal.  The answer is sent
%   asynchronously as a success/failure/error term to the target.
%   Options: template/1, offset/1, limit/1, target/1.

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal0, Options) :-
    strip_module(Goal0, _, Goal),
    Pid ! '$call'(Goal, Options).


%!  toplevel_next(+Pid) is det.
%!  toplevel_next(+Pid, +Options) is det.
%
%   Request the next batch of solutions from a suspended PTCP.
%   Options: limit/1, target/1 (ignored in this Trealla port).

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    Pid ! '$next'(Options).


%!  toplevel_stop(+Pid) is det.
%
%   Discard remaining solutions and return the PTCP to state s1.

toplevel_stop(Pid) :-
    Pid ! '$stop'.


%!  toplevel_abort(+Pid) is det.
%
%   Abort the goal currently running inside the toplevel.  The PTCP
%   restarts in state s1.

toplevel_abort(Pid) :-
    catch(thread_signal(Pid, throw('$abort_goal')),
          error(existence_error(_,_), _),
          true).
