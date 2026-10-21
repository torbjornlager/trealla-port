% SPDX-License-Identifier: MIT

:- module(distribution,
    [ remote_node_open/2,
      remote_node_open/3,
      remote_node_close/1,
      remote_drop_connection/1,
      remote_spawn/4,
      remote_send/3,
      remote_exit/3,
      remote_monitor/3,
      remote_demonitor/2,
      remote_toplevel_spawn/3,
      remote_toplevel_call/4,
      remote_toplevel_call_synch/4,
      remote_toplevel_call_synch/5,
      remote_toplevel_next_synch/3,
      remote_toplevel_next_synch/4,
      remote_toplevel_next/2,
      remote_toplevel_next/3,
      remote_toplevel_stop/2,
      remote_toplevel_abort/2,
      remote_toplevel_halt/2,
      remote_toplevel_respond/3,
      op(200, xfx, @)
    ]).

/** <module> Native Trealla Web Prolog distribution client

This module keeps one version-1 Web Prolog WebSocket open per remote node.
A named node-manager caches connections, reconnects them lazily, and maps
canonical PID and published `Name@Node` routes.  A writer
actor serializes frames and spawn rendezvous; an independent reader actor
turns inbound JSON events into the same Prolog messages used by local actors.
Remote pids are represented as `WirePid@NodeURL` and ordinary actor operations
route them transparently after this module is loaded.

The connection is suitable for trusted Trealla and SWI Web Prolog nodes.  It
is intentionally a layer above websocket.pl and web_prolog.pl, and contains
no Logtalk or foreign code.
*/

:- op(200, xfx, @).

:- use_module(actors).
:- use_module(isolation).
:- use_module(websocket).
:- use_module(web_prolog).
:- use_module(library(uuid)).

:- multifile
    actors:hook_spawn/3,
    actors:hook_send/2,
    actors:hook_exit/2,
    actors:hook_monitor/3,
    actors:hook_demonitor/1,
    actors:hook_stop/1,
    actors:hook_local_registration_pid/2.

:- multifile web_prolog:hook_io_request/2.
:- multifile web_prolog:hook_close_browser_io/1.

:- dynamic io_endpoint_target/2.

:- catch(mutex_create(_, [alias('$distribution_io_endpoints')]),
         error(permission_error(create, mutex,
                                '$distribution_io_endpoints'), _),
         true).

                 /*******************************
                 *        CONNECTION API         *
                 *******************************/

%! remote_node_open(+URL, -Node) is det.
%! remote_node_open(+URL, -Node, +Options) is det.

remote_node_open(URL, Node) :-
    remote_node_open(URL, Node, []).

remote_node_open(URL0, remote_node(URL, Reader, Writer), Options) :-
    node_url_atom(URL0, URL),
    node_websocket_url(URL, WebSocketURL),
    self(Owner),
    node_connection_options(Options, WebSocketOptions),
    web_prolog_connect(WebSocketURL, WS,
        [optional_subprotocols(['web-prolog-sync-v1']),selected_subprotocol(Selected)|WebSocketOptions]),
    ( Selected == 'web-prolog-sync-v1' -> Sync = true ; Sync = false ),
    spawn(remote_writer_start(WS, URL, Owner, Sync), Writer, [link(false)]),
    spawn(remote_reader_loop(WS, URL, Writer), Reader, [link(false)]).

node_url_atom(URL, URL) :- atom(URL), !.
node_url_atom(URL, Atom) :- atom_chars(Atom, URL).

node_websocket_url(URL, URL) :-
    ( sub_atom(URL, 0, 5, _, 'ws://')
    ; sub_atom(URL, 0, 6, _, 'wss://')
    ), !.
node_websocket_url(URL, WebSocketURL) :-
    ( sub_atom(URL, 0, 7, _, 'http://') ->
        sub_atom(URL, 7, _, 0, Rest), Scheme = 'ws://'
    ; sub_atom(URL, 0, 8, _, 'https://') ->
        sub_atom(URL, 8, _, 0, Rest), Scheme = 'wss://'
    ; Rest = URL, Scheme = 'ws://'
    ),
    strip_trailing_slash(Rest, Base),
    atom_concat(Scheme, Base, Prefix),
    atom_concat(Prefix, '/ws', WebSocketURL).

strip_trailing_slash(Rest, Base) :-
    atom_concat(Base, '/', Rest), !.
strip_trailing_slash(Rest, Rest).

node_connection_options(Options, WebSocketOptions) :-
    default_header('X-Web-Prolog-User', 'node:trealla', Options, O1),
    default_header('X-Web-Prolog-Capabilities',
                   'execute,internal_transport', O1, WebSocketOptions).

default_header(Name, _, Options, Options) :-
    memberchk(header(Name, _), Options), !.
default_header(Name, Value, Options, [header(Name, Value)|Options]).

%! remote_node_close(+Node) is det.

remote_node_close(Node) :-
    Node = remote_node(_URL, Reader, Writer),
    manager_forget_endpoints_if_running(Writer),
    % Cancellation is cooperative: never close the shared stream while the
    % reader can still be inside get_byte/2. Its registry entry is removed
    % by at_exit, after the reader goal has unwound.
    ( actors:actor_thread(Reader, ReaderThread) ->
        catch(thread_cancel(ReaderThread),
              error(existence_error(thread_object, _), _), true)
    ; true
    ),
    wait_thread_end(Reader, 100),
    Writer ! '$remote_close',
    wait_thread_end(Writer, 100).

%! remote_drop_connection(+URL) is det.
%
%  Close the manager-cached connection for URL.  The next transparent
%  operation reconnects lazily.  Connection-owned actors still terminate;
%  published service addresses remain reusable after reconnection.

remote_drop_connection(URL0) :-
    node_url_atom(URL0, URL),
    distribution_manager(Manager),
    self(Caller),
    Manager ! '$node_lookup'(URL, Caller),
    receive({ '$node_lookup_reply'(Manager, URL, Node) -> true }, []),
    ( Node == none -> true ; remote_node_close(Node) ).

wait_thread_end(Thread, Attempts) :-
    ( actors:actor_thread(Thread, _) ->
        ( Attempts > 0 ->
            sleep(0.01), Next is Attempts - 1,
            wait_thread_end(Thread, Next)
        ; throw(error(resource_error(remote_node_close_timeout(Thread)),
                      remote_node_close/1))
        )
    ; true
    ).


                 /*******************************
                 *         REMOTE ACTORS         *
                 *******************************/

%! remote_spawn(+Node, :Goal, -RemotePid, +Options) is det.

:- meta_predicate(remote_spawn(+, 0, -, +)).

remote_spawn(Node, Goal0, RemotePid, Options0) :-
    actors:validate_spawn_options(Options0,public,distribution:remote_spawn/4),
    remote_spawn_mode(Node, Goal0, RemotePid, Options0, explicit).

remote_spawn_mode(Node, Goal0, RemotePid, Options0, Mode) :-
    actors:validate_spawn_options(Options0,runtime,distribution:remote_spawn/4),
    Node = remote_node(URL, _Reader, Writer),
    self(Target),
    strip_module(Goal0, SourceModule, Goal0Plain),
    isolation:rewrite_source_options(Options0, SourceModule, Options1),
    exclude(local_spawn_option, Options1, Options),
    portable_term_for_writer(Writer, Goal0Plain-Options,
                             Goal-PortableOptions),
    term_wire_atom(Goal, GoalText),
    term_wire_atom(PortableOptions, OptionsText),
    add_inherited_io_fields([command-string_atom(spawn),
                             goal-string_atom(GoalText),
                             options-string_atom(OptionsText)], Fields),
    web_prolog:object(Fields, JSON),
    spawn_request(Writer, URL, Mode, Options0, Target, JSON, RemotePid).

local_spawn_option(target(_)).
local_spawn_option(link(_)).
local_spawn_option(monitor(_)).
local_spawn_option(node(_)).
local_spawn_option(io_target(_)).
local_spawn_option('$entry_context'(_)).
local_spawn_option('$name_reservation'(_)).

%! remote_send(+Node, +RemotePid, +Message) is det.

remote_send(Node, RemotePid, Message) :-
    node_wire_pid(Node, RemotePid, WirePid),
    Node = remote_node(_, _, Writer),
    portable_term_for_writer(Writer, Message, PortableMessage),
    term_wire_atom(PortableMessage, MessageText),
    web_prolog:object([command-string_atom(send), pid-number(WirePid),
                       message-string_atom(MessageText)], JSON),
    enqueue_json(Node, JSON).

%! remote_exit(+Node, +RemotePid, +Reason) is det.

remote_exit(Node, RemotePid, Reason) :-
    node_wire_pid(Node, RemotePid, WirePid),
    Node = remote_node(_, _, Writer),
    portable_term_for_writer(Writer, Reason, PortableReason),
    term_wire_atom(PortableReason, ReasonText),
    web_prolog:object([command-string_atom(exit), pid-number(WirePid),
                       reason-string_atom(ReasonText)], JSON),
    enqueue_json(Node, JSON).

