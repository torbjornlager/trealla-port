% SPDX-License-Identifier: MIT
:- use_module(rpc).
:- use_module(actors,[make_ref/1]).

rpc_lifecycle_tests :-
    lifecycle_collection,
    lifecycle_expiry,
    lifecycle_cleanup,
    lifecycle_retry,
    lifecycle_collector_interruption,
    lifecycle_waiting_disposal,
    lifecycle_hard_cancel_cleanup,
    lifecycle_startup_rollback,
    lifecycle_delivery_race,
    writeln('Promise lifecycle: all regressions passed').

start_test_promise(Delay,Expiry,Ref,Resources) :-
    make_ref(Ref),
    rpc:start_promise_setup(Ref,user:start_test_threads(Ref,Delay,Expiry,Resources)).
start_test_threads(Ref,Delay,Expiry,resources(Q,W,T)) :-
    rpc:start_promise_threads(Ref,
        rpc:promise_worker_run(user:(sleep(Delay),Result=success([ok],false)),Result,Ref),Expiry),
    % Capture handles before releasing the startup gate. Even a short-lived
    % expiry cannot retire the record before the fixture has its snapshot.
    once(rpc:promise_state(Ref,Q,W,T,_,_,_)).

resources(Ref,resources(Q,W,T)) :-
    rpc:promise_transaction(rpc:promise_state(Ref,Q,W,T,_,_,_Owner)).
assert_disposed(Ref,resources(Q,W,T)) :-
    \+ rpc:promise_state(Ref,_,_,_,_,_,_Owner),
    \+ queue_exists(Q),
    await(user:thread_gone(W),200),await(user:thread_gone(T),200).
queue_exists(Q) :- catch(message_queue_property(Q,size(_)),_,fail).
thread_gone(none) :- !.
thread_gone(T) :- \+ catch(thread_property(T,status(_)),_,fail).
await(Goal,N) :-
    (call(Goal) -> true
    ; N>0,sleep(0.005),Next is N-1,await(Goal,Next)).

lifecycle_collection :-
    start_test_promise(0.03,300,Ref,R),
    yield(Ref,Answer),Answer==success([ok],false),assert_disposed(Ref,R),
    start_test_promise(0.03,300,Mismatch,MR),
    \+ yield(Mismatch,wrong),assert_disposed(Mismatch,MR),
    writeln('collection and output mismatch reclaim queues and threads: ok').
lifecycle_expiry :-
    start_test_promise(60,0.03,Ref,R),
    await(user:reference_gone(Ref),200),assert_disposed(Ref,R),expect_gone(Ref),
    writeln('expiry stops outstanding worker and reclaims resources: ok').
lifecycle_cleanup :-
    start_test_promise(60,300,Ref,R),
    promise_cleanup(Ref),promise_cleanup(Ref),
    assert_disposed(Ref,R),expect_gone(Ref),
    writeln('explicit cleanup reclaims resources and is idempotent: ok').
lifecycle_retry :-
    start_test_promise(60,300,Ref,R),yield(Ref,Early,[timeout(0)]),Early==timeout,
    once(rpc:promise_state(Ref,_,_,_,none,pending,_Owner)),
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    yield(Ref,Answer),Answer==success([ok],false),assert_disposed(Ref,R),
    writeln('timeout releases the collector and preserves retry: ok').
reference_gone(Ref) :- \+ rpc:promise_active(Ref).
expect_gone(Ref) :-
    catch(yield(Ref,_),E,true),E=error(existence_error(promise,Ref),_).

% A second collector is rejected. Cancelling the first releases its claim;
% the ready answer remains retrievable, even if its queue wakeup was read.
lifecycle_collector_interruption :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_)),
    thread_self(Parent),
    thread_create(user:lifecycle_waiter(Ref,Parent),Collector,[detached(true)]),
    await(user:has_collector(Ref),200),
    catch(yield(Ref,_,[timeout(0)]),E,true),
    E=error(permission_error(collect,promise,Ref),_),
    thread_cancel(Collector),await(user:thread_gone(Collector),200),
    rpc:deliver_promise_answer(Ref,success([retained],false)),
    % Simulate the interruption boundary after dequeueing a wakeup: the
    % stored answer, rather than the token, determines readiness.
    once(rpc:promise_state(Ref,Q,_,_,_,_,_Owner)),thread_get_message(Q,ready),
    yield(Ref,A),A==success([retained],false),\+ queue_exists(Q),
    writeln('collector exclusion, interruption and answer retention: ok').
