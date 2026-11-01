% SPDX-License-Identifier: MIT
:- module(node_shutdown_tests,[run/0,held_cleanup/2]).
:- use_module(node).
:- use_module(actors,[make_ref/1]).

run :-
    thread_self(Parent),make_ref(Key),Port=65500,
    setup_call_cleanup(
      (node:register_node_connection(Port,Key,shutdown_test_stream),
       thread_create(thread_get_message(initial_wait),Worker,
         [detached(true),at_exit(node_shutdown_tests:held_cleanup(Parent,Key))]),
       node:set_node_connection_thread(Key,Worker)),
      (node:close_node_connections(Port),
       thread_get_message(Parent,cleanup_started(Key),[timeout(1)]),
       % Listener cleanup and a second caller may both drain during at_exit.
       node:close_node_connections(Port),
       catch(thread_send_message(Worker,release_cleanup),_,true),
       (thread_get_message(Parent,cleanup_done(Key),[timeout(1)]) -> true
       ; throw(error(connection_cleanup_interrupted,node_shutdown_tests:run/0))),
       node:node_connection_count(Port,0),
       \+node:node_connection_stopping(Key),
       node:close_node_connections(Port)),
      (catch(thread_send_message(Worker,release_cleanup),_,true),
       node:unregister_node_connection(Key))),
    writeln('Node shutdown cancels each connection only once through at_exit: ok').

held_cleanup(Parent,Key) :-
    thread_send_message(Parent,cleanup_started(Key)),
    thread_get_message(release_cleanup),
    node:node_connection_exit(Key,shutdown_test_stream),
    thread_send_message(Parent,cleanup_done(Key)).