%! remote_monitor(+Node, +RemotePid, -Ref) is det.

remote_monitor(Node, RemotePid, Ref) :-
    node_wire_pid(Node, RemotePid, WirePid),
    make_ref(Ref),
    term_wire_atom(Ref, RefText),
    web_prolog:object([command-string_atom(monitor), pid-number(WirePid),
                       ref-string_atom(RefText)], JSON),
    enqueue_json(Node, JSON).

%! remote_demonitor(+Node, +Ref) is det.

remote_demonitor(Node, Ref) :-
    term_wire_atom(Ref, RefText),
    web_prolog:object([command-string_atom(demonitor),
                       ref-string_atom(RefText)], JSON),
    enqueue_json(Node, JSON).


                 /*******************************
                 *       REMOTE TOPLEVELS        *
                 *******************************/

%! remote_toplevel_spawn(+Node, -RemotePid, +Options) is det.

:- meta_predicate(remote_toplevel_spawn(+, -, :)).

remote_toplevel_spawn(Node, RemotePid, Options0) :-
    remote_toplevel_spawn_mode(Node,RemotePid,Options0,explicit).

% Chart-owned toplevels need the ordinary transparent name/monitor handshake.
remote_toplevel_spawn_mode(Node, RemotePid, Options0, Mode) :-
    strip_module(Options0, SourceModule, Options1),
    (Mode==transparent -> Scope=runtime;Scope=public),
    toplevel_actors:validate_toplevel_spawn_options(Options1,Scope,
        distribution:remote_toplevel_spawn/3),
    Node = remote_node(URL, _Reader, Writer),
    self(Target),
    isolation:rewrite_source_options(Options1, SourceModule, Options2),
    exclude(local_spawn_option, Options2, Options),
    portable_term_for_writer(Writer,Options,PortableOptions),
    term_wire_atom(PortableOptions, OptionsText),
    add_inherited_io_fields([command-string_atom(toplevel_spawn),
                             options-string_atom(OptionsText)], Fields),
    web_prolog:object(Fields, JSON),
    spawn_request(Writer, URL, Mode, Options1, Target, JSON, RemotePid),
    % Public pid-based wrappers must reuse this owning connection.
    (Mode==explicit -> manager_register_route(RemotePid,Writer) ; true),
    (Mode==transparent,memberchk(target(ReplyTarget),Options1) ->
      node_wire_pid(Node,RemotePid,WirePid),Writer ! '$remote_set_target'(WirePid,ReplyTarget)
    ; true).

%! remote_toplevel_call(+Node, +RemotePid, :Goal, +Options) is det.

:- meta_predicate(remote_toplevel_call(+, +, 0, +)).

remote_toplevel_call(Node, RemotePid, Goal0, Options0) :-
    remote_toplevel_call_mode(Node,RemotePid,Goal0,Options0,keep).
remote_toplevel_call_routed(Node, RemotePid, Goal0, Options0) :-
    (memberchk(target(Target),Options0) -> Routing=target(Target);Routing=keep),
    remote_toplevel_call_mode(Node,RemotePid,Goal0,Options0,Routing).
remote_toplevel_call_mode(Node, RemotePid, Goal0, Options0, Routing) :-
    node_wire_pid(Node, RemotePid, WirePid),
    Node = remote_node(_, _, Writer),
    strip_module(Goal0, _, Goal0Plain),
    exclude(local_call_option, Options0, Options),
    portable_term_for_writer(Writer, Goal0Plain-Options,
                             Goal-PortableOptions),
    goal_options_wire_atoms(Goal, PortableOptions, GoalText, OptionsText),
    web_prolog:object([command-string_atom(toplevel_call), pid-number(WirePid),
                       goal-string_atom(GoalText),
                       options-string_atom(OptionsText)], JSON),
    goal_options_wire_atoms(Goal, [format(prolog)|PortableOptions], ExactGoal, ExactOptions),
    web_prolog:object([command-string_atom(toplevel_call),pid-number(WirePid),
                       goal-string_atom(ExactGoal),options-string_atom(ExactOptions)], ExactJSON),
    (Routing==keep -> Writer ! '$remote_toplevel_call'(JSON, ExactJSON)
    ; Routing=target(Target),Writer ! '$remote_toplevel_call_target'(WirePid,Target,JSON,ExactJSON)).

local_call_option(target(_)).

:- meta_predicate(remote_toplevel_call_synch(+,+,0,-)).
:- meta_predicate(remote_toplevel_call_synch(+,+,0,-,:)).
:- meta_predicate(remote_toplevel_next_synch(+,+,-,:)).

remote_toplevel_call_synch(Node,Pid,Goal,Answer) :-
    remote_toplevel_call_synch(Node,Pid,Goal,Answer,[]).
remote_toplevel_call_synch(Node,Pid,Goal0,Answer,Options) :-
    strip_module(Goal0,GoalModule,Goal),
    synchronous_remote(call,Node,Pid,Goal,GoalModule,Answer,Options).
remote_toplevel_next_synch(Node,Pid,Answer) :-
    remote_toplevel_next_synch(Node,Pid,Answer,[]).
remote_toplevel_next_synch(Node,Pid,Answer,Options) :-
    synchronous_remote(next,Node,Pid,true,user,Answer,Options).

synchronous_remote(Kind,Node,Pid,Goal,FallbackModule,Answer,Options0) :-
    synchronous_remote(Kind,Node,Pid,Goal,FallbackModule,Answer,Options0,legacy).
synchronous_remote(Kind,Node,Pid,Goal,FallbackModule,Answer,Options0,Routing) :-
    strip_module(Options0,Caller0,Options), must_be(list,Options),
    ( nonvar(Caller0) -> Caller=Caller0
    ; self(Actor),isolation:actor_source_module(Actor,Source) -> Caller=Source
    ; Caller=FallbackModule ),
    self(Self), sync_options(Options,Kind,Self,Query,Wait),
    node_wire_pid(Node,Pid,WirePid), Node=remote_node(URL,_,Writer),
    make_ref(FreshRef),
    (Routing==caller -> RequestRef='$toplevel_sync'(FreshRef) ; RequestRef=FreshRef),
    MonitorRef='$sync_monitor'(RequestRef),
    (Routing==caller -> WireQuery=[target(Self)|Query] ; WireQuery=Query),
    portable_term_for_writer(Writer,Goal-WireQuery,PortableGoal-PortableOptions),
    ( Kind == call -> Message='$call'(PortableGoal,['$request_ref'(RequestRef)|PortableOptions])
    ; Message='$next'(['$request_ref'(RequestRef)|PortableOptions]) ),
    web_prolog:canonical_answer_text(Message,Text),
    web_prolog:object([command-string_atom(send),pid-number(WirePid),message-string_atom(Text)],JSON),
    setup_call_cleanup(monitor(Writer,LocalRef),
        setup_call_cleanup(true,
            ( Writer ! '$sync_request'(RequestRef,WirePid,MonitorRef,Self,JSON),
              receive({
                '$sync_ready'(RequestRef,Status) -> distribution:sync_ready(Status,URL) ;
                down(_,LocalRef,_) -> throw(toplevel_down(connection_closed))
              },[]),
              sync_wait(RequestRef,LocalRef,Answer,Caller,Wait) ),
            sync_cleanup(Writer,RequestRef,LocalRef)),
        demonitor(LocalRef,[flush])).

sync_ready(ok,_) :- !.
sync_ready(unsupported,URL) :- !,
    throw(error(permission_error(use,toplevel_correlation,URL),remote_toplevel_call_synch/5)).
sync_ready(error(Error),_) :- throw(Error).

sync_options([],_,_,[],[]).
sync_options([Option|Options],Kind,Self,Query,Wait) :-
    must_be(nonvar,Option),
    ( Option=timeout(T) -> must_be(number,T), (T>=0->true;throw(error(domain_error(not_less_than_zero,T),sync_options/5))),
        Wait=[Option|RestWait],Query=RestQuery
    ; Option=on_timeout(G) -> must_be(callable,G),Wait=[Option|RestWait],Query=RestQuery
    ; Option=target(Target) -> must_be(nonvar,Target),
        (Target==Self->true;throw(error(domain_error(synchronous_toplevel_target,Target),sync_options/5))),
        Wait=RestWait,Query=RestQuery
    ; sync_query_option(Kind,Option), Wait=RestWait,Query=[Option|RestQuery] ),
    sync_options(Options,Kind,Self,RestQuery,RestWait).
sync_query_option(_,limit(N)) :- !,must_be(integer,N),(N>0->true;throw(error(domain_error(positive_integer,N),sync_options/5))).
sync_query_option(call,offset(N)) :- !,must_be(integer,N),(N>=0->true;throw(error(domain_error(not_less_than_zero,N),sync_options/5))).
sync_query_option(call,once(B)) :- !,must_be(boolean,B).
sync_query_option(call,template(_)) :- !.
sync_query_option(_,Option) :- throw(error(domain_error(synchronous_toplevel_option,Option),sync_options/5)).

