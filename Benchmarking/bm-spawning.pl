:- use_module(actors).

start(Num) :-
    self(Self),
    start_proc(Num, Self).
        
start_proc(0, Pid) :- !,
    Pid ! ok.
start_proc(Num, Pid) :-
    Num1 is Num-1,
    spawn(start_proc(Num1, Pid), NPid, [link(false)]),
    NPid ! ok,
    receive({ok -> true}).