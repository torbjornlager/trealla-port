% Engine-only tests: no Web Prolog dependencies.
:- module(receive_saved_primitive_tests,[run/0,interrupted/1]).
run :-
    thread_self(Self),
    nb_setval(saved,old),
    require(\+ '$thread_get_message_saved'(Self,_,[timeout(0)],saved,'$bb'(wrong)),timeout),
    nb_getval(saved,Old),require(Old==old,timeout_changed_store),
    thread_send_message(Self,untouched),
    catch('$thread_get_message_saved'(Self,_,[],saved,invalid_template),Error,true),
    require(nonvar(Error),invalid_template_accepted),
    thread_get_message(Self,untouched),
    thread_send_message(Self,first),thread_send_message(Self,second),
    '$thread_get_message_saved'(Self,second,[],saved,'$bb'(second)),
    nb_getval(saved,Second),require(Second==second,wrong_selected_value),
    thread_get_message(Self,first),
    thread_send_message(Self,pair(X,X)),
    '$thread_get_message_saved'(Self,M,[],saved,'$bb'([prefix,M])),
    nb_getval(saved,[prefix,pair(A,B)]),require(A==B,sharing_lost),
    M=pair(bound,bound),require(var(A),copy_aliased),
    forall(between(1,1000,_),one(Self)),
    writeln('Saved receive primitive: all regressions passed').
one(Parent) :-
    thread_create(receive_saved_primitive_tests:interrupted(Parent),T,[]),
    bounded(ready(T)),thread_signal(T,throw(stop)),
    bounded(result(T,Result)),thread_join(T,Status),
    require(Status==true,status(Status)),require(Result==ok,interruption(Result)).
interrupted(Parent) :-
    thread_self(Self),nb_setval(saved,[]),
    thread_send_message(Self,down(unrelated,probe,killed)),
    catch((thread_send_message(Parent,ready(Self)),
           '$thread_get_message_saved'(Self,M,[],saved,'$bb'([M])),
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
