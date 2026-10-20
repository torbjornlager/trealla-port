% SPDX-License-Identifier: MIT
:- module(server_promise_cleanup_tests,[run/0]).
:- use_module(server_actor).
:- use_module(actors).
:- use_module(library(freeze)).
:- dynamic installed/1.
:- multifile actors:hook_send/2.

% Controlled transport failure after the real monitor has been installed.
actors:hook_send(Pid,'$call'(Self,_,promise_send_fault)) :-
    findall(R,actors:monitor(Self,Pid,R),Refs),
    reverse(Refs,[Ref|_]),
    assertz(server_promise_cleanup_tests:installed(Ref)),
    send(Self,down(Pid,Ref,test_down)),
    throw(promise_send_error(original)).

run :-
    spawn(receive({stop -> true}),Pid),
    setup_call_cleanup(monitor(Pid,Other),checks(Pid,Other),
      (demonitor(Other,[flush]),exit(Pid,kill))),
    writeln('Server promise setup/send cleanup: all regressions passed').

checks(Pid,Other) :-
    self(Self),send(Self,unrelated_reply),send(Self,down(other,unrelated,normal)),
    findall(R,actors:monitor(Self,Pid,R),Before),
    % make_ref/1 fails when its output cannot unify with the generated ref.
    \+server_promise(Pid,unused,0,_),
    findall(R,actors:monitor(Self,Pid,R),Before),
    writeln('failed reference setup removes only the newly installed monitor: ok'),
    catch(server_promise(Pid,promise_send_fault,_,_),Error,true),
    Error==promise_send_error(original),
    retract(installed(Failed)),\+actors:monitor(Self,_,Failed),
    receive({down(_,Failed,_) -> fail},[timeout(0)]),
    findall(R,actors:monitor(Self,Pid,R),Before),
    writeln('send exception retains its original term and flushes only its monitor: ok'),
    freeze(BadRef,throw(promise_setup_error(original))),
    catch(server_promise(Pid,unused,BadRef,_),SetupError,true),
    SetupError==promise_setup_error(original),
    findall(R,actors:monitor(Self,Pid,R),Before),
    writeln('exception during reference setup removes the installed monitor: ok'),
    actors:monitor(Self,Pid,Other),
    receive({unrelated_reply -> true},[timeout(0),on_timeout(fail)]),
    receive({down(other,unrelated,normal) -> true},[timeout(0),on_timeout(fail)]),
    writeln('unrelated monitor and mailbox messages survive all failure paths: ok'),
    % Existing request/reply idiom retains the monitor until yield completes.
    server_spawn(server_promise_cleanup_tests:echo,[],Server),
    setup_call_cleanup(true,
      (server_promise(Server,pair(X,X),Ref,Mon),
       actors:monitor(Self,Server,Mon),var(X),
       server_yield(Ref,Mon,Answer,[timeout(2),on_timeout(fail)]),
       Answer=pair(A,B),var(A),A==B,\+actors:monitor(Self,_,Mon)),
      server_halt(Server,_)),
    writeln('successful sends retain their monitor, reply sharing and yield cleanup: ok').

echo(Request,State,Request,State).
