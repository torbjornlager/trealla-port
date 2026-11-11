% SPDX-License-Identifier: MIT
:- module(http_sessions, [session_route/2, session_request/8, close_sessions/1]).

:- use_module(actors, [self/1, send/2, receive/1, receive/2, exit/2]).
:- use_module(toplevel_actors, [toplevel_spawn/2, toplevel_call/3, toplevel_next/2,
                                toplevel_abort/1, toplevel_stop/1, toplevel_halt/1,
                                toplevel_halt/2]).
:- use_module(sandbox_policy, [sandbox_prepare_session_call/7]).
:- use_module(isolation, [actor_module/2]).
:- use_module(resource_policy, [check_term_text_size/2]).
:- use_module(governance_policy, [reserve_http_session_capacity/3,
                                   release_capacity_reservation/1]).

:- dynamic session/4, session_relay/1.
:- catch(mutex_create(_, [alias('$http_session_routes')]),
         error(permission_error(create, mutex, '$http_session_routes'), _), true).
:- multifile actors:hook_prompt_relay/1, toplevel_actors:hook_abort_ack/2.
actors:hook_prompt_relay(Relay) :- http_sessions:session_relay(Relay).
toplevel_actors:hook_abort_ack(Pid, Relay) :-
    http_sessions:session_relay(Relay),
    send(Relay, abort(Pid)).

session_route('/toplevel_spawn', toplevel_spawn).
session_route('/toplevel_call', toplevel_call).
session_route('/toplevel_next', toplevel_next).
session_route('/toplevel_poll', toplevel_poll).
session_route('/toplevel_stop', toplevel_stop).
session_route('/toplevel_abort', toplevel_abort).
session_route('/toplevel_halt', toplevel_halt).
session_route('/toplevel_respond', toplevel_respond).

session_request(Port, Access, _, _, toplevel_spawn, pairs(Fields), 200, spawned(Pid)) :- !,
    validate_spawn_options(Fields),
    setup_call_cleanup(message_queue_create(Reply),
        ( actors:spawn_runtime(http_sessions:admit_session(Port, Access, Reply),
                               _, [link(false), '$entry_context'(caller)]),
          ( thread_get_message(Reply, Created, [timeout(5)]) ->
              ( Created = spawned(Pid) -> true ; throw(Created) )
          ; throw(error(timeout, http_sessions)) )
        ),
        message_queue_destroy(Reply)).
session_request(Port, session_access(Owner, _, _), Profile, Sandbox, Command, Fields, Status, Event) :-
    memberchk(pid=PidText, Fields),
    atom_number(PidText, Pid),
    setup_call_cleanup(message_queue_create(Reply),
        ( with_mutex('$http_session_routes',
              ( session(Port, Pid, Owner, Relay),
                % This is our private relay, not a browser wire PID. General
                % send/2 takes the browser-capability lock; teardown can hold
                % that lock while retiring a route, reversing this lock order.
                actors:actor_thread(Relay, RelayThread),
                catch(thread_send_message(RelayThread,
                    '$http_session_request'(Reply, Command, Fields, Profile, Sandbox)),
                    _, fail) )) ->
            ( thread_get_message(Reply, reply(Status, Event), [timeout(10)]) -> true
            ; Status = 504, Event = error(timeout) )
        ; Status = 404, Event = error(existence_error(http_session, Pid))
        ),
        message_queue_destroy(Reply)).

validate_spawn_options(Fields) :-
    ( node:node_json_field(pairs(Fields), options, OptionsValue) ->
        OptionsValue = string(Options),
        atom_chars(OptionsAtom, Options),
        check_term_text_size(options, OptionsAtom),
        read_term_from_atom(OptionsAtom, Parsed, []),
        ( Parsed == [] ; Parsed == [session(true)] )
    ; true
    ).

:- multifile actors:hook_terminal_stream/1.
actors:hook_terminal_stream(Relay) :- session_relay(Relay).

