% Test-only follow-up: elapsed-time budget instead of 1000 tight polls.
% No Web Prolog, sleeps or candidate patches. Keep the original results intact.
exception_deadline :-
    forall(between(1,1000,I),
        (writeq(stage(iteration(I))),nl,flush_output,
         thread_create(throw(property_probe),T,[detached(true)]),
         get_time(Start),Deadline is Start+2,exception_poll(T,Deadline))),
    writeln('all regressions passed').
exception_poll(T,Deadline) :-
    (catch(thread_property(T,status(_)),error(existence_error(thread_object,_),_),fail) ->
        get_time(Now),
        (Now<Deadline -> exception_poll(T,Deadline)
        ; throw(exception_retirement_timeout(T)))
    ; true).
