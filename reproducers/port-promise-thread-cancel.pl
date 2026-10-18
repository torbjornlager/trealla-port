% SPDX-License-Identifier: MIT
% Runtime-only observation on Trealla v3.13.10, macOS arm64.
% Retest current upstream before filing. No Web Prolog modules are required.
% tpl -g "consult('reproducers/port-promise-thread-cancel.pl'),reproducer,halt"
reproducer :-
    thread_self(Parent),message_queue_create(Q),
    thread_create(setup_call_cleanup(
        thread_send_message(Parent,entered),
        thread_get_message(Q,_),
        thread_send_message(Parent,cleanup_ran)),T,[detached(true)]),
    thread_get_message(entered),sleep(0.03),thread_cancel(T),sleep(0.03),
    (catch(thread_property(T,status(running)),_,fail) ->
        writeln(cancelled_queue_reader_still_running)
    ; writeln(cancelled_queue_reader_stopped)),
    thread_send_message(Q,wake),wait_retired(T,200),
    (thread_get_message(Parent,cleanup_ran,[timeout(0)]) ->
        writeln(prolog_cleanup_ran)
    ; writeln(prolog_cleanup_missing)),
    message_queue_destroy(Q).
wait_retired(T,N) :-
    (catch(thread_property(T,status(_)),_,fail) ->
        N>0,sleep(0.005),Next is N-1,wait_retired(T,Next)
    ; true).
