% SPDX-License-Identifier: MIT
:- use_module(rpc).
:- use_module(actors).

rpc_promise_tests :-
    promise_retry_tests,
    promise_callback_tests,
    promise_actor_callback_test,
    promise_missing_tests,
    promise_output_tests,
    promise_worker_tests,
    writeln('Promise/yield correctness: all regressions passed').

% Fixtures use the production lifecycle state but do not start HTTP threads.
with_test_promise(Goal) :-
    make_ref(Ref),
    rpc:promise_transaction(rpc:new_promise_state(Ref,Queue)),
    setup_call_cleanup(true,call(Goal,Ref,Queue),promise_cleanup(Ref)).

promise_retry_tests :-
    with_test_promise(user:check_retry),
    writeln('timeout returns an answer and preserves retry: ok').
check_retry(Ref,_) :-
    yield(Ref,Early,[timeout(0)]),Early==timeout,
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    yield(Ref,Answer),Answer==success([ok],false),
    expect_missing(Ref).

promise_callback_tests :-
    with_test_promise(user:check_callbacks),
    writeln('callback answers, failure, exceptions and retry: ok').
check_callbacks(Ref,_) :-
    yield(Ref,Waiting,[timeout(0),on_timeout(Waiting=waiting)]),Waiting==waiting,
    nb_setval(promise_callback_count,0),
    yield(Ref,Default,[timeout(0),on_timeout(callback_once)]),Default==timeout,
    nb_getval(promise_callback_count,1),
    catch(yield(Ref,_,[timeout(0),on_timeout(fail)]),Failure,true),
    Failure=error(timeout_callback_failed(Ref),_),
    catch(yield(Ref,_,[timeout(0),on_timeout(throw(callback_error))]),Thrown,true),
    Thrown==callback_error,
    rpc:deliver_promise_answer(Ref,failure),yield(Ref,Answer),Answer==failure.
callback_once :-
    nb_getval(promise_callback_count,N),Next is N+1,
    nb_setval(promise_callback_count,Next),
    (true;throw(callback_backtracked)).

promise_actor_callback_test :-
    with_test_promise(user:check_actor_callback),
    writeln('private actor callback source context: ok').
check_actor_callback(Ref,_) :-
    self(Parent),
    spawn((yield(Ref,Answer,[timeout(0),on_timeout(local_wait(Answer))]),
           Parent ! promise_callback_result(Answer)),Pid,
          [src_text('local_wait(waiting).'),monitor(true),link(false)]),
    receive({promise_callback_result(Answer) -> Answer==waiting},
            [timeout(2),on_timeout(fail)]),
    receive({down(Pid,Pid,true) -> true},[timeout(2),on_timeout(fail)]).

promise_missing_tests :-
    make_ref(Unknown),expect_missing(Unknown),
    with_test_promise(user:check_cleaned),
    with_test_promise(user:check_expired),
    catch(yield(bad,_),Bad,true),Bad=error(type_error(integer,bad),_),
    catch(yield(_,_),Unbound,true),Unbound=error(instantiation_error,_),
    writeln('unknown, consumed, cleaned and expired references: ok').
expect_missing(Ref) :-
    catch(yield(Ref,_),Two,true),Two=error(existence_error(promise,Ref),_),
    catch(yield(Ref,_,[on_timeout(throw(wrong_callback))]),Three,true),
    Three=error(existence_error(promise,Ref),_).
check_cleaned(Ref,_) :- promise_cleanup(Ref),expect_missing(Ref).
check_expired(Ref,_) :- rpc:promise_auto_cleanup(Ref,0),expect_missing(Ref).

promise_output_tests :-
    with_test_promise(user:check_mismatch),
    with_test_promise(user:check_pattern),
    writeln('output matching happens after message selection and consumption: ok').
check_mismatch(Ref,_) :-
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    \+ yield(Ref,wrong),expect_missing(Ref).
check_pattern(Ref,_) :-
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    yield(Ref,success([Value],false),[]),Value==ok,expect_missing(Ref).

promise_worker_tests :-
    with_test_promise(user:check_worker_failure),
    with_test_promise(user:check_worker_exception),
    with_test_promise(user:check_remote_failure),
    with_test_promise(user:check_worker_success),
    writeln('worker failure and exceptions are delivered; remote failure is preserved: ok').
check_worker_failure(Ref,_) :-
    rpc:promise_worker_run(fail,_,Ref),yield(Ref,Failed),
    Failed=error(error(promise_worker_failed,_)).
check_worker_exception(Ref,_) :-
    rpc:promise_worker_run(throw(worker_error),_,Ref),yield(Ref,Thrown),
    Thrown==error(worker_error).
check_remote_failure(Ref,_) :-
    rpc:promise_worker_run(true,failure,Ref),yield(Ref,RemoteFailure),
    RemoteFailure==failure.
check_worker_success(Ref,_) :-
    rpc:promise_worker_run((Result=success([ok],false)),Result,Ref),yield(Ref,Success),
    Success==success([ok],false).

% Run against an existing disposable node; no server restart or n5 changes.
rpc_promise_live_test(Port) :-
    format(atom(URI),'http://localhost:~w',[Port]),
    promise(URI,(sleep(0.1),X=ok),Ref,[template(X)]),
    yield(Ref,Early,[timeout(0)]),Early==timeout,
    yield(Ref,Answer),Answer==success([ok],false),var(X),expect_missing(Ref),
    promise(URI,fail,FRef),yield(FRef,FAnswer),FAnswer==failure,
    promise(URI,throw(live_error),ERef),yield(ERef,EAnswer),EAnswer==error(live_error),
    format('Promise/yield live HTTP on ~w: ok~n',[Port]).
