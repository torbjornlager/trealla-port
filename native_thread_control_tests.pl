% SPDX-License-Identifier: MIT
:- module(native_thread_control_tests,[run/0,waiter/1]).
:- use_module(native_thread_control,[]).
:- use_module(sandbox_policy,[]).
:- use_module('reproducers/n5-native-signal-reuse-2026-11-15',[]).

run :-
    thread_self(Self),
    thread_create(native_thread_control_tests:waiter(Self),Worker,[]),
    thread_get_message(ready(Worker)),
    native_thread_control:signal(Worker,thread_send_message(Self,delivered)),
    thread_get_message(delivered),
    native_thread_control:cancel(Worker),
    thread_join(Worker,exited(cancelled)),
    % The same control goal delivered to a reused thread must have no effect.
    native_thread_control:deliver(Worker,throw(wrong_recipient)),
    catch(native_thread_control:deliver(Self,throw(expected_recipient)),Expected,true),
    Expected==expected_recipient,
    forall(member(Mode,[blacklist,whitelist]),
      (catch(sandbox_policy:sandbox_check_goal(Mode,actor,actor_context,
             native_thread_control:cancel(main)),Error,true),
       nonvar(Error))),
    n5_native_signal_reuse:guarded,
    writeln('Native control signals check the receiver identity; intended cancellation and sandbox denial: passed').

waiter(Parent) :-
    thread_self(Self),thread_send_message(Parent,ready(Self)),
    thread_get_message(never).
