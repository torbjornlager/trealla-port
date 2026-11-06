% SPDX-License-Identifier: MIT
:- module(write_output_tests,[run/0]).
:- use_module(actors).
:- use_module(sandbox_policy).
:- use_module(toplevel_actors,[]).
:- use_module(isolation,[]).

run :-
    terminal_case(writeln(raw_actor),[],[raw_actor]),
    terminal_case(writeln(source_actor),[src_text('loaded.')],[source_actor]),
    forall(member(Mode,[blacklist,whitelist]),
           (checks(Mode),newline_checks(Mode),linda_output_checks(Mode))),
    receive({_ -> fail},[timeout(0)]),
    writeln('Actor write/1 output: all regressions passed').
checks(Mode) :-
    forall(member(Kind,[write,writeln]),write_checks(Mode,Kind)),
    catch(sandbox_prepare_goal(Mode,actor,user,write(user_output,abc),_),Error,true),
    nonvar(Error),Error=error(permission_error(call,sandboxed,_),_),
    catch(sandbox_policy:sandbox_call(Mode,actor,user,[],write(user_output,abc)),
          RuntimeError,true),nonvar(RuntimeError),
    RuntimeError=error(permission_error(call,sandboxed,_),_),
    format('~w: write/writeln sharing, inherited terminal, higher-order calls and stream denial: ok~n',[Mode]).

write_checks(Mode,Kind) :-
    Input=..[Kind,pair(X,X)],
    sandbox_prepare_goal(Mode,actor,user,Input,Guarded),
    isolation:restore_actor_goal(Guarded,Public),
    Public=..[Kind,pair(A,B)],var(X),A==X,B==X,
    self(Self),spawn(Guarded,P,[monitor(true),io_target(Self),link(false)]),
    receive({terminal_io_output(P,pair(U,V)) -> var(U),U==V},[timeout(2),on_timeout(fail)]),
    receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),var(X),
    WriteABC=..[Kind,abc],
    sandbox_prepare_goal(Mode,actor,user,call(WriteABC),Closure),
    spawn(call(Closure),C,[monitor(true),io_target(Self),link(false)]),
    receive({terminal_io_output(C,abc) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(C,C,true) -> true},[timeout(2),on_timeout(fail)]).

newline_checks(Mode) :-
    atom_codes(Newline,[10]),
    forall(member(Goal,[nl,call(nl)]),
      (sandbox_prepare_goal(Mode,actor,user,Goal,Prepared),
       terminal_case(Prepared,[],[Newline]))),
    (Mode==blacklist ->
       sandbox_prepare_goal(Mode,actor,user,(G=nl,call(G)),Computed),
       terminal_case(Computed,[],[Newline])
    ; true),
    catch(sandbox_prepare_goal(Mode,actor,user,nl(user_output),_),Error,true),
    nonvar(Error),Error=error(permission_error(call,sandboxed,_),_),
    catch(sandbox_policy:sandbox_call(Mode,actor,user,[],nl(user_output)),RuntimeError,true),
    nonvar(RuntimeError),RuntimeError=error(permission_error(call,sandboxed,_),_).

% Both branches of the Linda tutorial's printing example. The local relation
% supplies tuple matches; these tests exercise output and private source copying.
linda_output_checks(Mode) :-
    atom_codes(Newline,[10]),
    Source="linda_rdp(setting(blue,size,large)). show_size :- (linda_rdp(setting(blue,size,Size))->write(Size),nl;write('No size has been published'),nl). show_missing :- (linda_rdp(setting(red,size,Size))->write(Size),nl;write('No size has been published'),nl). child :- spawn(show_size,_,[src_predicates([show_size/0,linda_rdp/1]),monitor(true)]), receive({down(_,_,true)->true}).",
    forall(member(Goal-Texts,[show_size-[large,Newline],
                            show_missing-['No size has been published',Newline],
                            child-[large,Newline]]),
      (sandbox_prepare_spawn(Mode,actor,actor_context,Goal,[src_text(Source)],Prepared,Options),
       terminal_case(Prepared,Options,Texts))),
    format('~w: nl/0 and both Linda output branches, copied child and stream denial: ok~n',[Mode]).

terminal_case(Goal,Options,Texts) :-
    self(Self),
    setup_call_cleanup(spawn(call(Goal),Pid,[monitor(true),io_target(Self),link(false)|Options]),
      (terminal_texts(Texts),
       receive({down(Pid,Pid,true)->true},[timeout(2),on_timeout(throw(missing_terminal_completion))])),
      (catch(exit(Pid,kill),_,true),catch(demonitor(Pid,[flush]),_,true))).
terminal_texts([]).
terminal_texts([Text|Texts]) :-
    atom_codes(Text,ExpectedCodes),
    receive({terminal_io_output(_,Actual)->atom_codes(Actual,Codes),Codes==ExpectedCodes},
            [timeout(2),on_timeout(throw(missing_terminal_text(Text)))]),
    terminal_texts(Texts).
