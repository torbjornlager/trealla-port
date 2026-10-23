% SPDX-License-Identifier: MIT
:- module(supervisor_source_tests,[run/0]).
:- use_module(web_prolog).
:- use_module(isolation).

run :-
    selection,
    private_case(inline_initial,
      'marker.',
      "supervisor_spawn([child(waiter,[start(receive({stop->true})),restart(temporary)])],Sup,[monitor(true)]),supervisor_count_children(Sup,[specs-1,active-1,supervisors-0,workers-1]),supervisor_halt(Sup),receive({down(Sup,Sup,true)->true},[timeout(3),on_timeout(throw(missing_down))])"),
    private_case(inline_dynamic,
      'marker.',
      "supervisor_spawn([],Sup,[monitor(true)]),supervisor_spawn_child(Sup,child(waiter,[start(receive({stop->true})),restart(temporary)]),ok),supervisor_count_children(Sup,[specs-1,active-1,supervisors-0,workers-1]),supervisor_halt(Sup),receive({down(Sup,Sup,true)->true},[timeout(3),on_timeout(throw(missing_down))])"),
    private_case(private_helpers,
      'waiter(Parent):-Parent ! ready(private_value),receive({stop->true}).',
      "self(Self),supervisor_spawn([child(waiter,[start(waiter(Self)),restart(temporary)])],Sup,[src_predicates([waiter/1]),monitor(true)]),receive({ready(private_value)->true},[timeout(3),on_timeout(throw(missing_helper))]),supervisor_count_children(Sup,[specs-1,active-1,supervisors-0,workers-1]),supervisor_halt(Sup),receive({down(Sup,Sup,true)->true},[timeout(3),on_timeout(throw(missing_down))])"),
    private_case(variable_receive,
      'wait(Clauses):-receive(Clauses). finish(Self):-Self ! finished.',
      "self(Self),spawn(wait({go->finish(Self)}),Child,[src_predicates([wait/1,finish/1]),monitor(true)]),send(Child,go),receive({finished->true},[timeout(3),on_timeout(throw(missing_body))]),receive({down(Child,Child,true)->true},[timeout(3),on_timeout(throw(missing_down))])"),
    private_case(variable_receive_options,
      'wait(Clauses,Options):-receive(Clauses,Options). done(Self):-Self ! timed_out.',
      "self(Self),spawn(wait({never->true},[timeout(0),on_timeout(done(Self))]),Child,[src_predicates([wait/2,done/1]),monitor(true)]),receive({timed_out->true},[timeout(3),on_timeout(throw(missing_callback))]),receive({down(Child,Child,true)->true},[timeout(3),on_timeout(throw(missing_down))])"),
    private_case(unrelated_monitors,
      'marker.',
      "spawn(receive({release->true}),Other,[monitor(true)]),monitor(Other,Ref),supervisor_spawn([child(waiter,[start(receive({stop->true})),restart(temporary)])],Sup,[monitor(true)]),supervisor_count_children(Sup,[specs-1,active-1,supervisors-0,workers-1]),supervisor_halt(Sup),receive({down(Sup,Sup,true)->true},[timeout(3),on_timeout(throw(missing_supervisor_down))]),send(Other,release),receive({down(Other,Other,true)->true},[timeout(3),on_timeout(throw(missing_default_down))]),receive({down(Other,Ref,true)->true},[timeout(3),on_timeout(throw(missing_extra_down))])"),
    qualification_identity,
    writeln('Supervisor source selection and variable receive: all regressions passed').

selection :-
    supervisor_actor:child_goal(actors:receive({stop->true}),actors:receive({stop->true}),[]),
    supervisor_actor:child_goal(supervisor_source_tests:user_helper,supervisor_source_tests:user_helper,[src_predicates([user_helper/0])]),
    \+ supervisor_actor:local_predicate(actors,receive/1),
    supervisor_actor:local_predicate(supervisor_source_tests,user_helper/0),
    writeln('framework entry excluded; real user helper remains copyable: ok').
user_helper :- true.

private_case(Name,Source,GoalText) :-
    isolation:source_text_atom(GoalText,Text),atom_to_term(Text,Goal,_),
    setup_call_cleanup(
      toplevel_actors:toplevel_spawn(Top,[session(true),src_text(Source)]),
      (toplevel_actors:toplevel_call_synch(Top,Goal,Answer,[template(ok),timeout(15)]),
       (Answer==success(Top,[ok],false)->true;throw(case_failed(Name,Answer)))),
      catch(toplevel_actors:toplevel_halt(Top),_,true)),
    format('~w: ok~n',[Name]).

qualification_identity :-
    setup_call_cleanup(
      toplevel_actors:toplevel_spawn(Top,[session(true),src_text('marker.')]),
      (isolation:actor_module(Top,M),
       isolation:call_in_module(M,'$actor_qualify_receive'(Clauses,Qualified)),
       var(Clauses),Clauses==Qualified,
       Clauses={stop->true},Qualified=={stop->true}),
      catch(toplevel_actors:toplevel_halt(Top),_,true)),
    writeln('variable receive qualification preserves variable identity: ok').
