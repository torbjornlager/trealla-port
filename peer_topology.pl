% SPDX-License-Identifier: MIT
:- module(peer_topology, [configure/1]).

/** <module> Owner-supplied node-to-WebSocket dial endpoints

The file contains one list of LogicalNodeURL-WebSocketURL pairs. Only the
dial address changes: actor pids and return paths keep their logical URLs.
No credentials or authority are inferred from a mapping. A private endpoint
must still enforce the receiving node's configured transport admission.
*/
:- use_module(distribution, []).
:- dynamic endpoint/2.
:- multifile distribution:hook_websocket_endpoint/2.

distribution:hook_websocket_endpoint(Node, Endpoint) :-
    peer_topology:endpoint(Node, Endpoint).

configure(File) :-
    setup_call_cleanup(open(File, read, Stream),
        (read(Stream, Pairs), read(Stream, End)), close(Stream)),
    ( End == end_of_file -> true
    ; throw(error(domain_error(peer_topology_file, File), configure/1)) ),
    must_be(list, Pairs),
    validate_pairs(Pairs, []),
    % Publish only after validating the entire file.
    retractall(endpoint(_,_)), install_pairs(Pairs).

validate_pairs([], _).
validate_pairs([Pair|Pairs], Seen) :-
    must_be(ground, Pair),
    ( Pair = Node-Endpoint -> true
    ; throw(error(domain_error(peer_endpoint, Pair), configure/1)) ),
    valid_url(Node, ['http://','https://']),
    valid_url(Endpoint, ['ws://','wss://']),
    ( memberchk(Node, Seen)
    -> throw(error(permission_error(redefine, peer_endpoint, Node), configure/1))
    ; true ),
    validate_pairs(Pairs, [Node|Seen]).

valid_url(URL, Schemes) :-
    must_be(atom, URL),
    ( member(Scheme, Schemes), atom_concat(Scheme, Rest, URL), Rest \== '',
      atom_codes(Rest, Codes), forall(member(C, Codes), (C > 32, C =\= 127)),
      \+ sub_atom(Rest, _, _, _, '@'),
      \+ sub_atom(Rest, _, _, _, '?'),
      \+ sub_atom(Rest, _, _, _, '#')
    -> true
    ; throw(error(domain_error(peer_endpoint_url, URL), configure/1)) ).

install_pairs([]).
install_pairs([Node-Endpoint|Pairs]) :-
    assertz(endpoint(Node, Endpoint)), install_pairs(Pairs).