sync_wait(Ref,LocalRef,Answer,Caller,Options) :-
    option(on_timeout(Callback),Options,true),
    ( option(timeout(T),Options) -> Wait=[timeout(T)] ; Wait=[] ),
    once(receive({
        '$sync_answer'(Ref,Reply) -> Answer=Reply ;
        '$sync_down'(Ref,Reason) -> throw(toplevel_down(Reason)) ;
        down(_,LocalRef,_) -> throw(toplevel_down(connection_closed))
    },[on_timeout(distribution:sync_callback(Caller,Callback))|Wait])).
sync_callback(Caller,Callback) :-
    ( nonvar(Caller) -> call(Caller:Callback) ; call(Callback) ).

sync_cleanup(Writer,Ref,LocalRef) :-
    ( actors:actor_thread(Writer,Thread),catch(thread_property(Thread,status(running)),_,fail)
    -> self(Self), Writer ! '$sync_release'(Ref,Self),
       once(receive({ '$sync_released'(Ref) -> true ; down(_,LocalRef,_) -> true },[]))
    ; true ),
    actors:discard_deferred(distribution:sync_private_message(Ref)),
    sync_flush(Ref).
sync_flush(Ref) :-
    receive({Message if distribution:sync_private_message(Ref,Message) -> distribution:sync_flush(Ref)},
        [timeout(0),on_timeout(true)]).
sync_private_message(Ref,'$sync_answer'(Other,_)) :- Ref==Other.
sync_private_message(Ref,'$sync_down'(Other,_)) :- Ref==Other.
sync_private_message(Ref,'$sync_ready'(Other,_)) :- Ref==Other.

remote_toplevel_next(Node, RemotePid) :-
    remote_toplevel_next(Node, RemotePid, []).

remote_toplevel_next(Node, RemotePid, Options) :-
    node_wire_pid(Node, RemotePid, WirePid),
    ( memberchk(limit(Limit), Options) ->
        Fields = [command-string_atom(toplevel_next), pid-number(WirePid),
                  limit-number(Limit)]
    ; Fields = [command-string_atom(toplevel_next), pid-number(WirePid)]
    ),
    web_prolog:object(Fields, JSON),
    enqueue_json(Node, JSON).

remote_toplevel_stop(Node, RemotePid) :-
    pid_command(Node, RemotePid, toplevel_stop).

remote_toplevel_abort(Node, RemotePid) :-
    pid_command(Node, RemotePid, toplevel_abort).

remote_toplevel_halt(Node, RemotePid) :-
    pid_command(Node, RemotePid, toplevel_halt).

remote_toplevel_respond(Node, RemotePid, Input) :-
    node_wire_pid(Node, RemotePid, WirePid),
    Node = remote_node(_, _, Writer),
    portable_term_for_writer(Writer, Input, PortableInput),
    term_wire_atom(PortableInput, InputText),
    web_prolog:object([command-string_atom(toplevel_respond),
                       pid-number(WirePid), input-string_atom(InputText)], JSON),
    enqueue_json(Node, JSON).

pid_command(Node, RemotePid, Command) :-
    node_wire_pid(Node, RemotePid, WirePid),
    web_prolog:object([command-string_atom(Command), pid-number(WirePid)], JSON),
    enqueue_json(Node, JSON).


                 /*******************************
                 *        WRITER / READER        *
                 *******************************/

spawn_request(Writer, URL, Mode, Options, Target, JSON, RemotePid) :-
    self(Caller),
    Writer ! '$spawn_request'(JSON, Mode, Options, Target, Caller),
    await_spawn_reply(Writer, URL, Mode, Options, Target, RemotePid).

await_spawn_reply(Writer, URL, Mode, Options, Target, RemotePid) :-
    receive({
        '$remote_spawn_prepare'(Writer, WirePid) ->
            catch((distribution:caller_prepare_target(Mode,WirePid,URL,Writer,Target,Options),
                   actors:publish_remote_spawn_name(WirePid@URL,Options),
                   Writer ! '$remote_spawn_ready'(Target,WirePid)),
                  Error,Writer ! '$remote_spawn_failed'(Target,WirePid,Error)),
            distribution:await_spawn_reply(Writer, URL, Mode, Options,
                                           Target, RemotePid) ;
        '$remote_spawned'(Writer, WirePid) ->
            RemotePid = WirePid@URL ;
        '$remote_spawn_error'(Writer, Error) -> throw(Error)
    }, []).

enqueue_json(remote_node(_URL, _Reader, Writer), JSON) :-
    Writer ! '$remote_json'(JSON).

remote_writer_start(WS, URL, Owner, Sync) :-
    nb_setval('$distribution_owner', Owner),
    nb_setval('$distribution_targets', []),
    nb_setval('$distribution_monitors', []),
    nb_setval('$distribution_io_requests', []),
    nb_setval('$distribution_answer_terms', false),
    nb_setval('$distribution_sync_supported', Sync),
    nb_setval('$distribution_waiters', []),
    send_transport_hello(WS),
    % The existing welcome completes negotiation, including legacy peers
    % whose welcome omits answer_terms. Do not send the first query early.
    receive({
        '$wire_capabilities'(Exact) -> nb_setval('$distribution_answer_terms', Exact), Ready = true ;
        '$remote_close' -> distribution:writer_message('$remote_close',WS,URL,Ready) ;
        '$remote_lost'(URL, Reason) -> distribution:writer_message('$remote_lost'(URL,Reason),WS,URL,Ready)
    }, []),
    ( Ready == true -> remote_writer_loop(WS, URL) ; true ).

send_transport_hello(WS) :-
    web_prolog:object([command-string_atom(transport_hello),
                       version-number(1),browser_pids-boolean(true),
                       io_ack-boolean(true),answer_terms-boolean(true)], JSON),
    web_prolog_send(WS, JSON).

remote_writer_loop(WS, URL) :-
    receive({ Message -> true }, []),
    writer_message(Message, WS, URL, Continue),
    ( Continue == true -> remote_writer_loop(WS, URL) ; true ).

writer_message('$remote_json'(JSON), WS, _, true) :- !,
    web_prolog_send(WS, JSON).
writer_message('$remote_set_target'(Pid,Target),_,_,true) :- !,
    writer_targets(Targets),maplist(retarget_toplevel(Pid,Target),Targets,Retargeted),
    nb_setval('$distribution_targets',Retargeted).
writer_message('$remote_toplevel_call_target'(Pid,Target,JSON,ExactJSON),WS,URL,true) :- !,
    writer_message('$remote_set_target'(Pid,Target),WS,URL,true),
    writer_message('$remote_toplevel_call'(JSON,ExactJSON),WS,URL,true).
writer_message('$remote_toplevel_call'(JSON, ExactJSON), WS, _, true) :- !,
    nb_getval('$distribution_answer_terms', Exact),
    ( Exact == true
    -> Request = ExactJSON
    ; Request = JSON ),
    web_prolog_send(WS, Request).
writer_message('$wire_capabilities'(Exact), _, _, true) :- !,
    nb_setval('$distribution_answer_terms', Exact).
writer_message('$sync_request'(Ref,Pid,Mon,Caller,JSON),WS,_,true) :- !,
    ( nb_getval('$distribution_sync_supported',true)
    -> catch((writer_add_waiter(Ref,Pid,Mon,Caller),
              sync_monitor_command(monitor,Pid,Mon,Monitor),web_prolog_send(WS,Monitor),
              web_prolog_send(WS,JSON),Caller ! '$sync_ready'(Ref,ok)),
             Error,(writer_release_waiter(Ref,WS),Caller ! '$sync_ready'(Ref,error(Error))))
    ; Caller ! '$sync_ready'(Ref,unsupported) ).
writer_message('$sync_release'(Ref,Caller),WS,_,true) :- !,
    writer_release_waiter(Ref,WS), Caller ! '$sync_released'(Ref).
writer_message('$wire_sync_reply'(Ref,Pid,Answer),_,_,true) :- !,
    nb_getval('$distribution_waiters',Waiters),
    ( memberchk(waiter(Ref,Pid,_,Caller),Waiters) -> Caller ! '$sync_answer'(Ref,Answer) ; true ).
writer_message('$spawn_request'(JSON, Mode, Options, Target, Caller), WS, URL,
               Continue) :- !,
    self(Writer),
    catch(web_prolog_send(WS,JSON),SendError,true),
    ( nonvar(SendError)
    -> Caller ! '$remote_spawn_error'(Writer,SendError),
       writer_notify_connection_closed(URL),Continue=false
    ; writer_wait_spawn(Writer,Mode,Options,Target,Caller,WS,URL,Continue) ).

