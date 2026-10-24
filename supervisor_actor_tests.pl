% SPDX-License-Identifier: MIT

:- module(supervisor_actor_tests, [run_supervisor_actor_tests/0]).

:- use_module(supervisor_actor).
:- use_module(server_actor).
:- use_module(actors).
:- use_module(sandbox_policy).

forever :- receive({}).
crasher(Delay) :- sleep(Delay), exit(crash).
finisher(Delay) :- sleep(Delay).

test_fridge(store(Food), Foods, ok, [Food|Foods]).
test_fridge(take(Food), Foods, ok(Food), Rest) :-
    select(Food, Foods, Rest), !.
test_fridge(take(_), Foods, not_found, Foods).

run_supervisor_actor_tests :-
    run_case(basic_startup, basic_startup),
    run_case(one_for_one_restart, one_for_one_restart),
    run_case(temporary_not_restarted, temporary_not_restarted),
    run_case(transient_normal_exit, transient_normal_exit),
    run_case(one_for_all, one_for_all),
    run_case(rest_for_one, rest_for_one),
    run_case(dynamic_start_child, dynamic_start_child),
    run_case(dynamic_terminate_and_delete, dynamic_terminate_and_delete),
    run_case(dynamic_restart_child, dynamic_restart_child),
    run_case(server_child_timed_shutdown_is_graceful,
             server_child_timed_shutdown_is_graceful),
    run_case(plain_child_timed_shutdown_uses_shutdown_signal,
             plain_child_timed_shutdown_uses_shutdown_signal),
    run_case(server_child, server_child),
    run_case(count_children, count_children),
    run_case(restart_intensity, restart_intensity),
    run_case(nested_supervision, nested_supervision),
    run_case(server_halt_permanent, server_halt_permanent),
    run_case(server_halt_transient, server_halt_transient),
    run_case(cascade_cleanup, cascade_cleanup),
    run_case(private_source_body, private_source_body),
    run_case(private_source_and_policy, private_source_and_policy),
    format('All 20 supervisor behaviour tests passed.~n', []).

run_case(Name, Goal) :-
    catch(( call(Goal) -> true ; throw(test_failed(Name)) ), Error, true),
    ( var(Error)
    -> format('supervisor ~w ok~n', [Name])
    ; throw(error(supervisor_actor_test_failed(Name, Error),
                  run_supervisor_actor_tests/0))
    ).

child_pid(Id, Children, Pid) :-
    member(info(Id, Pid, _, _), Children), !.

cleanup(Name) :-
    catch(supervisor_halt(Name), _, true),
    sleep(0.05).

% Trealla does not qualify a list-valued ':' meta-argument when an imported
% predicate is called from another module. Make the source module explicit;
% ordinary user and private-toplevel calls are qualified by their runtime
% entry points.
test_supervisor_spawn(Specs, Pid, Options) :-
    supervisor_spawn(supervisor_actor_tests:Specs, Pid, Options).

test_supervisor_spawn_child(Supervisor, Spec, Reply) :-
    supervisor_spawn_child(Supervisor, supervisor_actor_tests:Spec, Reply).

basic_startup :-
    test_supervisor_spawn([
        child(w1, [start(forever)]),
        child(w2, [start(forever)])
    ], _, [name(sup_t1)]),
    supervisor_which_children(sup_t1, Children),
    length(Children, 2),
    child_pid(w1, Children, Pid1),
    child_pid(w2, Children, Pid2),
    Pid1 \= undefined,
    Pid2 \= undefined,
    Pid1 \= Pid2,
    cleanup(sup_t1).

one_for_one_restart :-
    test_supervisor_spawn([
        child(stable, [start(forever)]),
        child(flaky, [start(crasher(0.08)), restart(permanent)])
    ], _, [strategy(one_for_one), intensity(5), period(10), name(sup_t2)]),
    supervisor_which_children(sup_t2, Before),
    child_pid(stable, Before, Stable1),
    child_pid(flaky, Before, Flaky1),
    sleep(0.25),
    supervisor_which_children(sup_t2, After),
    child_pid(stable, After, Stable2),
    child_pid(flaky, After, Flaky2),
    Stable2 == Stable1,
    Flaky2 \= Flaky1,
    Flaky2 \= undefined,
    cleanup(sup_t2).

temporary_not_restarted :-
    test_supervisor_spawn([
        child(keeper, [start(forever)]),
        child(temp, [start(crasher(0.05)), restart(temporary)])
    ], _, [intensity(5), period(10), name(sup_t3)]),
    sleep(0.2),
    supervisor_which_children(sup_t3, Children),
    Children = [info(keeper, _, worker, permanent)],
    cleanup(sup_t3).

transient_normal_exit :-
    test_supervisor_spawn([
        child(keeper, [start(forever)]),
        child(runner, [start(finisher(0.05)), restart(transient)])
    ], _, [intensity(5), period(10), name(sup_t4)]),
    sleep(0.2),
    supervisor_which_children(sup_t4, Children),
    child_pid(runner, Children, undefined),
    cleanup(sup_t4).

