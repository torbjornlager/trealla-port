% SPDX-License-Identifier: MIT

:- module(server_actor_tests, [run_server_actor_tests/0]).

:- use_module(server_actor).
:- use_module(actors).
:- use_module(isolation).
:- use_module(sandbox_policy).

test_fridge(store(Food), Foods, ok, [Food|Foods]).
test_fridge(take(Food), Foods, ok(Food), Rest) :-
    select(Food, Foods, Rest), !.
test_fridge(take(_), Foods, not_found, Foods).

fridge2(store(Food), Foods, stored(Food), [Food|Foods]).
fridge2(take(Food), Foods, taken(Food), Rest) :-
    select(Food, Foods, Rest), !.
fridge2(take(_), Foods, not_found, Foods).

original_fridge(store(Food), Foods, ok, [Food|Foods]).
original_fridge(take(Food), Foods, ok(Food), Rest) :-
    select(Food, Foods, Rest), !.
original_fridge(take(_), Foods, not_found, Foods).

counter(inc, N, ok, N1) :- N1 is N + 1.
counter(dec, N, ok, N1) :- N1 is N - 1.
counter(get, N, val(N), N).
counter(reset, _, ok, 0).

crasher_cb(_, _, _, _) :- throw(crash).
echo(Request, State, Request, State).
blocking_cb(_, State, _, State) :- sleep(3600).
tagged_cb(Tag, Request, State, Tag-Request, State).


run_server_actor_tests :-
    run_case(yield_selects_before_output_unification,
             yield_selects_before_output_unification),
    run_case(yield_accepts_matching_outputs, yield_accepts_matching_outputs),
    run_case(yield_preserves_other_replies_and_sharing,
             yield_preserves_other_replies_and_sharing),
    run_case(yield_timeout_bindings, yield_timeout_bindings),
    run_case(yield_timeout_failure_and_exception,
             yield_timeout_failure_and_exception),
    run_case(yield_timeout_alternatives, yield_timeout_alternatives),
    run_case(halt_detects_death_before_ack,
             halt_detects_death_before_ack),
    run_case(halt_preserves_unrelated_down,
             halt_preserves_unrelated_down),
    run_case(halt_preserves_existing_monitor,
             halt_preserves_existing_monitor),
    run_case(yield_cleans_monitor_on_timeout,
             yield_cleans_monitor_on_timeout),
    run_case(yield_cleans_monitor_on_reply_unification_failure,
             yield_cleans_monitor_on_reply_unification_failure),
    run_case(yield_preserves_timeout_handler_alternatives,
             yield_preserves_timeout_handler_alternatives),
    run_case(basic_spawn_and_request, basic_spawn_and_request),
    run_case(state_threading, state_threading),
    run_case(take_missing_item, take_missing_item),
    run_case(initial_state, initial_state),
    run_case(counter_state, counter_state),
    run_case(counter_reset, counter_reset),
    run_case(server_halt_reply, server_halt_reply),
    run_case(server_halt_ignores_uncorrelated_reply,
             server_halt_ignores_uncorrelated_reply),
    run_case(hot_code_swap, hot_code_swap),
    run_case(upgrade_preserves_state, upgrade_preserves_state),
    run_case(multiple_upgrades, multiple_upgrades),
    run_case(upgrade_without_source_rejects_unloaded_callback,
             upgrade_without_source_rejects_unloaded_callback),
    run_case(upgrade_without_source_accepts_loaded_callback,
             upgrade_without_source_accepts_loaded_callback),
    run_case(async_promise_yield, async_promise_yield),
    run_case(multiple_async_promises, multiple_async_promises),
    run_case(fail_fast_normal, fail_fast_normal),
    run_case(fail_fast_server_crash, fail_fast_server_crash),
    run_case(fail_fast_callback_failure, fail_fast_callback_failure),
    run_case(request_timeout, request_timeout),
    run_case(named_server, named_server),
    run_case(echo_server, echo_server),
    run_case(callback_closure, callback_closure),
    run_case(private_actor_source, private_actor_source),
    run_case(private_toplevel_query, private_toplevel_query),
    run_case(profile_and_sandbox_surface, profile_and_sandbox_surface),
    format('All 37 generic server behaviour tests passed.~n', []).

run_case(Name, Goal) :-
    catch(( call(Goal) -> true ; throw(test_failed(Name)) ), Error, true),
    ( var(Error)
    -> format('server ~w ok~n', [Name])
    ; throw(error(server_actor_test_failed(Name, Error),
                  run_server_actor_tests/0))
    ).

yield_selects_before_output_unification :-
    self(Self),make_ref(Ref),send(Self,Ref-actual),
    \+server_yield(Ref,different,
        [timeout(0),on_timeout(throw(unexpected_yield_timeout))]),
    % A mismatch consumes the selected reply, even though unification fails.
    receive({Ref-_ -> fail},[timeout(0)]).