writer_message('$wire_io_ack'(Ack),WS,_,true) :- !,web_prolog_send(WS,Ack).
writer_message('$remote_lost'(URL, _Reason), _, _, false) :- !,
    writer_notify_connection_closed(URL).
writer_message('$wire_event'(WirePid, Type, Event), _, URL, true) :- !,
    ( Type == down -> actors:remove_remote_aliases([WirePid@URL]) ; true ),
    ( Event=down(_,Ref,Reason),nonvar(Ref),Ref='$sync_monitor'(_)
    -> (writer_sync_down(WirePid,Ref,Reason)->true;true)
    ; writer_deliver_event(WirePid, Event) ),
    writer_note_terminal(Type, WirePid).
writer_message('$local_actor_message'(_, '$toplevel_reply'(Ref,Reply)),_,URL,true) :-
    ground(Ref),
    nb_getval('$distribution_waiters',Waiters),
    member(waiter(Ref,WirePid,_,Caller),Waiters),
    endpoint_sync_answer(Reply,WirePid,URL,Answer), !,
    Caller ! '$sync_answer'(Ref,Answer).
% A late public-wrapper reply has no waiter after release. Its tagged
% reference is private; ordinary application/legacy envelopes still pass on.
writer_message('$local_actor_message'(_, '$toplevel_reply'(Ref,_)),_,_,true) :-
    ground(Ref),Ref='$toplevel_sync'(_), !.
writer_message('$local_actor_message'(TargetId, Message), _, _, true) :- !,
    self(Writer),
    distribution_manager(Manager),
    Manager ! '$endpoint_deliver'(Writer, TargetId, Message).
writer_message('$io_request'(JSON, RequestId, ReplyQueue), WS, _, true) :- !,
    writer_add_io_request(RequestId, ReplyQueue),
    web_prolog_send(WS, JSON).
writer_message('$wire_io_reply'(RequestId, Status), _, _, true) :- !,
    writer_deliver_io_reply(RequestId, Status).
writer_message('$cancel_io_request'(RequestId), _, _, true) :- !,
    writer_remove_io_request(RequestId).
writer_message('$transparent_monitor'(WirePid, Ref, Watcher, Caller), _, _,
               true) :- !,
    writer_add_monitor(WirePid, Ref, Watcher),
    Caller ! '$transparent_monitor_ready'(Ref).
writer_message('$transparent_demonitor'(Ref), _, _, true) :- !,
    writer_remove_monitor(Ref).
writer_message('$target_stopped'(Target), _, _, true) :- !,
    writer_remove_watcher(Target).
writer_message('$owner_event'(Event), _, _, true) :- !,
    writer_owner(Owner), Owner ! Event.
writer_message('$remote_close', WS, URL, false) :- !,
    writer_notify_connection_closed(URL),
    catch(ws_close(WS, 1000, normal), _, true).
writer_message(_, _, _, true).

writer_wait_spawn(Writer,Mode,Options,Target,Caller,WS,URL,Continue) :-
      receive({
        '$wire_io_ack'(Ack) ->
            web_prolog_send(WS,Ack),
            distribution:writer_wait_spawn(Writer,Mode,Options,Target,Caller,WS,URL,Continue) ;
        '$wire_spawned'(WirePid) ->
            distribution:writer_finish_spawn(WirePid,Mode,Options,Target,Caller,WS,URL,Continue) ;
        '$wire_spawn_error'(Error) ->
            Caller ! '$remote_spawn_error'(Writer, Error),Continue=true ;
        '$remote_lost'(URL, Reason) ->
            Caller ! '$remote_spawn_error'(Writer,
                         error(remote_connection_closed(URL, Reason),remote_spawn/4)),
            distribution:writer_notify_connection_closed(URL),Continue=false
      }, []).

writer_finish_spawn(WirePid,Mode,Options,Target,Caller,WS,URL,Continue) :-
    self(Writer),
    catch((writer_add_target(WirePid,Target,Mode),
           writer_prepare_handshake(Mode,WirePid,Caller,Target),
           writer_prepare_target(Mode,WirePid,URL,Target,Options,WS)),Error,true),
    (var(Error) -> Caller ! '$remote_spawned'(Writer,WirePid),Continue=true
    ; catch(writer_rollback_spawn(WirePid,URL,Target,Options,WS),_,true),
      Caller ! '$remote_spawn_error'(Writer,Error),
      (Error=error(remote_connection_closed(URL,_),remote_spawn/4)
       -> writer_notify_connection_closed(URL),Continue=false
       ; Continue=true)).

writer_rollback_spawn(WirePid,URL,Target,Options,WS) :-
    Pid=WirePid@URL,
    actors:rollback_remote_spawn_name(Pid,Options),
    with_mutex('$actor_registry',
        (retractall(actors:link(Target,Pid)),retractall(actors:monitor(Target,Pid,Pid)))),
    manager_forget_route_if_running(Pid),
    writer_monitors(Monitors),exclude(rollback_monitor(WirePid,Target,Pid),Monitors,Kept),
    nb_setval('$distribution_monitors',Kept),
    % Retain delivery for any independently installed watcher of this PID.
    (member(monitor(WirePid,_,_),Kept) -> true
    ; writer_targets(Targets),exclude(rollback_target(WirePid),Targets,Rest),
      nb_setval('$distribution_targets',Rest)),
    web_prolog:object([command-string_atom(exit),pid-number(WirePid),reason-string_atom(kill)],JSON),
    catch(web_prolog_send(WS,JSON),_,true).
rollback_target(Pid,target(Pid,_,_,_)).
rollback_monitor(Pid,Watcher,Ref,monitor(Pid,Ref,Watcher)).

writer_owner(Owner) :-
    nb_getval('$distribution_owner', Owner).

% The peer's public URL can alias the registered connection URL. The writer
% and waiter identify the peer; return the caller's existing pid spelling.
endpoint_sync_answer(success(P,Rows,More),WirePid,URL,success(WirePid@URL,Rows,More)) :-
    endpoint_sync_pid(P,WirePid,URL).
endpoint_sync_answer(failure(P),WirePid,URL,failure(WirePid@URL)) :-
    endpoint_sync_pid(P,WirePid,URL).
endpoint_sync_answer(error(P,E),WirePid,URL,error(WirePid@URL,E)) :-
    endpoint_sync_pid(P,WirePid,URL).
endpoint_sync_pid(P,WirePid,_URL) :- P==WirePid, !.
endpoint_sync_pid(P,WirePid,_URL) :- nonvar(P),P=Id@_,Id==WirePid.

writer_add_waiter(Ref,Pid,Mon,Caller) :-
    nb_getval('$distribution_waiters',Waiters),
    nb_setval('$distribution_waiters',[waiter(Ref,Pid,Mon,Caller)|Waiters]).
writer_release_waiter(Ref,WS) :-
    nb_getval('$distribution_waiters',Waiters),
    ( select(waiter(Ref,Pid,Mon,_),Waiters,Rest)
    -> nb_setval('$distribution_waiters',Rest),
       sync_monitor_command(demonitor,Pid,Mon,JSON),
       catch((web_prolog_send(WS,JSON)->true;true),_,true)
    ; true ).
sync_monitor_command(Command,Pid,Ref,JSON) :-
    web_prolog:canonical_answer_text(Ref,Text),
    web_prolog:object([command-string_atom(Command),pid-number(Pid),ref-string_atom(Text)],JSON).
writer_sync_down(Pid,Mon,Reason) :-
    nb_getval('$distribution_waiters',Waiters),
    memberchk(waiter(Ref,Pid,Mon,Caller),Waiters),
    Caller ! '$sync_down'(Ref,Reason).
writer_close_waiters :-
    nb_getval('$distribution_waiters',Waiters),
    forall(member(waiter(Ref,_,_,Caller),Waiters),Caller ! '$sync_down'(Ref,connection_closed)),
    nb_setval('$distribution_waiters',[]).

retarget_toplevel(Pid,Target,target(Pid,_,Status,Mode),target(Pid,Target,Status,Mode)) :- !.
retarget_toplevel(_,_,Entry,Entry).

writer_targets(Targets) :-
    ( nb_current('$distribution_targets', Targets) -> true ; Targets = [] ).

writer_add_target(WirePid, Target, Mode) :-
    writer_targets(Targets),
    nb_setval('$distribution_targets',
           [target(WirePid, Target, live, Mode)|Targets]).

writer_prepare_target(explicit, _, _, _, _, _) :- !.
writer_prepare_target(transparent, WirePid, URL, Target, Options, _WS) :-
    CompoundPid = WirePid@URL,
    option(monitor(Monitor), Options, false),
    ( Monitor == true ->
        writer_add_monitor(WirePid, CompoundPid, Target)
    ; true
    ).

