% SPDX-License-Identifier: MIT
:- module(remote_portability_tests, [run/0]).
:- use_module(rpc, []).
:- use_module(web_prolog, []).
:- use_module(node_settings, []).
:- use_module(sandbox_policy).
:- use_module(peer_topology, []).
:- use_module(source_policy, []).

run :-
    source_policy:configure_source_policy([load_uri_allowed_origins(['https://peer.test'])], _),
    setup_call_cleanup(
      (assertz(web_prolog:node_public_url('https://fallback.test')),
       node_settings:register_node_settings(62001,'https://serving.test',actor,blacklist,open)),
      (rpc:resolve_rpc_uri(localhost,'https://fallback.test'),
       node_settings:with_node_settings(62001,
         (rpc:resolve_rpc_uri(localhost,'https://serving.test'),
          rpc:resolve_rpc_uri("localhost",'https://serving.test'),
          rpc:resolve_rpc_uri(localhost:3060,'http://localhost:3060'),
          rpc:resolve_rpc_uri('http://elsewhere.test','http://elsewhere.test')))),
      (retractall(web_prolog:node_public_url(_)),node_settings:forget_node_settings(62001))),
    forall(member(Mode,[blacklist,whitelist]),portability(Mode)),
    writeln('Current-node RPC, public remote source and unchanged sandbox denial: passed').

portability(Mode) :-
    Goal=(write(pair(X,X)),writeln(done),format('~w',[X])),
    sandbox_prepare_spawn(Mode,actor,user,Goal,[node('https://peer.test')],Wire,Options),
    Wire==Goal, var(X), Options==[node('https://peer.test')],
    Source="say(X) :- write(X), nl.",
    sandbox_prepare_spawn(Mode,actor,user,say(hello),
      [node('https://peer.test'),src_text(Source)],say(hello),RemoteOptions),
    memberchk(src_text(Source),RemoteOptions),
    sandbox_prepare_spawn(Mode,actor,user,write(local),[],Local,_),
    Local=actors:terminal_output(local,[source(io)]),
    forall(member(Unsafe,[open('/tmp/forbidden',write,_),write(user_output,secret),system:halt]),
      (catch(sandbox_prepare_spawn(Mode,actor,user,Unsafe,[node('https://peer.test')],_,_),E,true),
       nonvar(E),E=error(permission_error(_,_,_),_))),
    catch(sandbox_prepare_spawn(Mode,actor,user,evil,
      [node('https://peer.test'),src_text('evil :- open(secret,read,_).')],_,_),SourceError,true),
    nonvar(SourceError),SourceError=error(permission_error(_,_,_),_).
