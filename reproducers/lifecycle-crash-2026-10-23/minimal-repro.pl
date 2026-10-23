run :-
    forall(between(1,1000,_),
        (thread_create(throw(probe),T,[detached(true)]),poll(T,10000))),
    writeln(passed).
poll(_,0) :- throw(poll_exhausted).
poll(T,N) :-
    (catch(thread_property(T,status(_)),_,fail) ->
        Next is N-1,poll(T,Next)
    ; true).
