:- module(mutex_retention_controls,[run/1]).
run(Mode) :-
 mutex_create(_,[alias(probe_lock)]),thread_self(Main),
 (Mode==body -> true;mutex_lock(probe_lock)),
 thread_create(mutex_retention_controls:worker(Main,Mode),Worker,[]),
 thread_get_message(Main,ready,[timeout(2)]),
 (Mode==body -> thread_get_message(Main,body_entered,[timeout(2)]);sleep(0.01)),
 (Mode==normal -> true;thread_signal(Worker,throw(interrupted))),
 (Mode==body -> true;mutex_unlock(probe_lock)),
 (thread_get_message(Main,result(Error,Status),[timeout(2)]) ->
  drain(Main,Events),writeq(control(Mode,Worker,Error,Status,Events)),nl,flush_output,
  (expected(Mode,Worker,Error,Status,Events)->thread_join(Worker,_),halt;halt(1))
 ;writeln(missing_result),halt(2)).
worker(Main,Mode) :-
 catch((thread_send_message(Main,ready),
  setup_call_cleanup(
   (mutex_lock(probe_lock),thread_send_message(Main,setup_acquired)),
   (thread_send_message(Main,body_entered),(Mode==body -> thread_get_message(release);true)),
   (thread_send_message(Main,cleanup_entered),mutex_unlock(probe_lock))),Error=normal),E,Error=E),
 mutex_property(probe_lock,status(Status)),thread_send_message(Main,result(Error,Status)).
drain(Main,[E|Es]) :- thread_get_message(Main,E,[timeout(0)]),!,drain(Main,Es).
drain(_,[]).
expected(blocked,_,interrupted,unlocked,[setup_acquired,cleanup_entered]).
expected(normal,_,normal,unlocked,[setup_acquired,body_entered,cleanup_entered]).
% body_entered has already been consumed by the main thread.
expected(body,_,interrupted,unlocked,[setup_acquired,cleanup_entered]).
