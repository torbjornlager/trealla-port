% SPDX-License-Identifier: MIT

:- module(parallel,
       [ parallel/1,
         parallel_in/2,
         first_solution/2,
         first_solution/3,
         first_solution_in/4
       ]).

:- op(1000, xfy, if).

/** <module> Actor-based parallel predicate generics

Workers return only their goal-variable templates. A result message is
consumed before it is unified with the caller's template, so incompatible
bindings shared by independent workers make parallel/1 fail instead of
leaving an unmatched message and waiting forever.
An exit without a result preserves ordinary failure and exceptions; other
reasons raise worker_exit(Pid,Reason), subject to first_solution's on_error
policy. Later parallel workers may finish before their results are collected:
their normal down notifications remain deferred. After a result is accepted,
its down notification confirms termination regardless of reason.
*/

:- use_module(actors).
:- use_module(worker_cleanup).

:- meta_predicate parallel(:).
:- meta_predicate first_solution(?, :).
:- meta_predicate first_solution(?, :, +).


%!  parallel(:Goals) is semidet.

parallel(QualifiedGoals) :-
    strip_module(QualifiedGoals, Module, Goals0),
    parallel_in(Module, Goals0).

parallel_in(Module, Goals0) :-
    must_be(list, Goals0),
    qualify_goals(Goals0, Module, Goals),
    goal_templates(Goals, Templates),
    with_worker_scope(Scope,
        (spawn_parallel_workers(Scope, Goals, Templates, Pids),
         collect_parallel_workers(Scope, Pids, Pids, Templates))).

qualify_goals([], _, []).
qualify_goals([Goal|Goals], Module,
              [qualified_goal(Module,Goal)|Qualified]) :-
    qualify_goals(Goals, Module, Qualified).

goal_templates([], []).
goal_templates([Goal|Goals], [Template|Templates]) :-
    term_variables(Goal, Template),
    goal_templates(Goals, Templates).

spawn_parallel_workers(Goals, Templates, Pids) :-
    spawn_parallel_workers(none, Goals, Templates, Pids).
spawn_parallel_workers(_, [], [], []).
spawn_parallel_workers(Scope, [Goal|Goals], [Template|Templates], [Pid|Pids]) :-
    self(Self),
    spawn_worker(Scope, parallel:parallel_worker(Self, Pid, Goal, Template), Pid),
    spawn_parallel_workers(Scope, Goals, Templates, Pids).

parallel_worker(Self, Pid, Goal, Template) :-
    call_qualified_goal(Goal),
    send(Self, Pid-Template).

collect_parallel_workers(AllPids, Pids, Templates) :-
    collect_parallel_workers(none, AllPids, Pids, Templates).
collect_parallel_workers(_, _, [], []).
collect_parallel_workers(Scope, AllPids, [Pid|Pids], [Template|Templates]) :-
    receive({
        Pid-Answer ->
            ( Template = Answer
            -> receive({down(Pid, Pid, _) -> true}), release_worker(Scope, Pid)
            ;  close_workers(Scope, AllPids), !, fail
            ) ;
        down(FailedPid, FailedPid, false) if known_worker(FailedPid, AllPids) ->
            close_workers(Scope, AllPids), !, fail ;
        down(FailedPid, FailedPid, Reason)
                if (known_worker(FailedPid, AllPids),
                    (Reason \== true ; FailedPid == Pid)) ->
            % A later worker's normal down must wait for its result.
            close_workers(Scope, AllPids),
            worker_exit_error(FailedPid, Reason, Error),
            throw(Error)
    }),
    collect_parallel_workers(Scope, AllPids, Pids, Templates).


%!  first_solution(-Solution, :Goals) is semidet.
%!  first_solution(-Solution, :Goals, +Options) is semidet.
%
%   Options are on_fail(stop|continue), default continue, and
%   on_error(stop|continue), default stop.

first_solution(Solution, Goals) :-
    first_solution(Solution, Goals,
                   [on_fail(continue),on_error(stop)]).

