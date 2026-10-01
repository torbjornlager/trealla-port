% SPDX-License-Identifier: MIT

:- module(web_prolog,
    [ web_prolog_node/1,
      web_prolog_node/2,
      web_prolog_handler/2,
      web_prolog_handler/3,
      web_prolog_handler/4,
      web_prolog_connect/2,
      web_prolog_connect/3,
      web_prolog_send/2,
      web_prolog_receive/2,
      current_node_url/1,
      protocol_version/1
    ]).

/** <module> Web Prolog actor protocol over native Trealla WebSockets

This is a native Trealla implementation of version 1 of the JSON actor
protocol used by the Trinity demonstrator.  It deliberately has no Logtalk
dependency.  The transport is one JSON object per WebSocket text frame; Prolog
terms inside JSON fields use quoted Prolog syntax.

The module implements the core node-to-node vocabulary: `spawn`, `send`,
`monitor`, `demonitor`, `exit`, `toplevel_spawn`, `toplevel_call`,
`toplevel_next`, `toplevel_stop`, `toplevel_abort`, `toplevel_halt`,
`toplevel_respond`, private acknowledged `io_request` terminal delivery, and
the additive browser `transport_hello` handshake. Browser clients that
negotiate `io_ack:true` receive terminal output as `io_request` events and
must answer with `browser_io_reply`; prompt replies are authorized once and
scoped to the connection that received the prompt.

Node startup accepts Trinity-compatible execution profiles and native Trealla
`off`, `blacklist`, and `whitelist` sandbox modes. Public goals, opaque
meta-calls, asserted clauses, and source-bearing spawn options pass through
the configured policy. Execution/idle time, actor count, page size, and text
input ceilings are enforced independently. HTTP/WebSocket authentication,
browser WebSocket origin policy, and per-connection actor ownership are
enforced by the node boundary. Per-principal request rates, concurrent HTTP
calls, and WebSocket-owned actor counts are governed independently. Managed
bearer tokens support hashed persistence, expiry, and revocation.
Inference/stack ceilings and OS-level containment remain necessary.
*/

:- use_module(library(dcgs)).
:- use_module(library(json)).
:- use_module(actors).
:- use_module(isolation).
:- use_module(profile_policy).
:- use_module(sandbox_policy).
:- use_module(resource_policy).
:- use_module(governance_policy).
:- use_module(observability).
:- use_module(ip_policy, [record_ip_offense_address/1]).
:- use_module(toplevel_actors).
:- use_module(node).
:- use_module(websocket).

:- op(200, xfx, @).

:- multifile actors:hook_send/2.
:- multifile actors:hook_exit/2.
:- multifile hook_io_request/2.
:- multifile hook_terminal_delivery/2.
:- multifile hook_close_browser_io/1.

:- dynamic node_public_url/1.
:- dynamic browser_io_enabled/1.
:- dynamic browser_io_pending/3.
:- dynamic browser_io_prompt/3.
:- dynamic browser_actor_capability/3.

:- catch(mutex_create(_, [alias('$browser_terminal_io')]),
         error(permission_error(create, mutex,
                                '$browser_terminal_io'), _),
         true).

:- catch(mutex_create(_, [alias('$browser_actor_capabilities')]),
         error(permission_error(create, mutex,
                                '$browser_actor_capabilities'), _),
         true).

protocol_version(1).


                 /*******************************
                 *          SERVER API           *
                 *******************************/

%! web_prolog_node(+Port) is det.
%! web_prolog_node(+Port, +Options) is det.

web_prolog_node(Port) :-
    web_prolog_node(Port, []).

web_prolog_node(Port, Options) :-
    option(profile(Profile0), Options, workbench),
    normalize_profile(Profile0, Profile),
    option(sandbox(Sandbox0), Options, blacklist),
    normalize_sandbox_mode(Sandbox0, Sandbox),
    findall(File, member(load_shared_db_file(File), Options), SharedDBFiles),
    configure_shared_db(SharedDBFiles),
    configure_node_url(Port, Options, PublicURL),
    public_url_options(Options, PublicURL, NodeOptions),
    node(Port, web_prolog_handler(Profile, Sandbox), NodeOptions).

configure_node_url(Port, Options, URL) :-
    ( memberchk(node_url(URL0), Options) -> node_url_atom(URL0, URL1)
    ; format(atom(URL1), 'http://127.0.0.1:~w', [Port])
    ),
    strip_url_slash(URL1, URL),
    retractall(node_public_url(_)),
    asserta(node_public_url(URL)).

public_url_options(Options, _, Options) :-
    memberchk(node_url(_), Options), !.
public_url_options(Options, URL, [node_url(URL)|Options]).

node_url_atom(URL, URL) :- atom(URL), !.
node_url_atom(Chars, URL) :- atom_chars(URL, Chars).

strip_url_slash(URL0, URL) :- atom_concat(URL, '/', URL0), !.
strip_url_slash(URL, URL).

current_node_url(URL) :- node_public_url(URL).

%! web_prolog_handler(+WebSocket, +Path) is det.

web_prolog_handler(WS, '/ws') :-
    web_prolog_handler(workbench, blacklist, WS, '/ws').

web_prolog_handler(Profile, WS, '/ws') :-
    web_prolog_handler(Profile, blacklist, WS, '/ws').

web_prolog_handler(Profile, Sandbox, WS, '/ws') :-
    ( node:current_connection_governance(Principal, Identity) -> true
    ; Principal = principal(local, [admin]), Identity = local
    ),
    thread_self(Reader),
    make_ref(NamespaceId),
    Namespace = ws_client(NamespaceId),
    actors:spawn_scoped(
        relay_start(WS, Principal, Identity), Relay,
        [link(false)], Namespace, internal),
    setup_call_cleanup(
        observe_activity_start(ws_connection, Reader, Principal, websocket),
        once(read_loop(WS, Relay, Reader, Profile, Sandbox,
                       Principal, Identity)),
        ( close_connection(Relay),
          observe_activity_end(ws_connection, Reader, disconnected) )
    ).

read_loop(WS, Relay, Reader, Profile, Sandbox, Principal, Identity) :-
    ws_receive(WS, Frame),
    ( Frame = text(Text) ->
        catch(( check_ws_frame_size(Text),
                dispatch_text(Text, Relay, Reader, Profile, Sandbox,
                              Principal, Identity) ), Error,
              ( note_ws_ip_offense(Error), Relay ! protocol_error(Error) )),
        read_loop(WS, Relay, Reader, Profile, Sandbox, Principal, Identity)
    ; Frame = close(Code, Reason) ->
        Relay ! '$peer_close'(Code, Reason)
    ; Frame == end_of_file ->
        true
    ; read_loop(WS, Relay, Reader, Profile, Sandbox, Principal, Identity)
    ).

