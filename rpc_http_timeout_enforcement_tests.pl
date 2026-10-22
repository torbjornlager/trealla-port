% SPDX-License-Identifier: MIT
% The full group requires an engine enforcing stream read timeouts and the
% Python loopback fixture. The parse_error case also covers pinned v3.13.10.
% Run in the trusted standalone user context, like rpc_lifecycle_tests.pl.
:- use_module(rpc).

rpc_http_timeout_enforcement_tests(Base) :-
    url(Base,fast,Fast),rpc(Fast,X=ok),X==ok,
    forall((member(Path,[headers,body,partial]),
            member(Options,[[http_timeout(0.2)],[timeout(0.2)]])),
           rpc_timeout(Base,Path,Options)),
    rpc_timeout(Base,headers,[timeout(5),http_timeout(0.2)]),
    rpc_timeout(Base,headers,[http_timeout(0.2),timeout(5)]),
    url(Base,brief,Brief),
    rpc(Brief,Y=ok,[timeout(0.001),http_timeout(2)]),Y==ok,
    rpc(Brief,Z=ok,[timeout(infinite)]),Z==ok,
    forall(member(Path,[headers,body,partial]),promise_timeout(Base,Path)),
    retry_success(Brief),
    parse_error(Base),
    writeln('HTTP read-timeout enforcement, retry/callbacks and resource cleanup: passed').

rpc_http_timeout_enforcement_case(Name,Base) :-
    url(Base,fast,Fast),rpc(Fast,X=ok),X==ok,
    enforcement_case(Name,Base),
    format('HTTP timeout case ~w: passed~n',[Name]).
enforcement_case(promise_headers,Base) :- promise_timeout(Base,headers).
enforcement_case(promise_body,Base) :- promise_timeout(Base,body).
enforcement_case(promise_partial,Base) :- promise_timeout(Base,partial).
enforcement_case(retry_success,Base) :- url(Base,brief,URL),retry_success(URL).
enforcement_case(parse_error,Base) :- parse_error(Base).

parse_error(Base) :-
    url(Base,invalid,URL),streams(Before),
    promise(URL,X=ok,Ref,[template(X)]),resources(Ref,Resources),
    setup_call_cleanup(true,
      (yield(Ref,Answer,[timeout(3)]),
       enforcement_check(parse_answer(Answer),Answer=error(error(syntax_error(_),_))),
       var(X),enforcement_check(parse_disposed,disposed(Ref,Resources)),
       streams(After),enforcement_check(parse_streams(Before,After),Before==After)),
      promise_cleanup(Ref)),
    url(Base,fast,Fast),rpc(Fast,Y=ok),Y==ok,
    writeln('malformed reply: error answer; resources reclaimed; following request succeeds').

url(Base,Path,URL) :- format(atom(URL),'~w/~w',[Base,Path]).
streams(N) :- findall(S,stream_property(S,mode(_)),Ss),length(Ss,N).
timely(Start) :- get_time(End),Elapsed is End-Start,Elapsed<1.0.

rpc_timeout(Base,Path,Options) :-
    url(Base,Path,URL),streams(Before),get_time(Start),
    catch(rpc(URL,_=ok,Options),Error,true),
    nonvar(Error),Error=error(timeout_error(read,_),_),timely(Start),
    streams(Before),
    url(Base,fast,Fast),rpc(Fast,X=ok),X==ok,
    format('rpc ~w ~q: timeout; stream reclaimed; next request succeeds~n',[Path,Options]).

promise_timeout(Base,Path) :-
    url(Base,Path,URL),streams(Before),get_time(Start),
    promise(URL,X=ok,Ref,[template(X),http_timeout(0.2)]),resources(Ref,Resources),
    setup_call_cleanup(true,
      (yield(Ref,Early,[timeout(0),on_timeout(Early=waiting)]),
       enforcement_check(early(Path,Early),Early==waiting),
       yield(Ref,Answer,[timeout(3)]),
       enforcement_check(answer(Path,Answer),Answer=error(error(timeout_error(read,_),_))),
       enforcement_check(elapsed(Path),timely(Start)),var(X),
       enforcement_check(disposed(Path,Resources),disposed(Ref,Resources)),
       streams(After),enforcement_check(streams(Path,Before,After),Before==After)),
      promise_cleanup(Ref)),
    format('promise ~w: callback then error answer; queue, worker, timer and stream reclaimed~n',[Path]).

:- meta_predicate enforcement_check(+,0).
enforcement_check(Stage,Goal) :-
    (call(Goal) -> true ; throw(error(timeout_enforcement_check_failed(Stage),rpc_http_timeout_enforcement_tests/1))).

retry_success(URL) :-
    streams(Before),promise(URL,X=ok,Ref,[template(X-X),http_timeout(2)]),
    resources(Ref,Resources),
    setup_call_cleanup(true,
      (yield(Ref,Early,[timeout(0)]),Early==timeout,
       yield(Ref,Waiting,[timeout(0),on_timeout(Waiting=waiting)]),Waiting==waiting,
       yield(Ref,Answer,[timeout(3)]),Answer==success([ok-ok],false),var(X),
       disposed(Ref,Resources),streams(Before)),
      promise_cleanup(Ref)),
    writeln('short local waits preserve retry; final success reclaims resources: ok').

resources(Ref,resources(Q,W,T)) :-
    rpc:promise_transaction(rpc:promise_state(Ref,Q,W,T,_,_,_)).
disposed(Ref,resources(Q,W,T)) :-
    \+ rpc:promise_state(Ref,_,_,_,_,_,_),
    \+ catch(message_queue_property(Q,size(_)),_,fail),
    await_thread_gone(W,200),await_thread_gone(T,200).
await_thread_gone(none,_) :- !.
await_thread_gone(T,N) :-
    (\+catch(thread_property(T,status(_)),_,fail) -> true
    ; N>0,sleep(0.005),Next is N-1,await_thread_gone(T,Next)).
