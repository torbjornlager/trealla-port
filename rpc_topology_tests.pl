% SPDX-License-Identifier: MIT
:- module(rpc_topology_tests,[run/1]).
:- use_module(rpc,[]).
:- use_module(rpc_topology,[]).
:- use_module(node,[]).
:- use_module(actors,[make_ref/1]).
:- use_module(sandbox_policy).

run(Port) :-
    make_ref(Ref),format(atom(File),'/tmp/rpc-topology-~w.pl',[Ref]),
    format(atom(URL),'http://127.0.0.1:~w',[Port]),
    thread_create(node:node(Port,rpc_topology_tests:unused,
      [bind_address('127.0.0.1'),node_url(URL),profile(actor),auth(open),time_limit(3)]),Listener,[]),
    setup_call_cleanup(wait_ready(Port,100),checks(File,URL),
      (node:stop_node(Port),thread_join(Listener,_),catch(delete_file(File),_,true))),
    writeln('Owner RPC endpoints: sync, promise, paging, fail-closed reload and public boundaries passed').
unused(_,_).
wait_ready(Port,N) :- (node:node_running(Port)->true;N>0,sleep(0.01),M is N-1,wait_ready(Port,M)).
write_config(File,Pairs) :- setup_call_cleanup(open(File,write,S),
    (write_term(S,Pairs,[quoted(true)]),write(S,'.'),nl(S)),close(S)).
checks(File,URL) :-
    Logical='https://peer.invalid',
    rpc:rpc_endpoint('https://unconfigured.invalid','https://unconfigured.invalid'),
    write_config(File,[Logical-URL]),rpc_topology:configure(File),
    rpc:rpc_endpoint('https://peer.invalid:443',URL),
    rpc:rpc_endpoint('https://peer.invalid.evil','https://peer.invalid.evil'),
    rpc:rpc_endpoint('https://n5.elfenbenstornet.se','https://n5.elfenbenstornet.se'),
    rpc:rpc(Logical,X=ok),X==ok,
    findall(Y,rpc:rpc(Logical,member(Y,[a,b,c]),[limit(1)]),[a,b,c]),
    rpc:promise(Logical,Z=ok,Ref,[template(Z)]),
    rpc:yield(Ref,Answer,[timeout(2)]),Answer==success([ok],false),
    catch(rpc:rpc(Logical,throw(error(resource_error(time),fixture))),BackendError,true),
    BackendError=error(resource_error(time),_),
    catch(rpc:rpc(Logical,true,[rpc_endpoint(URL)]),OptionError,true),
    OptionError=error(domain_error(rpc_option,rpc_endpoint(URL)),_),
    forall(member(Mode,[blacklist,whitelist]),
      (catch(sandbox_prepare_spawn(Mode,actor,user,rpc_topology:configure(File),[],_,_),Denied,true),
       nonvar(Denied),Denied=error(permission_error(call,sandboxed,_),_))),
    forall(member(Bad,[['https://peer.invalid'-'http://user:secret@host'],
                      ['https://peer.invalid'-'http://host/path'],
                      ['https://peer.invalid'-'http://host?secret=x'],
                      ['https://peer.invalid'-URL,'https://peer.invalid:443'-URL],
                      [(:-halt)]]),
      (write_config(File,Bad),catch(rpc_topology:configure(File),Error,true),
       Error=error(domain_error(peer_rpc_endpoints_file,File),rpc_topology:configure/1),
       rpc:rpc_endpoint(Logical,URL))).