close_connection(Relay) :-
    close_browser_io(Relay),
    connection_owned_actors(Relay, OwnedActors),
    Relay ! '$ws_close',
    await_actor_threads_stopped([Relay|OwnedActors], 3),
    stop_connection_survivors([Relay|OwnedActors]),
    await_actor_threads_stopped([Relay|OwnedActors], 2).

connection_owned_actors(Relay, Actors) :-
    with_mutex('$browser_actor_capabilities',
        findall(RuntimePid,
                browser_actor_capability(Relay, _, RuntimePid),
                Actors0)),
    sort(Actors0, Actors).

stop_connection_survivors([]).
stop_connection_survivors([Pid|Pids]) :-
    ( actors:actor_thread(Pid, _) -> catch(exit(Pid, connection_closed), _, true)
    ; true
    ),
    stop_connection_survivors(Pids).

await_actor_threads_stopped(Pids, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_actor_threads_stopped_until(Pids, Deadline).

await_actor_threads_stopped_until(Pids, Deadline) :-
    ( actor_threads_stopped(Pids) -> true
    ; get_time(Now),
      ( Now >= Deadline -> true
      ; sleep(0.01),
        await_actor_threads_stopped_until(Pids, Deadline)
      )
    ).

actor_threads_stopped([]).
actor_threads_stopped([Pid|Pids]) :-
    \+ actors:actor_thread(Pid, _),
    actor_threads_stopped(Pids).

note_ws_ip_offense(error(rate_limit_exceeded(_,_,_,_), _)) :- !,
    ( node:current_connection_client_ip(ClientIP)
    -> catch(record_ip_offense_address(ClientIP), _, true)
    ; true
    ).
note_ws_ip_offense(_).


                 /*******************************
                 *        CLIENT HELPERS         *
                 *******************************/

%! web_prolog_connect(+URL, -Connection) is det.
%! web_prolog_connect(+URL, -Connection, +Options) is det.

web_prolog_connect(URL, Connection) :-
    web_prolog_connect(URL, Connection, []).

web_prolog_connect(URL, Connection, Options) :-
    protocol_version(Version),
    format(atom(VersionAtom), '~w', [Version]),
    http_open_websocket(URL, Connection,
                        [header('X-Web-Prolog-Protocol', VersionAtom)|Options]).

%! web_prolog_send(+Connection, +JSON) is det.
%! web_prolog_receive(+Connection, -JSON) is det.
%
%  JSON uses Trealla library(json)'s portable representation: pairs/1,
%  list/1, string/1, number/1, boolean/1 and null.

web_prolog_send(Connection, JSON) :-
    json_atom(JSON, Text),
    ws_send(Connection, text(Text)).

web_prolog_receive(Connection, JSON) :-
    ws_receive(Connection, Frame),
    ( Frame = text(Text) -> json_atom(JSON, Text)
    ; JSON = Frame
    ).


                 /*******************************
                 *          DISPATCH             *
                 *******************************/

dispatch_text(Text, Relay, Reader, Profile, Sandbox, Principal, Identity) :-
    json_atom(JSON, Text),
    json_atom_field(JSON, command, Command),
    observe_request(Principal, websocket, Command,
                    dispatch_governed(Command, JSON, Relay, Reader,
                                      Profile, Sandbox, Principal, Identity)).

dispatch_governed(Command, JSON, Relay, Reader, Profile, Sandbox,
                  Principal, Identity) :-
    enforce_ws_command_rate_limit(Principal, Identity, Command),
    enforce_spawn_rate_limit(Command, Principal, Identity),
    profile_check_command(Profile, Command),
    dispatch(Command, JSON, Relay, Reader, Profile, Sandbox).

enforce_spawn_rate_limit(Command, Principal, Identity) :-
    ( Command == toplevel_spawn
    -> enforce_session_spawn_rate_limit(Principal, Identity)
    ; true
    ).

dispatch(transport_hello, JSON, Relay, Reader, Profile, Sandbox) :- !,
    json_integer_default(JSON, version, 1, Version),
    json_boolean_default(JSON, io_ack, false, IoAck),
    ( Version =:= 1 ->
        Relay ! '$transport_hello'(Version, IoAck, Profile, Sandbox, Reader),
        thread_get_message(Reader, '$transport_ready'(Relay))
    ; throw(error(domain_error(web_prolog_protocol_version, Version),
                  web_prolog_handler/2))
    ).
dispatch(toplevel_spawn, JSON, Relay, _, Profile, Sandbox) :- !,
    json_options(JSON, Options0),
    sandbox_prepare_options(Sandbox, Profile, actor_context,
                            Options0, PreparedOptions),
    safe_spawn_options(PreparedOptions, Options1),
    spawn_io_options(JSON, Relay, Options1, Options),
    thread_self(Reader),
    Relay ! '$toplevel_spawn'(Options, Reader),
    await_relay_spawn(Reader).
dispatch(toplevel_call, JSON, Relay, _, Profile, Sandbox) :- !,
    json_text_field(JSON, goal, GoalText),
    json_text_default(JSON, options, '[]', OptionsText),
    read_goal_options(GoalText, OptionsText, Goal0, Options0),
    import_browser_pids(Goal0-Options0, Relay, Goal-Options),
    sandbox_prepare_spawn(Sandbox, Profile, actor_context, Goal, Options,
                          GuardedGoal, PreparedOptions),
    Relay ! '$toplevel_call'(JSON, GuardedGoal, PreparedOptions).
dispatch(toplevel_next, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(toplevel_next, JSON).
dispatch(toplevel_stop, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(toplevel_stop, JSON).
dispatch(toplevel_abort, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(toplevel_abort, JSON).
dispatch(toplevel_halt, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(toplevel_halt, JSON).
dispatch(toplevel_respond, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(toplevel_respond, JSON).
dispatch(browser_io_reply, JSON, Relay, _, _, _) :- !,
    json_text_field(JSON, request_id, RequestId),
    json_text_field(JSON, status, Status),
    ( memberchk(Status, [ok,error]) ->
        browser_io_reply(Relay, RequestId, Status)
    ; throw(error(domain_error(browser_io_status, Status),
                  web_prolog_handler/2))
    ).
dispatch(spawn, JSON, Relay, Reader, Profile, Sandbox) :- !,
    json_term_field(JSON, goal, Goal0),
    import_browser_pids(Goal0, Relay, Goal),
    json_options(JSON, Options0),
    sandbox_prepare_spawn(Sandbox, Profile, actor_context, Goal, Options0,
                          GuardedGoal, PreparedOptions),
    safe_spawn_options(PreparedOptions, Options1),
    spawn_io_options(JSON, Relay, Options1, Options),
    Relay ! '$spawn'(GuardedGoal, Options, Reader),
    await_relay_spawn(Reader).

await_relay_spawn(Reader) :-
    thread_get_message(Reader, Reply),
    ( Reply = '$spawned'(_) -> true
    ; Reply = '$spawn_failed'(Error) -> throw(Error)
    ; throw(error(unexpected_relay_reply(Reply), web_prolog_handler/2))
    ).
dispatch(send, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(send, JSON).
dispatch(monitor, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(monitor, JSON).
dispatch(demonitor, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(demonitor, JSON).
dispatch(exit, JSON, Relay, _, _, _) :- !,
    Relay ! '$ws_command'(exit, JSON).
dispatch(io_request, JSON, Relay, _, _, _) :- !,
    Relay ! '$io_request'(JSON).
dispatch(Command, _, _, _, _, _) :-
    throw(error(domain_error(web_prolog_command, Command),
                web_prolog_handler/2)).

relay_command(toplevel_call, JSON, Relay) :- !,
    owned_pid(JSON, Relay, session, Pid),
    json_text_field(JSON, goal, GoalText),
    json_text_default(JSON, options, '[]', OptionsText),
    read_goal_options(GoalText, OptionsText, Goal0, Options00),
    import_browser_pids(Goal0-Options00, Relay, Goal-Options0),
    safe_call_options(Options0, Options),
    toplevel_call(Pid, Goal, [target(Relay)|Options]).
relay_command(toplevel_next, JSON, Relay) :- !,
    owned_pid(JSON, Relay, session, Pid),
    ( json_integer_field(JSON, limit, Limit) -> Options = [limit(Limit),target(Relay)]
    ; Options = [target(Relay)]
    ),
    toplevel_next(Pid, Options).
relay_command(toplevel_stop, JSON, Relay) :- !,
    owned_pid(JSON, Relay, session, WirePid, Pid),
    toplevel_stop(Pid),
    Relay ! stop(WirePid).
relay_command(toplevel_abort, JSON, Relay) :- !,
    owned_pid(JSON, Relay, session, WirePid, Pid),
    toplevel_abort(Pid),
    Relay ! abort(WirePid).
relay_command(toplevel_halt, JSON, Relay) :- !,
    owned_pid(JSON, Relay, session, WirePid, Pid),
    relay_add_halt(Pid, WirePid),
    exit(Pid, kill).
relay_command(toplevel_respond, JSON, Relay) :- !,
    json_pid_field(JSON, pid, WirePid),
    json_term_field(JSON, input, Input0),
    import_browser_pids(Input0, Relay, Input),
    ( take_browser_prompt(Relay, WirePid, PromptPid) ->
        actors:actor_send(PromptPid, '$input'(Relay, Input))
    ; owned_pid(JSON, Relay, session, WirePid, Pid),
      actors:actor_send(Pid, '$input'(Relay, Input))
    ),
    Relay ! responded(WirePid).
relay_command(send, JSON, Relay) :- !,
    send_target(JSON, Relay, Target),
    json_term_field(JSON, message, Message0),
    import_browser_pids(Message0, Relay, Message),
    send_to_target(Target, Message).
relay_command(monitor, JSON, Relay) :- !,
    owned_pid(JSON, Relay, any, Pid),
    json_term_field(JSON, ref, Ref),
    relay_add_monitor(Pid, Ref).
relay_command(demonitor, JSON, _Relay) :- !,
    json_term_field(JSON, ref, Ref),
    relay_remove_monitor(Ref).
relay_command(exit, JSON, Relay) :- !,
    owned_pid(JSON, Relay, any, Pid),
    json_term_default(JSON, reason, kill, Reason0),
    import_browser_pids(Reason0, Relay, Reason),
    exit(Pid, Reason).

owned_pid(JSON, Relay, Kind, RuntimePid) :-
    owned_pid(JSON, Relay, Kind, _WirePid, RuntimePid).

owned_pid(JSON, _Relay, Kind, WirePid, RuntimePid) :-
    json_pid_field(JSON, pid, WirePid),
    ( Kind == any -> relay_actor(WirePid, RuntimePid, _)
    ; relay_actor(WirePid, RuntimePid, Kind)
    ), !.
owned_pid(JSON, _, _, WirePid, _) :-
    json_pid_field(JSON, pid, WirePid),
    throw(error(permission_error(access, web_prolog_actor, WirePid),
                web_prolog_handler/2)).

send_target(JSON, _Relay, service(Name)) :-
    json_pid_field(JSON, pid, Name),
    atom(Name),
    actors:published_service_target(Name, _),
    !.
send_target(JSON, Relay, actor(Pid)) :-
    owned_pid(JSON, Relay, any, Pid).

send_to_target(service(Name), Message) :- !,
    actors:send_service(Name, Message).
send_to_target(actor(Pid), Message) :-
    actors:actor_send(Pid, Message).


                 /*******************************
                 *           RELAY               *
                 *******************************/

relay_start(WS, Principal, Identity) :-
    relay_set_actors([]),
    relay_set_monitors([]),
    relay_set_halts([]),
    relay_set_governance(Principal, Identity),
    relay_loop(WS).

relay_loop(WS) :-
    receive({
        '$ws_close' ->
            web_prolog:relay_message(WS, '$ws_close') ;
        Message ->
            ( catch(web_prolog:relay_message(WS, Message), Error,
                    web_prolog:send_event(WS, error(Error))),
              web_prolog:relay_loop(WS)
            )
    }, []).

relay_message(_, '$ws_close') :- !,
    self(Relay),
    close_browser_io(Relay),
    relay_actors(Actors),
    forget_ws_actor_owners(Actors),
    observe_relay_actor_ends(Actors, connection_closed),
    stop_relay_actors(Actors),
    relay_clear_state.
relay_message(WS, '$transport_hello'(Version, IoAck, Profile, Sandbox, Reader)) :- !,
    self(Relay),
    set_browser_io_enabled(Relay, IoAck),
    send_event(WS, transport_welcome(Version, Profile, Sandbox)),
    thread_send_message(Reader, '$transport_ready'(Relay)).
relay_message(WS, '$peer_close'(Code, Reason)) :- !,
    catch(ws_send(WS, close(Code, Reason)), _, true),
    true.
relay_message(WS, '$ws_command'(Command, JSON)) :- !,
    self(Relay),
    catch(relay_command(Command, JSON, Relay), Error,
          send_event(WS, error(Error))).
relay_message(WS, '$toplevel_call'(JSON, Goal, Options0)) :- !,
    self(Relay),
    catch(
        ( owned_pid(JSON, Relay, session, Pid),
          safe_call_options(Options0, Options),
          toplevel_call(Pid, Goal, [target(Relay)|Options])
        ),
        Error,
        send_event(WS, error(Error))).
relay_message(WS, '$toplevel_spawn'(Options, Reader)) :- !,
    self(Relay),
    catch(
        ( relay_reserve_ws_actor(Reservation),
          catch(toplevel_spawn(RuntimePid,
                               [target(Relay),link(false),monitor(true)|Options]),
                SpawnError,
                ( release_capacity_reservation(Reservation),
                  throw(SpawnError) )),
          commit_ws_actor_capacity(Reservation, RuntimePid),
          wire_pid(RuntimePid, WirePid),
          relay_add_actor(WirePid, RuntimePid, session),
          relay_observe_actor_start(session, RuntimePid),
          thread_send_message(Reader, '$spawned'(WirePid)),
          send_event(WS, spawned(WirePid))
        ),
        Error,
        thread_send_message(Reader, '$spawn_failed'(Error))).
relay_message(WS, '$spawn'(Goal, Options, Reader)) :- !,
    catch(
        ( relay_reserve_ws_actor(Reservation),
          catch(spawn(web_prolog:run_spawn_goal(Goal), RuntimePid,
                      ['$entry_context'(caller),link(false),monitor(true)|Options]),
                SpawnError,
                ( release_capacity_reservation(Reservation),
                  throw(SpawnError) )),
          commit_ws_actor_capacity(Reservation, RuntimePid),
          wire_pid(RuntimePid, WirePid),
          relay_add_actor(WirePid, RuntimePid, actor),
          relay_observe_actor_start(actor, RuntimePid),
          thread_send_message(Reader, '$spawned'(WirePid)),
          send_event(WS, spawned(WirePid))
        ),
        Error,
        thread_send_message(Reader, '$spawn_failed'(Error))).

% Calling a conjunction received as data through the module-qualified actor
% trampoline makes current Trealla try to resolve ','/2 after its first arm.
% Walk conjunctions here so browser spawn goals retain ordinary Prolog control
% semantics.
run_spawn_goal((Left, Right)) :- !,
    run_spawn_goal(Left),
    run_spawn_goal(Right).
run_spawn_goal(Goal) :-
    isolation:execution_goal(Goal, ExecutionGoal),
    call(ExecutionGoal).
relay_message(WS, '$browser_message'(Target, Message)) :- !,
    send_event(WS, actor_message(Target, Message)).
relay_message(WS, '$browser_io_request'(RequestId, Message)) :- !,
    self(Relay),
    wire_event(Relay, Message, Event),
    send_event(WS, browser_io_request(RequestId, Event)).
relay_message(WS, '$browser_terminal'(prompt(RuntimePid, Data))) :- !,
    self(Relay),
    browser_source_pid(Relay, RuntimePid, WirePid),
    remember_browser_prompt(Relay, WirePid, RuntimePid),
    send_event(WS, prompt(WirePid, Data)).
relay_message(WS, '$browser_terminal'(Message)) :- !,
    self(Relay),
    wire_event(Relay, Message, Event),
    send_event(WS, Event).
relay_message(WS, '$io_request'(JSON)) :- !,
    json_text_field(JSON, request_id, RequestId),
    json_text_field(JSON, token, Token),
    json_term_field(JSON, message, Message0),
    self(Relay),
    import_browser_pids(Message0, Relay, Message),
    ( catch(once(hook_io_request(Token, Message)), _, fail) -> Status = ok
    ; Status = endpoint_unavailable
    ),
    send_event(WS, io_reply(RequestId, Status)).
relay_message(WS, down(RuntimePid, _DefaultRef, Reason)) :- !,
    ( relay_actor(WirePid, RuntimePid, ActorKind) ->
        relay_take_monitors(RuntimePid, Refs),
        ( Refs == [] -> send_event(WS, down(WirePid, WirePid, Reason))
        ; send_down_events(WS, WirePid, Refs, Reason)
        ),
        ( relay_take_halt(RuntimePid, HaltWirePid) ->
            send_event(WS, halted(HaltWirePid, true))
        ; true
        ),
        relay_remove_actor(WirePid),
        forget_ws_actor_owner(RuntimePid),
        actor_activity_kind(ActorKind, ActivityKind),
        observe_activity_end(ActivityKind, RuntimePid, Reason)
    ; true
    ).
relay_message(WS, protocol_error(Error)) :- !,
    send_event(WS, error(Error)).
relay_message(WS, prompt(RuntimePid, Data)) :- !,
    self(Relay),
    browser_source_pid(Relay, RuntimePid, WirePid),
    remember_browser_prompt(Relay, WirePid, RuntimePid),
    send_event(WS, prompt(WirePid, Data)).
relay_message(WS, Event) :-
    self(Relay),
    wire_event(Relay, Event, WireEvent),
    send_event(WS, WireEvent).

wire_event(Relay, success(RuntimePid, Rows0, More),
           success(WirePid, Rows, More)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid),
    export_browser_pids(Rows0, Relay, Rows).
wire_event(Relay, failure(RuntimePid), failure(WirePid)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, error(RuntimePid, Error), error(WirePid, Error)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, output(RuntimePid, Data), output(WirePid, Data)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, prompt(RuntimePid, Data), prompt(WirePid, Data)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, terminal_output(RuntimePid, Data), output(WirePid, Data)) :- !,
    browser_source_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, terminal_io_output(RuntimePid, Data), output(WirePid, Data)) :- !,
    browser_source_pid(Relay, RuntimePid, WirePid).
wire_event(_, Event, Event).

browser_source_pid(_Relay, RuntimePid, WirePid) :-
    relay_actor(WirePid, RuntimePid, _),
    !.
browser_source_pid(_, '$web_prolog_endpoint'(_, Id), Id@localhost) :- !.
browser_source_pid(_, RuntimePid, RuntimePid).

runtime_connection_pid(_Relay, RuntimePid, WirePid) :-
    relay_actor(WirePid, RuntimePid, _), !.
runtime_connection_pid(_, RuntimePid, _) :-
    throw(error(existence_error(web_prolog_actor, RuntimePid), relay_loop/1)).

fresh_wire_pid(WirePid) :-
    repeat,
    random_between(1000000000, 9999999999, Candidate),
    \+ relay_actor(Candidate, _, _),
    \+ browser_actor_capability(_, Candidate, _),
    !,
    WirePid = Candidate.

wire_pid(RuntimePid, RuntimePid) :-
    integer(RuntimePid),
    RuntimePid >= 1000000000,
    RuntimePid =< 9999999999,
    !.
wire_pid(_, WirePid) :-
    fresh_wire_pid(WirePid).

relay_actors(Actors) :-
    relay_state_key(actors, Key),
    ( bb_get(Key, Actors) -> true ; Actors = [] ).

relay_set_actors(Actors) :-
    relay_state_key(actors, Key),
    bb_put(Key, Actors).

relay_actor(WirePid, RuntimePid, Kind) :-
    relay_actors(Actors), memberchk(actor(WirePid, RuntimePid, Kind), Actors).

relay_add_actor(WirePid, RuntimePid, Kind) :-
    relay_actors(Actors),
    relay_set_actors([actor(WirePid, RuntimePid, Kind)|Actors]),
    thread_self(Relay),
    with_mutex('$browser_actor_capabilities',
               assertz(browser_actor_capability(Relay, WirePid, RuntimePid))).

relay_remove_actor(WirePid) :-
    relay_actors(Actors),
    exclude(wire_actor(WirePid), Actors, Rest),
    relay_set_actors(Rest),
    thread_self(Relay),
    with_mutex('$browser_actor_capabilities',
               retractall(browser_actor_capability(Relay, WirePid, _))).

wire_actor(WirePid, actor(WirePid, _, _)).

stop_relay_actors(Actors) :-
    relay_actor_pids(Actors, RuntimePids),
    stop_relay_actor_pids(RuntimePids),
    await_actor_threads_stopped(RuntimePids, 2).

relay_actor_pids([], []).
relay_actor_pids([actor(_, RuntimePid, _)|Actors], [RuntimePid|Pids]) :-
    relay_actor_pids(Actors, Pids).

stop_relay_actor_pids([]).
stop_relay_actor_pids([RuntimePid|Actors]) :-
    catch(exit(RuntimePid, connection_closed), _, true),
    stop_relay_actor_pids(Actors).

relay_monitors(Monitors) :-
    relay_state_key(monitors, Key),
    ( bb_get(Key, Monitors) -> true ; Monitors = [] ).

relay_set_monitors(Monitors) :-
    relay_state_key(monitors, Key),
    bb_put(Key, Monitors).

relay_add_monitor(RuntimePid, Ref) :-
    relay_monitors(Monitors),
    ( memberchk(monitor(RuntimePid, Ref), Monitors) -> true
    ; relay_set_monitors([monitor(RuntimePid, Ref)|Monitors])
    ).

relay_remove_monitor(Ref) :-
    relay_monitors(Monitors),
    exclude(monitor_ref(Ref), Monitors, Rest),
    relay_set_monitors(Rest).

monitor_ref(Ref, monitor(_, Ref)).

relay_take_monitors(RuntimePid, Refs) :-
    relay_monitors(Monitors),
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest),
    relay_set_monitors(Rest).

take_runtime_monitors([], _, [], []).
take_runtime_monitors([monitor(RuntimePid, Ref)|Monitors], RuntimePid,
                      [Ref|Refs], Rest) :- !,
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest).
take_runtime_monitors([Monitor|Monitors], RuntimePid, Refs, [Monitor|Rest]) :-
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest).

relay_add_halt(RuntimePid, WirePid) :-
    relay_halts(Halts),
    relay_set_halts([halt(RuntimePid, WirePid)|Halts]).

relay_take_halt(RuntimePid, WirePid) :-
    relay_halts(Halts),
    select(halt(RuntimePid, WirePid), Halts, Rest), !,
    relay_set_halts(Rest).

relay_halts(Halts) :-
    relay_state_key(halts, Key),
    ( bb_get(Key, Halts) -> true ; Halts = [] ).

relay_set_halts(Halts) :-
    relay_state_key(halts, Key),
    bb_put(Key, Halts).

relay_state_key(Kind, Key) :-
    thread_self(Relay),
    format(atom(Key), '$web_prolog_~w_~w', [Kind, Relay]).

relay_set_governance(Principal, Identity) :-
    relay_state_key(governance, Key),
    bb_put(Key, governance(Principal, Identity)).

relay_governance(Principal, Identity) :-
    relay_state_key(governance, Key),
    bb_get(Key, governance(Principal, Identity)).

relay_reserve_ws_actor(Reservation) :-
    relay_governance(Principal, Identity),
    reserve_ws_actor_capacity(Principal, Identity, Reservation).

relay_observe_actor_start(ActorKind, RuntimePid) :-
    relay_governance(Principal, _),
    actor_activity_kind(ActorKind, ActivityKind),
    observe_activity_start(ActivityKind, RuntimePid, Principal, websocket).

actor_activity_kind(session, isotope_session).
actor_activity_kind(actor, ws_actor).

observe_relay_actor_ends([], _).
observe_relay_actor_ends([actor(_,RuntimePid,ActorKind)|Actors], Reason) :-
    actor_activity_kind(ActorKind, ActivityKind),
    observe_activity_end(ActivityKind, RuntimePid, Reason),
    observe_relay_actor_ends(Actors, Reason).

relay_clear_state :-
    thread_self(Relay),
    with_mutex('$browser_actor_capabilities',
               retractall(browser_actor_capability(Relay, _, _))),
    relay_delete_state(actors),
    relay_delete_state(monitors),
    relay_delete_state(halts),
    relay_delete_state(governance).

relay_delete_state(Kind) :-
    relay_state_key(Kind, Key),
    ( bb_delete(Key, _) -> true ; true ).

send_down_events(_, _, [], _).
send_down_events(WS, Pid, [Ref|Refs], Reason) :-
    send_event(WS, down(Pid, Ref, Reason)),
    send_down_events(WS, Pid, Refs, Reason).

send_event(WS, Event) :-
    event_json(Event, JSON),
    web_prolog_send(WS, JSON).


                 /*******************************
                 *       EVENT SERIALIZATION     *
                 *******************************/

event_json(success(Pid, Rows, More), JSON) :- !,
    answer_rows_json(Rows, Data),
    object([type-string_atom(success), pid-json_pid(Pid),
            data-list(Data), more-boolean(More)], JSON).
event_json(failure(Pid), JSON) :- !,
    object([type-string_atom(failure), pid-json_pid(Pid)], JSON).
event_json(error(Pid, Error), JSON) :- !,
    term_wire_atom(Error, Data),
    object([type-string_atom(error), pid-json_pid(Pid), data-string_atom(Data)], JSON).
event_json(error(Error), JSON) :- !,
    term_wire_atom(Error, Data),
    object([type-string_atom(error), data-string_atom(Data)], JSON).
event_json(output(Pid, Data0), JSON) :- !,
    display_atom(Data0, Data),
    object([type-string_atom(output), pid-json_pid(Pid), data-string_atom(Data)], JSON).
event_json(prompt(Pid, Data0), JSON) :- !,
    display_atom(Data0, Data),
    object([type-string_atom(prompt), pid-json_pid(Pid), data-string_atom(Data)], JSON).
event_json(spawned(Pid), JSON) :- !,
    object([type-string_atom(spawned), pid-json_pid(Pid)], JSON).
event_json(stop(Pid), JSON) :- !,
    object([type-string_atom(stop), pid-json_pid(Pid)], JSON).
event_json(abort(Pid), JSON) :- !,
    object([type-string_atom(abort), pid-json_pid(Pid)], JSON).
event_json(responded(Pid), JSON) :- !,
    object([type-string_atom(responded), pid-json_pid(Pid)], JSON).
event_json(halted(Pid, Reply), JSON) :- !,
    term_wire_atom(Reply, ReplyText),
    object([type-string_atom(halted), pid-json_pid(Pid),
            reply-string_atom(ReplyText)], JSON).
event_json(down(Pid, Ref, Reason), JSON) :- !,
    term_wire_atom(Reason, ReasonText),
    object([type-string_atom(down), pid-json_pid(Pid), ref-json_pid(Ref),
            reason-string_atom(ReasonText)], JSON).
event_json(transport_welcome(Version), JSON) :- !,
    event_json(transport_welcome(Version, workbench, blacklist), JSON).
event_json(transport_welcome(Version, Profile), JSON) :- !,
    event_json(transport_welcome(Version, Profile, blacklist), JSON).
event_json(transport_welcome(Version, Profile, Sandbox), JSON) :- !,
    object([type-string_atom(transport_welcome),
            protocol-string_atom(web_prolog_browser_actor),
            io_ack-boolean(true), browser_pids-boolean(true),
            profile-string_atom(Profile),
            sandbox-string_atom(Sandbox),
            version-number(Version)], JSON).
event_json(actor_message(Target, Message), JSON) :- !,
    term_wire_atom(Target, TargetText),
    term_wire_atom(Message, MessageText),
    object([type-string_atom(actor_message), target-string_atom(TargetText),
            message-string_atom(MessageText)], JSON).
event_json(io_reply(RequestId, Status), JSON) :- !,
    object([type-string_atom(io_reply),request_id-string_atom(RequestId),
            status-string_atom(Status)], JSON).
event_json(browser_io_request(RequestId, Event), JSON) :- !,
    event_json(Event, EventJSON),
    object([type-string_atom(io_request),request_id-string_atom(RequestId),
            event-EventJSON], JSON).
event_json(Event, JSON) :-
    term_wire_atom(Event, Data),
    object([type-string_atom(error), data-string_atom(Data)], JSON).


                 /*******************************
                 *     BROWSER PID BRIDGING      *
                 *******************************/

actors:hook_send('$web_prolog_endpoint'(Relay, Id), Message) :-
    actors:actor_thread(Relay, Thread),
    catch(thread_property(Thread, status(running)), _, fail),
    Relay ! '$browser_message'(Id@localhost, Message).

actors:hook_send(WirePid, Message) :-
    integer(WirePid),
    WirePid >= 1000000000,
    WirePid =< 9999999999,
    with_mutex('$browser_actor_capabilities',
               browser_actor_capability(_, WirePid, RuntimePid)),
    WirePid \== RuntimePid,
    actors:actor_send(RuntimePid, Message).

actors:hook_exit(WirePid, Reason) :-
    integer(WirePid),
    WirePid >= 1000000000,
    WirePid =< 9999999999,
    with_mutex('$browser_actor_capabilities',
               browser_actor_capability(_, WirePid, RuntimePid)),
    WirePid \== RuntimePid,
    actors:exit(RuntimePid, Reason).

actors:hook_send('$browser_io'(Relay), Message) :-
    !,
    browser_terminal_delivery(Relay, Message).

hook_terminal_delivery('$browser_io'(Relay), Message) :-
    browser_terminal_delivery(Relay, Message).

browser_terminal_delivery(Relay, Message) :-
    browser_output_message(Message),
    !,
    browser_request_id(RequestId),
    setup_call_cleanup(
        message_queue_create(ReplyQueue),
        ( register_browser_io_request(Relay, RequestId, ReplyQueue),
          Relay ! '$browser_io_request'(RequestId, Message),
          ( thread_get_message(ReplyQueue, Status, [timeout(30)]) ->
              browser_io_result(Status)
          ; browser_io_result(timeout)
          )
        ),
        ( unregister_browser_io_request(Relay, RequestId),
          catch(message_queue_destroy(ReplyQueue), _, true)
        )
    ).
browser_terminal_delivery(Relay, Message) :-
    browser_io_is_enabled(Relay),
    Relay ! '$browser_terminal'(Message).

browser_output_message(terminal_output(_, _)).
browser_output_message(terminal_io_output(_, _)).

browser_request_id(RequestId) :-
    make_ref(N),
    format(atom(RequestId), 'browser-~w', [N]).

browser_io_result(ok) :- !.
browser_io_result(Reason) :-
    throw(error(io_error(write, Reason), terminal_output/2)).

set_browser_io_enabled(Relay, true) :- !,
    with_mutex('$browser_terminal_io',
        ( browser_io_enabled(Relay) -> true
        ; assertz(browser_io_enabled(Relay))
        )).
set_browser_io_enabled(Relay, false) :-
    close_browser_io(Relay).

browser_io_is_enabled(Relay) :-
    with_mutex('$browser_terminal_io', browser_io_enabled(Relay)).

register_browser_io_request(Relay, RequestId, ReplyQueue) :-
    with_mutex('$browser_terminal_io',
        ( browser_io_enabled(Relay) ->
            assertz(browser_io_pending(Relay, RequestId, ReplyQueue))
        ; browser_io_result(connection_closed)
        )).

unregister_browser_io_request(Relay, RequestId) :-
    with_mutex('$browser_terminal_io',
               retractall(browser_io_pending(Relay, RequestId, _))).

browser_io_reply(Relay, RequestId, Status) :-
    with_mutex('$browser_terminal_io',
        ( retract(browser_io_pending(Relay, RequestId, ReplyQueue)) ->
            catch(thread_send_message(ReplyQueue, Status), _, true)
        ; true
        )).

remember_browser_prompt(Relay, WirePid, RuntimePid) :-
    with_mutex('$browser_terminal_io',
        ( retractall(browser_io_prompt(Relay, WirePid, _)),
          assertz(browser_io_prompt(Relay, WirePid, RuntimePid))
        )).

take_browser_prompt(Relay, WirePid, RuntimePid) :-
    with_mutex('$browser_terminal_io',
               retract(browser_io_prompt(Relay, WirePid, RuntimePid))).

close_browser_io(Relay) :-
    with_mutex('$browser_terminal_io',
        ( retractall(browser_io_enabled(Relay)),
          retractall(browser_io_prompt(Relay, _, _)),
          findall(ReplyQueue,
                  retract(browser_io_pending(Relay, _, ReplyQueue)),
                  ReplyQueues)
        )),
    wake_browser_io_requests(ReplyQueues),
    forall(hook_close_browser_io(Relay), true).

wake_browser_io_requests([]).
wake_browser_io_requests([ReplyQueue|ReplyQueues]) :-
    catch(thread_send_message(ReplyQueue, connection_closed), _, true),
    wake_browser_io_requests(ReplyQueues).

export_browser_pids(Term0, _Relay, WirePid@Node) :-
    nonvar(Term0),
    relay_actor(WirePid, Term0, _),
    current_node_url(Node),
    !.
export_browser_pids(Term0, _Relay, Term0@Node) :-
    nonvar(Term0),
    actors:actor_thread(Term0, _),
    current_node_url(Node),
    !.
export_browser_pids(Term, _, Term) :- var(Term), !.
export_browser_pids(Term, _, Term) :- atomic(Term), !.
export_browser_pids(Term0, Relay, Term) :-
    functor(Term0, Name, Arity),
    functor(Term, Name, Arity),
    export_browser_pid_args(1, Arity, Relay, Term0, Term).

export_browser_pid_args(Index, Arity, _, _, _) :- Index > Arity, !.
export_browser_pid_args(Index, Arity, Relay, Term0, Term) :-
    arg(Index, Term0, Arg0),
    export_browser_pids(Arg0, Relay, Arg),
    arg(Index, Term, Arg),
    Next is Index + 1,
    export_browser_pid_args(Next, Arity, Relay, Term0, Term).

import_browser_pids(Term0, Relay, Term) :-
    ( local_server_wire_pid(Term0, Relay, RuntimePid) ->
        Term = RuntimePid
    ; browser_wire_pid(Term0, Id) ->
        Term = '$web_prolog_endpoint'(Relay, Id)
    ; var(Term0) -> Term = Term0
    ; atomic(Term0) -> Term = Term0
    ; functor(Term0, Name, Arity),
      functor(Term, Name, Arity),
      import_browser_pid_args(1, Arity, Relay, Term0, Term)
    ).

browser_wire_pid(Id@localhost, Id) :-
    integer(Id), Id >= 1000000000, Id =< 9999999999.

local_server_wire_pid(Id@Node, _Relay, RuntimePid) :-
    integer(Id), Id >= 1000000000, Id =< 9999999999,
    current_node_url(Node),
    ( relay_actor(Id, RuntimePid, _) -> true ; RuntimePid = Id ).

import_browser_pid_args(Index, Arity, _, _, _) :- Index > Arity, !.
import_browser_pid_args(Index, Arity, Relay, Term0, Term) :-
    arg(Index, Term0, Arg0),
    import_browser_pids(Arg0, Relay, Arg),
    arg(Index, Term, Arg),
    Next is Index + 1,
    import_browser_pid_args(Next, Arity, Relay, Term0, Term).

answer_rows_json([], []).
answer_rows_json([json_bindings(Bindings)|Rows], [JSON|JSONRows]) :- !,
    binding_json_fields(Bindings, Fields),
    object(Fields, JSON),
    answer_rows_json(Rows, JSONRows).
answer_rows_json([Term|Rows], [string(Chars)|JSONRows]) :-
    term_wire_atom(Term, Atom), atom_chars(Atom, Chars),
    answer_rows_json(Rows, JSONRows).

binding_json_fields(Bindings, Fields) :-
    binding_json_fields_(Bindings, Bindings, Fields).

binding_json_fields_([], _, []).
binding_json_fields_([Name=Value|Bindings], VarNames,
                     [Name-string_atom(Text)|Fields]) :-
    named_term_wire_atom(Value, VarNames, Text),
    binding_json_fields_(Bindings, VarNames, Fields).

named_term_wire_atom(Term, NamedVars, Atom) :-
    % Match SWI's binding serializer: retain query-variable names and render
    % variables introduced only inside an answer term as anonymous.
    term_variables(Term, Variables),
    anonymous_variable_names(Variables, NamedVars, AnonymousVars),
    append(NamedVars, AnonymousVars, VariableNames),
    with_output_to(atom(Atom),
                   write_term(Term, [quoted(true),
                                     variable_names(VariableNames)])).

anonymous_variable_names([], _, []).
anonymous_variable_names([Var|Vars], NamedVars, Names) :-
    ( named_variable(Var, NamedVars)
    -> Names = Rest
    ; Names = ['_'=Var|Rest]
    ),
    anonymous_variable_names(Vars, NamedVars, Rest).

named_variable(Var, [_Name=Value|_]) :-
    var(Value), Var == Value, !.
named_variable(Var, [_|Bindings]) :-
    named_variable(Var, Bindings).

object(Fields, pairs(Pairs)) :- fields_pairs(Fields, Pairs).

fields_pairs([], []).
fields_pairs([Key-Value0|Fields], [string(KeyChars)-Value|Pairs]) :-
    atom_chars(Key, KeyChars), json_value(Value0, Value),
    fields_pairs(Fields, Pairs).

json_value(string_atom(Atom), string(Chars)) :- !, atom_chars(Atom, Chars).
json_value(json_pid(Pid), Value) :- !, json_pid(Pid, Value).
json_value(Value, Value).

json_pid(Pid, number(Pid)) :- integer(Pid), !.
json_pid(Pid, string(Chars)) :- term_wire_atom(Pid, Atom), atom_chars(Atom, Chars).


                 /*******************************
                 *       JSON / TERM HELPERS     *
                 *******************************/

json_atom(JSON, Atom) :-
    var(JSON), !,
    atom_chars(Atom, Chars),
    phrase(json_chars(JSON), Chars).
json_atom(JSON, Atom) :-
    phrase(json_chars(JSON), Chars),
    atom_chars(Atom, Chars).

json_field(pairs(Pairs), Key, Value) :-
    atom_chars(Key, KeyChars),
    memberchk(string(KeyChars)-Value, Pairs).

json_atom_field(JSON, Key, Atom) :-
    json_text_field(JSON, Key, Atom).

json_text_field(JSON, Key, Atom) :-
    json_field(JSON, Key, string(Chars)), atom_chars(Atom, Chars).

json_text_default(JSON, Key, Default, Atom) :-
    ( json_text_field(JSON, Key, Found) -> Atom = Found ; Atom = Default ).

json_integer_field(JSON, Key, Number) :-
    json_field(JSON, Key, number(Number)), integer(Number).

json_integer_default(JSON, Key, Default, Number) :-
    ( json_integer_field(JSON, Key, Found) -> Number = Found ; Number = Default ).

json_boolean_default(JSON, Key, Default, Boolean) :-
    ( json_field(JSON, Key, boolean(Found)), memberchk(Found, [true,false]) ->
        Boolean = Found
    ; Boolean = Default
    ).

json_pid_field(JSON, Key, Pid) :-
    json_field(JSON, Key, Value),
    ( Value = number(Pid), integer(Pid)
    ; Value = string(Chars), atom_chars(Text, Chars), read_term_from_atom(Text, Pid, [])
    ).

json_term_field(JSON, Key, Term) :-
    json_text_field(JSON, Key, Text),
    check_term_text_size(Key, Text),
    normalize_wire_quoted_newlines(Text, Normalized),
    read_term_from_atom(Normalized, Term, []).

json_term_default(JSON, Key, Default, Term) :-
    ( json_term_field(JSON, Key, Found) -> Term = Found ; Term = Default ).

json_options(JSON, Options) :-
    json_text_default(JSON, options, '[]', Text),
    check_term_text_size(options, Text),
    normalize_wire_quoted_newlines(Text, Normalized),
    read_term_from_atom(Normalized, Options, []),
    must_be(list, Options).

read_goal_options(GoalText, OptionsText, Goal, Options) :-
    check_term_text_size(goal, GoalText),
    check_term_text_size(options, OptionsText),
    normalize_wire_quoted_newlines(GoalText, NormalizedGoal),
    normalize_wire_quoted_newlines(OptionsText, NormalizedOptions),
    format(atom(Text), '(~w)-(~w)', [NormalizedGoal, NormalizedOptions]),
    read_term_from_atom(Text, Goal-Options0, [variable_names(Bindings0)]),
    must_be(list, Options0),
    named_bindings(Bindings0, Bindings),
    exclude(template_option, Options0, CallOptions),
    Options = [template(json_bindings(Bindings))|CallOptions].

% SWI accepts physical line breaks inside quoted atoms and strings.  Trealla
% v3.12.6 reports unterminated_quoted_atom instead, although it accepts the
% equivalent \n escape.  Normalize only quoted regions at the protocol
% boundary; comments, character-code syntax, and ordinary multiline layout
% remain byte-for-byte unchanged.
normalize_wire_quoted_newlines(Text, Normalized) :-
    atom_codes(Text, Codes),
    normalize_wire_codes(Codes, plain, NormalizedCodes),
    atom_codes(Normalized, NormalizedCodes).

normalize_wire_codes([], _, []).
normalize_wire_codes([0'%|Codes], plain, [0'%|Normalized]) :- !,
    normalize_wire_codes(Codes, line_comment, Normalized).
normalize_wire_codes([0'/,0'*|Codes], plain, [0'/,0'*|Normalized]) :- !,
    normalize_wire_codes(Codes, block_comment, Normalized).
normalize_wire_codes([48,39,92,C|Codes], plain,
                     [48,39,92,C|Normalized]) :- !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([48,39,C|Codes], plain,
                     [48,39,C|Normalized]) :- !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([Quote|Codes], plain, [Quote|Normalized]) :-
    wire_quote(Quote), !,
    normalize_wire_codes(Codes, quoted(Quote), Normalized).
normalize_wire_codes([C|Codes], plain, [C|Normalized]) :-
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([13,10|Codes], line_comment, [13,10|Normalized]) :- !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([C|Codes], line_comment, [C|Normalized]) :-
    ( C =:= 10 ; C =:= 13 ), !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([C|Codes], line_comment, [C|Normalized]) :-
    normalize_wire_codes(Codes, line_comment, Normalized).
normalize_wire_codes([0'*,0'/|Codes], block_comment, [0'*,0'/|Normalized]) :- !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([C|Codes], block_comment, [C|Normalized]) :-
    normalize_wire_codes(Codes, block_comment, Normalized).
normalize_wire_codes([92,C|Codes], quoted(Quote),
                     [92,C|Normalized]) :- !,
    normalize_wire_codes(Codes, quoted(Quote), Normalized).
normalize_wire_codes([Quote,Quote|Codes], quoted(Quote),
                     [Quote,Quote|Normalized]) :- !,
    normalize_wire_codes(Codes, quoted(Quote), Normalized).
normalize_wire_codes([Quote|Codes], quoted(Quote), [Quote|Normalized]) :- !,
    normalize_wire_codes(Codes, plain, Normalized).
normalize_wire_codes([13,10|Codes], quoted(Quote),
                     [92,110|Normalized]) :- !,
    normalize_wire_codes(Codes, quoted(Quote), Normalized).
normalize_wire_codes([C|Codes], quoted(Quote),
                     [92,110|Normalized]) :-
    ( C =:= 10 ; C =:= 13 ), !,
    normalize_wire_codes(Codes, quoted(Quote), Normalized).
normalize_wire_codes([C|Codes], quoted(Quote), [C|Normalized]) :-
    normalize_wire_codes(Codes, quoted(Quote), Normalized).

wire_quote(39).
wire_quote(34).
wire_quote(96).

template_option(template(_)).

named_bindings([], []).
named_bindings([Name=Value|Bindings], Named) :-
    ( anonymous_variable_name(Name)
    -> Named = Rest
    ; Named = [Name=Value|Rest]
    ),
    named_bindings(Bindings, Rest).

anonymous_variable_name(Name) :-
    atom_chars(Name, ['_'|_]).

safe_spawn_options(Options0, Options) :-
    exclude(reserved_spawn_option, Options0, Options).

spawn_io_options(JSON, _Relay, Options0, [io_target(Endpoint)|Options0]) :-
    json_term_field(JSON, io_target, Endpoint),
    valid_io_endpoint(Endpoint),
    !.
spawn_io_options(JSON, _Relay, _, _) :-
    json_field(JSON, io_target, _),
    !,
    throw(error(domain_error(distributed_io_endpoint, io_target),
                web_prolog_handler/2)).
spawn_io_options(_, Relay, Options, [io_target('$browser_io'(Relay))|Options]) :-
    browser_io_is_enabled(Relay),
    !.
spawn_io_options(_, Relay, Options, [io_target(Relay)|Options]).

valid_io_endpoint('$io_endpoint'(Token)@HomeNode) :-
    atom(Token), atom(HomeNode).

reserved_spawn_option(target(_)).
reserved_spawn_option(link(_)).
reserved_spawn_option(monitor(_)).
reserved_spawn_option(node(_)).
reserved_spawn_option(io_target(_)).

safe_call_options(Options0, Options) :-
    exclude(reserved_call_option, Options0, Options).

reserved_call_option(target(_)).

term_wire_atom(Term, Atom) :-
    copy_term(Term, Copy), numbervars(Copy, 0, _),
    format(atom(Atom), '~q', [Copy]).

display_atom(Term, Atom) :- atom(Term), !, Atom = Term.
display_atom(Term, Atom) :- string(Term), !, atom_string(Atom, Term).
display_atom(Term, Atom) :- term_wire_atom(Term, Atom).