yield_accepts_matching_outputs :-
    self(Self),make_ref(Ref),send(Self,Ref-ok),
    server_yield(Ref,ok,[timeout(0),on_timeout(fail)]),
    make_ref(Ref2),send(Self,Ref2-ok),server_yield(Ref2,ok).

yield_preserves_other_replies_and_sharing :-
    self(Self),make_ref(Ref),make_ref(Other),
    send(Self,Other-unrelated),send(Self,Ref-pair(X,X)),
    server_yield(Ref,Answer,[timeout(0),on_timeout(fail)]),
    Answer=pair(A,B),var(A),A==B,
    server_yield(Other,unrelated,[timeout(0),on_timeout(fail)]).

yield_timeout_bindings :-
    make_ref(Ref),server_yield(Ref,Unbound,[timeout(0)]),var(Unbound),
    server_yield(Ref,Answer,[timeout(0),on_timeout(Answer=waiting)]),
    Answer==waiting,
    server_yield(Ref,prebound,[timeout(0),on_timeout(true)]).

yield_timeout_failure_and_exception :-
    make_ref(Ref),\+server_yield(Ref,_,[timeout(0),on_timeout(fail)]),
    catch(server_yield(Ref,_,[timeout(0),on_timeout(throw(yield_timeout_test))]),
      Error,true),Error==yield_timeout_test.

yield_timeout_alternatives :-
    make_ref(Ref),
    findall(X,server_yield(Ref,X,
      [timeout(0),on_timeout(member(X,[a,b]))]),Xs),Xs==[a,b].

halt_detects_death_before_ack :-
    spawn(receive({'$stop'(_, _) -> fail}), Pid, []),
    catch(server_halt(Pid, _), Error, true),
    Error == server_down(false).

halt_preserves_unrelated_down :-
    self(Self),
    send(Self, down(other, unrelated, false)),
    server_spawn(echo, [], Pid),
    server_halt(Pid, true),
    receive({down(other, unrelated, false) -> true},
            [timeout(0), on_timeout(fail)]).

halt_preserves_existing_monitor :-
    server_spawn(echo, [], Pid),
    monitor(Pid, Ref),
    server_halt(Pid, true),
    receive({down(Pid, Ref, true) -> true},
            [timeout(1), on_timeout(fail)]),
    receive({down(Pid, _, _) -> fail}, [timeout(0)]).

yield_cleans_monitor_on_timeout :-
    timeout_cleanup_case(true),
    timeout_cleanup_case(fail),
    timeout_cleanup_case(throw(timeout_test)).

timeout_cleanup_case(Handler) :-
    spawn(receive({stop -> true}), Pid, []),
    monitor(Pid, Ref),
    catch(ignore(server_yield(unanswered, Ref, _,
                             [timeout(0), on_timeout(Handler)])),
          timeout_test, true),
    monitor(Pid, Witness),
    send(Pid, stop),
    receive({down(Pid, Witness, true) -> true},
            [timeout(1), on_timeout(fail)]),
    receive({down(Pid, Ref, _) -> fail}, [timeout(0)]).

yield_cleans_monitor_on_reply_unification_failure :-
    self(Self),
    spawn(receive({stop -> true}), Pid, []),
    monitor(Pid, Ref),
    send(Self, answer-actual),
    \+ server_yield(answer, Ref, different, []),
    monitor(Pid, Witness),
    send(Pid, stop),
    receive({down(Pid, Witness, true) -> true},
            [timeout(1), on_timeout(fail)]),
    receive({down(Pid, Ref, _) -> fail}, [timeout(0)]).

yield_preserves_timeout_handler_alternatives :-
    spawn(receive({stop -> true}), Pid, []),
    monitor(Pid, Ref),
    findall(X, server_yield(unanswered, Ref, _,
                           [timeout(0), on_timeout(member(X, [a,b]))]), Xs),
    Xs == [a,b],
    monitor(Pid, Witness),
    send(Pid, stop),
    receive({down(Pid, Witness, true) -> true},
            [timeout(1), on_timeout(fail)]),
    receive({down(Pid, Ref, _) -> fail}, [timeout(0)]).

basic_spawn_and_request :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), ok),
    server_halt(Pid, true).

state_threading :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), ok),
    server_request(Pid, store(eggs), ok),
    server_request(Pid, take(milk), ok(milk)),
    server_request(Pid, take(eggs), ok(eggs)),
    server_halt(Pid, true).

take_missing_item :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, take(bread), not_found),
    server_halt(Pid, true).

initial_state :-
    server_spawn(test_fridge, [milk,eggs], Pid),
    server_request(Pid, take(milk), ok(milk)),
    server_request(Pid, take(eggs), ok(eggs)),
    server_halt(Pid, true).

counter_state :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, ok),
    server_request(Pid, inc, ok),
    server_request(Pid, inc, ok),
    server_request(Pid, dec, ok),
    server_request(Pid, get, val(2)),
    server_halt(Pid, true).

