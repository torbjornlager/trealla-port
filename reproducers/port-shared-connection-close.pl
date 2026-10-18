% SPDX-License-Identifier: MIT
% Application-level stress observation, not a minimized engine bug.
% Requires an existing disposable peer (for example assessment port 3061).
% This pattern exited with status 139 during the v3.13.10 assessment.
% Sixteen fresh pre-repair runs passed; the historical crash is intermittent.
% The port now confirms reader termination before closing the shared stream.
% tpl -g "consult('reproducers/port-shared-connection-close.pl'),reproducer(3061),halt"
:- use_module('../distribution').
:- use_module('../actors').

reproducer(Port) :-
    format(atom(URL),'ws://127.0.0.1:~w/ws',[Port]),
    remote_node_open(URL,Node),remote_toplevel_spawn(Node,P,[session(true)]),
    spawn(user:close_shared(Node),_,[link(false)]),
    catch(remote_toplevel_next_synch(Node,P,Answer,[timeout(3)]),Error,true),
    writeq(result(Answer,Error)),nl.
close_shared(Node) :- sleep(0.05),remote_node_close(Node).
