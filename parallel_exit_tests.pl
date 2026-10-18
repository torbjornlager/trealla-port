% SPDX-License-Identifier: MIT
:- use_module(actors).
:- use_module(parallel).

parallel_exit_tests :-
    parallel_exit_errors,
    first_exit_policies,
    later_parallel_completion,
    accepted_result_termination,
    unrelated_exit_monitors,
    writeln('Unexpected worker exits: all regressions passed').

parallel_exit_errors :-
    catch(parallel([exit(killed)]), Killed, true),
    Killed=worker_exit(KPid,killed),ground(KPid),
    catch(parallel([exit(true)]), Normal, true),
    Normal=worker_exit(NPid,true),ground(NPid),
    % A later worker's abnormal exit must interrupt a blocked earlier one.
    catch(parallel([receive({never -> true}),exit(other)]), Later, true),
    Later=worker_exit(LPid,other),ground(LPid),
    catch(parallel([throw(original_error)]), Original, true),
    Original==original_error,
    \+ parallel([fail]),
    writeln('parallel exit classification and fail-fast handling: ok').

first_exit_policies :-
    catch(first_solution(_, [exit(killed)]), Default, true),
    Default=worker_exit(DPid,killed),ground(DPid),
    catch(first_solution(_, [exit(true)], [on_error(stop)]), Normal, true),
    Normal=worker_exit(NPid,true),ground(NPid),
    first_solution(X,[exit(killed),(sleep(0.03),X=ok)],[on_error(continue)]),X==ok,
    \+ first_solution(_, [exit(killed),exit(true)], [on_error(continue)]),
    catch(first_solution(_, [throw(original_error)]), Original, true),
    Original==original_error,
    \+ first_solution(_, [fail], [on_fail(stop),on_error(continue)]),
    writeln('first_solution default, stop, continue and exhaustion: ok').

% Wait for the later worker to terminate before releasing the earlier one.
% The extra monitor is an ordering barrier; the original down stays queued.
later_parallel_completion :-
    parallel:spawn_parallel_workers(
        [qualified_goal(user,receive({go -> true})),qualified_goal(user,true)],
        [[],[]],[First,Second]),
    monitor(Second,Barrier),
    receive({down(Second,Barrier,_) -> true},[timeout(2),on_timeout(fail)]),
    First ! go,
    parallel:collect_parallel_workers([First,Second],[First,Second],[[],[]]),
    writeln('later normal completion is deferred until its result: ok').

% Once accepted, the result establishes success; down only confirms exit.
accepted_result_termination :-
    self(Self),
    spawn(user:result_then_exit(Self,Pid),Pid,[monitor(true),link(false)]),
    parallel:collect_parallel_workers([Pid],[Pid],[[Value]]),Value==ok,
    writeln('accepted result survives nonstandard termination reason: ok').

result_then_exit(Parent,Pid) :-
    Parent ! Pid-[ok],exit(killed).

unrelated_exit_monitors :-
    self(Self),
    spawn(receive({finish -> true}),Other,[monitor(true),link(false)]),
    Other ! finish,
    Self ! down(unrelated,probe,killed),
    catch(parallel([exit(killed)]),worker_exit(_,killed),true),
    first_solution(X,[exit(true),(sleep(0.03),X=ok)],[on_error(continue)]),X==ok,
    receive({down(Other,Other,true) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(unrelated,probe,killed) -> true},[timeout(0),on_timeout(fail)]),
    writeln('unrelated real and queued monitor messages remain available: ok').
