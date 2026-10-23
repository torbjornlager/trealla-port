% SPDX-License-Identifier: MIT
:- module(receive_handoff_tests,[run/0,semantics/0,interrupted_owner/2]).
:- use_module(actors).

run :-
    semantics,
    thread_self(Parent),
    forall(member(Mode,[blocking,poll,timed,deadline]),
           forall(between(1,250,_),interrupted_receive(Parent,Mode))),
    writeln('Receive handoff: all regressions passed').

semantics :-
    forall(member(Options,[[],[timeout(0)],[timeout(1)],deadline]),
           receive_semantics(Options)).

receive_semantics(Options0) :-
    (Options0==deadline -> get_time(Now),D is Now+1,Options=[deadline(D)]
    ;Options=Options0),
    thread_self(Self),
    nb_setval('$actor_deferred',[]),
    thread_send_message(Self,down(unrelated,probe,killed)),
    thread_send_message(Self,target(value)),
    thread_send_message(Self,tail),
    catch(receive({target(X) if throw('$abort_goal') -> true},Options),E,true),
    require(E=='$abort_goal',guard_exception(Options,E)),
    require(var(X),guard_binding_escaped),
    receive({down(unrelated,probe,killed) -> true},[timeout(0),on_timeout(throw(missing_unrelated))]),
    receive({target(Y) -> true},[timeout(0),on_timeout(throw(missing_target))]),
    require(Y==value,target_binding(Y)),
    receive({tail -> true},[timeout(0),on_timeout(throw(missing_tail))]),
    thread_send_message(Self,body),
    catch(receive({body -> throw(body_error)},Options),BodyError,true),
    require(BodyError==body_error,body_exception(BodyError)),
    receive({body -> throw(duplicate_body)},[timeout(0)]),
    receive({target(_) -> throw(duplicate_target)},[timeout(0)]),
    thread_send_message(Self,failed_body),
    require(\+receive({failed_body -> fail},Options),body_failure_changed),
    receive({failed_body -> throw(duplicate_failed_body)},[timeout(0)]),
    thread_send_message(Self,guarded(value)),thread_send_message(Self,after_guard),
    receive({guarded(Z) if throw(user_guard_error) -> throw(guard_should_reject);
             after_guard -> true},[timeout(0),on_timeout(throw(missing_after_guard))]),
    require(var(Z),rejected_guard_binding_escaped),
    receive({guarded(G) -> true},[timeout(0),on_timeout(throw(missing_rejected_message))]),
    require(G==value,rejected_message_changed),
    actors:deferred_list(Left),require(Left==[],leftover(Left)),
    require(\+thread_peek_message(Self,_),native_leftover).

interrupted_receive(Parent,Mode) :-
    thread_create(receive_handoff_tests:interrupted_owner(Parent,Mode),T,[]),
    bounded_message(ready(T)),
    thread_signal(T,throw('$abort_goal')),
    bounded_message(result(T,Result)),
    thread_join(T,Status),
    require(Status==true,thread_status(Status)),
    require(Result==ok,interrupted_receive(Result)).

interrupted_owner(Parent,Mode) :-
    thread_self(Self),
    thread_send_message(Self,down(unrelated,probe,killed)),
    catch((thread_send_message(Parent,ready(Self)),wait_interruption(Mode)),Error,true),
    catch((require(Error=='$abort_goal',interruption(Error)),
           receive({down(unrelated,probe,killed) -> true},
                   [timeout(0),on_timeout(throw(missing_unrelated))]),
           receive({down(unrelated,probe,killed) -> throw(duplicate_unrelated)},[timeout(0)]),
           Result=ok),Failure,Result=failed(Failure)),
    thread_send_message(Parent,result(Self,Result)).

bounded_message(Message) :-
    thread_self(Self),get_time(Now),Deadline is Now+5,
    (thread_get_message(Self,Message,[deadline(Deadline)]) -> true
    ;throw(wait_timeout(Message))).
require(Goal,Error) :- (call(Goal) -> true;throw(Error)).

wait_interruption(blocking) :- receive({never -> true}).
wait_interruption(poll) :- repeat,receive({never -> true},[timeout(0)]),fail.
wait_interruption(timed) :- receive({never -> true},[timeout(5)]).
wait_interruption(deadline) :- get_time(Now),D is Now+5,receive({never -> true},[deadline(D)]).
