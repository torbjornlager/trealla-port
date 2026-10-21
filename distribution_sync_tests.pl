% SPDX-License-Identifier: MIT
:- use_module(distribution).
:- use_module(actors).
:- use_module(websocket).

distribution_sync_tests :-
    websocket:validate_client_subprotocol([], [optional_subprotocols(['web-prolog-sync-v1']),selected_subprotocol(None)]),
    None==none,
    websocket:validate_client_subprotocol(['sec-websocket-protocol'-'web-prolog-sync-v1'],
        [optional_subprotocols(['web-prolog-sync-v1']),selected_subprotocol(Selected)]),
    Selected=='web-prolog-sync-v1',
    catch(websocket:validate_client_subprotocol(['sec-websocket-protocol'-other],
        [optional_subprotocols(['web-prolog-sync-v1'])]),Wrong,true),
    Wrong=error(websocket_handshake(subprotocol(other)),_),
    catch(websocket:validate_client_subprotocol([],[subprotocol('web-prolog-sync-v1')]),Required,true),
    Required=error(websocket_handshake(missing_header(_)),_),
    self(Self),
    distribution:sync_options([template(X),limit(1),timeout(0),on_timeout(X=waiting)],call,Self,Query,Wait),
    Query=[template(X),limit(1)],Wait=[timeout(0),on_timeout(X=waiting)],var(X),
    catch(distribution:sync_options([timeout(-1)],call,Self,_,_),Bad,true),nonvar(Bad),
    nb_setval('$distribution_waiters',[]),
    distribution:writer_add_waiter(100,7,200,Self),
    distribution:writer_add_waiter(101,8,201,Self),
    distribution:writer_message('$wire_sync_reply'(100,7,success(7,[ok],false)),unused,unused,true),
    receive({'$sync_answer'(100,Answer)->Answer==success(7,[ok],false)},[timeout(1),on_timeout(fail)]),
    \+ distribution:writer_sync_down(7,201,kill),
    distribution:writer_sync_down(7,200,kill),
    receive({'$sync_down'(100,kill)->true},[timeout(1),on_timeout(fail)]),
    setup_call_cleanup(open('/dev/null',write,Sink,[type(binary)]),
        distribution:writer_release_waiter(100,ws(Sink,server,1024)),close(Sink)),
    nb_getval('$distribution_waiters',Kept),Kept==[waiter(101,8,201,Self)],
    setup_call_cleanup(open('/dev/null',write,Sink2,[type(binary)]),
        distribution:writer_release_waiter(101,ws(Sink2,server,1024)),close(Sink2)),
    nb_getval('$distribution_waiters',Empty),Empty==[],
    distribution:writer_message('$wire_sync_reply'(100,7,success(7,[late],false)),unused,unused,true),
    receive({'$sync_answer'(100,_)->fail},[timeout(0),on_timeout(true)]),
    nb_setval('$distribution_sync_supported',true),
    open('/dev/null',write,Closed,[type(binary)]),close(Closed),
    distribution:writer_message('$sync_request'(900,7,901,Self,pairs([])),ws(Closed,server,1024),unused,true),
    receive({'$sync_ready'(900,error(SetupError))->nonvar(SetupError)},[timeout(1),on_timeout(fail)]),
    nb_getval('$distribution_waiters',AfterError),AfterError==[],
    nb_setval('$distribution_targets',[]),
    distribution:writer_message('$wire_event'(7,down,down(7,'$sync_monitor'(100),kill)),unused,unused,true),
    receive({down(7,'$sync_monitor'(100),_)->fail},[timeout(0),on_timeout(true)]),
    endpoint_reply_vectors,
    close_confirmation_vectors,
    writeln('Outbound synchronous vectors: ok').

% An exhausted confirmation wait must fail explicitly, while preserving
% an unrelated monitor. No mailbox-wide monitor flushing is allowed.
close_confirmation_vectors :-
    spawn(receive({finish -> true}), Probe, [link(false)]),
    monitor(Probe, Ref),
    catch(distribution:wait_thread_end(Probe,0), Error, true),
    Error == error(resource_error(remote_node_close_timeout(Probe)),remote_node_close/1),
    actors:actor_thread(Probe,_),
    Probe ! finish,
    receive({down(Probe,Ref,true) -> true},[timeout(2),on_timeout(fail)]),
    distribution:wait_thread_end(Probe,0).

endpoint_reply_vectors :-
    self(Self),
    nb_setval('$distribution_waiters',[waiter('$toplevel_sync'(700),17,701,Self)]),
    distribution:writer_message('$local_actor_message'(900,
      '$toplevel_reply'('$toplevel_sync'(700),success(17@'http://localhost:1234',[pair(X,X)],false))),
      unused,'http://127.0.0.1:1234',true),
    receive({'$sync_answer'('$toplevel_sync'(700),Reply) ->
      Reply=success(17@'http://127.0.0.1:1234',[pair(A,B)],false),var(A),A==B},
      [timeout(0),on_timeout(fail)]),
    nb_setval('$distribution_waiters',[]),
    distribution:writer_message('$local_actor_message'(900,
      '$toplevel_reply'('$toplevel_sync'(700),failure(17))),unused,'http://127.0.0.1:1234',true),
    receive({'$sync_answer'('$toplevel_sync'(700),_) -> fail},[timeout(0),on_timeout(true)]).