writer_prepare_handshake(explicit, _, _, _) :- !.
writer_prepare_handshake(transparent, WirePid, Caller, Target) :-
    self(Writer),
    Caller ! '$remote_spawn_prepare'(Writer, WirePid),
    receive({
        '$remote_spawn_ready'(Target,WirePid) -> true ;
        '$remote_spawn_failed'(Target,WirePid,Error) -> throw(Error) ;
        '$remote_lost'(URL,Reason) -> throw(error(remote_connection_closed(URL,Reason),remote_spawn/4))
    }, []).

writer_monitors(Monitors) :-
    ( nb_current('$distribution_monitors', Monitors) -> true ; Monitors = [] ).

writer_add_monitor(WirePid, Ref, Watcher) :-
    writer_monitors(Monitors),
    nb_setval('$distribution_monitors',
           [monitor(WirePid, Ref, Watcher)|Monitors]).

writer_remove_monitor(Ref) :-
    writer_monitors(Monitors),
    exclude(writer_monitor_ref(Ref), Monitors, Rest),
    nb_setval('$distribution_monitors', Rest).

writer_monitor_ref(Ref, monitor(_, Ref, _)).

writer_remove_watcher(Watcher) :-
    writer_monitors(Monitors),
    exclude(writer_monitor_watcher(Watcher), Monitors, Rest),
    nb_setval('$distribution_monitors', Rest).

writer_monitor_watcher(Watcher, monitor(_, _, Watcher)).

writer_io_requests(Requests) :-
    ( nb_current('$distribution_io_requests', Requests) -> true ; Requests = [] ).

writer_add_io_request(RequestId, ReplyQueue) :-
    writer_io_requests(Requests),
    nb_setval('$distribution_io_requests',
           [io_request(RequestId, ReplyQueue)|Requests]).

writer_remove_io_request(RequestId) :-
    writer_io_requests(Requests),
    exclude(writer_io_request_id(RequestId), Requests, Rest),
    nb_setval('$distribution_io_requests', Rest).

writer_io_request_id(RequestId, io_request(RequestId, _)).

writer_deliver_io_reply(RequestId, Status) :-
    writer_io_requests(Requests),
    ( select(io_request(RequestId, ReplyQueue), Requests, Rest) ->
        nb_setval('$distribution_io_requests', Rest),
        catch(thread_send_message(ReplyQueue, Status), _, true)
    ; true
    ).

writer_fail_io_requests(Reason) :-
    writer_io_requests(Requests),
    fail_io_requests(Requests, Reason),
    nb_setval('$distribution_io_requests', []).

fail_io_requests([], _).
fail_io_requests([io_request(_, ReplyQueue)|Requests], Reason) :-
    catch(thread_send_message(ReplyQueue, Reason), _, true),
    fail_io_requests(Requests, Reason).

writer_deliver_event(WirePid, Event) :-
    writer_targets(Targets),
    ( memberchk(target(WirePid, Target, _, Mode), Targets) ->
        writer_deliver_target_event(Mode, WirePid, Target, Event)
    ; writer_owner(Owner), Owner ! Event
    ).

writer_deliver_target_event(explicit, _, Target, Event) :- !,
    Target ! Event.
writer_deliver_target_event(transparent, WirePid, _,
                            down(Pid, _RemoteRef, Reason)) :- !,
    writer_monitors(Monitors),
    take_wire_monitors(Monitors, WirePid, Watchers, Rest),
    nb_setval('$distribution_monitors', Rest),
    deliver_wire_downs(Watchers, Pid, Reason),
    cleanup_transparent_pid(Pid).
writer_deliver_target_event(transparent, _, Target, Event) :-
    Target ! Event.

take_wire_monitors([], _, [], []).
take_wire_monitors([monitor(WirePid, Ref, Watcher)|Monitors], WirePid,
                   [monitor(Ref, Watcher)|Watchers], Rest) :- !,
    take_wire_monitors(Monitors, WirePid, Watchers, Rest).
take_wire_monitors([Monitor|Monitors], WirePid, Watchers, [Monitor|Rest]) :-
    take_wire_monitors(Monitors, WirePid, Watchers, Rest).

deliver_wire_downs([], _, _).
deliver_wire_downs([monitor(Ref, Watcher)|Watchers], Pid, Reason) :-
    Watcher ! down(Pid, Ref, Reason),
    deliver_wire_downs(Watchers, Pid, Reason).

cleanup_transparent_pid(Pid) :-
    manager_forget_route_if_running(Pid),
    retractall(actors:link(_, Pid)).

writer_note_terminal(Type, WirePid) :-
    ( Type == down ; Type == halted ), !,
    writer_targets(Targets),
    mark_writer_target_dead(Targets, WirePid, Marked),
    nb_setval('$distribution_targets', Marked).
writer_note_terminal(_, _).

mark_writer_target_dead([], _, []).
mark_writer_target_dead([target(WirePid, Target, _, Mode)|Targets], WirePid,
                        [target(WirePid, Target, dead, Mode)|Marked]) :- !,
    mark_writer_target_dead(Targets, WirePid, Marked).
mark_writer_target_dead([Target|Targets], WirePid, [Target|Marked]) :-
    mark_writer_target_dead(Targets, WirePid, Marked).

writer_notify_connection_closed(URL) :-
    writer_known_remote_pids(URL,Pids),
    actors:remove_remote_aliases(Pids),
    writer_close_waiters,
    writer_targets(Targets),
    notify_live_targets(Targets, URL),
    nb_setval('$distribution_targets', []),
    nb_setval('$distribution_monitors', []),
    writer_fail_io_requests(connection_closed),
    self(Writer),
    manager_forget_endpoints_if_running(Writer),
    manager_forget_node_if_running(URL, Writer).

% Snapshot before close clears waiters, targets and monitors. Include explicit
% and synchronous-only targets, and avoid a node-URL-wide registration sweep.
writer_known_remote_pids(URL,Pids) :-
    writer_targets(Targets), writer_monitors(Monitors),
    ( nb_current('$distribution_waiters',Waiters) -> true ; Waiters=[] ),
    findall(Pid@URL,
        ( member(target(Pid,_,_,_),Targets)
        ; member(monitor(Pid,_,_),Monitors)
        ; member(waiter(_,Pid,_,_),Waiters) ),
        Known),
    sort(Known,Pids).

notify_live_targets([], _).
notify_live_targets([target(WirePid, Target, State, Mode)|Targets], URL) :-
    ( State == live ->
        notify_live_target(Mode, WirePid, Target, URL)
    ; true
    ),
    notify_live_targets(Targets, URL).

notify_live_target(explicit, WirePid, Target, URL) :- !,
    Target ! down(WirePid@URL, WirePid@URL, connection_closed).
notify_live_target(transparent, WirePid, _, URL) :-
    writer_monitors(Monitors),
    notify_wire_monitors(Monitors, WirePid, URL),
    cleanup_transparent_pid(WirePid@URL),
    retractall(actors:monitor(_, WirePid@URL, _)).

notify_wire_monitors([], _, _).
notify_wire_monitors([monitor(WirePid, Ref, Watcher)|Monitors], WirePid,
                     URL) :- !,
    Watcher ! down(WirePid@URL, Ref, connection_closed),
    notify_wire_monitors(Monitors, WirePid, URL).
notify_wire_monitors([_|Monitors], WirePid, URL) :-
    notify_wire_monitors(Monitors, WirePid, URL).

remote_reader_loop(WS, URL, Writer) :-
    catch(web_prolog_receive(WS, Message), Error, Message = reader_error(Error)),
    ( Message = pairs(_) ->
        catch(dispatch_remote_event(Message, URL, Writer), EventError,
              notify_connection_error(Writer, EventError)),
        remote_reader_loop(WS, URL, Writer)
    ; Message = close(Code, Reason) ->
        connection_lost(Writer, URL, close(Code, Reason))
    ; Message == end_of_file ->
        connection_lost(Writer, URL, end_of_file)
    ; Message = reader_error(Error) ->
        connection_lost(Writer, URL, Error)
    ; remote_reader_loop(WS, URL, Writer)
    ).

dispatch_remote_event(JSON, URL, Writer) :-
    web_prolog:json_atom_field(JSON, type, Type),
    dispatch_remote_type(Type, JSON, URL, Writer).

dispatch_remote_type(spawned, JSON, _, Writer) :- !,
    web_prolog:json_pid_field(JSON, pid, WirePid),
    Writer ! '$wire_spawned'(WirePid).
dispatch_remote_type(error, JSON, _, Writer) :-
    \+ web_prolog:json_field(JSON, pid, _), !,
    remote_error_term(JSON, Error),
    Writer ! '$wire_spawn_error'(Error).
dispatch_remote_type(transport_welcome, JSON, _, Writer) :- !,
    web_prolog:json_boolean_default(JSON, answer_terms, false, Exact),
    nb_setval('$distribution_answer_terms', Exact),
    Writer ! '$wire_capabilities'(Exact).
