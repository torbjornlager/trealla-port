% SPDX-License-Identifier: MIT
:- module(rpc_once_tests,[run/1,live/1]).
:- use_module(rpc).
:- use_module(library(http)).
:- dynamic request/2.

run(Port) :-
    thread_create(http_server(rpc_once_tests:reply,[port('127.0.0.1':Port)]),Server,[]),
    format(atom(Base),'http://127.0.0.1:~w',[Port]),
    setup_call_cleanup(wait_ready(Base,100),
      checks(Base),
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
    format('RPC once live checks on ~w: passed~n',[URL]).
