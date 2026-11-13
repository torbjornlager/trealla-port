% SPDX-License-Identifier: MIT
:- module(rpc_topology,[configure/1]).
:- use_module(rpc,[]).
:- use_module(source_policy,[normalize_source_origin/2]).
:- dynamic endpoint/2.
:- multifile rpc:hook_rpc_endpoint/2.

% This is an execution connection map, not a source-loading alias table.
% Owner configuration cannot grant remote capabilities or change node identity.
rpc:hook_rpc_endpoint(Logical,Endpoint) :-
    catch(source_policy:normalize_source_origin(Logical,Origin),_,fail),
    rpc_topology:endpoint(Origin,Endpoint).

configure(File) :-
    (catch((setup_call_cleanup(open(File,read,S),
               (read(S,Pairs),read(S,End)),close(S)),
            End==end_of_file,is_list(Pairs),ground(Pairs),
            normalize_pairs(Pairs,[],Normalized)),_,fail)
    -> retractall(endpoint(_,_)),install(Normalized)
    ;throw(error(domain_error(peer_rpc_endpoints_file,File),rpc_topology:configure/1))).
normalize_pairs([],_,[]).
normalize_pairs([Logical-Target|Pairs],Seen,[Origin-Target|Rest]) :-
    atom(Logical),atom(Target),
    normalize_source_origin(Logical,Origin),
    normalize_source_origin(Target,_),
    \+memberchk(Origin,Seen),normalize_pairs(Pairs,[Origin|Seen],Rest).
install([]).
install([Origin-Target|Pairs]) :- assertz(endpoint(Origin,Target)),install(Pairs).