% Acknowledge only decoded terminal events, never arbitrary nested commands.
dispatch_remote_type(io_request,JSON,URL,Writer) :- !,
    web_prolog:json_text_field(JSON,request_id,RequestId),
    (catch((web_prolog:json_field(JSON,event,Event),
           web_prolog:json_atom_field(Event,type,Kind),
           memberchk(Kind,[output,statechart_trace]),
           dispatch_remote_event(Event,URL,Writer),Status=ok),_,Status=error) -> true;Status=error),
    (var(Status) -> Delivered=error;Delivered=Status),
    web_prolog:object([command-string_atom(browser_io_reply),
        request_id-string_atom(RequestId),status-string_atom(Delivered)],Ack),
    Writer ! '$wire_io_ack'(Ack).
dispatch_remote_type(io_reply, JSON, _, Writer) :- !,
    web_prolog:json_text_field(JSON, request_id, RequestId),
    web_prolog:json_atom_field(JSON, status, Status),
    Writer ! '$wire_io_reply'(RequestId, Status).
dispatch_remote_type(actor_message, JSON, _, Writer) :- !,
    web_prolog:json_text_field(JSON, target, TargetText),
    browser_target_id(TargetText, TargetId),
    json_event_term(JSON, message, Message),
    Writer ! '$local_actor_message'(TargetId, Message).
dispatch_remote_type(Type, JSON, URL, Writer) :-
    web_prolog:json_pid_field(JSON, pid, WirePid),
    ( web_prolog:json_text_field(JSON,toplevel_correlation,RefText)
    -> read_term_from_atom(RefText,Ref,[]),ground(Ref),
       remote_answer_event(Type,JSON,WirePid@URL,true,Event),
       Writer ! '$wire_sync_reply'(Ref,WirePid,Event)
    ; ( nb_current('$distribution_answer_terms', Exact) -> true ; Exact = false ),
      remote_answer_event(Type, JSON, WirePid@URL, Exact, Event),
      Writer ! '$wire_event'(WirePid, Type, Event) ).

browser_target_id(Text, TargetId) :-
    atom_concat(IdAtom, '@localhost', Text),
    atom_number(IdAtom, TargetId), integer(TargetId).

remote_answer_event(Type, JSON, Pid, true, Event) :-
    memberchk(Type,[success,error]), !,
    ( web_prolog:json_field(JSON, term, _)
    -> ( catch((web_prolog:json_text_field(JSON, term, Text),
                read_term_from_atom(Text, Payload, []),
                canonical_event(Type, JSON, Pid, Payload, Parsed)), _, fail)
       -> Event = Parsed
       ; Event = error(Pid,remote_answer_protocol_error(invalid_term)) )
    ; Event = error(Pid,remote_answer_protocol_error(missing_term)) ).
remote_answer_event(Type, JSON, Pid, _, Event) :-
    remote_event(Type, JSON, Pid, Event).

canonical_event(success, JSON, Pid, Rows, success(Pid,Rows,More)) :-
    must_be(list, Rows),
    web_prolog:json_boolean_default(JSON, more, false, More).
canonical_event(error, _, Pid, Error, error(Pid,Error)).

remote_event(success, JSON, Pid, success(Pid, Rows, More)) :- !,
    web_prolog:json_field(JSON, data, list(Data)),
    json_terms(Data, Rows),
    ( web_prolog:json_field(JSON, more, boolean(true)) -> More = true
    ; More = false
    ).
remote_event(failure, _, Pid, failure(Pid)) :- !.
remote_event(error, JSON, Pid, error(Pid, remote_error(Data))) :- !,
    web_prolog:json_text_default(JSON, data, 'Unknown remote error', Data).
remote_event(statechart_trace,JSON,Pid,terminal_output(Pid,statechart_trace(Data))) :- !,
    json_event_term(JSON,data,Data).
remote_event(output, JSON, Pid, output(Pid, Data)) :- !,
    json_event_term(JSON, data, Data).
remote_event(prompt, JSON, Pid, prompt(Pid, Prompt)) :- !,
    web_prolog:json_text_default(JSON, data, '', Prompt).
remote_event(stop, _, Pid, stop(Pid)) :- !.
remote_event(abort, _, Pid, abort(Pid)) :- !.
remote_event(responded, _, Pid, responded(Pid)) :- !.
remote_event(halted, JSON, Pid, halted(Pid, Reply)) :- !,
    json_event_term(JSON, reply, Reply).
remote_event(down, JSON, Pid, down(Pid, Ref, Reason)) :- !,
    ( web_prolog:json_pid_field(JSON, ref, Ref0) -> Ref = Ref0 ; Ref = Pid ),
    json_event_term(JSON, reason, Reason).
remote_event(Type, _, Pid, unknown_remote_event(Pid, Type)).

json_terms([], Terms) :- Terms = [].
json_terms([string(Chars)|Values], [Term|Terms]) :-
    atom_chars(Text, Chars),
    ( catch(read_term_from_atom(Text, Term, []), _, fail) -> true ; Term = Text ),
    json_terms(Values, Terms).
json_terms([pairs(Bindings)|Values], [Term|Terms]) :-
    json_binding_row(Bindings, Term),
    json_terms(Values, Terms).

json_binding_row([_-Value], Term) :- !,
    json_binding_value(Value, Term).
json_binding_row(Bindings, Terms) :-
    json_binding_values(Bindings, Terms).

json_binding_values([], Terms) :- Terms = [].
json_binding_values([string(NameChars)-Value|Bindings],
                    [Name=Term|Terms]) :-
    atom_chars(Name, NameChars),
    json_binding_value(Value, Term),
    json_binding_values(Bindings, Terms).

json_binding_value(string(Chars), Term) :-
    atom_chars(Text, Chars),
    ( catch(read_term_from_atom(Text, Term, []), _, fail) -> true ; Term = Text ).

json_event_term(JSON, Key, Term) :-
    web_prolog:json_text_default(JSON, Key, '', Text),
    ( catch(distribution:read_term_from_atom(Text, Term, []), _, fail) -> true ; Term = Text ).

remote_error_term(JSON, error(remote_error(Data), distribution)) :-
    web_prolog:json_text_default(JSON, data, 'Unknown remote error', Data).

connection_lost(Writer, URL, Reason) :-
    Writer ! '$remote_lost'(URL, Reason).

notify_connection_error(Writer, Error) :-
    Writer ! '$owner_event'(error(remote_connection, Error)).


                 /*******************************
                 *     DISTRIBUTED TERMINAL I/O *
                 *******************************/

add_inherited_io_fields(Fields0,
                        [io_target-string_atom(EndpointText)|Fields0]) :-
    inherited_io_endpoint(Endpoint),
    !,
    term_wire_atom(Endpoint, EndpointText).
add_inherited_io_fields(Fields, Fields).

inherited_io_endpoint(Endpoint) :-
    actors:current_io_target(Target),
    Target \== '$io_sink'(distributed),
    ( valid_io_endpoint(Target) -> Endpoint = Target
    ; web_prolog:current_node_url(HomeNode),
      io_endpoint_for_target(Target, Token),
      Endpoint = '$io_endpoint'(Token)@HomeNode
    ).

valid_io_endpoint('$io_endpoint'(Token)@HomeNode) :-
    atom(Token), atom(HomeNode).

io_endpoint_for_target(Target, Token) :-
    with_mutex('$distribution_io_endpoints',
        ( io_endpoint_target(Existing, Target) -> Token = Existing
        ; fresh_io_token(Token),
          assertz(io_endpoint_target(Token, Target))
        )).

fresh_io_token(Token) :-
    repeat,
    uuidv4_string(Chars),
    atom_chars(Candidate, Chars),
    \+ io_endpoint_target(Candidate, _),
    !,
    Token = Candidate.

forget_io_endpoints_for_target(Target) :-
    with_mutex('$distribution_io_endpoints',
               retractall(io_endpoint_target(_, Target))).

web_prolog:hook_io_request(Token, Message) :-
    deliver_io_endpoint(Token, Message).

deliver_io_endpoint(Token, Message) :-
    io_protocol_message(Message),
    with_mutex('$distribution_io_endpoints',
               io_endpoint_target(Token, Target)),
    deliver_terminal_target(Target, Message).

deliver_terminal_target(Target, Message) :-
    web_prolog:hook_terminal_delivery(Target, Message),
    !.
deliver_terminal_target(Target, Message) :-
    actors:actor_thread(Target, Thread),
    catch(thread_property(Thread, status(running)), _, fail),
    Target ! Message.

web_prolog:hook_close_browser_io(Relay) :-
    forget_io_endpoints_for_target('$browser_io'(Relay)).

io_protocol_message(terminal_output(_, _)).
io_protocol_message(terminal_io_output(_, _)).
io_protocol_message(prompt(_, _)).

route_io_endpoint(Token, HomeNode, Message) :-
    io_protocol_message(Message),
    !,
    ( web_prolog:current_node_url(HomeNode) ->
        ( deliver_io_endpoint(Token, Message) -> true
        ; io_request_error(endpoint_unavailable)
        )
    ; remote_io_request(HomeNode, Token, Message)
    ).
