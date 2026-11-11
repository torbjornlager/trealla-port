% SPDX-License-Identifier: MIT
:- module(monitor_preflight_tests,[run/0]).
:- use_module(actors).

run :-
    variable_target,
    forall(member(Node-Formal,
      [_-instantiation_error,
       "https://example.test"-type_error(atom,"https://example.test"),
       [104,116,116,112]-type_error(atom,[104,116,116,112])]),
      (snapshot(Node,Before),caught(monitor(1@Node,R),Formal),
       unchanged(Before,Node),var(R))),
    forall(member(Options-Formal,
      [_-instantiation_error,[flush|_]-instantiation_error,
       [_]-instantiation_error,bad-type_error(list,bad),
       [flush|bad]-type_error(list,[flush|bad]),
       [flush,unknown]-domain_error(demonitor_option,unknown),
       [flush,flush(X)]-domain_error(demonitor_option,flush(X)),
       [flush,flush,flush,flush,flush,flush,flush,flush,flush,flush,flush|bad]-
         type_error(list,[flush,flush,flush,flush,flush,flush,flush,flush,flush,flush,flush|bad])]),
      invalid_options(Options,Formal)),
    self(Self),send(Self,down(example,wrapper(keep),queued)),
    caught(demonitor(wrapper(V),[flush]),instantiation_error),var(V),
    receive({down(example,wrapper(keep),queued)->true},
            [timeout(0),on_timeout(throw(preflight_flushed))]),
    writeln('Monitor preflight preserves bindings, observations and queued data: passed').

caught(Goal,Formal) :-
    catch((call(Goal),Outcome=returned),error(E,_),Outcome=raised(E)),
    nonvar(Outcome),Outcome=raised(Actual),Actual=@=Formal.

variable_target :-
    setup_call_cleanup(
      (spawn(receive({finish->true}),Pid),register(preflight_named,Pid)),
      (caught(monitor(Target,Ref),instantiation_error),var(Target),var(Ref)),
      (unregister(preflight_named),exit(Pid,kill))).

invalid_options(Options,Formal) :-
    setup_call_cleanup(
      (spawn(receive({finish->true}),Pid),monitor(Pid,Ref),self(Self)),
      (send(Self,down(Pid,Ref,queued)),snapshot(Options,Before),
       caught(demonitor(Ref,Options),Formal),unchanged(Before,Options),
       actors:monitor(Self,Pid,Ref),
       receive({down(Pid,Ref,queued)->true},
               [timeout(0),on_timeout(throw(preflight_flushed))])),
      (send(Pid,finish),receive({down(Pid,Ref,true)->true},
                              [timeout(2),on_timeout(throw(preflight_removed_monitor))]))).

snapshot(Value, variable) :- var(Value), !.
snapshot(Value, term(Copy)) :- copy_term(Value,Copy).
unchanged(variable, Value) :- var(Value).
unchanged(term(Copy), Value) :- Value=@=Copy.
