% Test-only delay of the second down, using the existing send hook.
:- module(intensity_delayed_notification_control,[run/0]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/actors.pl').
:- dynamic armed/0.
:- multifile actors:hook_send/2.
actors:hook_send(_,down(Pid,Ref,shutdown)) :-
    Ref \== Pid,
    retract(intensity_delayed_notification_control:armed),
    supervisor_restart_tests:observer(Observer),
    thread_send_message(Observer,delayed_second_down(Pid,Ref)),
    sleep(0.05),
    fail.
run :-
    assertz(armed),
    supervisor_intensity_tests:exhaustion(one_for_one,0,normal),
    receive({delayed_second_down(Pid,Ref) -> true},
            [timeout(1),on_timeout(throw(missing_delay_control))]),
    writeq(delayed_second_notification_selected(Pid,Ref)),nl.
