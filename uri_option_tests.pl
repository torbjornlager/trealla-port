% SPDX-License-Identifier: MIT
:- module(uri_option_tests,[run/0,live/1]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(rpc,[]).
:- use_module(distribution,[]).
:- use_module(source_policy,[]).

text_form(atom,A,A).
text_form(chars,A,C) :- atom_chars(A,C).
text_form(codes,A,C) :- atom_codes(A,C).

run :-
    forall(member(Form,[atom,chars,codes]),
      (text_form(Form,'https://example.org/é?x=%2F',Input),
       source_policy:uri_atom(Input,URI),URI=='https://example.org/é?x=%2F',atom(URI),
       rpc:resolve_rpc_uri(Input,RPC),RPC==URI,
       distribution:node_url_atom(Input,Node),Node==URI)),
    rpc:resolve_rpc_uri(localhost:3053,'http://localhost:3053'),
    forall(member(V,[42,1.5,foo(bar)]),
      (catch(rpc:rpc(V,true,[src_uri('https://invalid.example/source')]),A,true),nonvar(A),A=error(type_error(text,V),_),
       catch(rpc:promise(V,true,R,[src_uri('https://invalid.example/source')]),B,true),nonvar(B),B=error(type_error(text,V),_),var(R))),
    catch(rpc:rpc(Pending,true),E,true),nonvar(E),E=error(instantiation_error,_),var(Pending),
    catch(rpc:promise(host:Port,true,_),F,true),nonvar(F),F=error(instantiation_error,_),var(Port),
    catch(rpc:rpc(host:bad,true),G,true),nonvar(G),G=error(type_error(integer,bad),_),
    self(Self),atom_chars(localhost,Local),
    Self@Local ! uri_local_send,
    receive({uri_local_send -> true},[timeout(1),on_timeout(throw(missing_local_uri_send))]),
    writeln('URI canonicalization, early errors and local routing: passed').

live(URI) :-
    forall(member(Form,[atom,chars,codes]),
      (text_form(Form,URI,Input),
       once(rpc:rpc(Input,X=ok)),X==ok,
       rpc:promise(Input,Y=ok,Ref,[template(pair(Y,Y))]),
       rpc:yield(Ref,success([pair(ok,ok)],false),[timeout(2)]),var(Y))),
    source_policy:parse_http_uri(URI,_,Host,Port,_),
    once(rpc:rpc(Host:Port,Z=ok)),Z==ok,
    writeln('URI text forms and Host:Port live RPC/promise: passed').
