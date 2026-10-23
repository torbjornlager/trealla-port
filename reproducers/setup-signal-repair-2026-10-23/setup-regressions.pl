:- module(setup_signal_regressions,[run/0]).
require(G,Name) :- (call(G)->true;throw(assertion_failed(Name))).
mark(K) :- nb_getval(events,Es),append(Es,[K],New),nb_setval(events,New).
reset :- nb_setval(events,[]).
events(E) :- nb_getval(events,Actual),require(Actual==E,events(Actual,E)).
queue(G) :- thread_self(Self),thread_signal(Self,G).
run :-
 reset,setup_call_cleanup(mark(setup),mark(body),mark(cleanup)),events([setup,body,cleanup]),
 reset,\+setup_call_cleanup(fail,mark(body),mark(cleanup)),events([]),
 queue(setup_signal_regressions:mark(after_failure)),true,events([after_failure]),
 reset,catch(setup_call_cleanup(throw(setup_error),mark(body),mark(cleanup)),E,true),require(E==setup_error,setup_error),events([]),
 queue(setup_signal_regressions:mark(after_error)),true,events([after_error]),
 reset,catch(setup_call_cleanup((mark(setup),queue(throw(interrupted))),mark(body),mark(cleanup)),E2,true),require(E2==interrupted,queued_setup),events([setup,cleanup]),
 reset,catch(setup_call_cleanup(true,(mark(body),throw(body_error)),mark(cleanup)),E3,true),require(E3==body_error,body_error),events([body,cleanup]),
 reset,once(setup_call_cleanup(true,member(_,[a,b]),mark(cleanup))),events([cleanup]),
 reset,findall(X,setup_call_cleanup(true,member(X,[a,b]),mark(cleanup)),Xs),require(Xs==[a,b],answers),events([cleanup]),
 reset,catch(setup_call_cleanup(
  (setup_call_cleanup((queue(throw(nested)),mark(inner_setup)),mark(inner_body),mark(inner_cleanup)),mark(outer_setup)),
  mark(outer_body),mark(outer_cleanup)),E4,true),require(E4==nested,nested_error),events([inner_setup,inner_body,inner_cleanup,outer_setup,outer_cleanup]),
 setup_wait_check,
 writeln('setup signal regressions: ok').

setup_wait_check :-
 thread_self(Main),thread_create(setup_signal_regressions:setup_wait_worker(Main),Worker,[]),
 require(thread_get_message(Main,setup_waiting,[timeout(2)]),setup_waiting),
 thread_signal(Worker,throw(wait_interrupted)),
 thread_send_message(Worker,release),
 require(thread_get_message(Main,wait_result(Error,Es),[timeout(2)]),setup_wait_result),
 require(Error==wait_interrupted,setup_wait_error(Error)),
 require(Es==[setup,cleanup],setup_wait_events(Es)),thread_join(Worker,Status),require(Status==true,setup_wait_status(Status)).
setup_wait_worker(Main) :-
 reset,
 catch(setup_call_cleanup(
  (thread_send_message(Main,setup_waiting),thread_get_message(release),mark(setup)),
  mark(body),mark(cleanup)),E,true),
 nb_getval(events,Es),thread_send_message(Main,wait_result(E,Es)).
