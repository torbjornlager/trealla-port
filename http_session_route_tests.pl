% SPDX-License-Identifier: MIT
:- module(http_session_route_tests, [run/0, relay/1, request/2, local_relay/2, send_local/2]).
:- use_module(web_prolog).
:- use_module(actors, [spawn_runtime/3, exit/2]).
:- use_module(http_sessions).

% HTTP dispatch must not take the browser-capability mutex while holding
% the route mutex. WebSocket teardown may already own that capability lock.
run :- route_dispatch, local_actor_routing, http_output_json.

route_dispatch :-
    message_queue_create(Ready),
    message_queue_create(Done),
    setup_call_cleanup(
        spawn_runtime(http_session_route_tests:relay(Ready), Relay,
                      [link(false), '$entry_context'(caller)]),
        ( thread_get_message(Ready, ready, [timeout(2)]),
          setup_call_cleanup(
              assertz(http_sessions:session(9999, 1234567890, route_test, Relay)),
              setup_call_cleanup(
                  mutex_lock('$browser_actor_capabilities'),
                  ( thread_create(http_session_route_tests:request(Done, 1234567890), Worker, []),
                    ( thread_get_message(Done, route_reply(200, route_test_reply), [timeout(2)])
                    -> Passed = true ; Passed = false ) ),
                  mutex_unlock('$browser_actor_capabilities')),
              retractall(http_sessions:session(9999, 1234567890, route_test, Relay))),
          thread_join(Worker, _),
          Passed == true,
          write('HTTP session route dispatch avoids the browser capability lock: ok'), nl
        ),
        ( exit(Relay, cleanup), message_queue_destroy(Ready), message_queue_destroy(Done) )).

relay(Ready) :-
    thread_send_message(Ready, ready),
    thread_get_message('$http_session_request'(Reply, _, _, _, _)),
    thread_send_message(Reply, reply(200, route_test_reply)),
    thread_get_message(stop).

request(Done, Pid) :-
    atom_number(Text, Pid),
    http_sessions:session_request(9999, session_access(route_test, test, test),
                                 actor, blacklist, toplevel_next, [pid=Text], Status, Event),
    thread_send_message(Done, route_reply(Status, Event)).

% Holding unrelated browser metadata must not block native actor delivery.
local_actor_routing :-
    message_queue_create(Ready), message_queue_create(Done),
    setup_call_cleanup(
        spawn_runtime(http_session_route_tests:local_relay(Ready,Done), Relay,
                      [link(false), '$entry_context'(caller)]),
        ( thread_get_message(Ready,ready,[timeout(2)]),
          setup_call_cleanup(
              mutex_lock('$browser_actor_capabilities'),
              once((thread_create(http_session_route_tests:send_local(Relay,Done),Worker,[]),
                    (thread_get_message(Done,sent,[timeout(2)]),
                     thread_get_message(Done,received,[timeout(2)])
                    -> Passed=true ; Passed=false))),
              mutex_unlock('$browser_actor_capabilities')),
          thread_join(Worker,_), Passed==true,
          write('Native actor delivery avoids the browser capability lock: ok'),nl ),
        (exit(Relay,cleanup),message_queue_destroy(Ready),message_queue_destroy(Done))).

local_relay(Ready,Done) :-
    thread_send_message(Ready,ready),thread_get_message(ping),
    thread_send_message(Done,received),thread_get_message(stop).
send_local(Relay,Done) :-
    actors:send(Relay,ping),thread_send_message(Done,sent).

% Runtime terminal output must retain its text without adding a newline.
% This also catches accidentally retained helpers from an unmerged stream API.
http_output_json :-
    node:node_json_object([type-string_atom(output),pid-number(1234567890),
                          data-string_atom('hello(world)'),stdout-string_atom('hello(world)')],Expected),
    node:session_event_json(terminal_io_output(1234567890, hello(world)), Actual),
    Actual == Expected,
    write('HTTP terminal output matches the runtime output envelope: ok'), nl.