route_io_endpoint(_, _, _).

remote_io_request(HomeNode, Token, Message0) :-
    transparent_node(HomeNode, remote_node(_, _, Writer)),
    portable_term_for_writer(Writer, Message0, Message),
    term_wire_atom(Message, MessageText),
    fresh_io_token(RequestId),
    web_prolog:object([command-string_atom(io_request),
                       token-string_atom(Token),
                       message-string_atom(MessageText),
                       request_id-string_atom(RequestId)], JSON),
    setup_call_cleanup(
        message_queue_create(ReplyQueue),
        ( Writer ! '$io_request'(JSON, RequestId, ReplyQueue),
          ( thread_get_message(ReplyQueue, Status, [timeout(30)]) ->
              io_request_result(Status)
          ; io_request_error(timeout)
          )
        ),
        ( Writer ! '$cancel_io_request'(RequestId),
          catch(message_queue_destroy(ReplyQueue), _, true)
        )).

io_request_result(ok) :- !.
io_request_result(Reason) :- io_request_error(Reason).

io_request_error(Reason) :-
    throw(error(io_error(write, Reason), terminal_output/2)).


                 /*******************************
                 *      TRANSPARENT ROUTING      *
                 *******************************/

% Match only addresses that the send path routes back to this node. Merely
% checking a remote alias must not connect, fetch, or change PID mappings.
actors:hook_local_registration_pid(Pid@Node0,Pid) :-
    integer(Pid), nonvar(Node0),
    ( Node0 == localhost -> true
    ; catch((node_url_atom(Node0,URL),web_prolog:current_node_url(URL)),_,fail) ).

actors:hook_spawn(Goal, RemotePid, Options0) :-
    take_node_option(Options0, URL0, Options),
    URL0 \== localhost,
    node_url_atom(URL0, URL),
    transparent_node(URL, Node),
    remote_spawn_mode(Node, Goal, RemotePid, Options, transparent).

actors:hook_send('$io_endpoint'(Token)@HomeNode, Message) :-
    !,
    route_io_endpoint(Token, HomeNode, Message).

actors:hook_send(Name@Node0, Message) :-
    atom(Name),
    !,
    ( Node0 == localhost ->
        actors:send_service(Name, Message)
    ; node_url_atom(Node0, URL),
      transparent_node(URL, remote_node(_, _, Writer)),
      portable_term_for_writer(Writer, Message, PortableMessage),
      term_wire_atom(PortableMessage, MessageText),
      web_prolog:object([command-string_atom(send),pid-json_pid(Name),
                         message-string_atom(MessageText)], JSON),
      Writer ! '$remote_json'(JSON)
    ).

% A qualified pid can arrive as ordinary data without having been created by
% this node (for example, a SWI actor passes its own pid to a Trealla actor as
% a reply address).  Route it by its node URL instead of requiring a route
% entry installed by an earlier transparent spawn.
actors:hook_send(WirePid@Node0, Message) :-
    integer(WirePid),
    !,
    node_url_atom(Node0, URL),
    ( ( Node0 == localhost ; web_prolog:current_node_url(URL) ) ->
        actors:send(WirePid, Message)
    ; transparent_node(URL, remote_node(_, _, Writer)),
      portable_term_for_writer(Writer, Message, PortableMessage),
      term_wire_atom(PortableMessage, MessageText),
      web_prolog:object([command-string_atom(send), pid-number(WirePid),
                         message-string_atom(MessageText)], JSON),
      Writer ! '$remote_json'(JSON)
    ).

actors:hook_send(RemotePid, Message) :-
    remote_pid_writer(RemotePid, Writer, WirePid),
    portable_term_for_writer(Writer, Message, PortableMessage),
    term_wire_atom(PortableMessage, MessageText),
    web_prolog:object([command-string_atom(send), pid-number(WirePid),
                       message-string_atom(MessageText)], JSON),
    Writer ! '$remote_json'(JSON).

actors:hook_exit(RemotePid, Reason) :-
    remote_pid_writer(RemotePid, Writer, WirePid),
    portable_term_for_writer(Writer, Reason, PortableReason),
    term_wire_atom(PortableReason, ReasonText),
    web_prolog:object([command-string_atom(exit), pid-number(WirePid),
                       reason-string_atom(ReasonText)], JSON),
    Writer ! '$remote_json'(JSON).

actors:hook_monitor(Watcher, RemotePid, Ref) :-
    remote_pid_writer(RemotePid, Writer, WirePid),
    self(Caller),
    Writer ! '$transparent_monitor'(WirePid, Ref, Watcher, Caller),
    receive({ '$transparent_monitor_ready'(Ref) -> true },
            [timeout(2),
             on_timeout(throw(error(remote_monitor_timeout(RemotePid),
                                    monitor/2))) ]).

actors:hook_demonitor(Ref) :-
    actors:monitor(_, RemotePid, Ref),
    remote_pid_writer(RemotePid, Writer, _),
    Writer ! '$transparent_demonitor'(Ref).

actors:hook_stop(Target) :-
    forget_io_endpoints_for_target(Target),
    distribution_manager(Manager),
    Manager ! '$target_stopped'(Target).

take_node_option([node(URL)|Options], URL, Options) :- !.
take_node_option([Option|Options0], URL, [Option|Options]) :-
    take_node_option(Options0, URL, Options).

transparent_node(URL, Node) :-
    distribution_manager(Manager),
    self(Caller),
    Manager ! '$node_request'(URL, Caller),
    receive({
        '$node_reply'(Manager, URL, Node) -> true ;
        '$node_error'(Manager, URL, Error) -> throw(Error)
    }, []).

remote_pid_writer(RemotePid, Writer, WirePid) :-
    RemotePid = WirePid@_,
    integer(WirePid),
    distribution_manager(Manager),
    self(Caller),
    Manager ! '$route_request'(RemotePid, Caller),
    receive({
        '$route_reply'(Manager, RemotePid, Writer) -> true ;
        '$route_missing'(Manager, RemotePid) -> fail
    },
            [timeout(0.2),on_timeout(fail)]).

caller_prepare_target(explicit, _, _, _, _, _) :- !.
caller_prepare_target(transparent, WirePid, URL, Writer, Target, Options) :-
    CompoundPid = WirePid@URL,
    manager_register_route(CompoundPid, Writer),
    option(link(Link), Options, true),
    ( Link == true -> assertz(actors:link(Target, CompoundPid)) ; true ),
    option(monitor(Monitor), Options, false),
    ( Monitor == true ->
        assertz(actors:monitor(Target, CompoundPid, CompoundPid))
    ; true
    ).

manager_register_route(RemotePid, Writer) :-
    distribution_manager(Manager),
    self(Caller),
    Manager ! '$route_register'(RemotePid, Writer, Caller),
    receive({ '$route_registered'(Manager, RemotePid) -> true }, []).

manager_forget_node_if_running(URL, Writer) :-
    ( catch(thread_property('$distribution_manager', status(running)), _, fail) ->
        '$distribution_manager' ! '$node_forget'(URL, Writer)
    ; true
    ).

manager_forget_endpoints_if_running(Writer) :-
    ( catch(thread_property('$distribution_manager', status(running)), _, fail) ->
        '$distribution_manager' ! '$endpoint_writer_forget'(Writer)
    ; true
    ).

manager_forget_route_if_running(Pid) :-
    ( catch(thread_property('$distribution_manager', status(running)), _, fail) ->
        '$distribution_manager' ! '$route_forget'(Pid)
    ; true
    ).

distribution_manager('$distribution_manager') :-
    catch(thread_property('$distribution_manager', status(running)), _, fail),
    !.
distribution_manager('$distribution_manager') :-
    catch(thread_create(distribution:distribution_manager_start, _,
                        [alias('$distribution_manager'),detached(true)]),
          _, true),
    wait_distribution_manager(100).

wait_distribution_manager(0) :-
    throw(error(resource_error(distribution_manager), distribution)).
wait_distribution_manager(Attempts) :-
    ( catch(thread_property('$distribution_manager', status(running)), _, fail) ->
        true
    ; sleep(0.01), Next is Attempts - 1,
      wait_distribution_manager(Next)
    ).

distribution_manager_start :-
    nb_setval('$distribution_endpoints', []),
    distribution_manager_loop([], []).

distribution_manager_loop(Nodes, Routes) :-
    thread_get_message(Message),
    catch(manager_message(Message, Nodes, Routes, NextNodes, NextRoutes), _,
          ( NextNodes = Nodes, NextRoutes = Routes )),
    distribution_manager_loop(NextNodes, NextRoutes).

