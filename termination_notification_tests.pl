% SPDX-License-Identifier: MIT
:- module(termination_notification_tests,[run/0,live/1,explicit_live/1,combined_connections_diagnostic/1]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(distribution).
:- use_module(web_prolog,[]).

run :-
    relay_case([], [701]),
    relay_case(['$sync_monitor'(ref(3))], [701,'$sync_monitor'(ref(3))]),
    relay_case([701,application,'$sync_monitor'(ref(3)),application,701],
               [701,application,'$sync_monitor'(ref(3))]),
    writeln('Termination relay: default, private, duplicate, removed and unrelated refs: ok').

relay_case(Refs,Expected) :-
    make_ref(Id),format(atom(File),'/tmp/trealla-down-notifications-~w.bin',[Id]),
    setup_call_cleanup(true,
      (web_prolog:relay_set_actors([actor(701,probe_runtime,session),actor(702,other_runtime,session)]),
       findall(monitor(probe_runtime,R),member(R,Refs),Monitors),
       web_prolog:relay_set_monitors([monitor(other_runtime,unrelated)|Monitors]),
       web_prolog:relay_add_monitor(probe_runtime,removed),
       web_prolog:relay_remove_monitor(removed),
       web_prolog:relay_set_halts([]),
       once(setup_call_cleanup(open(File,write,Out,[type(binary)]),
         (web_prolog:relay_message(ws(Out,server,65536),down(probe_runtime,ignored,true)),
          web_prolog:relay_message(ws(Out,server,65536),down(probe_runtime,ignored,true))),
         close(Out))),
       once(setup_call_cleanup(open(File,read,In,[type(binary)]),read_refs(In,Actual),close(In))),
       msort(Actual,Sorted),msort(Expected,Sorted),
       web_prolog:relay_monitors([monitor(other_runtime,unrelated)]),
       web_prolog:relay_actors([actor(702,other_runtime,session)])),
      (web_prolog:relay_set_actors([]),web_prolog:relay_set_monitors([]),delete_file(File))).

read_refs(In,Refs) :-
    peek_byte(In,Byte),
    (Byte == -1 -> Refs=[]
    ; web_prolog:web_prolog_receive(ws(In,client,65536),JSON),
      web_prolog:json_atom_field(JSON,type,down),
      web_prolog:json_pid_field(JSON,pid,701),
      web_prolog:json_pid_field(JSON,ref,Ref),
      web_prolog:json_term_field(JSON,reason,true),
      Refs=[Ref|Rest],read_refs(In,Rest)).

live(URL) :-
    setup_call_cleanup(true,
      (one_shot(URL),existing_one_shot(URL),independent_monitors(URL),
       format('Termination notification contracts on ~w: passed~n',[URL])),
      remote_drop_connection(URL)).

% Keep the independent explicit-connection contract in a fresh client process.
% The pinned engine can crash when it follows the transparent sequence above;
% this also reproduces with the pre-repair demonitor implementation.
explicit_live(URL) :- explicit_refs(URL).
combined_connections_diagnostic(URL) :-
    setup_call_cleanup(true,
      (one_shot(URL),existing_one_shot(URL),independent_monitors(URL),
       explicit_live(URL)),
      remote_drop_connection(URL)).

one_shot(URL) :-
    toplevel_spawn(P,[node(URL),session(false),link(false),monitor(true)]),
    one_shot_answer(P).
existing_one_shot(URL) :-
    distribution:transparent_node(URL,Node),
    distribution:remote_toplevel_spawn_mode(Node,P,
      user:[session(false),link(false),monitor(true)],transparent),
    one_shot_answer(P).
one_shot_answer(P) :-
    toplevel_call_synch(P,true,Answer,[timeout(2)]),
    Answer==success(P,[true],false),
    receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(P,P,_) -> fail},[timeout(0.1),on_timeout(true)]),
    receive({down(P,'$sync_monitor'(_),_) -> fail},[timeout(0),on_timeout(true)]),
    writeln('one-shot answer and independent spawn notification, exactly once: ok').

independent_monitors(URL) :-
    spawn(receive({finish -> true}),Unrelated,[link(false)]),monitor(Unrelated,OtherRef),
    setup_call_cleanup(true,
      (toplevel_spawn(P,[node(URL),session(true),link(false),monitor(true)]),
       monitor(P,Keep),
       setup_call_cleanup(true,
         (toplevel_call_synch(P,true,Answer,[timeout(2)]),
          Answer==success(P,[true],false),
          exit(P,kill),
          receive({down(P,P,Reason) -> true},[timeout(2),on_timeout(fail)]),
          receive({down(P,Keep,Reason) -> true},[timeout(2),on_timeout(fail)]),
          receive({down(P,_,_) -> fail},[timeout(0.1),on_timeout(true)])),
         (exit(P,kill),demonitor(Keep,[flush])))),
      (exit(Unrelated,kill),
       receive({down(Unrelated,OtherRef,_) -> true},[timeout(2),on_timeout(fail)]),
       demonitor(OtherRef,[flush]))),
    writeln('spawn/additional refs survive private cleanup; unrelated monitor preserved: ok').

% Retain explicit transport reference checks alongside public monitor tests.
explicit_refs(URL) :-
    remote_node_open(URL,Node),
    setup_call_cleanup(true,
      (remote_toplevel_spawn(Node,P,[session(true)]),
       remote_monitor(Node,P,Keep),remote_monitor(Node,P,Removed),
       remote_demonitor(Node,Removed),
       remote_toplevel_call_synch(Node,P,true,Answer,[timeout(2)]),
       Answer==success(P,[true],false),
       remote_exit(Node,P,kill),
       receive({down(P,Keep,Reason) -> nonvar(Reason)},[timeout(2),on_timeout(fail)]),
       receive({down(P,Default,DefaultReason) -> nonvar(DefaultReason)},[timeout(2),on_timeout(fail)]),
       Default\==Keep,Default\==Removed,\+Default='$sync_monitor'(_),
       receive({down(P,_,_) -> fail},[timeout(0.1),on_timeout(true)])),
      remote_node_close(Node)),
    writeln('explicit protocol retains default/kept refs, removes demonitor ref and filters private refs: ok').