counter_reset :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, ok),
    server_request(Pid, inc, ok),
    server_request(Pid, reset, ok),
    server_request(Pid, get, val(0)),
    server_halt(Pid, true).

server_halt_reply :-
    server_spawn(test_fridge, [], Pid),
    server_halt(Pid, true).

server_halt_ignores_uncorrelated_reply :-
    self(Self),
    send(Self, reply(stale)),
    server_spawn(test_fridge, [], Pid),
    server_halt(Pid, true),
    receive({reply(Stale) -> true}),
    Stale == stale.

hot_code_swap :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), ok),
    server_upgrade(Pid, fridge2, [src_predicates([fridge2/4])]),
    server_request(Pid, take(milk), taken(milk)),
    server_halt(Pid, true).

upgrade_preserves_state :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, ok),
    server_request(Pid, inc, ok),
    server_request(Pid, inc, ok),
    server_upgrade(Pid, echo, [src_predicates([echo/4])]),
    server_request(Pid, get, get),
    server_halt(Pid, true).

multiple_upgrades :-
    server_spawn(test_fridge, [milk], Pid),
    server_upgrade(Pid, fridge2, [src_predicates([fridge2/4])]),
    server_upgrade(Pid, original_fridge,
                   [src_predicates([original_fridge/4])]),
    server_request(Pid, take(milk), ok(milk)),
    server_halt(Pid, true).

upgrade_without_source_rejects_unloaded_callback :-
    server_spawn(test_fridge, [], Pid),
    catch(server_upgrade(Pid, fridge2), Error, true),
    Error = error(existence_error(procedure, _), _),
    server_halt(Pid, true).

upgrade_without_source_accepts_loaded_callback :-
    server_spawn(test_fridge, [], Pid,
                 [src_predicates([fridge2/4])]),
    server_upgrade(Pid, fridge2),
    server_halt(Pid, true).

async_promise_yield :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(meat), Ref),
    server_yield(Ref, ok),
    server_halt(Pid, true).

multiple_async_promises :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(milk), Ref1),
    server_promise(Pid, store(eggs), Ref2),
    server_yield(Ref1, ok),
    server_yield(Ref2, ok),
    server_halt(Pid, true).

fail_fast_normal :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(milk), Ref, MonitorRef),
    server_yield(Ref, MonitorRef, ok, []),
    server_halt(Pid, true).

fail_fast_server_crash :-
    server_spawn(crasher_cb, [], Pid),
    catch(server_request(Pid, anything, _), Error, true),
    Error = server_down(exception(crash)).

fail_fast_callback_failure :-
    server_spawn(test_fridge, [], Pid),
    catch(server_request(Pid, unknown_request, _), Error, true),
    Error == server_down(false).

request_timeout :-
    server_spawn(blocking_cb, [], Pid),
    server_request(Pid, anything, Response, [timeout(0.05)]),
    var(Response),
    exit(Pid, kill).

named_server :-
    server_spawn(test_fridge, [], _Pid, [name(test_named_fridge)]),
    server_request(test_named_fridge, store(butter), ok),
    server_halt(test_named_fridge, true).

echo_server :-
    server_spawn(echo, state, Pid),
    server_request(Pid, hello, hello),
    server_halt(Pid, true).

callback_closure :-
    server_spawn(tagged_cb(label), state, Pid),
    server_request(Pid, ping, label-ping),
    server_halt(Pid, true).

private_actor_source :-
    self(Self),
    Terms = [
        (private_counter(inc, N, val(N1), N1) :- N1 is N + 1),
        (private_server_parent(Root) :-
            server_spawn(private_counter, 0, Pid),
            server_request(Pid, inc, val(1)),
            server_halt(Pid, true),
            actors:send(Root, private_server_ok))
    ],
    spawn(private_server_parent(Self), _Parent,
          [src_list(Terms), link(false)]),
    receive({private_server_ok -> true},
            [timeout(2), on_timeout(fail)]).

private_toplevel_query :-
    Terms = [(query_counter(inc, N, val(N1), N1) :- N1 is N + 1)],
    spawn(receive({stop -> true}), Holder,
          [src_list(Terms), link(false)]),
    actor_module(Holder, Module),
    run_actor_query(Module, server_spawn(query_counter, 0, Pid)),
    server_request(Pid, inc, val(1)),
    server_halt(Pid, true),
    send(Holder, stop).

profile_and_sandbox_surface :-
    sandbox_prepare_goal(whitelist, actor, user,
                         server_spawn(callback, state, _Pid), Prepared),
    Prepared = server_spawn(callback, state, _),
    catch(sandbox_prepare_goal(whitelist, isotope, user,
                               server_spawn(callback, state, _), _),
          Error, true),
    Error = error(profile_violation(isotope, goal(_)), _).
