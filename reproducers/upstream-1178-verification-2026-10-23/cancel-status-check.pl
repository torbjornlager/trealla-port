% SPDX-License-Identifier: MIT
% Polling a cancelled detached thread's status must survive its cleanup
% freeing exited(cancelled), and must never report a status it did not end with.
missing(error(existence_error(thread_object,_),_)).
% Existing dispatch may report this if retirement races its kind lookup.
missing(error(uninstantiation_error(_),_)).
valid_status(running).
valid_status(exited(cancelled)).
waiter(Q) :- (thread_get_message(Q,_,[timeout(0.05)]) -> true ; waiter(Q)).
poll(_,0) :- throw(poll_exhausted).
poll(T,N) :-
    catch((thread_property(T,status(S)) -> Again=true ; Again=false),E,
          (missing(E) -> Again=false ; throw(E))),
    (Again==true ->
        (valid_status(S) -> true ; throw(unexpected_status(S))),
        Next is N-1,poll(T,Next)
    ; true).
once_cancelled :-
    message_queue_create(Q),
    thread_create(waiter(Q),T,[detached(true)]),
    thread_cancel(T),poll(T,100000),
    message_queue_destroy(Q).
run :-
    forall(between(1,300,_),once_cancelled),
    writeln('all regressions passed').
:- initialization((catch(run,E,(writeq(E),nl,halt(1)))->halt;halt(1))).
