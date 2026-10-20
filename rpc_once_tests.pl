% SPDX-License-Identifier: MIT
:- module(rpc_once_tests,[run/1,live/1,promise_live/1]).
:- use_module(rpc).
:- use_module(library(http)).
:- dynamic request/2, delayed_gate/1.

run(Port) :-
    thread_create(http_server(rpc_once_tests:reply,[port('127.0.0.1':Port)]),Server,[]),
    format(atom(Base),'http://127.0.0.1:~w',[Port]),
    setup_call_cleanup(wait_ready(Base,100),
      (checks(Base),promise_checks(Base)),
      (atom_concat(Base,'/stop',Stop),get_body(Stop),thread_join(Server,true))),
    writeln('RPC once: all regressions passed').

wait_ready(Base,N) :-
    atom_concat(Base,'/ready',URL),
    (catch(get_body(URL),_,fail) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_ready(Base,Next)).
get_body(URL) :-
    setup_call_cleanup(http_open(URL,S,[timeout(2)]),getline(S,_),close(S)).

% This peer deliberately ignores once=true and advertises More=true, so the
% client must enforce the first-slice boundary itself. Every request is logged.
reply(Request) :-
    memberchk(path(Path),Request),
    (Path=="/stop" -> memberchk(port(Port),Request),http_stop_server(Port,[]),Body=ok
    ; Path=="/ready" -> Body=ok
    ; memberchk(search(Search),Request),
      memberchk(offset=OffsetChars,Search),number_chars(Offset,OffsetChars),
      memberchk(once=OnceChars,Search),atom_chars(Once,OnceChars),
      assertz(request(Offset,Once)),
      response(Path,Offset,Body)),
    format('Content-type: text/plain\r\n\r\n~q.~n',[Body]).

response("/pages/call",0,success([v(a),v(b)],true)).
response("/pages/call",2,success([v(c)],false)).
response("/sharing/call",0,success([v(pair(A,A),A),v(pair(B,B),B)],true)).
response("/failure/call",0,failure).
response("/error/call",0,error(test_rpc_once_error)).
response("/delayed/call",0,success([ready],true)) :-
    delayed_gate(Queue),thread_get_message(Queue,release).

checks(Base) :-
    atom_concat(Base,'/pages',Pages),
    page_check(Pages,[once(true)],[a,b],[0-true]),
    page_check(Pages,[once(false)],[a,b,c],[0-false,2-false]),
    page_check(Pages,[],[a,b,c],[0-false,2-false]),
    page_check(Pages,[once(true),once(false)],[a,b],[0-true]),
    page_check(Pages,[once(false),once(true)],[a,b,c],[0-false,2-false]),
    writeln('whole first slice, request count, default and duplicate precedence: ok'),
    retractall(request(_,_)),
    catch(rpc(Pages,true,[src_uri('http://invalid/source'),once(true),once(bad)]),Error,true),
    nonvar(Error),Error=error(type_error(boolean,bad),context(rpc:rpc/3,'invalid client option')),
    requests([]),
    atom_concat(Base,'/sharing',Sharing),
    findall(X-V,(rpc(Sharing,X=pair(V,V),[limit(2),once(true)]),
                 X=pair(L,R),L==R,L==V,var(V)),Rows),
    Rows=[pair(A,A)-A,pair(B,B)-B],var(A),var(B),requests([0-true]),
    writeln('validation precedes I/O; non-ground answer sharing is preserved: ok'),
    retractall(request(_,_)),atom_concat(Base,'/failure',Failure),
    \+rpc(Failure,true,[once(true)]),requests([0-true]),
    retractall(request(_,_)),atom_concat(Base,'/error',ErrorURL),
    catch(rpc(ErrorURL,true,[once(true)]),Thrown,true),
    Thrown==test_rpc_once_error,requests([0-true]),
    writeln('failure and error delivery: ok').

page_check(URL,Options,Expected,Requests) :-
    retractall(request(_,_)),
    findall(X,rpc(URL,member(X,[a,b,c]),[limit(2)|Options]),Rows),
    Rows==Expected,requests(Requests).
requests(Expected) :- findall(Offset-Once,request(Offset,Once),Actual),Actual==Expected.

promise_answer(URL,Goal,Options,Answer) :-
    setup_call_cleanup(promise(URL,Goal,Ref,Options),
      yield(Ref,Answer,[timeout(3)]),promise_cleanup(Ref)).