has_collector(Ref) :- rpc:promise_state(Ref,_,_,_,C,_,_Owner),C\==none.
lifecycle_waiter(Ref,Parent) :-
    catch(yield(Ref,A,[timeout(3)]),E,true),
    thread_send_message(Parent,wait_finished(Ref,A,E)).

lifecycle_waiting_disposal :-
    start_test_promise(60,300,Ref,R),thread_self(Parent),
    thread_create(user:lifecycle_waiter(Ref,Parent),C,[detached(true)]),
    await(user:has_collector(Ref),200),promise_cleanup(Ref),
    thread_get_message(Parent,wait_finished(Ref,_,E),[timeout(2)]),
    E=error(existence_error(promise,Ref),_),
    await(user:thread_gone(C),200),assert_disposed(Ref,R),
    % Exercise real timer-driven expiry with a blocked collector too.
    start_test_promise(60,0.1,Exp,ER),
    catch(yield(Exp,_,[timeout(2)]),EE,true),
    EE=error(existence_error(promise,Exp),_),assert_disposed(Exp,ER),
    writeln('cleanup and expiry wake waiting collectors before queue destruction: ok').

lifecycle_hard_cancel_cleanup :-
    start_test_promise(60,300,Ref,R),thread_self(Parent),
    thread_create(user:lifecycle_waiter(Ref,Parent),C,[detached(true)]),
    await(user:has_collector(Ref),200),
    thread_cancel(C),promise_cleanup(Ref),
    await(user:thread_gone(C),200),assert_disposed(Ref,R),
    writeln('disposal recovers a concurrently hard-cancelled collector: ok').

lifecycle_startup_rollback :-
    make_ref(Ref),
    catch(rpc:start_promise_setup(Ref,user:partial_start(Ref,throw(rollback_error))),E,true),
    E==rollback_error,nb_getval(rollback_resources,R),assert_disposed(Ref,R),
    make_ref(FRef),
    \+ rpc:start_promise_setup(FRef,user:partial_start(FRef,fail)),
    nb_getval(rollback_resources,FR),assert_disposed(FRef,FR),
    writeln('partial startup failure and exception roll back resources: ok').
partial_start(Ref,Finish) :-
    once(rpc:promise_state(Ref,Q,none,none,none,pending,_Owner)),
    thread_create(rpc:promise_thread(Ref,sleep(60)),W,[detached(true)]),
    retract(rpc:promise_state(Ref,Q,none,none,none,pending,_Owner)),
    assertz(rpc:promise_state(Ref,Q,W,none,none,pending,_Owner)),
    nb_setval(rollback_resources,resources(Q,W,none)),
    call(Finish).

lifecycle_delivery_race :-
    forall(between(1,30,_),user:delivery_cleanup_once),
    writeln('late delivery and cleanup races leave no resources: ok').
delivery_cleanup_once :-
    start_test_promise(0,300,Ref,R),
    promise_cleanup(Ref),rpc:deliver_promise_answer(Ref,success([late],false)),
    assert_disposed(Ref,R).

rpc_lifecycle_live_test(Port) :-
    format(atom(URI),'http://localhost:~w',[Port]),
    stream_count(Before),
    promise(URI,(sleep(1),X=slow),Ref,[template(X)]),resources(Ref,R),
    await(user:more_streams_than(Before),200),
    promise_cleanup(Ref),assert_disposed(Ref,R),stream_count(Before),
    % Collection on the same node still works after stopping the local wait.
    promise(URI,Y=ok,Next,[template(Y)]),resources(Next,NR),
    yield(Next,Answer),Answer==success([ok],false),assert_disposed(Next,NR),
    format('HTTP worker cancellation closes its own stream on ~w: ok~n',[Port]).
stream_count(N) :- findall(S,stream_property(S,mode(_)),Streams),length(Streams,N).
more_streams_than(N) :- stream_count(Current),Current>N.
