% SPDX-License-Identifier: MIT
:- module(rpc_http_timeout_tests,[run/1,diagnose_expiry/1]).
:- use_module(rpc).
:- use_module(library(http)).

run(Port) :-
    validation, mapping,
    thread_create(http_server(rpc_http_timeout_tests:reply,[port('127.0.0.1':Port)]),Server,[]),
    format(atom(Base),'http://127.0.0.1:~w',[Port]),
    setup_call_cleanup(wait_ready(Base,100),
      transport_checks(Base),
      (atom_concat(Base,'/stop',Stop),get_body(Stop),thread_join(Server,true))),
    writeln('HTTP timeout options: all regressions passed').

:- meta_predicate rejects(0,?,+).
rejects(Goal,Formal,PI) :-
    catch(call(Goal),Error,true),nonvar(Error),
    Error=error(Formal,context(PI,'invalid client option')).
validation :-
    forall(member(Kind,[rpc,promise]),
      (bad_options(Kind,[http_timeout(bad)],type_error(number,bad)),
       bad_options(Kind,[http_timeout(infinite)],type_error(number,infinite)),
       bad_options(Kind,[http_timeout(_)],instantiation_error),
       bad_options(Kind,[http_timeout(1),http_timeout(bad)],type_error(number,bad)),
       bad_options(Kind,[http_timeout(1),timeout(bad)],type_error(number,bad)),
       rpc:validate_client_options(Kind,[http_timeout(-1),http_timeout(0),http_timeout(0.5)]))),
    rejects(yield(42,_,[http_timeout(1)]),domain_error(yield_option,http_timeout(1)),rpc:yield/3).
bad_options(rpc,Options,Formal) :-
    rejects(rpc('http://invalid',true,[src_uri('http://invalid/source')|Options]),Formal,rpc:rpc/3).
bad_options(promise,Options,Formal) :-
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),Before),
    findall(Q,message_queue_property(Q,size(_)),Queues),
    rejects(promise('http://invalid',true,Ref,[src_uri('http://invalid/source')|Options]),Formal,rpc:promise/4),var(Ref),
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),After),Before==After,
    findall(Q,message_queue_property(Q,size(_)),AfterQueues),Queues==AfterQueues.
mapping :-
    rpc:rpc_http_options([timeout(infinite),timeout(6)], [timeout(infinite),timeout(6)]),
    rpc:rpc_http_options([http_timeout(-2)],[timeout(0)]),
    forall(member(Options,[[timeout(0),http_timeout(5),http_timeout(6)],
                           [http_timeout(5),timeout(0),http_timeout(6)]]),
      rpc:rpc_http_options([request_header('X-Test'=value)|Options],
                          [timeout(5),request_header('X-Test'=value)])),
    rpc:rpc_http_options([http_timeout(3),http_timeout(5)],[timeout(3)]).

wait_ready(Base,N) :-
    atom_concat(Base,'/ready',URL),
    (catch(get_body(URL),_,fail) -> true
    ; N>0,sleep(0.01),Next is N-1,wait_ready(Base,Next)).
get_body(URL) :- setup_call_cleanup(http_open(URL,S,[timeout(2)]),getline(S,_),close(S)).
reply(Request) :-
    memberchk(path(Path),Request),
    (Path=="/stop" -> memberchk(port(Port),Request),http_stop_server(Port,[]),Body=ok
    ; Path=="/ready" -> Body=ok
    ; (Path=="/expiry/call" -> sleep(2.2) ; sleep(0.3)),
      (Path=="/sharing/call" -> Body=success([ok-ok],false)
                  ; Body=success([v(ok)],false))),
    format('Content-type: text/plain\r\n\r\n~q.~n',[Body]).
transport_checks(Base) :-
    atom_concat(Base,'/slow',URL),
    rpc(URL,Z=ok,[timeout(1),http_timeout(5)]),Z==ok,
    rpc(URL,W=ok,[http_timeout(5),timeout(1)]),W==ok,
    atom_concat(Base,'/sharing',Sharing),
    promise(Sharing,A=ok,Ref,[template(A-A),http_timeout(5),timeout(1)]),
    yield(Ref,Early,[timeout(0)]),Early==timeout,
    yield(Ref,Waiting,[timeout(0),on_timeout(Waiting=waiting)]),Waiting==waiting,
    yield(Ref,Answer,[timeout(6)]),Answer==success([ok-ok],false),var(A),
    true.

% A separate diagnostic, not a passing conformance assertion: v3.13.10
% stores stream timeout/1 but does not consult it while reading the reply.
diagnose_expiry(Port) :-
    thread_create(http_server(rpc_http_timeout_tests:reply,[port('127.0.0.1':Port)]),Server,[]),
    format(atom(Base),'http://127.0.0.1:~w',[Port]),
    setup_call_cleanup(wait_ready(Base,100),
      expiry_results(Base),
      (atom_concat(Base,'/stop',Stop),get_body(Stop),thread_join(Server,true))).
expiry_results(Base) :-
    atom_concat(Base,'/expiry',URL),
    forall(member(Options,[[http_timeout(1)],[timeout(1)]]),
      (get_time(Start),
       (catch((rpc(URL,X=ok,Options),Outcome=success(X)),E,Outcome=error(E))
        -> true ; Outcome=failure),
       get_time(End),Elapsed is End-Start,
       format('Expiry diagnostic ~q: ~q after ~3f seconds~n',[Options,Outcome,Elapsed]))),
    promise(URL,Y=ok,Ref,[template(Y),http_timeout(1)]),
    yield(Ref,Answer,[timeout(6)]),
    format('Promise expiry diagnostic: ~q~n',[Answer]).
