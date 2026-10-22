% Standalone regression: no Web Prolog, threads, callbacks, queues or sockets.
:- use_module('state-library.pl').
mark(X) :- writeq(X),nl,flush_output.
run(Path) :-
    assertz(callback_probe_state:state(kept)),
    findall(X,callback_probe_state:state(X),Before),mark(before(Before)),
    format(atom(Text),':- use_module(~q).',[Path]),
    load_text(Text,[module(callback_probe_importer)]),
    findall(X,callback_probe_state:state(X),After),mark(after(After)),
    (After == [kept] -> mark(state_preserved)
    ; throw(error(import_lost_state(After),run/1))).
