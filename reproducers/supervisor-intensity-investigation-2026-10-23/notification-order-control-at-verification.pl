% Test-only scheduling control. Uses the existing send hook; no engine or
% application-runtime source is patched. The original zero-time assertion runs.
:- module(intensity_notification_order_control,[run/0]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/supervisor_intensity_tests.pl',[]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/actors.pl').
:- dynamic armed/0.
:- multifile actors:hook_send/2.
actors:hook_send(_,down(Pid,Ref,shutdown)) :-
    Ref \== Pid,
    retract(intensity_notification_order_control:armed),
    thread_self(Sender),
    supervisor_restart_tests:observer(Observer),
    thread_send_message(Observer,intensity_gate(Sender,Pid,Ref)),
    (thread_get_message(Sender,intensity_release,[timeout(5)]) -> true
    ; throw(intensity_gate_release_timeout)),
    fail.

run :-
    assertz(armed),
    catch(supervisor_intensity_tests:exhaustion(one_for_one,0,normal),Error,true),
    Error == intensity_assertion_failed(extra_supervisor_down),
    receive({intensity_gate(Sender,Sup,Ref) -> true},
            [timeout(1),on_timeout(throw(missing_gate))]),
    thread_send_message(Sender,intensity_release),
    receive({down(Sup,Ref,shutdown) -> true},
            [timeout(1),on_timeout(throw(missing_released_down))]),
    writeln('original zero-time assertion failed while second notification was pending; exact notification arrived after release').
