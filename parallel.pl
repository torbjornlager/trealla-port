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
    spawn_parallel_workers(Goals, Templates, Pids),
    collect_parallel_workers(Pids, Pids, Templates).

qualify_goals([], _, []).
qualify_goals([Goal|Goals], Module,
              [qualified_goal(Module,Goal)|Qualified]) :-
    qualify_goals(Goals, Module, Qualified).

goal_templates([], []).
goal_templates([Goal|Goals], [Template|Templates]) :-
    term_variables(Goal, Template),
    goal_templates(Goals, Templates).

spawn_parallel_workers([], [], []).
spawn_parallel_workers([Goal|Goals], [Template|Templates], [Pid|Pids]) :-
    self(Self),
    spawn_runtime(parallel:parallel_worker(Self, Pid, Goal, Template), Pid,
          [monitor(true),'$entry_context'(caller)]),
    spawn_parallel_workers(Goals, Templates, Pids).

parallel_worker(Self, Pid, Goal, Template) :-
    call_qualified_goal(Goal),
    send(Self, Pid-Template).

collect_parallel_workers(_, [], []).
collect_parallel_workers(AllPids, [Pid|Pids], [Template|Templates]) :-
    receive({
        Pid-Answer ->
            ( Template = Answer
            -> receive({down(Pid, _, _) -> true})
            ;  tidy_up_all(AllPids), !, fail
            ) ;
        down(FailedPid, _, false) if known_worker(FailedPid, AllPids) ->
            tidy_up_all(AllPids), !, fail ;
        down(FailedPid, _, Reason)
                if (known_worker(FailedPid, AllPids),
                    (Reason \== true ; FailedPid == Pid)) ->
            % A later worker's normal down must wait for its result.
            tidy_up_all(AllPids),
            worker_exit_error(FailedPid, Reason, Error),
            throw(Error)
    }),
    collect_parallel_workers(AllPids, Pids, Templates).


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
    spawn_first_workers(Goals, Solution, Pids),
    wait_first(Pids, Solution, OnFail, OnError).

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

spawn_first_workers([], _, []).
spawn_first_workers([Goal|Goals], Solution, [Pid|Pids]) :-
    self(Self),
    spawn_runtime(parallel:first_worker(Self, Pid, Solution, Goal), Pid,
          [monitor(true),'$entry_context'(caller)]),
    spawn_first_workers(Goals, Solution, Pids).

first_worker(Self, Pid, Solution, Goal) :-
    call_qualified_goal(Goal),
    send(Self, Pid-Solution).

call_qualified_goal(qualified_goal(Module, Goal)) :-
    isolation:call_in_module(Module, Goal).

wait_first([], _, _, _) :- !, fail.
wait_first(Pids, Solution, OnFail, OnError) :-
    receive({
        Winner-Answer if known_worker(Winner, Pids) ->
            ( Solution = Answer
            -> tidy_up_all(Pids)
            ;  tidy_up_all(Pids), !, fail
            ) ;
        down(FailedPid, _, false) if known_worker(FailedPid, Pids) ->
            handle_first_failure(FailedPid, Pids, Solution,
                                 OnFail, OnError) ;
        down(FailedPid, _, Reason)
                if known_worker(FailedPid, Pids) ->
            worker_exit_error(FailedPid, Reason, Error),
            handle_first_error(FailedPid, Error, Pids, Solution,
                               OnFail, OnError)
    }).

handle_first_failure(Pid, Pids, Solution, continue, OnError) :- !,
    select(Pid, Pids, Rest),
    wait_first(Rest, Solution, continue, OnError).
handle_first_failure(_, Pids, _, stop, _) :-
    tidy_up_all(Pids), !, fail.

handle_first_error(Pid, _, Pids, Solution, OnFail, continue) :- !,
    select(Pid, Pids, Rest),
    wait_first(Rest, Solution, OnFail, continue).
handle_first_error(_, Error, Pids, _, _, stop) :-
    tidy_up_all(Pids),
    throw(Error).


worker_exit_error(_, exception(Error), Error) :- !.
worker_exit_error(Pid, Reason, worker_exit(Pid, Reason)).

known_worker(Pid, Pids) :-
    ground(Pid),
    memberchk(Pid, Pids).


% Cleanup uses a fresh monitor as an ordering barrier. Once its down/3 has
% arrived, no result or earlier monitor notification from that worker can be
% delivered after the zero-time drain.
tidy_up_all([]).
tidy_up_all([Pid|Pids]) :-
    tidy_up(Pid),
    tidy_up_all(Pids).

tidy_up(Pid) :-
    demonitor(Pid, [flush]),
    monitor(Pid, CleanupRef),
    exit(Pid, kill),
    receive({down(Pid, CleanupRef, _) -> true}),
    drain_worker_messages(Pid).

drain_worker_messages(Pid) :-
    receive({
        Pid-_ -> drain_worker_messages(Pid) ;
        down(Pid, _, _) -> drain_worker_messages(Pid)
    }, [timeout(0)]).
