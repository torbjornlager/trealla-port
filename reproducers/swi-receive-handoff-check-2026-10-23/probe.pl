:- module(receive_handoff_swi_gated,[run/0,control/0,owner/1,gate/0]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/actors.pl',[]).
:- use_module(library(prolog_wrap)).
run :-
 setup_call_cleanup(
   wrap_predicate(actors:receive_message(_,_,_),handoff_probe,Wrapped,
                  (call(Wrapped),receive_handoff_swi_gated:gate)),
   (thread_self(P),forall(between(1,20,_),trial(P))),
   unwrap_predicate(actors:receive_message/3,handoff_probe)).
trial(P) :-
 thread_create(receive_handoff_swi_gated:owner(P),T,[]),
 bounded(acquired(T)),thread_signal(T,throw('$abort_goal')),
 bounded(result(T,R)),thread_join(T,S),
 (S==true->true;throw(status(S))),writeq(R),nl.
owner(P) :-
 nb_setval(probe_parent,P),thread_self(Self),
 thread_send_message(Self,down(unrelated,probe,killed)),
 catch(actors:receive({never->true}),E,true),
 nb_delete(probe_parent),
 (thread_peek_message(Self,down(unrelated,probe,killed))->Native=present;Native=absent),
 (clause(actors:deferred(down(unrelated,probe,killed)),true,_)->Deferred=present;Deferred=absent),
 catch(((E=='$abort_goal'->true;throw(wrong_exception(E))),
   actors:receive({down(unrelated,probe,killed)->true},
      [timeout(0),on_timeout(throw(missing_unrelated))]),R=ok),
   Failure,R=failed(Failure,Native,Deferred)),
 thread_send_message(P,result(Self,R)).
gate :-
 (nb_current(probe_parent,P)->thread_self(Self),
   thread_send_message(P,acquired(Self)),thread_get_message(Self,continue)
 ;true).
bounded(M) :- thread_self(Self),get_time(Now),D is Now+5,
 (thread_get_message(Self,M,[deadline(D)])->true;throw(wait_timeout(M))).

% Ungated native selective receive. The final assertion still uses our adapter.
control :- thread_self(P),forall(between(1,5000,_),native_trial(P)),
           writeln('Native controls: 5000 passed').
native_trial(P) :-
    thread_create(receive_handoff_swi_gated:native_owner(P),T,[]),
    bounded(ready(T)),thread_signal(T,throw('$abort_goal')),
    bounded(result(T,R)),thread_join(T,true),
    (R==ok->true;throw(native_control_failed(R))).
native_owner(P) :-
    thread_self(Self),thread_send_message(Self,down(unrelated,probe,killed)),
    catch((thread_send_message(P,ready(Self)),thread_get_message(Self,never)),E,true),
    catch(((E=='$abort_goal'->true;throw(wrong_exception(E))),
       actors:receive({down(unrelated,probe,killed)->true},
         [timeout(0),on_timeout(throw(missing_unrelated))]),R=ok),Failure,R=failed(Failure)),
    thread_send_message(P,result(Self,R)).
