:- module(distribution,
    [ remote_node_open/2,
      remote_node_open/3,
      remote_node_close/1,
      remote_spawn/4,
      remote_send/3,
      remote_exit/3,
      remote_monitor/3,
      remote_demonitor/2,
      remote_toplevel_spawn/3,
      remote_toplevel_call/4,
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
A named node-manager caches connections and canonical PID routes.  A writer
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
:- use_module(websocket).
:- use_module(web_prolog).

:- multifile
    actors:hook_spawn/3,
    actors:hook_send/2,
    actors:hook_exit/2,
    actors:hook_monitor/3,
    actors:hook_demonitor/1,
    actors:hook_stop/1.

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
    web_prolog_connect(WebSocketURL, WS, WebSocketOptions),
    spawn(remote_writer_start(WS, URL, Owner), Writer, [link(false)]),
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
    Node = remote_node(URL, Reader, Writer),
    manager_forget_node_if_running(URL),
    Writer ! '$remote_close',
    ( catch(thread_property(Reader, status(running)), _, fail) ->
        catch(thread_cancel(Reader), _, true)
    ; true
    ),
    wait_thread_end(Reader, 100),
    wait_thread_end(Writer, 100).

wait_thread_end(_, 0) :- !.
wait_thread_end(Thread, Attempts) :-
    ( thread_property(Thread, status(running)) ->
        sleep(0.01), Next is Attempts - 1,
        wait_thread_end(Thread, Next)
    ; true
    ).


                 /*******************************
                 *         REMOTE ACTORS         *
                 *******************************/

%! remote_spawn(+Node, :Goal, -RemotePid, +Options) is det.

:- meta_predicate(remote_spawn(+, 0, -, +)).

remote_spawn(Node, Goal0, RemotePid, Options0) :-
    remote_spawn_mode(Node, Goal0, RemotePid, Options0, explicit).

remote_spawn_mode(Node, Goal0, RemotePid, Options0, Mode) :-
    Node = remote_node(URL, _Reader, Writer),
    self(Target),
    strip_module(Goal0, _, Goal),
    term_wire_atom(Goal, GoalText),
    exclude(local_spawn_option, Options0, Options),
    term_wire_atom(Options, OptionsText),
    web_prolog:object([command-string_atom(spawn),
                       goal-string_atom(GoalText),
                       options-string_atom(OptionsText)], JSON),
    spawn_request(Writer, URL, Mode, Options0, Target, JSON, RemotePid).

local_spawn_option(target(_)).
local_spawn_option(link(_)).
local_spawn_option(monitor(_)).
local_spawn_option(node(_)).

%! remote_send(+Node, +RemotePid, +Message) is det.

remote_send(Node, RemotePid, Message) :-
    node_wire_pid(Node, RemotePid, WirePid),
    term_wire_atom(Message, MessageText),
    web_prolog:object([command-string_atom(send), pid-number(WirePid),
                       message-string_atom(MessageText)], JSON),
    enqueue_json(Node, JSON).

%! remote_exit(+Node, +RemotePid, +Reason) is det.

remote_exit(Node, RemotePid, Reason) :-
    node_wire_pid(Node, RemotePid, WirePid),
    term_wire_atom(Reason, ReasonText),
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

remote_toplevel_spawn(Node, RemotePid, Options0) :-
    Node = remote_node(URL, _Reader, Writer),
    self(Target),
    exclude(local_spawn_option, Options0, Options),
    term_wire_atom(Options, OptionsText),
    web_prolog:object([command-string_atom(toplevel_spawn),
                       options-string_atom(OptionsText)], JSON),
    spawn_request(Writer, URL, explicit, Options0, Target, JSON, RemotePid).

%! remote_toplevel_call(+Node, +RemotePid, :Goal, +Options) is det.

:- meta_predicate(remote_toplevel_call(+, +, 0, +)).

remote_toplevel_call(Node, RemotePid, Goal0, Options0) :-
    node_wire_pid(Node, RemotePid, WirePid),
    strip_module(Goal0, _, Goal),
    exclude(local_call_option, Options0, Options),
    goal_options_wire_atoms(Goal, Options, GoalText, OptionsText),
    web_prolog:object([command-string_atom(toplevel_call), pid-number(WirePid),
                       goal-string_atom(GoalText),
                       options-string_atom(OptionsText)], JSON),
    enqueue_json(Node, JSON).

local_call_option(target(_)).

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
    term_wire_atom(Input, InputText),
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
            distribution:caller_prepare_target(Mode, WirePid, URL, Writer,
                                               Target, Options),
            Writer ! '$remote_spawn_ready'(Target, WirePid),
            distribution:await_spawn_reply(Writer, URL, Mode, Options,
                                           Target, RemotePid) ;
        '$remote_spawned'(Writer, WirePid) ->
            RemotePid = WirePid@URL ;
        '$remote_spawn_error'(Writer, Error) -> throw(Error)
    }, []).

