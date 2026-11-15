% SPDX-License-Identifier: MIT
% Isolated reproducer: compare raw engine signal delivery with receiver identity checks.
% Reports raw misdelivery rather than requiring the engine bug on future versions.
:- module(n5_native_signal_reuse,[run/0,guarded/0,old/1,sender/4,victim/1,delivered/3]).
:- use_module('../native_thread_control',[]).
run :- exercise(raw),exercise(guarded).
guarded :- exercise(guarded).
exercise(Mode) :-
    thread_self(Parent),big(200000,Payload),
    forall(between(1,10,I),one(Mode,I,Parent,Payload)).
big(0,[]) :- !.
big(N,[N|Xs]) :- M is N-1,big(M,Xs).
old(Parent) :- thread_send_message(Parent,old_ready),thread_get_message(go),sleep(0.0002).
sender(Mode,Old,Parent,Payload) :-
    thread_send_message(Parent,sender_ready),thread_get_message(go),
    thread_send_message(Parent,signalling),
    catch((Mode==raw -> thread_signal(Old,n5_native_signal_reuse:delivered(Old,Parent,Payload)); native_thread_control:signal(Old,n5_native_signal_reuse:delivered(Old,Parent,Payload))),E,
          thread_send_message(Parent,send_error(E))).
victim(Parent) :- thread_self(T),thread_send_message(Parent,victim_ready(T)),thread_get_message(finish).
delivered(Expected,Parent,Payload) :- thread_self(Actual),length(Payload,N),thread_send_message(Parent,delivered(Expected,Actual,N)).
wait_gone(T) :- (catch(thread_property(T,status(_)),_,fail)->sleep(0.0001),wait_gone(T);true).
one(Mode,I,Parent,Payload) :-
    thread_create(n5_native_signal_reuse:old(Parent),Old,[detached(true)]),thread_get_message(old_ready),
    thread_create(n5_native_signal_reuse:sender(Mode,Old,Parent,Payload),Sender,[]),thread_get_message(sender_ready),
    thread_send_message(Sender,go),thread_get_message(signalling),thread_send_message(Old,go),
    wait_gone(Old),thread_create(n5_native_signal_reuse:victim(Parent),Victim,[]),thread_get_message(victim_ready(Victim)),
    thread_join(Sender,Status),
    (thread_get_message(Parent,delivered(Expected,Actual,Size),[timeout(0.1)]) ->
       (Expected==Actual -> Kind=correct;Kind=wrong_target),
       (Mode==guarded,Kind==wrong_target -> throw(stale_signal_was_executed);true),
       writeq(observation(Mode,I,Kind,Expected,Actual,Size,Status)),nl
    ; writeq(observation(Mode,I,no_delivery,Status)),nl),
    thread_send_message(Victim,finish),thread_join(Victim,_),flush_output.
