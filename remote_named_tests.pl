% SPDX-License-Identifier: MIT
:- module(remote_named_tests,[remote_named_tests/0,remote_named_live_test/1]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(server_actor).
:- use_module(supervisor_actor).
:- use_module(namespace_tests).
:- use_module(remote_alias_tests).

new_name(Name) :- make_ref(Id),format(atom(Name),'remote_named_~w',[Id]).
remote_named_tests :-
    remote_named_publication,
    remote_named_closed_namespace,
    remote_named_handshake_failures,
    writeln('Atomic remote named startup: all regressions passed').
remote_named_publication :-
    new_name(Name),actors:reserve_spawn_name(Name,Token),
    Options=['$name_reservation'(Token)],Pid=811@'http://remote-name.test',
    distribution:local_spawn_option('$name_reservation'(Token)),
    publish_remote_spawn_name(Pid,Options),whereis(Name,Pid),
    rollback_remote_spawn_name(Pid,Options),whereis(Name,undefined),
    rollback_remote_spawn_name(Pid,Options),actors:release_spawn_name(Token),
    new_name(Occupied),self(Self),register(Occupied,Self),
    catch(server_spawn(no_such_callback,[],_,[name(Occupied),node('http://invalid'),src_uri('http://invalid/source')]),E,true),
    E==name_is_in_use(Occupied),
    catch(supervisor_spawn([],_,[name(Occupied),node('http://invalid')]),SE,true),SE==name_is_in_use(Occupied),
    unregister(Occupied),
    writeln('caller-side publication/rollback and pre-I/O wrapper name conflicts: ok').
remote_named_closed_namespace :-
    namespace_tests:new_scope(NS,P),new_name(Name),self(Parent),make_ref(Req),
    P ! run(Req,remote_named_tests:reserve_pause(Parent,Name)),
    receive({remote_reserved(Token) -> true},[timeout(2),on_timeout(fail)]),
    web_prolog:retire_websocket_namespace(NS),
    register(Name,812@'http://remote-name.test'),P ! resume,
    receive({scope_result(Req,Result) -> true},[timeout(2),on_timeout(fail)]),
    Result=error(error(permission_error(register,closed_namespace,NS),_)),
    whereis(Name,812@'http://remote-name.test'),unregister(Name),actors:release_spawn_name(Token),
    namespace_tests:stop_scope(P),writeln('closed caller namespace rejects remote publication without erasing replacement: ok').
reserve_pause(Parent,Name) :-
    actors:reserve_spawn_name(Name,T),Parent ! remote_reserved(T),receive({resume -> true}),
    publish_remote_spawn_name(813@'http://remote-name.test',['$name_reservation'(T)]).
remote_named_handshake_failures :-
    self(Self),
    Self ! '$remote_spawn_failed'(Self,10,original_error),
    catch(distribution:writer_prepare_handshake(transparent,10,Self,Self),E,true),E==original_error,
    receive({'$remote_spawn_prepare'(Self,10) -> true},[timeout(0),on_timeout(fail)]),
    Self ! '$remote_lost'('http://remote-name.test',connection_closed),
    catch(distribution:writer_prepare_handshake(transparent,11,Self,Self),Lost,true),
    Lost==error(remote_connection_closed('http://remote-name.test',connection_closed),remote_spawn/4),
    receive({'$remote_spawn_prepare'(Self,11) -> true},[timeout(0),on_timeout(fail)]),
    remote_alias_tests:seed_writer,
    new_name(Name),actors:reserve_spawn_name(Name,Token),
    publish_remote_spawn_name(814@'http://remote-name.test',['$name_reservation'(Token)]),
    with_mutex('$actor_registry',(assertz(actors:link(Self,814@'http://remote-name.test')),
        assertz(actors:monitor(Self,814@'http://remote-name.test',814@'http://remote-name.test')),
        assertz(actors:monitor(Self,815@'http://remote-name.test',unrelated)))),
    nb_setval('$distribution_targets',[target(814,Self,live,transparent),target(815,Self,live,transparent)]),
    nb_setval('$distribution_monitors',[monitor(814,814@'http://remote-name.test',Self),monitor(815,unrelated,Self)]),
    open('/dev/null',write,S,[type(binary)]),
    distribution:writer_rollback_spawn(814,'http://remote-name.test',Self,['$name_reservation'(Token)],ws(S,server,1024)),close(S),
    whereis(Name,undefined),actors:monitor(Self,815@'http://remote-name.test',unrelated),
    nb_getval('$distribution_monitors',Kept),Kept==[monitor(815,unrelated,Self)],
    retractall(actors:monitor(Self,815@'http://remote-name.test',unrelated)),actors:release_spawn_name(Token),
    remote_alias_tests:seed_writer,
    Self ! '$remote_spawn_failed'(Self,816,publication_error),
    open('/dev/null',write,Sink,[type(binary)]),
    distribution:writer_finish_spawn(816,transparent,[],Self,Self,ws(Sink,server,1024),'http://remote-name.test',true),
    close(Sink),
    receive({'$remote_spawn_prepare'(Self,816) -> true},[timeout(0),on_timeout(fail)]),
    receive({'$remote_spawn_error'(Self,publication_error) -> true},[timeout(0),on_timeout(fail)]),
    nb_getval('$distribution_targets',AfterFailure),AfterFailure==[],
    writeln('failure/loss releases handshake and rollback preserves unrelated monitors: ok').

named_waiter(URL,Name,P) :-
    with_spawn_name([name(Name),node(URL)],P,remote_named_tests:spawn_waiter(URL,P)).
spawn_waiter(URL,P,NameOptions) :-
    append(NameOptions,[node(URL),link(false),monitor(true)],Options),
    spawn_runtime(receive({finish -> true}),P,Options).
remote_named_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    new_name(Name),named_waiter(URL,Name,P),whereis(Name,P),
    P ! finish,receive({down(P,P,true) -> true},[timeout(4),on_timeout(fail)]),whereis(Name,undefined),
    new_name(Failed),
    catch(with_spawn_name([name(Failed),node(URL)],_,remote_named_tests:spawn_bad_source(URL)),StartupError,true),
    nonvar(StartupError),whereis(Failed,undefined),
    named_waiter(URL,Failed,Retry),Retry ! finish,
    receive({down(Retry,Retry,true) -> true},[timeout(4),on_timeout(fail)]),
    forall(between(1,5,_),remote_named_tests:live_competition(URL)),
    % Immediate termination must not be followed by a late alias insertion.
    new_name(Immediate),with_spawn_name([name(Immediate),node(URL)],Quick,
        remote_named_tests:spawn_quick(URL,Quick)),
    receive({down(Quick,Quick,true) -> true},[timeout(4),on_timeout(fail)]),whereis(Immediate,undefined),
    remote_drop_connection(URL),format('Live atomic remote named startup on ~w: ok~n',[Port]).
spawn_bad_source(URL,NameOptions) :-
    append(NameOptions,[node(URL),link(false),src_list([(:- throw(remote_named_prepare_error))])],Options),
    spawn_runtime(true,_,Options).
spawn_quick(URL,P,NameOptions) :-
    append(NameOptions,[node(URL),link(false),monitor(true)],Options),spawn_runtime(true,P,Options).
spawn_recorded(URL,P,Attempts,Options) :-
    thread_send_message(Attempts,create),spawn_waiter(URL,P,Options).
compete(Gate,Replies,Attempts,URL,Name) :-
    thread_get_message(Gate,go),catch((with_spawn_name([name(Name),node(URL)],P,remote_named_tests:spawn_recorded(URL,P,Attempts)),R=won(P)),E,R=lost(E)),thread_send_message(Replies,R).
live_competition(URL) :-
    new_name(Name),message_queue_create(Gate),message_queue_create(Replies),message_queue_create(Attempts),
    thread_create(remote_named_tests:compete(Gate,Replies,Attempts,URL,Name),A,[]),
    thread_create(remote_named_tests:compete(Gate,Replies,Attempts,URL,Name),B,[]),
    thread_send_message(Gate,go),thread_send_message(Gate,go),
    thread_get_message(Replies,R1),thread_get_message(Replies,R2),thread_join(A,_),thread_join(B,_),
    message_queue_property(Attempts,size(1)),
    sort([R1,R2],Results),sort([won(P),lost(name_is_in_use(Name))],Results),whereis(Name,P),
    % The creator's thread owns its spawn-time monitor; install our own monitor.
    monitor(P,Ref),P ! finish,receive({down(P,Ref,true) -> true},[timeout(4),on_timeout(fail)]),
    whereis(Name,undefined),message_queue_destroy(Gate),message_queue_destroy(Replies),message_queue_destroy(Attempts).
