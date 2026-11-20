% SPDX-License-Identifier: MIT
:- module(peer_topology_tests, [run/0]).
:- use_module(peer_topology, []).
:- use_module(distribution, []).
:- use_module(actors, [make_ref/1]).

run :-
    make_ref(Ref),format(atom(File),'/tmp/peer-topology-~w.pl',[Ref]),
    setup_call_cleanup(true,(checks(File),credential_checks(File),path_checks(File)),catch(delete_file(File),_,true)),
    peer_topology:configure('Deployment/n5-peer-websocket-endpoints.example.pl'),
    distribution:node_websocket_url('https://n3.elfenbenstornet.se','ws://wp_n3:3053/ws'),
    distribution:node_websocket_url('https://n4.elfenbenstornet.se','ws://wp_n4:3055/ws'),
    writeln('Owner topology: exact dial mapping, invalid/duplicate files and fail-closed reload passed').

checks(File) :-
    Good=['https://node.test/'-'ws://private-node:3053/ws'],
    write_config(File,Good),peer_topology:configure(File),
    distribution:node_websocket_url('https://node.test','ws://private-node:3053/ws'),
    distribution:node_websocket_url('https://node.test/','ws://private-node:3053/ws'),
    distribution:node_websocket_url('https://other.test','wss://other.test/ws'),
    forall(member(Bad,[['https://node.test'-'http://wrong-scheme/ws'],
                       ['https://node.test'-'ws://host/ws?secret=bad'],
                       ['https://node.test'-'ws://user:pass@host/ws'],
                       ['https://node.test'-'ws://a/ws','https://node.test'-'ws://b/ws'],
                       ['https://node.test'-'ws://a/ws','https://node.test/'-'ws://b/ws'],
                       [(:- halt)]]),
      (write_config(File,Bad),catch(peer_topology:configure(File),E,true),nonvar(E),
       distribution:node_websocket_url('https://node.test','ws://private-node:3053/ws'))).
write_config(File,Term) :-
    setup_call_cleanup(open(File,write,S),
      (write_term(S,Term,[quoted(true)]),write(S,'.'),nl(S)),close(S)).

credential_checks(File) :-
    Token='synthetic-owner-credential-000000000',
    write_config(File,['https://node.test/'-Token]),peer_topology:configure_credentials(File),
    peer_topology:inbound_options(File,[bearer_token('https://node.test',Token,[execute,internal_transport])]),
    distribution:hook_websocket_options('https://node.test',[header('Authorization',Bearer)]),
    atom_concat('Bearer ',Token,Bearer),
    distribution:hook_websocket_options('https://node.test/',[header('Authorization',Bearer)]),
    \+ distribution:hook_websocket_options('https://node.test.invalid',_),
    forall(member(Foreign,['https://other.test','http://node.test','https://node.test:444','https://node.test/path','https://node.test/path/']),
           \+ distribution:hook_websocket_options(Foreign,_)),
    forall(member(Bad,[['https://node.test'-short],
                       ['https://node.test'-'synthetic-token-with-newline\n000000'],
                       ['https://node.test'-Token,'https://node.test'-Token],
                       ['https://node.test'-Token,'https://node.test/'-Token],
                       [(:- halt)]]),
      (write_config(File,Bad),catch(peer_topology:configure_credentials(File),E,true),nonvar(E),
       distribution:hook_websocket_options('https://node.test',[header('Authorization',Bearer)]))).

% Non-root paths are distinct logical nodes, even if default /ws dialing
% would happen to reach the same endpoint. Owner credentials never cross them.
path_checks(File) :-
    A='https://node.test/path',B='https://node.test/path/',
    write_config(File,[A-'ws://plain:3053/ws',B-'ws://slash:3053/ws']),
    peer_topology:configure(File),
    distribution:node_websocket_url(A,'ws://plain:3053/ws'),
    distribution:node_websocket_url(B,'ws://slash:3053/ws'),
    Token='synthetic-path-credential-00000000',
    write_config(File,[A-Token]),peer_topology:configure_credentials(File),
    distribution:hook_websocket_options(A,_),
    \+ distribution:hook_websocket_options(B,_).
