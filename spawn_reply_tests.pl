% SPDX-License-Identifier: MIT
:- module(spawn_reply_tests,[run/0,live/1]).
:- use_module(web_prolog,[]).
:- use_module(distribution,[]).
:- use_module(actors).
:- use_module(actor_api).
:- dynamic diagnostic/2.
:- multifile distribution:hook_transport_error/2.
distribution:hook_transport_error(URL,Error) :- assertz(spawn_reply_tests:diagnostic(URL,Error)).
run :-
    web_prolog:json_atom(J,'{"request_id":"first"}'),
    web_prolog:spawn_reply_context(spawn,J,request(first)),
    web_prolog:spawn_reply_context(toplevel_spawn,J,request(first)),
    web_prolog:spawn_reply_context(send,J,legacy),
    web_prolog:spawn_reply_context(spawn,pairs([]),legacy),
    web_prolog:json_atom(Bad,'{"request_id":42}'),
    catch(web_prolog:spawn_reply_context(spawn,Bad,_),E,true),
    E=error(type_error(string,number(42)),_),
    web_prolog:answer_event_json('$spawn_reply'(request(first),spawned(123)),false,A),
    web_prolog:json_text_field(A,request_id,first),
    web_prolog:json_text_field(A,type,spawned),
    web_prolog:answer_event_json('$spawn_reply'(request(second),error(test_error)),true,B),
    web_prolog:json_text_field(B,request_id,second),
    web_prolog:json_text_field(B,type,error),
    web_prolog:answer_event_json('$spawn_reply'(legacy,spawned(123)),false,C),
    \+web_prolog:json_field(C,request_id,_),
    web_prolog:answer_event_json('$spawn_reply'(legacy,error(test_error)),true,D),
    \+web_prolog:json_field(D,request_id,_),
    writer_selection,
    writeln('Spawn correlation, error isolation, legacy replies and connection loss: ok').

init_writer(Correlated) :-
    nb_setval('$distribution_spawn_correlated',Correlated),
    nb_setval('$distribution_targets',[]),nb_setval('$distribution_monitors',[]),
    nb_setval('$distribution_waiters',[]),nb_setval('$distribution_io_requests',[]).
wait_spawn(Request,Continue) :-
    self(Self),
    distribution:writer_wait_spawn(Self,Request,explicit,[],Self,Self,unused,'http://peer',Continue).
expect_error(Expected) :-
    self(Self),receive({'$remote_spawn_error'(Self,E) -> E=Expected},[timeout(0),on_timeout(fail)]).
writer_selection :-
    self(Self),init_writer(true),retractall(diagnostic(_,_)),
    % Errors arriving before/during a later spawn must not become its failure.
    send(Self,'$wire_spawn_error'(before)),send(Self,unrelated),
    send(Self,down(unrelated,kept,normal)),
    web_prolog:json_atom(Old,'{"type":"error","data":"old","request_id":"old"}'),
    distribution:dispatch_remote_type(error,Old,'http://peer',Self),
    send(Self,'$wire_spawn_error'(during)),
    web_prolog:json_atom(Good,'{"type":"spawned","pid":42,"request_id":"current"}'),
    distribution:dispatch_remote_type(spawned,Good,'http://peer',Self),
    wait_spawn(current,true),
    receive({'$remote_spawned'(Self,42) -> true},[timeout(0),on_timeout(fail)]),
    findall(E,diagnostic('http://peer',E),[before,during]),
    receive({unrelated -> true},[timeout(0),on_timeout(fail)]),
    receive({down(unrelated,kept,normal) -> true},[timeout(0),on_timeout(fail)]),
    init_writer(true),
    web_prolog:json_atom(Failed,'{"type":"error","data":"startup rejected","request_id":"failed"}'),
    distribution:dispatch_remote_type(error,Failed,'http://peer',Self),
    wait_spawn(failed,true),expect_error(error(remote_error('startup rejected'),distribution)),
    init_writer(false),send(Self,'$wire_spawn_error'(legacy_failure)),
    wait_spawn(legacy,true),expect_error(legacy_failure),
    send(Self,'$wire_spawned'(43)),wait_spawn(legacy,true),
    receive({'$remote_spawned'(Self,43) -> true},[timeout(0),on_timeout(fail)]),
    forall(member(Flag,[true,false]),
      (init_writer(Flag),send(Self,'$remote_lost'('http://peer',closed)),
       wait_spawn(closed,false),
       expect_error(error(remote_connection_closed('http://peer',closed),remote_spawn/4)))),
    init_writer(false),retractall(diagnostic(_,_)),
    receive({_ -> fail},[timeout(0),on_timeout(true)]).

% Run unchanged against current SWI and Trealla peers on disposable ports.
live(URL) :-
    distribution:remote_node_open(URL,Node),
    setup_call_cleanup(retractall(diagnostic(_,_)),live_connection(Node),
      (distribution:remote_node_close(Node),retractall(diagnostic(_,_)))).
live_connection(Node) :-
    spawn(receive({stop -> true}),Other,[link(false)]),monitor(Other,OtherRef),
    setup_call_cleanup(true,
      (forall(member(_,[first,second]),live_spawn(Node)),
       catch(distribution:remote_spawn(Node,true,_,[src_text('broken(')]),Error,true),
       nonvar(Error),live_spawn(Node),
       findall(E,diagnostic(_,E),Diagnostics),length(Diagnostics,N),(N>=3 -> true ; throw(missing_transport_diagnostics(N,Diagnostics))),
       Other ! stop,
       receive({down(Other,OtherRef,true) -> true},[timeout(3),on_timeout(fail)])),
      (exit(Other,kill),demonitor(OtherRef,[flush]))),
    writeln('Live spawn correlation: unrelated errors, genuine startup failure and monitors: ok').
live_spawn(Node) :-
    web_prolog:object([command-string_atom(toplevel_call),pid-number(99999999999),goal-string_atom(true),options-string_atom('[]')],BadCommand),
    distribution:enqueue_json(Node,BadCommand),
    distribution:remote_toplevel_spawn(Node,P,[session(true)]),
    setup_call_cleanup(true,
      (toplevel_call_synch(P,X=ok,A,[template(X-X),timeout(3)]),
       A==success(P,[ok-ok],false),var(X),
       distribution:remote_monitor(Node,P,Ref),
       distribution:remote_exit(Node,P,kill),
       receive({down(P,Ref,_) -> true},[timeout(3),on_timeout(fail)])),
      distribution:remote_exit(Node,P,kill)).
