% SPDX-License-Identifier: MIT
% No Web Prolog: query the status of a detached thread as it retires.
run_property_race(Kind,N) :-
    forall(between(1,N,I),property_race_once(Kind,I)),
    writeln('all regressions passed').
property_race_once(Kind,I) :-
    writeq(stage(iteration(Kind,I))),nl,flush_output,
    thread_create(user:property_worker(Kind),T,[detached(true)]),
    property_poll(T,1000).
property_worker(success).
property_worker(failure) :- fail.
property_worker(exception) :- throw(property_probe).
property_poll(T,N) :-
    (catch(thread_property(T,status(_)),E,(writeq(stage(property_error(T,E))),nl,flush_output,fail)) ->
        (N>0 -> Next is N-1,property_poll(T,Next)
        ; throw(property_poll_exhausted(T)))
    ; true).
