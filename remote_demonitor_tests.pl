% SPDX-License-Identifier: MIT
:- module(remote_demonitor_tests,[run/0,live/1]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(distribution).

run :-
    lock_ack_and_flush,
    writer_ownership,
    stopped_writer,
    unresponsive_writer,
    writeln('Remote demonitor: lock, acknowledgement, ownership, flush and writer failures: ok').

lock_ack_and_flush :-
    self(Self),make_ref(Ref),make_ref(Keep),make_ref(Foreign),make_ref(Other),
    P=91001@'http://demonitor-fixture.test',
    spawn((nb_setval('$distribution_monitors',
                    [monitor(91001,Ref,Self),monitor(91001,Keep,Self),monitor(91002,Foreign,other_owner)]),
           repeat,
           receive({'$transparent_demonitor'(R,W,T) ->
             send(Self,down(P,R,already_selected)),
             distribution:writer_message('$transparent_demonitor'(R,W,T),unused,unused,true),
             nb_getval('$distribution_monitors',Left),send(Self,writer_state(Left))}),fail),
          Writer,[link(false)]),
    distribution:manager_register_route(P,Writer),
    assertz(actors:monitor(Self,P,Ref)),assertz(actors:monitor(Self,P,Keep)),
    assertz(actors:monitor(other_owner,P,Foreign)),
    setup_call_cleanup(true,
      (demonitor(Foreign,[flush]),actors:monitor(other_owner,P,Foreign),
       send(Self,down(P,Ref,old_one)),send(Self,down(P,Ref,old_two)),
       send(Self,down(other,Other,keep)),send(Self,retain_marker),
       demonitor(Ref,[flush]),
       \+actors:monitor(Self,P,Ref),actors:monitor(Self,P,Keep),
       receive({writer_state(State) ->
         State==[monitor(91001,Keep,Self),monitor(91002,Foreign,other_owner)]},
         [timeout(1),on_timeout(fail)]),
       receive({down(_,Ref,_) -> fail},[timeout(0),on_timeout(true)]),
       receive({down(other,Other,keep) -> true},[timeout(0),on_timeout(fail)]),
       receive({retain_marker -> true},[timeout(0),on_timeout(fail)]),
       demonitor(Ref,[flush]),demonitor(Ref),
       receive({writer_state(_) -> fail},[timeout(0),on_timeout(true)])),
      (retractall(actors:monitor(Self,P,_)),retractall(actors:monitor(other_owner,P,_)),
       distribution:manager_forget_route_if_running(P),exit(Writer,kill))).

writer_ownership :-
    self(Self),make_ref(Ref),make_ref(Ticket),
    nb_setval('$distribution_monitors',[monitor(1,Ref,Self),monitor(1,Ref,other_owner)]),
    distribution:writer_message('$transparent_demonitor'(Ref,Self,Ticket),unused,unused,true),
    receive({'$transparent_demonitor_done'(Ticket) -> true},[timeout(0),on_timeout(fail)]),
    nb_getval('$distribution_monitors',[monitor(1,Ref,other_owner)]),
    nb_setval('$distribution_monitors',[]).

stopped_writer :-
    self(Self),make_ref(Ref),P=91003@'http://demonitor-fixture.test',
    spawn(receive({finish -> true}),Writer,[link(false)]),monitor(Writer,Dead),
    distribution:manager_register_route(P,Writer),assertz(actors:monitor(Self,P,Ref)),
    setup_call_cleanup(true,
      (exit(Writer,kill),receive({down(Writer,Dead,_) -> true},[timeout(1),on_timeout(fail)]),
       demonitor(Ref,[flush]),\+actors:monitor(Self,P,Ref),
       \+actors:monitor(Self,Writer,_)),
      (demonitor(Dead,[flush]),retractall(actors:monitor(Self,P,_)),
       distribution:manager_forget_route_if_running(P),exit(Writer,kill))).

unresponsive_writer :-
    self(Self),make_ref(Ref),P=91004@'http://demonitor-fixture.test',
    spawn(receive({finish -> true}),Writer,[link(false)]),
    distribution:manager_register_route(P,Writer),assertz(actors:monitor(Self,P,Ref)),
    setup_call_cleanup(true,
      (catch(demonitor(Ref,[flush]),Error,true),
       Error==error(remote_demonitor_timeout(P),demonitor/2),
       actors:monitor(Self,P,Ref),\+actors:monitor(Self,Writer,_)),
      (retractall(actors:monitor(Self,P,_)),
       distribution:manager_forget_route_if_running(P),exit(Writer,kill))).

live(URL) :-
    setup_call_cleanup(true,live_refs(URL),remote_drop_connection(URL)),
    format('Public remote demonitor contracts on ~w: passed~n',[URL]).
live_refs(URL) :-
    self(Self),spawn(receive({finish -> true}),Unrelated,[link(false)]),monitor(Unrelated,Other),
    setup_call_cleanup(true,
      (toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true)]),
       monitor(P,Keep),monitor(P,Removed),
       setup_call_cleanup(true,
         (spawn((demonitor(Keep,[flush]),send(Self,foreign_attempt_done)),Foreign,
                [link(false),monitor(true)]),
          receive({foreign_attempt_done -> true},[timeout(2),on_timeout(fail)]),
          receive({down(Foreign,Foreign,true) -> true},[timeout(2),on_timeout(fail)]),
          send(Self,down(P,Removed,queued_one)),send(Self,down(P,Removed,queued_two)),
          demonitor(Removed,[flush]),demonitor(Removed),demonitor(Removed,[flush]),
          toplevel_call_synch(P,true,Answer,[timeout(2)]),Answer==success(P,[true],false),
          exit(P,kill),
          receive({down(P,P,Reason) -> true},[timeout(2),on_timeout(fail)]),
          receive({down(P,Keep,Reason) -> true},[timeout(2),on_timeout(fail)]),
          receive({down(P,_,_) -> fail},[timeout(0.1),on_timeout(true)])),
         (exit(P,kill),demonitor(Keep,[flush]),demonitor(Removed,[flush])))),
      (exit(Unrelated,kill),
       receive({down(Unrelated,Other,_) -> true},[timeout(2),on_timeout(fail)]),
       demonitor(Other,[flush]))).
