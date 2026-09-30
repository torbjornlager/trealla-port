% SPDX-License-Identifier: MIT

:- module(web_prolog,
    [ web_prolog_node/1,
      web_prolog_node/2,
      web_prolog_handler/2,
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
the additive browser `transport_hello` handshake.

This first port is intended for trusted peers.  Unlike the Trinity node it
does not yet implement authentication, origin checks, execution profiles,
resource quotas, or a source-code sandbox.
*/

:- use_module(library(dcgs)).
:- use_module(library(json)).
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(node).
:- use_module(websocket).

:- op(200, xfx, @).

:- multifile actors:hook_send/2.
:- multifile hook_io_request/2.

:- dynamic node_public_url/1.

protocol_version(1).


                 /*******************************
                 *          SERVER API           *
                 *******************************/

%! web_prolog_node(+Port) is det.
%! web_prolog_node(+Port, +Options) is det.

web_prolog_node(Port) :-
    web_prolog_node(Port, []).

web_prolog_node(Port, Options) :-
    configure_node_url(Port, Options),
    node(Port, web_prolog_handler, Options).

configure_node_url(Port, Options) :-
    ( memberchk(node_url(URL0), Options) -> node_url_atom(URL0, URL1)
    ; format(atom(URL1), 'http://127.0.0.1:~w', [Port])
    ),
    strip_url_slash(URL1, URL),
    retractall(node_public_url(_)),
    asserta(node_public_url(URL)).

node_url_atom(URL, URL) :- atom(URL), !.
node_url_atom(Chars, URL) :- atom_chars(URL, Chars).

strip_url_slash(URL0, URL) :- atom_concat(URL, '/', URL0), !.
strip_url_slash(URL, URL).

current_node_url(URL) :- node_public_url(URL).

%! web_prolog_handler(+WebSocket, +Path) is det.

web_prolog_handler(WS, '/ws') :-
    thread_self(Reader),
    spawn(relay_start(WS), Relay, [link(false)]),
    setup_call_cleanup(
        true,
        read_loop(WS, Relay, Reader),
        close_connection(Relay)
    ).

read_loop(WS, Relay, Reader) :-
    ws_receive(WS, Frame),
    ( Frame = text(Text) ->
        catch(dispatch_text(Text, Relay, Reader), Error,
              Relay ! protocol_error(Error)),
        read_loop(WS, Relay, Reader)
    ; Frame = close(Code, Reason) ->
        Relay ! '$peer_close'(Code, Reason, Reader),
        thread_get_message(Reader, '$peer_closed'(Relay))
    ; Frame == end_of_file ->
        true
    ; read_loop(WS, Relay, Reader)
    ).

close_connection(Relay) :-
    Relay ! '$ws_close'.


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

dispatch_text(Text, Relay, Reader) :-
    json_atom(JSON, Text),
    json_atom_field(JSON, command, Command),
    dispatch(Command, JSON, Relay, Reader).

dispatch(transport_hello, JSON, Relay, _) :- !,
    json_integer_default(JSON, version, 1, Version),
    ( Version =:= 1 -> Relay ! transport_welcome(1)
    ; throw(error(domain_error(web_prolog_protocol_version, Version),
                  web_prolog_handler/2))
    ).
dispatch(toplevel_spawn, JSON, Relay, _) :- !,
    json_options(JSON, Options0),
    safe_spawn_options(Options0, Options1),
    spawn_io_options(JSON, Options1, Options),
    thread_self(Reader),
    Relay ! '$toplevel_spawn'(Options, Reader),
    thread_get_message(Reader, '$spawned'(_WirePid)).
dispatch(toplevel_call, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_call, JSON).
dispatch(toplevel_next, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_next, JSON).
dispatch(toplevel_stop, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_stop, JSON).
dispatch(toplevel_abort, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_abort, JSON).
dispatch(toplevel_halt, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_halt, JSON).
dispatch(toplevel_respond, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(toplevel_respond, JSON).
dispatch(spawn, JSON, Relay, Reader) :- !,
    json_term_field(JSON, goal, Goal0),
    import_browser_pids(Goal0, Relay, Goal),
    json_options(JSON, Options0),
    safe_spawn_options(Options0, Options1),
    spawn_io_options(JSON, Options1, Options),
    Relay ! '$spawn'(Goal, Options, Reader),
    thread_get_message(Reader, '$spawned'(_Pid)).
dispatch(send, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(send, JSON).
dispatch(monitor, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(monitor, JSON).
dispatch(demonitor, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(demonitor, JSON).
dispatch(exit, JSON, Relay, _) :- !,
    Relay ! '$ws_command'(exit, JSON).
dispatch(io_request, JSON, Relay, _) :- !,
    Relay ! '$io_request'(JSON).
dispatch(Command, _, _, _) :-
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
    owned_pid(JSON, Relay, session, WirePid, Pid),
    json_term_field(JSON, input, Input0),
    import_browser_pids(Input0, Relay, Input),
    actors:actor_send(Pid, '$input'(Relay, Input)),
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

relay_start(WS) :-
    bb_put('$web_prolog_actors', []),
    bb_put('$web_prolog_monitors', []),
    bb_put('$web_prolog_halts', []),
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
    relay_actors(Actors),
    stop_relay_actors(Actors),
    bb_put('$web_prolog_actors', []),
    bb_put('$web_prolog_monitors', []),
    bb_put('$web_prolog_halts', []).
relay_message(WS, '$peer_close'(Code, Reason, Reader)) :- !,
    self(Relay),
    catch(ws_send(WS, close(Code, Reason)), _, true),
    thread_send_message(Reader, '$peer_closed'(Relay)).
relay_message(WS, '$ws_command'(Command, JSON)) :- !,
    self(Relay),
    catch(relay_command(Command, JSON, Relay), Error,
          send_event(WS, error(Error))).
relay_message(WS, '$toplevel_spawn'(Options, Reader)) :- !,
    self(Relay),
    toplevel_spawn(RuntimePid, [target(Relay),link(false),monitor(true)|Options]),
    fresh_wire_pid(WirePid),
    relay_add_actor(WirePid, RuntimePid, session),
    thread_send_message(Reader, '$spawned'(WirePid)),
    send_event(WS, spawned(WirePid)).
relay_message(WS, '$spawn'(Goal, Options, Reader)) :- !,
    spawn(Goal, RuntimePid, [link(false),monitor(true)|Options]),
    fresh_wire_pid(WirePid),
    relay_add_actor(WirePid, RuntimePid, actor),
    thread_send_message(Reader, '$spawned'(WirePid)),
    send_event(WS, spawned(WirePid)).
relay_message(WS, '$browser_message'(Target, Message)) :- !,
    send_event(WS, actor_message(Target, Message)).
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
    ( relay_actor(WirePid, RuntimePid, _) ->
        relay_take_monitors(RuntimePid, Refs),
        ( Refs == [] -> send_event(WS, down(WirePid, WirePid, Reason))
        ; send_down_events(WS, WirePid, Refs, Reason)
        ),
        ( relay_take_halt(RuntimePid, HaltWirePid) ->
            send_event(WS, halted(HaltWirePid, true))
        ; true
        ),
        relay_remove_actor(WirePid)
    ; true
    ).
relay_message(WS, protocol_error(Error)) :- !,
    send_event(WS, error(Error)).
relay_message(WS, Event) :-
    self(Relay),
    wire_event(Relay, Event, WireEvent),
    send_event(WS, WireEvent).

wire_event(Relay, success(RuntimePid, Rows, More), success(WirePid, Rows, More)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, failure(RuntimePid), failure(WirePid)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, error(RuntimePid, Error), error(WirePid, Error)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, output(RuntimePid, Data), output(WirePid, Data)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(Relay, prompt(RuntimePid, Data), prompt(WirePid, Data)) :- !,
    runtime_connection_pid(Relay, RuntimePid, WirePid).
wire_event(_, Event, Event).

runtime_connection_pid(_Relay, RuntimePid, WirePid) :-
    relay_actor(WirePid, RuntimePid, _), !.
runtime_connection_pid(_, RuntimePid, _) :-
    throw(error(existence_error(web_prolog_actor, RuntimePid), relay_loop/1)).

fresh_wire_pid(WirePid) :-
    repeat,
    random_between(10000000, 99999999, Candidate),
    \+ relay_actor(Candidate, _, _),
    !,
    WirePid = Candidate.

relay_actors(Actors) :-
    ( bb_get('$web_prolog_actors', Actors) -> true ; Actors = [] ).

relay_actor(WirePid, RuntimePid, Kind) :-
    relay_actors(Actors), memberchk(actor(WirePid, RuntimePid, Kind), Actors).

relay_add_actor(WirePid, RuntimePid, Kind) :-
    relay_actors(Actors),
    bb_put('$web_prolog_actors', [actor(WirePid, RuntimePid, Kind)|Actors]).

relay_remove_actor(WirePid) :-
    relay_actors(Actors),
    exclude(wire_actor(WirePid), Actors, Rest),
    bb_put('$web_prolog_actors', Rest).

wire_actor(WirePid, actor(WirePid, _, _)).

stop_relay_actors([]).
stop_relay_actors([actor(_, RuntimePid, _)|Actors]) :-
    catch(exit(RuntimePid, connection_closed), _, true),
    stop_relay_actors(Actors).

relay_monitors(Monitors) :-
    ( bb_get('$web_prolog_monitors', Monitors) -> true ; Monitors = [] ).

relay_add_monitor(RuntimePid, Ref) :-
    relay_monitors(Monitors),
    ( memberchk(monitor(RuntimePid, Ref), Monitors) -> true
    ; bb_put('$web_prolog_monitors', [monitor(RuntimePid, Ref)|Monitors])
    ).

relay_remove_monitor(Ref) :-
    relay_monitors(Monitors),
    exclude(monitor_ref(Ref), Monitors, Rest),
    bb_put('$web_prolog_monitors', Rest).

monitor_ref(Ref, monitor(_, Ref)).

relay_take_monitors(RuntimePid, Refs) :-
    relay_monitors(Monitors),
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest),
    bb_put('$web_prolog_monitors', Rest).

take_runtime_monitors([], _, [], []).
take_runtime_monitors([monitor(RuntimePid, Ref)|Monitors], RuntimePid,
                      [Ref|Refs], Rest) :- !,
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest).
take_runtime_monitors([Monitor|Monitors], RuntimePid, Refs, [Monitor|Rest]) :-
    take_runtime_monitors(Monitors, RuntimePid, Refs, Rest).

relay_add_halt(RuntimePid, WirePid) :-
    ( bb_get('$web_prolog_halts', Halts) -> true ; Halts = [] ),
    bb_put('$web_prolog_halts', [halt(RuntimePid, WirePid)|Halts]).

relay_take_halt(RuntimePid, WirePid) :-
    bb_get('$web_prolog_halts', Halts),
    select(halt(RuntimePid, WirePid), Halts, Rest), !,
    bb_put('$web_prolog_halts', Rest).

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
    terms_json_strings(Rows, Data),
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
    object([type-string_atom(transport_welcome),
            protocol-string_atom(web_prolog_browser_actor),
            io_ack-boolean(true), browser_pids-boolean(true),
            version-number(Version)], JSON).
event_json(actor_message(Target, Message), JSON) :- !,
    term_wire_atom(Target, TargetText),
    term_wire_atom(Message, MessageText),
    object([type-string_atom(actor_message), target-string_atom(TargetText),
            message-string_atom(MessageText)], JSON).
event_json(io_reply(RequestId, Status), JSON) :- !,
    object([type-string_atom(io_reply),request_id-string_atom(RequestId),
            status-string_atom(Status)], JSON).
event_json(Event, JSON) :-
    term_wire_atom(Event, Data),
    object([type-string_atom(error), data-string_atom(Data)], JSON).


                 /*******************************
                 *     BROWSER PID BRIDGING      *
                 *******************************/

actors:hook_send('$web_prolog_endpoint'(Relay, Id), Message) :-
    catch(thread_property(Relay, status(running)), _, fail),
    Relay ! '$browser_message'(Id@localhost, Message).

import_browser_pids(Term0, Relay, Term) :-
    ( browser_wire_pid(Term0, Id) ->
        Term = '$web_prolog_endpoint'(Relay, Id)
    ; var(Term0) -> Term = Term0
    ; atomic(Term0) -> Term = Term0
    ; functor(Term0, Name, Arity),
      functor(Term, Name, Arity),
      import_browser_pid_args(1, Arity, Relay, Term0, Term)
    ).

browser_wire_pid(Id@localhost, Id) :-
    integer(Id), Id >= 1000000000, Id =< 9999999999.

import_browser_pid_args(Index, Arity, _, _, _) :- Index > Arity, !.
import_browser_pid_args(Index, Arity, Relay, Term0, Term) :-
    arg(Index, Term0, Arg0),
    import_browser_pids(Arg0, Relay, Arg),
    arg(Index, Term, Arg),
    Next is Index + 1,
    import_browser_pid_args(Next, Arity, Relay, Term0, Term).

terms_json_strings([], []).
terms_json_strings([Term|Terms], [string(Chars)|JSONTerms]) :-
    term_wire_atom(Term, Atom), atom_chars(Atom, Chars),
    terms_json_strings(Terms, JSONTerms).

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

json_pid_field(JSON, Key, Pid) :-
    json_field(JSON, Key, Value),
    ( Value = number(Pid), integer(Pid)
    ; Value = string(Chars), atom_chars(Text, Chars), read_term_from_atom(Text, Pid, [])
    ).

json_term_field(JSON, Key, Term) :-
    json_text_field(JSON, Key, Text),
    read_term_from_atom(Text, Term, []).

json_term_default(JSON, Key, Default, Term) :-
    ( json_term_field(JSON, Key, Found) -> Term = Found ; Term = Default ).

json_options(JSON, Options) :-
    json_text_default(JSON, options, '[]', Text),
    read_term_from_atom(Text, Options, []),
    must_be(list, Options).

read_goal_options(GoalText, OptionsText, Goal, Options) :-
    format(atom(Text), '(~w)-(~w)', [GoalText, OptionsText]),
    read_term_from_atom(Text, Goal-Options, []),
    must_be(list, Options).

safe_spawn_options(Options0, Options) :-
    exclude(reserved_spawn_option, Options0, Options).

spawn_io_options(JSON, Options0, [io_target(Endpoint)|Options0]) :-
    json_term_field(JSON, io_target, Endpoint),
    valid_io_endpoint(Endpoint),
    !.
spawn_io_options(JSON, _, _) :-
    json_field(JSON, io_target, _),
    !,
    throw(error(domain_error(distributed_io_endpoint, io_target),
                web_prolog_handler/2)).
spawn_io_options(_, Options, Options).

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
