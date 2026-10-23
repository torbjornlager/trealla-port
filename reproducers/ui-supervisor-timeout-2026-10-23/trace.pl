:- use_module('../../web_prolog.pl').
:- multifile actors:hook_spawn/3.
actors:hook_spawn(G,_,O) :-
    writeq(spawn_request(G,O)),nl,flush_output,fail.
run :-
    thread_create(user:observe,_,[detached(true)]),
    toplevel_actors:toplevel_spawn(T,[session(true),src_text('probe_marker.')]),
    toplevel_actors:toplevel_call_synch(T,
      (supervisor_spawn([child(waiter,[start(receive({stop->true})),restart(temporary)])],S,[monitor(true)]),
       supervisor_count_children(S,Counts)),A,[template(S-Counts),timeout(12)]),
    writeq(answer(A)),nl,flush_output,
    halt.

observe :- sleep(1),
    findall(P-T,actors:pid_thread(P,T),Threads),writeq(threads(Threads)),nl,
    findall(P-M,isolation:actor_namespace(P,M),Modules),writeq(modules(Modules)),nl,
    findall(P-M,isolation:actor_source_namespace(P,M),Sources),writeq(sources(Sources)),nl,
    flush_output.
