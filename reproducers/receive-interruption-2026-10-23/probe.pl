:- module(receive_interruption_probe,[run/0,run_native/0,owner/5]).
:- use_module('actors.pl').

% No actor creation, worker combinators, monitors, or worker cleanup.
run :- run_mode(adapter).
run_native :- run_mode(native).
run_mode(Mode) :-
 thread_self(Parent),
 forall(member(Size,[0,1000,10000]),
   forall(member(Delay,[0,0.0001,0.001,0.005,0.02]),
     forall(between(1,20,Trial),one(Parent,Size,Delay,Trial,Mode)))),
 writeln(probe_complete).
one(Parent,Size,Delay,Trial,Mode) :-
 thread_create(receive_interruption_probe:owner(Parent,Size,Delay,Trial,Mode),T,[]),
 thread_get_message(ready(T)),
 sleep(Delay),
 thread_signal(T,throw('$abort_goal')),
 thread_get_message(result(T,State)),
 thread_join(T,Status),
 (State=ok('$abort_goal'),Status==true -> true
 ; writeq(finding(Size,Delay,Trial,State,Status)),nl,flush_output).
owner(Parent,Size,_,_,Mode) :-
 thread_self(T),length(Noise,Size),fill(Noise),
 nb_setval('$actor_deferred',Noise),
 thread_send_message(T,down(unrelated,probe,killed)),
 thread_send_message(Parent,ready(T)),
 catch(wait(Mode,T),E,true),
 (thread_peek_message(T,down(unrelated,probe,killed)) -> Native=present;Native=absent),
 (nb_current('$actor_deferred',D),member(down(unrelated,probe,killed),D) -> Deferred=present;Deferred=absent),
 catch((actors:receive_qualified(receive_interruption_probe:{down(unrelated,probe,killed) -> true},
    [timeout(0),on_timeout(throw(missing_unrelated))]),State=ok(E)),
    Error,State=failed(Error,E,Native,Deferred)),
 thread_send_message(Parent,result(T,State)).
fill([]).
fill([noise|T]) :- fill(T).

wait(adapter,_) :- actors:receive_qualified(receive_interruption_probe:{never -> true},[]).
wait(native,T) :- thread_get_message(T,never).