one_for_all :-
    test_supervisor_spawn([
        child(a, [start(forever)]),
        child(b, [start(forever)]),
        child(c, [start(crasher(0.08)), restart(permanent)])
    ], _, [strategy(one_for_all), intensity(5), period(10), name(sup_t5)]),
    supervisor_which_children(sup_t5, Before),
    child_pid(a, Before, A1), child_pid(b, Before, B1), child_pid(c, Before, C1),
    sleep(0.25),
    supervisor_which_children(sup_t5, After),
    child_pid(a, After, A2), child_pid(b, After, B2), child_pid(c, After, C2),
    A2 \= A1, B2 \= B1, C2 \= C1,
    cleanup(sup_t5).

rest_for_one :-
    test_supervisor_spawn([
        child(first, [start(forever)]),
        child(middle, [start(crasher(0.08)), restart(permanent)]),
        child(last, [start(forever)])
    ], _, [strategy(rest_for_one), intensity(5), period(10), name(sup_t6)]),
    supervisor_which_children(sup_t6, Before),
    child_pid(first, Before, F1),
    child_pid(middle, Before, M1),
    child_pid(last, Before, L1),
    sleep(0.25),
    supervisor_which_children(sup_t6, After),
    child_pid(first, After, F2),
    child_pid(middle, After, M2),
    child_pid(last, After, L2),
    F2 == F1, M2 \= M1, L2 \= L1,
    cleanup(sup_t6).

dynamic_start_child :-
    test_supervisor_spawn([], _, [name(sup_t7)]),
    test_supervisor_spawn_child(sup_t7, child(dyn, [start(forever)]), ok),
    test_supervisor_spawn_child(sup_t7, child(dyn, [start(forever)]),
                           error(already_present)),
    supervisor_which_children(sup_t7, Children),
    child_pid(dyn, Children, Pid), Pid \= undefined,
    cleanup(sup_t7).

dynamic_terminate_and_delete :-
    test_supervisor_spawn([child(w1, [start(forever)])], _, [name(sup_t8)]),
    supervisor_terminate_child(sup_t8, w1, ok),
    supervisor_which_children(sup_t8, Stopped),
    child_pid(w1, Stopped, undefined),
    supervisor_delete_child(sup_t8, w1, ok),
    supervisor_delete_child(sup_t8, w1, error(not_found)),
    supervisor_which_children(sup_t8, []),
    cleanup(sup_t8).

dynamic_restart_child :-
    test_supervisor_spawn([child(w1, [start(forever)])], _, [name(sup_t9)]),
    supervisor_which_children(sup_t9, Before), child_pid(w1, Before, Pid1),
    supervisor_terminate_child(sup_t9, w1, ok),
    supervisor_respawn_child(sup_t9, w1, ok(Pid2)),
    Pid2 \= Pid1,
    supervisor_which_children(sup_t9, After), child_pid(w1, After, Pid2),
    cleanup(sup_t9).

server_child_timed_shutdown_is_graceful :-
    test_supervisor_spawn([
        child(fridge_shutdown, [
            start(server(test_fridge, [initial_state([])])), shutdown(1)])
    ], _, [name(sup_t10)]),
    supervisor_which_children(sup_t10, Children),
    child_pid(fridge_shutdown, Children, Pid),
    monitor(Pid, Ref),
    supervisor_terminate_child(sup_t10, fridge_shutdown, ok),
    receive({down(Pid, Ref, Reason) -> true},
            [timeout(2), on_timeout(fail)]),
    Reason == true,
    cleanup(sup_t10).

plain_child_timed_shutdown_uses_shutdown_signal :-
    test_supervisor_spawn([
        child(worker_shutdown, [start(forever), shutdown(1)])
    ], _, [name(sup_t11)]),
    supervisor_which_children(sup_t11, Children),
    child_pid(worker_shutdown, Children, Pid),
    monitor(Pid, Ref),
    supervisor_terminate_child(sup_t11, worker_shutdown, ok),
    receive({down(Pid, Ref, Reason) -> true},
            [timeout(2), on_timeout(fail)]),
    Reason == shutdown,
    cleanup(sup_t11).

server_child :-
    test_supervisor_spawn([
        child(fridge_service, [
            start(server(test_fridge, [initial_state([])])),
            restart(permanent), shutdown(1)])
    ], _, [name(sup_t12)]),
    supervisor_which_children(sup_t12, _),
    server_request(fridge_service, store(milk), ok),
    server_request(fridge_service, take(milk), ok(milk)),
    server_request(fridge_service, take(bread), not_found),
    cleanup(sup_t12).

