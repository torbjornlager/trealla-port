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
    forall(member(URI-Canonical,[
      'https://node.test/'-'https://node.test',
      'http://node.test:8080/'-'http://node.test:8080',
      'https://node.test/path/'-'https://node.test/path/',
      'https://node.test/?x=1'-'https://node.test/?x=1',
      'https://node.test/#part'-'https://node.test/#part']),
      forall(member(Form,[atom,chars,codes]),
        (text_form(Form,URI,Input),distribution:node_url_atom(Input,Canonical)))),
    forall(member(Form,[atom,chars,codes]),
      (text_form(Form,'https://example.org/é?x=%2F',Input),
       source_policy:uri_atom(Input,URI),URI=='https://example.org/é?x=%2F',atom(URI),
       rpc:resolve_rpc_uri(Input,RPC),RPC==URI,
       distribution:node_url_atom(Input,Node),Node==URI)),
    % Host:Port is not a URI.
    catch(rpc:resolve_rpc_uri(localhost:3053,_),H,true),nonvar(H),H=error(type_error(atom_or_string,localhost:3053),_),
    forall(member(V,[42,1.5,foo(bar)]),
      (catch(rpc:rpc(V,true,[src_uri('https://invalid.example/source')]),A,true),nonvar(A),A=error(type_error(atom_or_string,V),_),
       catch(rpc:promise(V,true,R,[src_uri('https://invalid.example/source')]),B,true),nonvar(B),B=error(type_error(atom_or_string,V),_),var(R))),
    catch(rpc:rpc(Pending,true),E,true),nonvar(E),E=error(instantiation_error,_),var(Pending),
    catch(rpc:promise(host:Port,true,_),F,true),nonvar(F),F=error(type_error(atom_or_string,host:Port),_),var(Port),
    catch(rpc:rpc(host:bad,true),G,true),nonvar(G),G=error(type_error(atom_or_string,host:bad),_),
    self(Self),atom_chars(localhost,Local),
    Self@Local ! uri_local_send,
    receive({uri_local_send -> true},[timeout(1),on_timeout(throw(missing_local_uri_send))]),
    % An address must name its node; sending never binds a pending node.
    catch(send(9999999999@PendingNode,probe),PE,true),nonvar(PE),PE=error(instantiation_error,_),var(PendingNode),
    % Monitoring resolves Id@localhost to the local actor, as sending does.
    spawn(receive({stop -> true}),Child),
    monitor(Child@localhost,Ref),Child ! stop,
    receive({down(_,Ref,true) -> true},[timeout(2),on_timeout(throw(missing_local_uri_down))]),
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
