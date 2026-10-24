% SPDX-License-Identifier: MIT
% Public receive semantics on the upstream sig_atomic path. No engine patch.
:- module(receive_atomic_tests,[run/0,handler_owner/1,refresh_deferred/1,idle_owner/2]).
:- use_module(actors).

run :-
    require(predicate_property(sig_atomic(_),defined),public_sig_atomic_missing),
    short_deadlines,
    timeout_with_nonmatches,
    returning_handler,
    idle_interruption(signal),
    idle_interruption(time_limit),
    writeln('Signal-atomic receive: all regressions passed').

short_deadlines :-
    forall(member(Mode,[poll,relative,absolute,long_relative,long_absolute,past]),one_deadline(Mode)).
one_deadline(Mode) :-
    get_time(Start),
    (Mode==poll -> Options=[timeout(0)]
    ;Mode==relative -> Options=[timeout(0.03)]
    ;Mode==absolute -> D is Start+0.03,Options=[deadline(D)]
    ;Mode==long_relative -> Options=[timeout(0.23)]
    ;Mode==long_absolute -> D is Start+0.23,Options=[deadline(D)]
    ;D is Start-1,Options=[deadline(D)]),
    nb_setval(atomic_timeout_count,0),
    append(Options,[on_timeout(receive_atomic_tests:timeout_mark)],All),
    receive({never -> throw(unexpected_answer)},All),
    get_time(End),Elapsed is End-Start,
    require(Elapsed<0.5,deadline_extended(Mode,Elapsed)),
    (member(Mode,[relative,absolute]) -> require(Elapsed>=0.02,deadline_early(Mode,Elapsed));true),
    (member(Mode,[long_relative,long_absolute]) -> require(Elapsed>=0.2,deadline_early(Mode,Elapsed));true),
    nb_getval(atomic_timeout_count,N),require(N==1,callback_count(Mode,N)).
timeout_mark :- nb_getval(atomic_timeout_count,N),Next is N+1,nb_setval(atomic_timeout_count,Next).

timeout_with_nonmatches :-
    thread_self(Self),
    thread_send_message(Self,first),thread_send_message(Self,second),thread_send_message(Self,third),
    nb_setval(atomic_timeout_count,0),
    get_time(Start),D is Start+0.03,
    receive({never -> throw(unexpected_answer)},[deadline(D),on_timeout(receive_atomic_tests:timeout_mark)]),
    get_time(End),Elapsed is End-Start,
    require(Elapsed<0.5,nonmatches_extended_deadline(Elapsed)),
    nb_getval(atomic_timeout_count,1),
    receive({A -> true},[timeout(0),on_timeout(throw(missing_first))]),
    receive({B -> true},[timeout(0),on_timeout(throw(missing_second))]),
    receive({C -> true},[timeout(0),on_timeout(throw(missing_third))]),
    require([A,B,C]==[first,second,third],order_changed(A,B,C)).

returning_handler :-
    thread_self(Parent),
    setup_call_cleanup(thread_create(receive_atomic_tests:handler_owner(Parent),T,[]),
        ( bounded(handler_ready(T)),sleep(0.03),
          thread_signal(T,receive_atomic_tests:refresh_deferred(Parent)),
          bounded(handler_done(T)),thread_send_message(T,target),
          bounded(handler_result(T,Result)),thread_join(T,Status),
          require(Status==true,handler_status(Status)),
          require(Result==ok,handler_result(Result))
        ),stop_join(T)).
handler_owner(Parent) :-
    thread_self(Self),
    catch((thread_send_message(Self,old),
           receive({never -> true},[timeout(0)]),
           thread_send_message(Parent,handler_ready(Self)),
           receive({target -> true}),
           receive({handler_message -> true},[timeout(0),on_timeout(throw(handler_message_lost))]),
           receive({old -> throw(stale_message_restored)},[timeout(0)]),
           receive({handler_message -> throw(duplicate_handler_message)},[timeout(0)]),
           Result=ok),Error,Result=failed(Error)),
    thread_send_message(Parent,handler_result(Self,Result)).
refresh_deferred(Parent) :-
    thread_self(Self),
    receive({old -> true},[timeout(0),on_timeout(throw(missing_old))]),
    thread_send_message(Self,handler_message),
    receive({never -> true},[timeout(0)]),
    thread_send_message(Parent,handler_done(Self)).

idle_interruption(Mode) :-
    thread_self(Parent),
    setup_call_cleanup(thread_create(receive_atomic_tests:idle_owner(Parent,Mode),T,[]),
        ( bounded(idle_ready(T)),sleep(0.03),get_time(Start),
          (Mode==signal -> thread_signal(T,throw('$abort_goal'));true),
          bounded(idle_result(T,Error)),get_time(End),Elapsed is End-Start,
          require(Elapsed<0.6,idle_not_interruptible(Mode,Elapsed)),
          (Mode==signal -> require(Error=='$abort_goal',wrong_signal(Error))
          ;require(is_time_limit(Error),wrong_time_limit(Error))),
          thread_join(T,Status),require(Status==true,idle_status(Status))
        ),stop_join(T)).
idle_owner(Parent,Mode) :-
    thread_self(Self),
    catch((thread_send_message(Parent,idle_ready(Self)),
           (Mode==signal -> receive({never -> true})
           ;call_with_time_limit(0.03,receive({never -> true})))),Error,true),
    thread_send_message(Parent,idle_result(Self,Error)).
is_time_limit(time_limit_exceeded).
is_time_limit(error(time_limit_exceeded(_,_),_)).

stop_join(T) :- catch(thread_cancel(T),_,true),catch(thread_join(T,_),_,true).
bounded(M) :- thread_self(Self),get_time(Now),D is Now+2,
    (thread_get_message(Self,M,[deadline(D)]) -> true;throw(wait_timeout(M))).
require(G,E) :- (call(G)->true;throw(E)).
