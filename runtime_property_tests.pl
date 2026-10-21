% SPDX-License-Identifier: MIT
:- module(runtime_property_tests,[run/0,live/2]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(sandbox_policy,[]).

expected([implementation(trealla_native),persistent(true),
          inbound_addressable(true),dom(false),actor_isolation(native_thread),
          hard_termination(true)]).

run :-
    expected(Expected),
    findall(P,runtime_property(P),Expected),
    findall(I,runtime_property(implementation(I)),[trealla_native]),
    runtime_property(persistent(true)),
    \+runtime_property(persistent(false)),
    \+runtime_property(implementation(swi_native)),
    \+runtime_property(unknown(_)),
    \+runtime_property(42),
    \+runtime_property(runtime_property(_, _)),
    forall(member(Mode,[blacklist,whitelist]),
      forall(member(Profile,[isobase,isotope,actor]),
        checked_query(Mode,Profile,Expected))),
    toplevel_check([],Expected),
    toplevel_check([src_text('probe(ok).')],Expected),
    child_check,
    writeln('Runtime properties: enumeration, matching, sandbox, toplevel and child checks passed').

checked_query(Mode,Profile,Expected) :-
    sandbox_policy:sandbox_prepare_goal(Mode,Profile,actor_context,
      findall(P,runtime_property(P),Properties),Goal),
    setup_call_cleanup(
      isolation:prepare_actor(runtime_property_test,user,[],M),
      (isolation:run_actor_query(M,Goal),Properties==Expected),
      isolation:cleanup_actor(runtime_property_test)).

toplevel_check(Options,Expected) :-
    self(Self),
    toplevel_spawn(Pid,[target(Self),session(true),link(false),monitor(true)|Options]),
    setup_call_cleanup(true,
      (toplevel_call_synch(Pid,findall(P,runtime_property(P),Properties),Answer,
         [template(Properties),limit(1),
          timeout(3),on_timeout(throw(runtime_property_timeout))]),
       (Answer=error(Pid,E) -> throw(E)
       ; Answer=success(Pid,[Actual],false),Actual==Expected)),
      (exit(Pid,kill),receive({down(Pid,Pid,_) -> true},
                           [timeout(3),on_timeout(fail)]))).

child_check :-
    self(Self),
    spawn((runtime_property(implementation(I)),Self ! implementation(I)),Pid,
          [monitor(true),link(false),src_text('probe(ok).')]),
    receive({implementation(trealla_native) -> true},
            [timeout(3),on_timeout(throw(runtime_property_child_timeout))]),
    receive({down(Pid,Pid,true) -> true},[timeout(3),on_timeout(fail)]).

% Identical public HTTP assertions on both native runtimes; only identity varies.
live(Node,Implementation) :-
    Expected=[implementation(Implementation),persistent(true),
              inbound_addressable(true),dom(false),actor_isolation(native_thread),
              hard_termination(true)],
    rpc(Node,findall(P,runtime_property(P),Properties)),Properties==Expected,
    rpc(Node,findall(P,runtime_property(P),Private),[src_text('probe(ok).')]),
    Private==Expected,
    findall(I,rpc(Node,runtime_property(implementation(I))),[Implementation]),
    rpc(Node,runtime_property(persistent(true))),
    \+rpc(Node,runtime_property(persistent(false))),
    \+rpc(Node,runtime_property(unknown(_))),
    \+rpc(Node,runtime_property(42)),
    format('Public runtime properties on ~w: passed~n',[Implementation]).
