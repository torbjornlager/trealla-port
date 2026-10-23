:- module(mutex_retention_probe,[run/0]).
run :- mutex_create(_,[alias(probe_lock)]), thread_self(Main), mutex_lock(probe_lock),
 thread_create(mutex_retention_probe:worker(Main),Worker,[]),
 thread_get_message(Main,ready,[timeout(2)]),
 sleep(0.01),
 thread_signal(Worker,throw(interrupted)),
 mutex_unlock(probe_lock),
 (thread_get_message(Main,caught(Error,Status),[timeout(2)]) ->
   writeq(result(Worker,Error,Status)),nl,flush_output,
   (Status==unlocked -> thread_join(Worker,_),halt;halt(1))
 ; mutex_property(probe_lock,status(Status)),writeq(missing(Worker,Status)),nl,flush_output,halt(2)).
worker(Main) :-
 catch((thread_send_message(Main,ready),with_mutex(probe_lock,true)),E,Error=E),
 mutex_property(probe_lock,status(Status)),
 thread_send_message(Main,caught(Error,Status)).
