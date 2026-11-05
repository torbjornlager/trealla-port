:- module(localhost_rpc_tests,[run/2]).
:- use_module(actor_api).

% The node is a separate process, exactly as in the existing RPC live tests.
% Each assertion invokes localhost from within that node's stateless endpoint.
run(Node, SourceBase) :-
    atom_concat(SourceBase,'/source.pl',SourceURI),
    rpc(Node,findall(X,rpc(localhost,member(X,[a,b]),[limit(1)]),[a,b])),
    rpc(Node,rpc(localhost,uri_value('hållå €'),[src_uri(SourceURI)])),
    rpc(Node,(promise(localhost,uri_value(X),R,[src_uri(SourceURI),template(v(X)),once(true)]),
              var(X),yield(R,success([v('hållå €')],false)),var(X))),
    rpc(Node,(rpc(localhost,localhost_loaded(ok),[src_text('localhost_loaded(ok).')]),
              catch(rpc(localhost,localhost_loaded(_)),_,Missing=true),Missing==true)),
    rpc(Node,(promise(localhost,fail,F),yield(F,failure))),
    rpc(Node,(promise(localhost,throw(local_error),E),yield(E,error(local_error)))),
    (catch(rpc(Node,(web_prolog:local_rpc_uri(_),true)),_,fail) -> throw(private_rpc_metadata_exposed);true),
    rpc(Node,rpc(localhost,true),[src_list([hook_local_rpc_uri('http://unapproved.invalid')])]),
    rpc(Node,rpc(localhost,true)),
    writeln('PASS localhost RPC/promise: local listener, paging, caller-fetched sources, stateless isolation and failure/error answers').