enqueue_json(remote_node(_URL, _Reader, Writer), JSON) :-
    Writer ! '$remote_json'(JSON).

remote_writer_start(WS, URL, Owner) :-
    bb_put('$distribution_owner', Owner),
    bb_put('$distribution_targets', []),
    bb_put('$distribution_monitors', []),
    remote_writer_loop(WS, URL).

remote_writer_loop(WS, URL) :-
    receive({ Message -> true }, []),
    writer_message(Message, WS, URL, Continue),
    ( Continue == true -> remote_writer_loop(WS, URL) ; true ).

writer_message('$remote_json'(JSON), WS, _, true) :- !,
    web_prolog_send(WS, JSON).
writer_message('$spawn_request'(JSON, Mode, Options, Target, Caller), WS, URL,
               Continue) :- !,
    self(Writer),
    web_prolog_send(WS, JSON),
    receive({
        '$wire_spawned'(WirePid) ->
            distribution:writer_add_target(WirePid, Target, Mode),
            distribution:writer_prepare_handshake(Mode, WirePid, Caller,
                                                  Target),
            distribution:writer_prepare_target(Mode, WirePid, URL, Target,
                                               Options, WS),
            Caller ! '$remote_spawned'(Writer, WirePid),
            Continue = true ;
        '$wire_spawn_error'(Error) ->
            Caller ! '$remote_spawn_error'(Writer, Error),
            Continue = true ;
        '$remote_lost'(URL, Reason) ->
            Caller ! '$remote_spawn_error'(Writer,
                         error(remote_connection_closed(URL, Reason),
                               remote_spawn/4)),
            distribution:writer_notify_connection_closed(URL),
            Continue = false
    }, []).
writer_message('$remote_lost'(URL, _Reason), _, _, false) :- !,
    writer_notify_connection_closed(URL).
writer_message('$wire_event'(WirePid, Type, Event), _, _, true) :- !,
    writer_deliver_event(WirePid, Event),
    writer_note_terminal(Type, WirePid).
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

writer_owner(Owner) :-
    bb_get('$distribution_owner', Owner).

writer_targets(Targets) :-
    ( bb_get('$distribution_targets', Targets) -> true ; Targets = [] ).