count_children :-
    test_supervisor_spawn([
        child(w1, [start(forever)]),
        child(w2, [start(forever)]),
        child(w3, [start(forever)])
    ], _, [name(sup_t13)]),
    supervisor_count_children(sup_t13, Counts),
    memberchk(specs-3, Counts), memberchk(active-3, Counts),
    memberchk(workers-3, Counts), memberchk(supervisors-0, Counts),
    cleanup(sup_t13).

restart_intensity :-
    test_supervisor_spawn([
        child(bomb, [start(crasher(0.05)), restart(permanent)])
    ], Pid, [intensity(2), period(10), name(sup_t14), monitor(true)]),
    receive({down(Pid, _, Reason) -> true},
            [timeout(3), on_timeout(fail)]),
    Reason == shutdown.

nested_supervision :-
    Inner = [child(iw1, [start(forever)]), child(iw2, [start(forever)])],
    test_supervisor_spawn([
        child(inner, [
            start(start_sub_supervisor(Inner,
                  [strategy(one_for_one),intensity(3),period(10)])),
            type(supervisor), restart(permanent), shutdown(infinity)]),
        child(outer_worker, [start(forever)])
    ], _, [intensity(5), period(10), name(sup_t15)]),
    supervisor_which_children(sup_t15, Before),
    child_pid(inner, Before, Inner1),
    child_pid(outer_worker, Before, Worker1),
    exit(Inner1, kill),
    sleep(0.2),
    supervisor_which_children(sup_t15, After),
    child_pid(inner, After, Inner2),
    child_pid(outer_worker, After, Worker2),
    Inner2 \= Inner1, Worker2 == Worker1,
    cleanup(sup_t15).

server_halt_permanent :-
    test_supervisor_spawn([
        child(restart_fridge, [
            start(server(test_fridge, [initial_state([milk])])),
            restart(permanent), shutdown(1)])
    ], _, [intensity(5), period(10), name(sup_t16)]),
    supervisor_which_children(sup_t16, _),
    supervisor_which_children(sup_t16, Before),
    child_pid(restart_fridge, Before, Pid1),
    server_halt(restart_fridge, true),
    sleep(0.2),
    supervisor_which_children(sup_t16, After),
    child_pid(restart_fridge, After, Pid2),
    Pid2 \= Pid1, Pid2 \= undefined,
    server_request(restart_fridge, store(eggs), ok),
    cleanup(sup_t16).

server_halt_transient :-
    test_supervisor_spawn([
        child(transient_fridge, [
            start(server(test_fridge, [initial_state([])])),
            restart(transient), shutdown(1)])
    ], _, [intensity(5), period(10), name(sup_t17)]),
    supervisor_which_children(sup_t17, _),
    server_halt(transient_fridge, true),
    sleep(0.15),
    supervisor_which_children(sup_t17, Children),
    child_pid(transient_fridge, Children, undefined),
    cleanup(sup_t17).

cascade_cleanup :-
    Inner = [child(deep1, [start(forever)]),
             child(deep2, [start(forever)])],
    test_supervisor_spawn([
        child(inner_sup, [
            start(start_sub_supervisor(Inner,
                  [strategy(one_for_one),intensity(3),period(10)])),
            type(supervisor), restart(permanent), shutdown(infinity)])
    ], Outer, [intensity(3), period(10), name(sup_t18), monitor(true)]),
    supervisor_which_children(sup_t18, Children),
    child_pid(inner_sup, Children, InnerPid),
    monitor(InnerPid, Ref),
    exit(Outer, kill),
    receive({down(InnerPid, Ref, _) -> true},
            [timeout(3), on_timeout(fail)]).

private_source_body :-
    self(Self),
    Terms = [
        (private_supervisor_parent(Root) :-
            supervisor_spawn([child(private_child,
                                    [start(sleep(3600))])], Sup, []),
            supervisor_which_children(Sup, Children),
            member(info(private_child, Pid, worker, permanent), Children),
            Pid \= undefined,
            supervisor_halt(Sup),
            actors:send(Root, private_supervisor_ok))
    ],
    spawn(private_supervisor_parent(Self), _,
          [src_list(Terms), link(false)]),
    receive({private_supervisor_ok -> true},
            [timeout(3), on_timeout(fail)]).

private_source_and_policy :-
    sandbox_prepare_goal(whitelist, actor, user,
                         supervisor_spawn([], _), Prepared),
    Prepared = sandbox_policy:sandbox_supervisor_call(
        whitelist,actor,user,[],supervisor_spawn([],_)),
    catch(sandbox_prepare_goal(whitelist, isotope, user,
                               supervisor_spawn([], _), _),
          Error, true),
    Error = error(profile_violation(isotope, goal(_)), _),
    catch(sandbox_prepare_goal(blacklist, actor, user,
                               supervisor_spawn([
                                   child(unsafe, [start(shell(command))])
                               ], _), _),
          UnsafeError, true),
    UnsafeError = error(permission_error(call, sandboxed,
                                         shell(command)), _).