promise_checks(Base) :-
    atom_concat(Base,'/pages',Pages),
    promise_page(Pages,[once(true)],true),
    promise_page(Pages,[once(false)],false),
    promise_page(Pages,[],false),
    promise_page(Pages,[once(true),once(false)],true),
    promise_page(Pages,[once(false),once(true)],false),
    % The fixture reports More=true even for once=true. Preserve its answer.
    writeln('promise forwards once/default/first duplicate, fetches one page and preserves peer More: ok'),
    retractall(request(_,_)),
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),Before),
    findall(Q,message_queue_property(Q,size(_)),Queues),
    catch(promise(Pages,true,Ref,[src_uri('http://invalid/source'),once(true),once(bad)]),Error,true),
    nonvar(Error),Error=error(type_error(boolean,bad),context(rpc:promise/4,'invalid client option')),
    var(Ref),requests([]),
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),Before),
    findall(Q,message_queue_property(Q,size(_)),Queues),
    atom_concat(Base,'/sharing',Sharing),
    promise_answer(Sharing,X=pair(V,V),[template(v(X,V)),once(true)],Answer),
    Answer=success([v(pair(A,A),A),v(pair(B,B),B)],true),
    var(A),var(B),var(X),var(V),requests([0-true]),
    retractall(request(_,_)),
    promise_answer(Pages,member(Y,[a,b,c]),[template(v(Y)),offset(2),once(true)],
                   success([v(c)],false)),var(Y),requests([2-true]),
    retractall(request(_,_)),atom_concat(Base,'/failure',Failure),
    promise_answer(Failure,true,[once(true)],failure),requests([0-true]),
    retractall(request(_,_)),atom_concat(Base,'/error',ErrorURL),
    promise_answer(ErrorURL,true,[once(true)],error(test_rpc_once_error)),requests([0-true]),
    writeln('promise validation precedes source/resources; sharing, offset, failure/error remain intact: ok'),
    promise_retry(Base).

promise_page(URL,Options,Once) :-
    retractall(request(_,_)),
    promise_answer(URL,member(X,[a,b,c]),[template(v(X)),limit(2)|Options],
                   success([v(a),v(b)],true)),
    var(X),requests([0-Once]).

% An explicit gate guarantees the HTTP reply cannot be ready during either
% zero-time wait; no sleep-based assumption about worker scheduling is needed.
promise_retry(Base) :-
    retractall(request(_,_)),atom_concat(Base,'/delayed',URL),
    setup_call_cleanup((message_queue_create(Q),assertz(delayed_gate(Q))),
      setup_call_cleanup(promise(URL,true,Ref,[once(true)]),
        (yield(Ref,Early,[timeout(0)]),Early==timeout,
         yield(Ref,Waiting,[timeout(0),on_timeout(Waiting=waiting)]),Waiting==waiting,
         thread_send_message(Q,release),
         yield(Ref,Answer,[timeout(3)]),Answer==success([ready],true),
         requests([0-true])),
        promise_cleanup(Ref)),
      (retractall(delayed_gate(_)),message_queue_destroy(Q))),
    writeln('promise timeout/default callback and retry preserve the single request and original answer: ok').

% Run unchanged against real SWI and Trealla destinations from a fresh client.
live(URL) :-
    findall(X,rpc(URL,member(X,[a,b,c,d,e]),[limit(2),once(true)]),[a,b]),
    findall(X,rpc(URL,member(X,[a,b,c,d,e]),[limit(2),once(false)]),[a,b,c,d,e]),
    findall(X,rpc(URL,member(X,[a,b,c,d,e]),[limit(2)]),[a,b,c,d,e]),
    findall(X,rpc(URL,member(X,[a,b,c,d,e]),[limit(2),once(true),once(false)]),[a,b]),
    findall(X,rpc(URL,member(X,[a,b,c,d,e]),[limit(2),once(false),once(true)]),[a,b,c,d,e]),
    findall(X-V,rpc(URL,(member(X,[pair(V,V),pair(V,V),other])),
                     [limit(2),once(true)]),Rows),
    Rows=[pair(A,A)-A,pair(B,B)-B],var(A),var(B),
    \+rpc(URL,fail,[once(true)]),
    catch(rpc(URL,throw(test_rpc_once_error),[once(true)]),Error,true),
    Error==test_rpc_once_error,
    promise_live(URL),
    format('RPC once live checks on ~w: passed~n',[URL]).

promise_live(URL) :-
    promise_true_vectors([[once(true)],[once(true),once(false)]],URL),
    promise_false_vectors([[],[once(false)],[once(false),once(true)]],URL),
    promise_answer(URL,member(X,[a,b,c,d,e]),[template(X),offset(2),limit(2),once(true)],
                   success([c,d],false)),var(X),
    promise_answer(URL,member(P,[pair(V,V),pair(V,V),other]),
                   [template(P-V),limit(2),once(true)],Shared),
    Shared=success([pair(A,A)-A,pair(B,B)-B],false),var(A),var(B),var(P),var(V),
    promise_answer(URL,fail,[once(true)],failure),
    promise_answer(URL,throw(promise_once_error),[once(true)],error(promise_once_error)),
    format('Promise once live forwarding, full slices, offset, sharing and failure/error on ~w: passed~n',[URL]).
promise_true_vectors([],_).
promise_true_vectors([Options|Rest],URL) :-
    promise_answer(URL,member(X,[a,b,c,d,e]),[template(X),limit(2)|Options],
                   success([a,b],false)),var(X),promise_true_vectors(Rest,URL).
promise_false_vectors([],_).
promise_false_vectors([Options|Rest],URL) :-
    promise_answer(URL,member(X,[a,b,c,d,e]),[template(X),limit(2)|Options],
                   success([a,b],true)),var(X),
    promise_answer(URL,member(Y,[a,b,c,d,e]),[template(Y),offset(2),limit(3)|Options],
                   success([c,d,e],false)),var(Y),promise_false_vectors(Rest,URL).