first_solution(Solution, QualifiedGoals, Options) :-
    strip_module(QualifiedGoals, Module, Goals0),
    first_solution_in(Module, Solution, Goals0, Options).

first_solution_in(Module, Solution, Goals0, Options) :-
    must_be(list, Options),
    validate_first_solution_options(Options),
    option(on_fail(OnFail), Options, continue),
    option(on_error(OnError), Options, stop),
    valid_stop_policy(OnFail),
    valid_stop_policy(OnError),
    must_be(list, Goals0),
    qualify_goals(Goals0, Module, Goals),
    with_worker_scope(Scope,
        (spawn_first_workers(Scope, Goals, Solution, Pids),
         wait_first(Scope, Pids, Solution, OnFail, OnError))).

validate_first_solution_options([]).
validate_first_solution_options([on_fail(_)|Options]) :- !,
    validate_first_solution_options(Options).
validate_first_solution_options([on_error(_)|Options]) :- !,
    validate_first_solution_options(Options).
validate_first_solution_options([Option|_]) :-
    throw(error(domain_error(first_solution_option, Option),
                first_solution/3)).

valid_stop_policy(stop) :- !.
valid_stop_policy(continue) :- !.
valid_stop_policy(Value) :-
    throw(error(domain_error(first_solution_policy, Value),
                first_solution/3)).

spawn_first_workers(Goals, Solution, Pids) :-
    spawn_first_workers(none, Goals, Solution, Pids).
spawn_first_workers(_, [], _, []).
spawn_first_workers(Scope, [Goal|Goals], Solution, [Pid|Pids]) :-
    self(Self),
    spawn_worker(Scope, parallel:first_worker(Self, Pid, Solution, Goal), Pid),
    spawn_first_workers(Scope, Goals, Solution, Pids).

first_worker(Self, Pid, Solution, Goal) :-
    call_qualified_goal(Goal),
    send(Self, Pid-Solution).

call_qualified_goal(qualified_goal(Module, Goal)) :-
    isolation:call_in_module(Module, Goal).

wait_first(Scope, [], _, _, _) :- !, close_workers(Scope, []), fail.
wait_first(Scope, Pids, Solution, OnFail, OnError) :-
    receive({
        Winner-Answer if known_worker(Winner, Pids) ->
            ( Solution = Answer
            -> close_workers(Scope, Pids)
            ;  close_workers(Scope, Pids), !, fail
            ) ;
        down(FailedPid, FailedPid, false) if known_worker(FailedPid, Pids) ->
            release_worker(Scope, FailedPid),
            handle_first_failure(Scope, FailedPid, Pids, Solution,
                                 OnFail, OnError) ;
        down(FailedPid, FailedPid, Reason)
                if known_worker(FailedPid, Pids) ->
            worker_exit_error(FailedPid, Reason, Error),
            release_worker(Scope, FailedPid),
            handle_first_error(Scope, FailedPid, Error, Pids, Solution,
                               OnFail, OnError)
    }).

handle_first_failure(Scope, Pid, Pids, Solution, continue, OnError) :- !,
    selectchk(Pid, Pids, Rest),
    wait_first(Scope, Rest, Solution, continue, OnError).
handle_first_failure(Scope, _, Pids, _, stop, _) :-
    close_workers(Scope, Pids), !, fail.

handle_first_error(Scope, Pid, _, Pids, Solution, OnFail, continue) :- !,
    selectchk(Pid, Pids, Rest),
    wait_first(Scope, Rest, Solution, OnFail, continue).
handle_first_error(Scope, _, Error, Pids, _, _, stop) :-
    close_workers(Scope, Pids),
    throw(Error).


worker_exit_error(_, exception(Error), Error) :- !.
worker_exit_error(Pid, Reason, worker_exit(Pid, Reason)).

known_worker(Pid, Pids) :-
    ground(Pid),
    memberchk(Pid, Pids).


% Private compatibility path for focused collector tests; public calls always
% supply an owning scope spanning startup and collection.
close_workers(none, Pids) :- !, tidy_up_all(Pids).
close_workers(Scope, _) :- close_worker_scope(Scope).