manager_message('$node_request'(URL, Caller), Nodes, Routes,
                NextNodes, Routes) :- !,
    ( select(node(URL, Node), Nodes, Rest), node_writer_running(Node) ->
        NextNodes = [node(URL, Node)|Rest], Error = none
    ; catch(remote_node_open(URL, Node), OpenError, true),
      ( var(OpenError) ->
          exclude(manager_node_url(URL), Nodes, OtherNodes),
          NextNodes = [node(URL, Node)|OtherNodes], Error = none
      ; NextNodes = Nodes, Error = OpenError
      )
    ),
    manager_identity(Manager),
    ( Error == none -> Caller ! '$node_reply'(Manager, URL, Node)
    ; Caller ! '$node_error'(Manager, URL, Error)
    ).
manager_message('$node_lookup'(URL, Caller), Nodes, Routes,
                Nodes, Routes) :- !,
    manager_identity(Manager),
    ( member(node(URL, Node0), Nodes), node_writer_running(Node0) -> Node = Node0
    ; Node = none
    ),
    Caller ! '$node_lookup_reply'(Manager, URL, Node).
manager_message('$route_register'(Pid, Writer, Caller), Nodes, Routes,
                Nodes, [route(Pid, Writer)|Rest]) :- !,
    exclude(manager_route_pid(Pid), Routes, Rest),
    manager_identity(Manager),
    Caller ! '$route_registered'(Manager, Pid).
manager_message('$route_request'(Pid, Caller), Nodes, Routes, Nodes, Routes) :- !,
    manager_identity(Manager),
    ( memberchk(route(Pid, Writer), Routes) ->
        Caller ! '$route_reply'(Manager, Pid, Writer)
    ; Caller ! '$route_missing'(Manager, Pid)
    ).
manager_message('$route_forget'(Pid), Nodes, Routes, Nodes, Rest) :- !,
    exclude(manager_route_pid(Pid), Routes, Rest).
manager_message('$node_forget'(_URL, Writer), Nodes, Routes,
                RestNodes, RestRoutes) :- !,
    remove_writer_nodes(Nodes, Writer, RestNodes),
    remove_writer_routes(Routes, Writer, RestRoutes).
manager_message('$endpoint_writer_forget'(Writer), Nodes, Routes,
                Nodes, Routes) :- !,
    manager_endpoints(Endpoints),
    remove_writer_endpoints(Endpoints, Writer, RestEndpoints),
    nb_setval('$distribution_endpoints', RestEndpoints).
manager_message('$target_stopped'(Target), Nodes, Routes, Nodes, Routes) :- !,
    notify_node_target_stopped(Nodes, Target),
    manager_endpoints(Endpoints),
    exclude(manager_endpoint_target(Target), Endpoints, RestEndpoints),
    nb_setval('$distribution_endpoints', RestEndpoints).
manager_message('$endpoint_request'(Writer, Target, Caller),
                Nodes, Routes, Nodes, Routes) :- !,
    manager_endpoints(Endpoints),
    ( endpoint_lookup(Endpoints, Writer, Target, Id) ->
        NextEndpoints = Endpoints
    ; fresh_endpoint_id(Endpoints, Id),
      NextEndpoints = [endpoint(Writer, Id, Target)|Endpoints]
    ),
    nb_setval('$distribution_endpoints', NextEndpoints),
    manager_identity(Manager),
    Caller ! '$endpoint_reply'(Manager, Writer, Target, Id).
manager_message('$endpoint_deliver'(Writer, Id, Message),
                Nodes, Routes, Nodes, Routes) :- !,
    manager_endpoints(Endpoints),
    ( endpoint_lookup_id(Endpoints, Writer, Id, Target) ->
        Target ! Message
    ; true
    ).
manager_message(_, Nodes, Routes, Nodes, Routes).

% The manager is deliberately a raw Trealla thread alias rather than an
% actor. Its request/reply protocol therefore identifies it by that stable
% alias, not by the lazy logical PID self/1 assigns to non-actor threads.
manager_identity('$distribution_manager').

node_writer_running(remote_node(_, Reader, Writer)) :-
    actors:actor_thread(Reader, ReaderThread),
    actors:actor_thread(Writer, WriterThread),
    catch(thread_property(ReaderThread, status(running)), _, fail),
    catch(thread_property(WriterThread, status(running)), _, fail).

manager_route_pid(Pid, route(Pid, _)).
manager_node_url(URL, node(URL, _)).
manager_endpoint_target(Target, endpoint(_, _, EndpointTarget)) :-
    EndpointTarget == Target.

remove_writer_nodes([], _, []).
remove_writer_nodes([Node|Nodes], Writer, Rest) :-
    Node = node(_, remote_node(_, _, NodeWriter)),
    ( NodeWriter == Writer -> Rest = Tail ; Rest = [Node|Tail] ),
    remove_writer_nodes(Nodes, Writer, Tail).

remove_writer_routes([], _, []).
remove_writer_routes([Route|Routes], Writer, Rest) :-
    Route = route(_, RouteWriter),
    ( RouteWriter == Writer -> Rest = Tail ; Rest = [Route|Tail] ),
    remove_writer_routes(Routes, Writer, Tail).

manager_endpoints(Endpoints) :-
    ( nb_current('$distribution_endpoints', Endpoints) -> true ; Endpoints = [] ).

remove_writer_endpoints([], _, []).
remove_writer_endpoints([endpoint(EndpointWriter, Id, Target)|Endpoints],
                        Writer, Rest) :-
    ( EndpointWriter == Writer -> Rest = Tail
    ; Rest = [endpoint(EndpointWriter, Id, Target)|Tail]
    ),
    remove_writer_endpoints(Endpoints, Writer, Tail).

endpoint_lookup([endpoint(EndpointWriter, Id, EndpointTarget)|_], Writer,
                Target, Id) :-
    EndpointWriter == Writer, EndpointTarget == Target, !.
endpoint_lookup([_|Endpoints], Writer, Target, Id) :-
    endpoint_lookup(Endpoints, Writer, Target, Id).

endpoint_lookup_id([endpoint(EndpointWriter, Id0, Target)|_], Writer, Id,
                   Target) :-
    EndpointWriter == Writer, Id0 =:= Id, !.
endpoint_lookup_id([_|Endpoints], Writer, Id, Target) :-
    endpoint_lookup_id(Endpoints, Writer, Id, Target).

fresh_endpoint_id(Endpoints, Id) :-
    random_between(1000000000, 9999999999, Candidate),
    ( member(endpoint(_, Candidate, _), Endpoints) ->
        fresh_endpoint_id(Endpoints, Id)
    ; Id = Candidate
    ).

notify_node_target_stopped([], _).
notify_node_target_stopped([node(_, remote_node(_, _, Writer))|Nodes], Target) :-
    Writer ! '$target_stopped'(Target),
    notify_node_target_stopped(Nodes, Target).


                 /*******************************
                 *     RETURN-PATH ENDPOINTS     *
                 *******************************/

portable_term_for_writer(Writer, Term0, Term) :-
    ( local_runtime_pid(Term0) ->
        endpoint_for_target(Writer, Term0, Id),
        Term = Id@localhost
    ; var(Term0) -> Term = Term0
    ; atomic(Term0) -> Term = Term0
    ; functor(Term0, Name, Arity),
      functor(Term, Name, Arity),
      portable_term_args(1, Arity, Writer, Term0, Term)
    ).

portable_term_args(Index, Arity, _, _, _) :- Index > Arity, !.
portable_term_args(Index, Arity, Writer, Term0, Term) :-
    arg(Index, Term0, Arg0),
    portable_term_for_writer(Writer, Arg0, Arg),
    arg(Index, Term, Arg),
    Next is Index + 1,
    portable_term_args(Next, Arity, Writer, Term0, Term).

local_runtime_pid(Pid) :-
    nonvar(Pid),
    actors:actor_thread(Pid, Thread),
    catch(thread_property(Thread, status(_)), _, fail).

endpoint_for_target(Writer, Target, Id) :-
    distribution_manager(Manager),
    self(Caller),
    Manager ! '$endpoint_request'(Writer, Target, Caller),
    receive({ '$endpoint_reply'(Manager, Writer, Target, Id) -> true }, []).


                 /*******************************
                 *          WIRE TERMS           *
                 *******************************/

node_wire_pid(remote_node(URL, _, _), WirePid@PidURL, WirePid) :-
    PidURL == URL, integer(WirePid), !.
node_wire_pid(remote_node(URL, _, _), Pid, _) :-
    throw(error(domain_error(remote_pid_for_node(URL), Pid), distribution)).

term_wire_atom(Term, Atom) :-
    copy_term(Term, Copy), numbervars(Copy, 0, _),
    format(atom(Atom), '~q', [Copy]).

goal_options_wire_atoms(Goal, Options, GoalAtom, OptionsAtom) :-
    term_variables(Goal-Options, Vars),
    web_prolog:answer_variable_names(Vars, 1, Names),
    WriteOptions = [quoted(true),ignore_ops(false),numbervars(false),variable_names(Names)],
    write_term_to_atom(GoalAtom, Goal, WriteOptions),
    write_term_to_atom(OptionsAtom, Options, WriteOptions).
