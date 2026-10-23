% SPDX-License-Identifier: MIT
% Load rpc_lifecycle_tests.pl first. These are test-only controlled schedules.
:- dynamic legacy_exhausted/0.
controls :-
    wait_control,retirement_control,
    writeln('all regressions passed').
wait_control :-
    % Reproduce the old helper's misleading backtracking path deterministically.
    retractall(legacy_exhausted),nb_setval(expiry_wait_probe,0),
    \+ (legacy_wait(user:ready_after_one,2),fail),legacy_exhausted,
    nb_setval(expiry_wait_probe,0),
    \+ (await(user:ready_after_one,2),fail),
    % The completed wait must remain completed if its continuation fails.
    \+ (await(true,0),fail),
    catch(await(fail,0),E,true),
    nonvar(E),E=error(lifecycle_wait_timeout(fail,0,_),_),
    writeln('completed wait cannot become timeout on backtracking: ok').
ready_after_one :-
    nb_getval(expiry_wait_probe,N),Next is N+1,nb_setval(expiry_wait_probe,Next),N>0.
legacy_wait(Goal,N) :-
    (call(Goal) -> true
    ; N>0,Next is N-1,legacy_wait(Goal,Next)
    ; assertz(legacy_exhausted),fail).
retirement_control :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,Q)),
    message_queue_create(Control),thread_self(Parent),
    setup_call_cleanup(true,
        (thread_create(user:controlled_retirement(Ref,Q,Control,Parent),T,[]),
         thread_get_message(Parent,in_retirement(Ref),[timeout(2)]),
         % Unlocked reads can observe absent record plus still-existing queue.
         \+ rpc:promise_state(Ref,_,_,_,_,_,_),queue_exists(Q),
         thread_send_message(Control,finish),
         % The supported fixture view waits out the transaction.
         disposal_snapshot(Ref,Q,resources(false,false)),
         thread_join(T,true)),
        message_queue_destroy(Control)),
    writeln('unlocked retirement gap reproduced; locked snapshot is complete: ok').
controlled_retirement(Ref,Q,Control,Parent) :-
    rpc:promise_transaction(
        (retract(rpc:promise_state(Ref,Q,none,none,none,pending,_)),
         thread_send_message(Parent,in_retirement(Ref)),
         thread_get_message(Control,finish,[timeout(2)]),
         message_queue_destroy(Q))).
expiry_batch(N) :-
    assertz(lifecycle_diagnostics),
    forall(between(1,N,I),
        (lifecycle_stage(expiry_iteration(I)),lifecycle_expiry)),
    writeln('all regressions passed').
