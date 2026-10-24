% No Web Prolog code. Original engines demonstrate the non-atomic handoff;
% candidate engines use the private atomic dequeue-and-save primitive.
:- module(receive_handoff_standalone,[run/0,interrupted/1]).
run :- thread_self(Self),forall(between(1,1000,_),one(Self)),
       writeln('Standalone handoff: all regressions passed').
% The deterministic gate is inside the protected region. Parent releases it
% only after sending the signal, so saving must finish before stop is thrown.
acquire(Self,M,Parent) :-
    sig_atomic((thread_get_message(Self,M),
                thread_send_message(Parent,acquired(Self)),
                thread_get_message(Self,continue),
                nb_setval(saved,[M]))).
one(Parent) :-
    thread_create(receive_handoff_standalone:interrupted(Parent),T,[]),
    bounded(ready(T)),bounded(acquired(T)),thread_signal(T,throw(stop)),thread_send_message(T,continue),
    bounded(result(T,Result)),thread_join(T,Status),
    require(Status==true,status(Status)),require(Result==ok,interruption(Result)).
interrupted(Parent) :-
    thread_self(Self),nb_setval(saved,[]),
    thread_send_message(Self,down(unrelated,probe,killed)),
    catch((thread_send_message(Parent,ready(Self)),
           acquire(Self,_M,Parent),
           thread_get_message(Self,never)),Error,true),
    catch((require(Error==stop,wrong_exception(Error)),nb_getval(saved,Saved),
           (Saved==[down(unrelated,probe,killed)] ->
              require(\+thread_peek_message(Self,_),duplicate_native)
           ;Saved==[] ->
              require(thread_get_message(Self,down(unrelated,probe,killed),[timeout(0)]),missing_unrelated)
           ;throw(bad_store(Saved))),Result=ok),Failure,Result=failed(Failure)),
    thread_send_message(Parent,result(Self,Result)).
bounded(M) :- thread_self(Self),get_time(Now),D is Now+5,
    (thread_get_message(Self,M,[deadline(D)]) -> true;throw(wait_timeout(M))).
require(G,E) :- (call(G) -> true;throw(E)).
