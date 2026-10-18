% Regression smoke check for the repaired receiver entry (not an engine bug).
% From the repository root with its pinned TPL_LIBRARY_PATH configured:
% tpl -g "consult('reproducers/port-remote-supervisor-entry.pl'),port_remote_supervisor_entry(3061),halt"
% Use a disposable Trealla peer; no name is registered on either node.
:- use_module('../actors').
:- use_module('../distribution').
:- use_module('../supervisor_actor').

port_remote_supervisor_entry(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    setup_call_cleanup(true,
        (supervisor_spawn([],Pid,[node(URL),link(false),monitor(true)]),
         supervisor_count_children(Pid,Counts),memberchk(active-0,Counts),
         supervisor_halt(Pid),
         receive({down(Pid,Pid,Reason) -> writeq(Reason),nl},
                 [timeout(3),on_timeout(throw(no_termination_observed))])),
        remote_drop_connection(URL)).
