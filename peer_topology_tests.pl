% SPDX-License-Identifier: MIT
:- module(peer_topology_tests, [run/0]).
:- use_module(peer_topology, []).
:- use_module(distribution, []).
:- use_module(actors, [make_ref/1]).

run :-
    make_ref(Ref),format(atom(File),'/tmp/peer-topology-~w.pl',[Ref]),
    setup_call_cleanup(true,checks(File),catch(delete_file(File),_,true)),
    peer_topology:configure('Deployment/n5-peer-websocket-endpoints.example.pl'),
    distribution:node_websocket_url('https://n3.elfenbenstornet.se','ws://wp_n3:3053/ws'),
    distribution:node_websocket_url('https://n4.elfenbenstornet.se','ws://wp_n4:3055/ws'),
    writeln('Owner topology: exact dial mapping, invalid/duplicate files and fail-closed reload passed').

checks(File) :-
    Good=['https://node.test'-'ws://private-node:3053/ws'],
    write_config(File,Good),peer_topology:configure(File),
    distribution:node_websocket_url('https://node.test','ws://private-node:3053/ws'),
    distribution:node_websocket_url('https://other.test','wss://other.test/ws'),
    forall(member(Bad,[['https://node.test'-'http://wrong-scheme/ws'],
                       ['https://node.test'-'ws://host/ws?secret=bad'],
                       ['https://node.test'-'ws://user:pass@host/ws'],
                       ['https://node.test'-'ws://a/ws','https://node.test'-'ws://b/ws'],
                       [(:- halt)]]),
      (write_config(File,Bad),catch(peer_topology:configure(File),E,true),nonvar(E),
       distribution:node_websocket_url('https://node.test','ws://private-node:3053/ws'))).
write_config(File,Term) :-
    setup_call_cleanup(open(File,write,S),
      (write_term(S,Term,[quoted(true)]),write(S,'.'),nl(S)),close(S)).
