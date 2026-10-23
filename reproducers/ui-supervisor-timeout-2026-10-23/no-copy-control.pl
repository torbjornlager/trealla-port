:- use_module('../../web_prolog.pl').
:- multifile actors:hook_spawn/3.
% Test adapter only: bypass copying the framework receive/1 into this child.
actors:hook_spawn(supervisor_actor:child_entry(Goal),Pid,Options0) :-
    memberchk(src_list([(receive(_):-receive(_,[]))]),Options0),
    !,
    exclude(copied_receive_option,Options0,Options),
    actors:current_actor_namespace(Namespace),
    actors:spawn_scoped(supervisor_actor:child_entry(Goal),Pid,Options,Namespace,public).
copied_receive_option(src_list([(receive(_):-receive(_,[]))])).
run :-
    toplevel_actors:toplevel_spawn(T,[session(true),src_text('probe_marker.')]),
    toplevel_actors:toplevel_call_synch(T,
      (supervisor_spawn([child(waiter,[start(receive({stop->true})),restart(temporary)])],S,[monitor(true)]),
       supervisor_count_children(S,Counts),supervisor_halt(S),
       receive({down(S,S,Reason)->true},[timeout(3),on_timeout(throw(missing_down))])),
      A,[template(Counts-Reason),timeout(12)]),
    writeq(answer(A)),nl,flush_output,halt.
