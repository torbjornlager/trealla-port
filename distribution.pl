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

This module keeps one version-1 Web Prolog WebSocket open to a remote node.
A writer actor serializes frames and spawn rendezvous; an independent reader
actor turns inbound JSON events into the same Prolog messages used by local
toplevel actors.  Remote pids are represented as `WirePid@NodeURL`.

The connection is suitable for trusted Trealla and SWI Web Prolog nodes.  It
is intentionally a layer above websocket.pl and web_prolog.pl, and contains
no Logtalk or foreign code.
*/

:- op(200, xfx, @).

:- use_module(actors).
:- use_module(websocket).
:- use_module(web_prolog).

                 /*******************************
                 *        CONNECTION API         *
                 *******************************/

%! remote_node_open(+URL, -Node) is det.
%! remote_node_open(+URL, -Node, +Options) is det.

remote_node_open(URL, Node) :-
    remote_node_open(URL, Node, []).

remote_node_open(URL, remote_node(URL, Reader, Writer), Options) :-
    self(Owner),
    node_connection_options(Options, WebSocketOptions),
    web_prolog_connect(URL, WS, WebSocketOptions),
    spawn(remote_writer_start(WS, URL, Owner), Writer, [link(false)]),
    spawn(remote_reader_loop(WS, URL, Writer), Reader, [link(false)]).

node_connection_options(Options, WebSocketOptions) :-
    default_header('X-Web-Prolog-User', 'node:trealla', Options, O1),
    default_header('X-Web-Prolog-Capabilities',
                   'execute,internal_transport', O1, WebSocketOptions).

default_header(Name, _, Options, Options) :-
    memberchk(header(Name, _), Options), !.
default_header(Name, Value, Options, [header(Name, Value)|Options]).

%! remote_node_close(+Node) is det.

remote_node_close(remote_node(_URL, Reader, Writer)) :-
    Writer ! '$remote_close',
    catch(thread_cancel(Reader), _, true),
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
    Node = remote_node(URL, _Reader, Writer),
    self(Target),
    strip_module(Goal0, _, Goal),
    term_wire_atom(Goal, GoalText),
    exclude(local_spawn_option, Options0, Options),
    term_wire_atom(Options, OptionsText),
    web_prolog:object([command-string_atom(spawn),
                       goal-string_atom(GoalText),
                       options-string_atom(OptionsText)], JSON),
    spawn_request(Writer, URL, actor, Target, JSON, RemotePid).

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
    spawn_request(Writer, URL, session, Target, JSON, RemotePid).

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

spawn_request(Writer, URL, Kind, Target, JSON, RemotePid) :-
    self(Caller),
    Writer ! '$spawn_request'(JSON, Kind, Target, Caller),
    receive({
        '$remote_spawned'(Writer, WirePid) ->
            RemotePid = WirePid@URL ;
        '$remote_spawn_error'(Writer, Error) -> throw(Error)
    }, []).

enqueue_json(remote_node(_URL, _Reader, Writer), JSON) :-
    Writer ! '$remote_json'(JSON).

remote_writer_start(WS, URL, Owner) :-
    bb_put('$distribution_owner', Owner),
    bb_put('$distribution_targets', []),
    remote_writer_loop(WS, URL).

remote_writer_loop(WS, URL) :-
    receive({ Message -> true }, []),
    writer_message(Message, WS, URL, Continue),
    ( Continue == true -> remote_writer_loop(WS, URL) ; true ).

writer_message('$remote_json'(JSON), WS, _, true) :- !,
    web_prolog_send(WS, JSON).
writer_message('$spawn_request'(JSON, _Kind, Target, Caller), WS, URL,
               Continue) :- !,
    self(Writer),
    web_prolog_send(WS, JSON),
    receive({
        '$wire_spawned'(WirePid) ->
            distribution:writer_add_target(WirePid, Target),
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
writer_message('$owner_event'(Event), _, _, true) :- !,
    writer_owner(Owner), Owner ! Event.
writer_message('$remote_close', WS, _, false) :- !,
    catch(ws_close(WS, 1000, normal), _, true).
writer_message(_, _, _, true).

writer_owner(Owner) :-
    bb_get('$distribution_owner', Owner).

writer_targets(Targets) :-
    ( bb_get('$distribution_targets', Targets) -> true ; Targets = [] ).

writer_add_target(WirePid, Target) :-
    writer_targets(Targets),
    bb_put('$distribution_targets', [target(WirePid, Target, live)|Targets]).

writer_deliver_event(WirePid, Event) :-
    writer_targets(Targets),
    ( memberchk(target(WirePid, Target, _), Targets) -> Target ! Event
    ; writer_owner(Owner), Owner ! Event
    ).

writer_note_terminal(Type, WirePid) :-
    ( Type == down ; Type == halted ), !,
    writer_targets(Targets),
    mark_writer_target_dead(Targets, WirePid, Marked),
    bb_put('$distribution_targets', Marked).
writer_note_terminal(_, _).

mark_writer_target_dead([], _, []).
mark_writer_target_dead([target(WirePid, Target, _)|Targets], WirePid,
                        [target(WirePid, Target, dead)|Marked]) :- !,
    mark_writer_target_dead(Targets, WirePid, Marked).
mark_writer_target_dead([Target|Targets], WirePid, [Target|Marked]) :-
    mark_writer_target_dead(Targets, WirePid, Marked).

writer_notify_connection_closed(URL) :-
    writer_targets(Targets),
    notify_live_targets(Targets, URL),
    bb_put('$distribution_targets', []).

notify_live_targets([], _).
notify_live_targets([target(WirePid, Target, State)|Targets], URL) :-
    ( State == live ->
        Target ! down(WirePid@URL, WirePid@URL, connection_closed)
    ; true
    ),
    notify_live_targets(Targets, URL).

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