writer_add_target(WirePid, Target, Mode) :-
    writer_targets(Targets),
    bb_put('$distribution_targets',
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
    receive({ '$remote_spawn_ready'(Target, WirePid) -> true }, []).

writer_monitors(Monitors) :-
    ( bb_get('$distribution_monitors', Monitors) -> true ; Monitors = [] ).

writer_add_monitor(WirePid, Ref, Watcher) :-
    writer_monitors(Monitors),
    bb_put('$distribution_monitors',
           [monitor(WirePid, Ref, Watcher)|Monitors]).

writer_remove_monitor(Ref) :-
    writer_monitors(Monitors),
    exclude(writer_monitor_ref(Ref), Monitors, Rest),
    bb_put('$distribution_monitors', Rest).

writer_monitor_ref(Ref, monitor(_, Ref, _)).

writer_remove_watcher(Watcher) :-
    writer_monitors(Monitors),
    exclude(writer_monitor_watcher(Watcher), Monitors, Rest),
    bb_put('$distribution_monitors', Rest).

writer_monitor_watcher(Watcher, monitor(_, _, Watcher)).

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
    bb_put('$distribution_monitors', Rest),
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
    bb_put('$distribution_targets', Marked).
writer_note_terminal(_, _).

mark_writer_target_dead([], _, []).
mark_writer_target_dead([target(WirePid, Target, _, Mode)|Targets], WirePid,
                        [target(WirePid, Target, dead, Mode)|Marked]) :- !,
    mark_writer_target_dead(Targets, WirePid, Marked).
mark_writer_target_dead([Target|Targets], WirePid, [Target|Marked]) :-
    mark_writer_target_dead(Targets, WirePid, Marked).

writer_notify_connection_closed(URL) :-
    writer_targets(Targets),
    notify_live_targets(Targets, URL),
    bb_put('$distribution_targets', []),
    bb_put('$distribution_monitors', []),
    manager_forget_node_if_running(URL).

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
    Writer ! '$owner_event'(transport_welcome(JSON)).
dispatch_remote_type(Type, JSON, URL, Writer) :-
    web_prolog:json_pid_field(JSON, pid, WirePid),
    remote_event(Type, JSON, WirePid@URL, Event),
    Writer ! '$wire_event'(WirePid, Type, Event).

remote_event(success, JSON, Pid, success(Pid, Rows, More)) :- !,
    web_prolog:json_field(JSON, data, list(Data)),
    json_terms(Data, Rows),
    ( web_prolog:json_field(JSON, more, boolean(true)) -> More = true
    ; More = false
    ).
remote_event(failure, _, Pid, failure(Pid)) :- !.
remote_event(error, JSON, Pid, error(Pid, remote_error(Data))) :- !,
    web_prolog:json_text_default(JSON, data, 'Unknown remote error', Data).
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

json_terms([], []).
json_terms([string(Chars)|Values], [Term|Terms]) :-
    atom_chars(Text, Chars),
    ( catch(read_term_from_atom(Text, Term, []), _, fail) -> true ; Term = Text ),
    json_terms(Values, Terms).

json_event_term(JSON, Key, Term) :-
    web_prolog:json_text_default(JSON, Key, '', Text),
    ( catch(read_term_from_atom(Text, Term, []), _, fail) -> true ; Term = Text ).

remote_error_term(JSON, error(remote_error(Data), distribution)) :-
    web_prolog:json_text_default(JSON, data, 'Unknown remote error', Data).

connection_lost(Writer, URL, Reason) :-
    Writer ! '$remote_lost'(URL, Reason).

notify_connection_error(Writer, Error) :-
    Writer ! '$owner_event'(error(remote_connection, Error)).


                 /*******************************
                 *      TRANSPARENT ROUTING      *
                 *******************************/

actors:hook_spawn(Goal, RemotePid, Options0) :-
    take_node_option(Options0, URL0, Options),
    URL0 \== localhost,
    node_url_atom(URL0, URL),
    transparent_node(URL, Node),
    remote_spawn_mode(Node, Goal, RemotePid, Options, transparent).

actors:hook_send(RemotePid, Message) :-
    remote_pid_writer(RemotePid, Writer, WirePid),
    term_wire_atom(Message, MessageText),
    web_prolog:object([command-string_atom(send), pid-number(WirePid),
                       message-string_atom(MessageText)], JSON),
    Writer ! '$remote_json'(JSON).

actors:hook_exit(RemotePid, Reason) :-
    remote_pid_writer(RemotePid, Writer, WirePid),
    term_wire_atom(Reason, ReasonText),
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

manager_forget_node_if_running(URL) :-
    ( catch(thread_property('$distribution_manager', status(running)), _, fail) ->
        '$distribution_manager' ! '$node_forget'(URL)
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
    catch(thread_create(distribution:distribution_manager_loop([], []), _,
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

distribution_manager_loop(Nodes, Routes) :-
    thread_get_message(Message),
    manager_message(Message, Nodes, Routes, NextNodes, NextRoutes),
    distribution_manager_loop(NextNodes, NextRoutes).

manager_message('$node_request'(URL, Caller), Nodes, Routes,
                NextNodes, Routes) :- !,
    ( select(node(URL, Node), Nodes, Rest), node_writer_running(Node) ->
        NextNodes = [node(URL, Node)|Rest], Error = none
    ; catch(remote_node_open(URL, Node), OpenError, true),
      ( var(OpenError) ->
          NextNodes = [node(URL, Node)|Nodes], Error = none
      ; NextNodes = Nodes, Error = OpenError
      )
    ),
    self(Manager),
    ( Error == none -> Caller ! '$node_reply'(Manager, URL, Node)
    ; Caller ! '$node_error'(Manager, URL, Error)
    ).
manager_message('$route_register'(Pid, Writer, Caller), Nodes, Routes,
                Nodes, [route(Pid, Writer)|Rest]) :- !,
    exclude(manager_route_pid(Pid), Routes, Rest),
    self(Manager),
    Caller ! '$route_registered'(Manager, Pid).
manager_message('$route_request'(Pid, Caller), Nodes, Routes, Nodes, Routes) :- !,
    self(Manager),
    ( memberchk(route(Pid, Writer), Routes) ->
        Caller ! '$route_reply'(Manager, Pid, Writer)
    ; Caller ! '$route_missing'(Manager, Pid)
    ).
manager_message('$route_forget'(Pid), Nodes, Routes, Nodes, Rest) :- !,
    exclude(manager_route_pid(Pid), Routes, Rest).
manager_message('$node_forget'(URL), Nodes, Routes, RestNodes, RestRoutes) :- !,
    exclude(manager_node_url(URL), Nodes, RestNodes),
    exclude(manager_route_url(URL), Routes, RestRoutes).
manager_message('$target_stopped'(Target), Nodes, Routes, Nodes, Routes) :- !,
    notify_node_target_stopped(Nodes, Target).
manager_message(_, Nodes, Routes, Nodes, Routes).

node_writer_running(remote_node(_, _, Writer)) :-
    catch(thread_property(Writer, status(running)), _, fail).

manager_route_pid(Pid, route(Pid, _)).
manager_node_url(URL, node(URL, _)).
manager_route_url(URL, route(_@URL, _)).

notify_node_target_stopped([], _).
notify_node_target_stopped([node(_, remote_node(_, _, Writer))|Nodes], Target) :-
    Writer ! '$target_stopped'(Target),
    notify_node_target_stopped(Nodes, Target).


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
    copy_term(Goal-Options, GoalCopy-OptionsCopy),
    numbervars(GoalCopy-OptionsCopy, 0, _),
    format(atom(GoalAtom), '~q', [GoalCopy]),
    format(atom(OptionsAtom), '~q', [OptionsCopy]).
