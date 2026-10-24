% Test-node observer only. Native sampling thread is not an actor.
:- module(parity_node_probe,[run/1,observe/0,observe_dump/0]).
% The launcher loads distribution from the repository root for both engines.
:- dynamic observation/3.
run(Port) :-
 thread_create(parity_node_probe:observe_dump,_,[]),
 web_prolog:web_prolog_node(Port,[bind_address('127.0.0.1')]).
observe_dump :-
 (catch(observe,E,(get_time(T),assertz(observation(T,probe_error,E)))) -> true
 ;get_time(T),assertz(observation(T,probe_failed,[]))),
 findall(observation(Time,Kind,Rows),observation(Time,Kind,Rows),History),
 writeq(history(History)),nl,flush_output.
observe :- get_time(Now),Deadline is Now+3,observe_(Deadline,initial).
observe_(Deadline,Previous) :-
 snapshot(Rows),get_time(Time),
 (Rows==Previous -> true;assertz(observation(Time,change,Rows)),writeq(sample(Time,Rows)),nl,flush_output),
 (Time>=Deadline -> assertz(observation(Time,finished,Rows))
 ;sleep(0.002),observe_(Deadline,Rows)).
snapshot(Rows) :-
 (mutex_trylock('$actor_registry') ->
  setup_call_cleanup(true,
   findall(actor(Pid,Namespace,Public,Thread,Reason),
    (actors:actor_alive(Pid),
     (actors:actor_namespace(Pid,Namespace)->true;Namespace=none),
     (actors:actor_public_namespace(Pid,Public)->true;Public=internal),
     (actors:pid_thread(Pid,Thread)->true;Thread=not_started),
     (actors:exit_reason(Pid,Reason)->true;Reason=not_exiting)),Base),
   mutex_unlock('$actor_registry')),
  statuses(Base,Rows)
 ;Rows=registry_busy).
statuses([],[]).
statuses([actor(P,N,V,T,R)|Rest],[actor(P,N,V,T,S,R)|Rows]) :-
 (catch(thread_property(T,status(S)),_,fail)->true;S=gone),statuses(Rest,Rows).
