% SPDX-License-Identifier: MIT
:- module(remote_alias_tests,[remote_alias_tests/0,remote_alias_live_test/1]).
:- use_module(actors).
:- use_module(distribution).

alias_name(Name) :- make_ref(Id),format(atom(Name),'remote_alias_~w',[Id]).
seed_writer :-
    self(Self),nb_setval('$distribution_owner',Self),
    nb_setval('$distribution_targets',[]),nb_setval('$distribution_monitors',[]),
    nb_setval('$distribution_waiters',[]),nb_setval('$distribution_io_requests',[]).

remote_alias_tests :-
    alias_down_modes,
    alias_connection_close(lost),alias_connection_close(explicit),
    writeln('Remote alias cleanup: all regressions passed').

alias_down_modes :-
    self(Self),seed_writer,
    alias_name(Name),alias_name(Other),alias_name(LocalName),
    P=7001@'http://alias.test',Q=7002@'http://alias.test',
    register(Name,P),register(Other,Q),register(LocalName,Self),
    nb_setval('$distribution_targets',[target(7001,Self,live,transparent)]),
    nb_setval('$distribution_monitors',[monitor(7001,one,Self),monitor(7002,two,Self)]),
    distribution:writer_message('$wire_event'(7001,down,down(P,wire_ref,killed)),unused,'http://alias.test',true),
    whereis(Name,undefined),whereis(Other,Q),whereis(LocalName,Self),
    receive({down(P,one,killed) -> true},[timeout(1),on_timeout(fail)]),
    nb_getval('$distribution_monitors',Monitors),Monitors==[monitor(7002,two,Self)],
    % Explicit and private synchronous-monitor paths also observe termination.
    register(Name,P),nb_setval('$distribution_targets',[target(7001,Self,live,explicit)]),
    distribution:writer_message('$wire_event'(7001,down,down(P,explicit_ref,true)),unused,'http://alias.test',true),
    whereis(Name,undefined),receive({down(P,explicit_ref,true) -> true},[timeout(1),on_timeout(fail)]),
    register(Name,P),nb_setval('$distribution_waiters',[waiter(request,7001,'$sync_monitor'(request),Self)]),
    distribution:writer_message('$wire_event'(7001,down,down(P,'$sync_monitor'(request),no_process)),unused,'http://alias.test',true),
    whereis(Name,undefined),receive({'$sync_down'(request,no_process) -> true},[timeout(1),on_timeout(fail)]),
    % Owner fallback when there is no spawned-target entry.
    register(Name,P),nb_setval('$distribution_targets',[]),
    distribution:writer_message('$wire_event'(7001,down,down(P,fallback,true)),unused,'http://alias.test',true),
    whereis(Name,undefined),receive({down(P,fallback,true) -> true},[timeout(1),on_timeout(fail)]),
    unregister(Other),unregister(LocalName),seed_writer,
    writeln('transparent, explicit, synchronous and owner down paths preserve delivery: ok').

alias_connection_close(Mode) :-
    seed_writer,self(Self),
    alias_name(A),alias_name(B),alias_name(C),alias_name(D),alias_name(E),
    alias_name(F),alias_name(G),alias_name(H),
    URL='http://alias-close.test',OtherURL='http://alias-other.test',
    register(A,7101@URL),register(B,7102@URL),register(C,7103@URL),
    register(D,7104@URL),register(E,7105@URL),
    register(F,7999@URL),register(G,7101@OtherURL),register(H,Self),
    nb_setval('$distribution_targets',[target(7101,Self,live,transparent),
        target(7102,Self,live,explicit),target(7103,Self,dead,explicit)]),
    nb_setval('$distribution_monitors',[monitor(7101,public_ref,Self),monitor(7104,only_monitor,Self)]),
    nb_setval('$distribution_waiters',[waiter(pending,7105,private_ref,Self)]),
    % Alias cleanup must not change the separate service registry.
    actors:register_service(A,Self),
    % A real unrelated local monitor must survive connection cleanup.
    spawn(receive({finish -> true}),Local,[link(false)]),monitor(Local,UnrelatedRef),
    close_vector(Mode,URL),
    whereis(A,undefined),whereis(B,undefined),whereis(C,undefined),
    whereis(D,undefined),whereis(E,undefined),
    whereis(F,7999@URL),whereis(G,7101@OtherURL),whereis(H,Self),
    actors:whereis_service(A,Self),actors:unregister_service(A),
    receive({down(7101@URL,public_ref,connection_closed) -> true},[timeout(1),on_timeout(fail)]),
    receive({down(7102@URL,7102@URL,connection_closed) -> true},[timeout(1),on_timeout(fail)]),
    receive({'$sync_down'(pending,connection_closed) -> true},[timeout(1),on_timeout(fail)]),
    Local ! finish,receive({down(Local,UnrelatedRef,true) -> true},[timeout(2),on_timeout(fail)]),
    unregister(F),unregister(G),unregister(H),seed_writer,
    format('~w close removes known aliases only, preserving services/names/monitors: ok~n',[Mode]).
close_vector(lost,URL) :-
    distribution:writer_message('$remote_lost'(URL,test_loss),unused,URL,false).
close_vector(explicit,URL) :-
    open('/dev/null',write,Stream,[type(binary)]),
    distribution:writer_message('$remote_close',ws(Stream,server,1024),URL,false).

remote_alias_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    remote_node_open(URL,Node),remote_node_open(URL,Other),
    setup_call_cleanup(true,remote_alias_tests:live_sessions(Node,Other),
        (remote_node_close(Node),remote_node_close(Other))),
    format('Live remote alias cleanup on ~w: ok~n',[Port]).
live_sessions(Node,Other) :-
    alias_name(Name),alias_name(KeptName),
    remote_spawn(Node,receive({finish -> true}),P,[monitor(true),link(false)]),register(Name,P),
    remote_spawn(Other,receive({finish -> true}),Q,[link(false)]),register(KeptName,Q),
    remote_monitor(Other,Q,Ref),
    remote_send(Node,P,finish),receive({down(P,_,true) -> true},[timeout(3),on_timeout(fail)]),
    whereis(Name,undefined),whereis(KeptName,Q),
    remote_spawn(Node,receive({finish -> true}),Closing,[link(false)]),register(Name,Closing),
    remote_node_close(Node),whereis(Name,undefined),whereis(KeptName,Q),
    remote_send(Other,Q,finish),receive({down(Q,Ref,true) -> true},[timeout(3),on_timeout(fail)]),
    whereis(KeptName,undefined).
