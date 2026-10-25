% SPDX-License-Identifier: MIT
:- module(boolean_option_tests,[run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(rpc,[]).

expect_boolean_error(Goal) :-
    catch(call(Goal),Error,true),nonvar(Error),
    (Error=error(type_error(boolean,_),_);Error=error(domain_error(boolean,_),_)),!.

run :-
    forall(member(V,[1,0,-1,1.0,"true","false",'TRUE',[t,r,u,e],@(true)]),
      (expect_boolean_error(spawn(true,_,[link(V)])),
       expect_boolean_error(spawn(true,_,[monitor(V)])),
       expect_boolean_error(toplevel_spawn(_,[session(V)])),
       expect_boolean_error(statechart_spawn(_,[src_text('<invalid/>'),trace(V)])),
       expect_boolean_error(rpc:rpc('http://invalid.example',true,[once(V)])),
       expect_boolean_error(rpc:promise('http://invalid.example',true,_,[once(V)])),
       self(Self),expect_boolean_error(toplevel_call(Self,true,[once(V)])),
       expect_boolean_error(toplevel_call(Self,true,[once(false),once(V)])))),
    self(Me),catch(toplevel_call(Me,true,[once(B)]),E,true),
    nonvar(E),E=error(instantiation_error,_),var(B),
    receive({'$call'(_,_) -> throw(invalid_call_was_sent)},[timeout(0)]),
    forall(member(Good,[true,false]),
      (toplevel_call(Me,true,[once(Good),once(false)]),
       receive({'$call'(_,Options) -> Options==[once(Good),once(false)]},
                [timeout(1),on_timeout(throw(missing_valid_call))]))),
    writeln('Strict Boolean options: all regressions passed').
