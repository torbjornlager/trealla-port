% Standalone Trealla module-table growth/lookup race. No Web Prolog code.
:- module(module_map_reproducer, [run/0]).
:- use_module(library(lists)).

worker_loop(0) :- !.
worker_loop(N) :-
    append([a,b], [c,d], List),
    length(List, 4),
    Next is N-1,
    worker_loop(Next).

run :-
    thread_self(Main),
    thread_create((thread_send_message(Main, ready), worker_loop(200000)),
                  Worker, []),
    thread_get_message(ready),
    forall(between(1, 300, N),
           (format(atom(Module), 'grow_~w', [N]), '$create_module'(Module))),
    thread_join(Worker, true).
