% SPDX-License-Identifier: MIT
:- module(uri_option_tests,[run/0,live/1]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(rpc,[]).
:- use_module(distribution,[]).
:- use_module(source_policy,[]).

run :-
    URI='https://example.org/é?x=%2F',
    source_policy:uri_atom(URI,URI),
    rpc:resolve_rpc_uri(URI,URI),distribution:node_url_atom(URI,URI),
    source_policy:uri_atom('https://example.org/','https://example.org/'),
    distribution:node_url_atom('https://example.org/','https://example.org'),
    forall(member(V,[42,1.5,foo(bar),[h,t,t,p],[104,116,116,112],localhost:3053,host:bad]),
      (catch(rpc:rpc(V,true,[src_uri('https://invalid.example/source')]),A,true),nonvar(A),A=error(type_error(atom,V),_),
       catch(rpc:promise(V,true,R,[src_uri('https://invalid.example/source')]),B,true),nonvar(B),B=error(type_error(atom,V),_),var(R))),
    catch(rpc:rpc(Pending,true),E,true),nonvar(E),E=error(instantiation_error,_),var(Pending),
    catch(rpc:promise(host:Port,true,_),F,true),nonvar(F),F=error(type_error(atom,host:Port),_),var(Port),
    forall((member(V,[[h,t,t,p],host:80]),member(Name,[node,src_uri])),
      (Option=..[Name,V],catch(spawn(true,Pid,[Option]),Error,true),
       nonvar(Error),Error=error(type_error(atom,V),_),var(Pid))),
    self(Self),Self@localhost ! uri_local_send,
    receive({uri_local_send -> true},[timeout(1),on_timeout(throw(missing_local_uri_send))]),
    writeln('URI atoms, early errors and local routing: passed').

live(URI) :-
    once(rpc:rpc(URI,X=ok)),X==ok,
    rpc:promise(URI,Y=ok,Ref,[template(pair(Y,Y))]),
    rpc:yield(Ref,success([pair(ok,ok)],false),[timeout(2)]),var(Y),
    writeln('URI atom live RPC/promise: passed').