admit_session(Port, session_access(Owner, Principal, Identity), Reply) :-
    catch(reserve_http_session_capacity(Principal, Identity, Reservation),
          Error, (thread_send_message(Reply, Error), fail)),
    setup_call_cleanup(true,
        session_worker(Port, Owner, Reply),
        release_capacity_reservation(Reservation)).

session_worker(Port, Owner, Reply) :-
    self(Relay),
    setup_call_cleanup(
        assertz(session_relay(Relay)),
        ( catch(toplevel_spawn(Pid, [session(true), target(Relay), monitor(true)]),
                Error, (thread_send_message(Reply, Error), fail)),
          setup_call_cleanup(
              assertz(session(Port, Pid, Owner, Relay)),
              ( thread_send_message(Reply, spawned(Pid)),
                session_loop(Pid, none)
              ),
              ( retractall(session(Port, Pid, Owner, Relay)), toplevel_halt(Pid) ))
        ),
        retractall(session_relay(Relay))).

close_sessions(Port) :-
    forall(session(Port, _, _, Relay), exit(Relay, shutdown)).

session_loop(Pid, Pending) :-
    receive({
        '$http_session_request'(Reply, Command, Fields, Profile, Sandbox) ->
            catch(( session_command(Command, Pid, Pending, Fields, Profile, Sandbox, Status, Event, Next) -> true
                  ; Status = 400, Event = error(invalid_request), Next = Pending
                  ),
                  Error, (Status = 200, Event = error(Error), Next = Pending)),
            reply_to_request(Reply, Status, Event),
            ( (Command == toplevel_halt ; Next == retired) -> true ; session_loop(Pid, Next) )
      ; down(Pid, Pid, _) -> true
    }).

reply_to_request(Reply, Status, Event) :-
    catch(thread_send_message(Reply, reply(Status, Event)), _, true).

session_command(toplevel_call, Pid, none, Fields, Profile, Sandbox, Status, Event, Next) :-
    memberchk(goal=Text, Fields),
    check_term_text_size(goal, Text),
    read_term_from_atom(Text, Goal0, [variable_names(Bindings0)]),
    sandbox_prepare_session_call(Sandbox, Profile, Pid, Goal0, [], Checked, []),
    rewrite_read(Checked, Goal),
    node:named_bindings(Bindings0, Bindings),
    ( memberchk(limit=LimitText, Fields) -> atom_number(LimitText, Limit), integer(Limit), Limit > 0
    ; Limit = 1
    ),
    % A source-less actor already has a private module. Use the fixed runtime
    % dispatcher so assertions and later calls share that module without
    % Trealla treating a dynamic Module:Goal term as nested meta-goals.
    actor_module(Pid, QueryModule),
    RuntimeGoal = isolation:run_actor_query(QueryModule, Goal),
    toplevel_call(Pid, RuntimeGoal, [template(json_bindings(Bindings)), limit(Limit)]),
    await_session_event(Pid, Status, Event, Next).
session_command(toplevel_next, Pid, none, _, _, _, Status, Event, Next) :-
    toplevel_next(Pid, []),
    await_session_event(Pid, Status, Event, Next).
session_command(toplevel_poll, Pid, none, _, _, _, Status, Event, Next) :-
    await_session_event(Pid, Status, Event, Next).
session_command(toplevel_stop, Pid, none, _, _, _, 200, stop(Pid), none) :-
    toplevel_stop(Pid).
session_command(toplevel_abort, Pid, _, _, _, _, 200, Event, none) :-
    abort_session(Pid, Event).
session_command(toplevel_halt, Pid, _, _, _, _, 200, halted(Pid, true), none) :-
    halt_session(Pid).
