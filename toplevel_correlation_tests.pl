% SPDX-License-Identifier: MIT
:- use_module(toplevel_actors).
:- use_module(web_prolog).

toplevel_correlation_tests :-
    toplevel_spawn(P,[session(true)]),
    setup_call_cleanup(true, correlated_session(P), toplevel_halt(P,true)),
    web_prolog:answer_event_json('$toplevel_reply'(ref(7,'$VAR'(1)),success(9,[pair(X,X)],false)),false,JSON),
    web_prolog:json_text_field(JSON,toplevel_correlation,RT),
    read_term_from_atom(RT,ref(7,'$VAR'(1)),[]),
    web_prolog:json_text_field(JSON,term,Text),
    read_term_from_atom(Text,[pair(A,B)],[]),var(A),A==B,
    web_prolog:event_json(actor_message(12,'$toplevel_reply'(ref(7),success(9,[pair(Y,Y),'$VAR'(1)],false))),Browser),
    web_prolog:json_text_field(Browser,message,BT),
    read_term_from_atom(BT,'$toplevel_reply'(ref(7),success(9,[pair(C,D),Literal],false)),[]),
    var(C),C==D,Literal=='$VAR'(1),
    functor(Target,target,1),arg(1,Target,old),functor(Count,count,1),arg(1,Count,1),
    toplevel_actors:apply_next([target(endpoint(main))],Count,Target),
    toplevel_actors:answer_target(Target,endpoint(main)),
    toplevel_actors:apply_next([target(endpoint(worker))],Count,Target),
    toplevel_actors:answer_target(Target,endpoint(worker)),
    web_prolog:json_atom(Native,'{}'),
    Message='$call'(true,[target(1234567890@'http://localhost'),'$request_ref'(1)]),
    web_prolog:correlated_return_target(Native,relay,Message,'$call'(true,NativeOptions)),
    memberchk(target(relay),NativeOptions),
    web_prolog:correlated_return_target(Native,relay,
        '$next'([target(1234567890@'http://127.0.0.1:49999'),'$request_ref'(2)]),
        '$next'([target(relay),'$request_ref'(2)])),
    web_prolog:correlated_return_target(Native,relay,'$next'([]),'$next'([])),
    web_prolog:correlated_return_target(Native,relay,Unbound,Same),var(Unbound),Unbound==Same,
    web_prolog:correlated_return_target(Native,relay,'$call'(true,[Option]),Unchanged),
    var(Option), Unchanged == '$call'(true,[Option]),
    writeln('Toplevel correlation vectors: ok').

correlated_session(P) :-
    toplevel_call(P,member(X,[a,b,c]),[template(X),limit(1),'$request_ref'(101)]),
    receive({'$toplevel_reply'(101,success(P,[a],true))->true},[timeout(2),on_timeout(fail)]),
    toplevel_next(P,['$request_ref'(202)]),
    receive({'$toplevel_reply'(202,success(P,[b],true))->true},[timeout(2),on_timeout(fail)]),
    toplevel_next(P),
    receive({success(P,[c],false)->true},[timeout(2),on_timeout(fail)]),
    toplevel_call(P,fail,['$request_ref'(303)]),
    receive({'$toplevel_reply'(303,failure(P))->true},[timeout(2),on_timeout(fail)]),
    toplevel_call(P,throw(probe),['$request_ref'(404)]),
    receive({'$toplevel_reply'(404,error(P,probe))->true},[timeout(2),on_timeout(fail)]),
    toplevel_call(P,true,[template(ok)]),
    receive({success(P,[ok],false)->true},[timeout(2),on_timeout(fail)]).
