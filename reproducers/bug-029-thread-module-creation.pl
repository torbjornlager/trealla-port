% SPDX-License-Identifier: MIT
% Standalone: use variable module qualifiers so compilation cannot pre-create
% the new destination and accidentally bypass the crashing path.
:- module(thread_module_creation_reproducer,[run/1]).

run(load_new) :-
    worker_load(tmc_new),writeln(passed(load_new)).
run(load_existing) :-
    '$create_module'(tmc_existing),
    worker_load(tmc_existing),writeln(passed(load_existing)).
run(module_new) :-
    worker_switch(tmc_switch),writeln(passed(module_new)).
run(module_existing) :-
    '$create_module'(tmc_switch_existing),
    worker_switch(tmc_switch_existing),writeln(passed(module_existing)).
run(command_load) :-
    load(tmc_command),verify(tmc_command),writeln(passed(command_load)).
run(command_module) :-
    switch(tmc_command_switch),verify(tmc_command_switch),writeln(passed(command_module)).

worker_load(Module) :-
    thread_create(thread_module_creation_reproducer:load(Module),T,[]),
    thread_join(T,true),verify(Module).
worker_switch(Module) :-
    thread_create(thread_module_creation_reproducer:switch(Module),T,[]),
    thread_join(T,true),verify(Module).
load(Module) :-
    atom_chars('probe(ok).',Chars),
    load_text(Chars,[module(Module)]),
    call(Module:probe(ok)).
switch(Module) :-
    '$module'(Module),assertz(Module:probe(ok)),call(Module:probe(ok)).
verify(Module) :- findall(X,call(Module:probe(X)),Xs),Xs==[ok].