session_command(toplevel_respond, Pid, Pending, Fields, _, _, Status, Event, Next) :-
    ( prompt_reply_allowed(Pending, Fields) ->
        memberchk(input=Text, Fields),
        check_term_text_size(input, Text),
        read_term_from_atom(Text, Value, []),
        route_prompt_reply(Pid, Pending, Value),
        Status = 200, Event = responded(Pid), Next = none
    ; Status = 400, Event = invalid_prompt_ref(Pid), Next = Pending
    ).

halt_session(Pid) :-
    toplevel_halt(Pid, true),
    % Stop admitting requests before rejecting work already queued at Halt.
    self(Relay),
    with_mutex('$http_session_routes', retractall(session(_, Pid, _, Relay))),
    reject_retired_requests(Pid).

reject_retired_requests(Pid) :-
    receive({
        '$http_session_request'(Reply, _, _, _, _) ->
            reply_to_request(Reply, 404, error(existence_error(http_session, Pid))),
            reject_retired_requests(Pid)
    }, [timeout(0)]).

prompt_reply_allowed(correlated(Ref), Fields) :-
    memberchk(prompt_ref=Token, Fields),
    term_to_atom(Ref, Token).

route_prompt_reply(Pid, correlated(Ref), Value) :-
    self(Relay),
    send(Pid, '$input'(Relay, Ref, Value)).

await_session_event(Pid, Status, Event, Pending) :-
    receive({
        '$http_session_request'(AbortReply, toplevel_abort, _, _, _) ->
            abort_session(Pid, Event),
            reply_to_request(AbortReply, 200, Event),
            Pending = none
      ; '$http_session_request'(HaltReply, toplevel_halt, _, _, _) ->
            halt_session(Pid),
            reply_to_request(HaltReply, 200, halted(Pid, true)),
            Event = error(existence_error(http_session, Pid)), Pending = retired
      ; '$input_prompt'(Pid, Ref, Prompt) ->
            term_to_atom(Ref, Token), Event = prompt(Pid, Prompt, Token), Pending = correlated(Ref)
      ; terminal_output(Pid, Data) -> Event = output(Pid, Data), Pending = none
      ; terminal_io_output(Pid, Data) -> Event = terminal_io_output(Pid, Data), Pending = none
      ; output(Pid, Data) -> Event = output(Pid, Data), Pending = none
      ; success(Pid, Rows, More) -> Event = success(Pid, Rows, More), Pending = none
      ; failure(Pid) -> Event = failure(Pid), Pending = none
      ; error(Pid, Error) -> Event = error(Pid, Error), Pending = none
    }, [timeout(4), on_timeout((Event = error(timeout), Pending = none))]),
    ( Pending == retired -> Status = 404 ; Status = 200 ).

abort_session(Pid, Event) :-
    toplevel_abort(Pid),
    await_session_abort(Pid, Event).

await_session_abort(Pid, Event) :-
    receive({
        abort(Pid) -> actors:discard_deferred(http_sessions:old_session_event(Pid)), Event = abort(Pid)
    }, [timeout(4), on_timeout(Event = error(timeout))]).

old_session_event(Pid, '$input_prompt'(Pid, _, _)).
old_session_event(Pid, prompt(Pid, _)).
old_session_event(Pid, terminal_output(Pid, _)).
old_session_event(Pid, terminal_io_output(Pid, _)).
old_session_event(Pid, output(Pid, _)).
old_session_event(Pid, success(Pid, _, _)).
old_session_event(Pid, failure(Pid)).
old_session_event(Pid, error(Pid, _)).

rewrite_read(Goal, Goal) :- var(Goal), !.
rewrite_read(read(Value), input('|:', Value)) :- !.
rewrite_read((A,B), (X,Y)) :- !, rewrite_read(A, X), rewrite_read(B, Y).
rewrite_read((A;B), (X;Y)) :- !, rewrite_read(A, X), rewrite_read(B, Y).
rewrite_read((A->B), (X->Y)) :- !, rewrite_read(A, X), rewrite_read(B, Y).
rewrite_read(Goal, Goal).
