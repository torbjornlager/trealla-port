% SPDX-License-Identifier: MIT
:- module(write_output_tests,[run/0]).
:- use_module(actors).
:- use_module(sandbox_policy).
:- use_module(toplevel_actors,[]).

run :-
    forall(member(Mode,[blacklist,whitelist]),checks(Mode)),
    receive({_ -> fail},[timeout(0)]),
    writeln('Actor write/1 output: all regressions passed').
checks(Mode) :-
    sandbox_prepare_goal(Mode,actor,user,write(pair(X,X)),Guarded),
    Guarded=actors:terminal_output(pair(A,B),[source(io)]),var(X),A==X,B==X,
    self(Self),spawn(Guarded,P,[monitor(true),io_target(Self),link(false)]),
    receive({terminal_io_output(P,pair(U,V)) -> var(U),U==V},[timeout(2),on_timeout(fail)]),
    receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),var(X),
    sandbox_prepare_goal(Mode,actor,user,call(write(abc)),Closure),
    spawn(call(Closure),C,[monitor(true),io_target(Self),link(false)]),
    receive({terminal_io_output(C,abc) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(C,C,true) -> true},[timeout(2),on_timeout(fail)]),
    catch(sandbox_prepare_goal(Mode,actor,user,write(user_output,abc),_),Error,true),
    nonvar(Error),Error=error(permission_error(call,sandboxed,_),_),
    catch(sandbox_policy:sandbox_call(Mode,actor,user,[],write(user_output,abc)),
          RuntimeError,true),nonvar(RuntimeError),
    RuntimeError=error(permission_error(call,sandboxed,_),_),
    format('~w: sharing, inherited terminal, higher-order call and stream denial: ok~n',[Mode]).
