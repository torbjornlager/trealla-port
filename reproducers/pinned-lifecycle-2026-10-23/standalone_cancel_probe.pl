% SPDX-License-Identifier: MIT
% Standalone hard-cancel probe: Trealla thread, queue and mutex primitives
% only. It loads no Web Prolog file and changes no runtime code.
%
% minimal:    a detached collector polls a private queue in bounded slices
%             and acknowledges startup; the parent cancels it, polls for its
%             retirement, and only then destroys the queue.
% concurrent: the same sequence plus the surrounding traffic of the original
%             fixture: the collector takes a mutex between slices, two
%             detached sleepers stand in for the worker and timer, and right
%             after cancelling, the parent takes the mutex, posts a wakeup to
%             the queue and signals both sleepers with throw/1. The queue is
%             still destroyed only after the collector has retired.

% Created as rpc.pl creates its lifecycle mutex; with_mutex/2 needs it first.
:- catch(mutex_create(_, [alias(probe_lifecycle)]),
         error(permission_error(create, mutex, probe_lifecycle), _), true).

probe_stage(Stage) :- writeq(stage(Stage)),nl,flush_output.

probe_step(Stage,Goal) :-
    probe_stage(enter(Stage)),
    catch((call(Goal) -> Outcome=success ; Outcome=failure),Error,Outcome=exception(Error)),
    probe_stage(leave(Stage,Outcome)),
    (Outcome==success -> true
    ; Outcome=exception(E) -> throw(E)
    ; fail).

standalone_cancel(Kind,N) :-
    memberchk(Kind,[minimal,concurrent]),
    forall(between(1,N,I),
        (probe_stage(iteration(Kind,I)),
         probe_step(case(Kind,I),probe_case(Kind,I)))),
    writeln('all regressions passed').

probe_case(Kind,I) :-
    thread_self(Parent),
    message_queue_create(Q),
    (Kind==concurrent -> start_sleepers(Sleepers) ; Sleepers=[]),
    thread_create(probe_collector(Kind,Q,Parent,I),C,[detached(true)]),
    probe_step(startup_ack(C),thread_get_message(Parent,collector_started(I),[timeout(2)])),
    probe_step(cancel(C),thread_cancel(C)),
    (Kind==concurrent -> probe_step(disturb(C),disturb(Q,Sleepers)) ; true),
    probe_step(collector_retirement(C),poll(thread_gone(C),400)),
    probe_step(queue_destroy(Q),message_queue_destroy(Q)),
    probe_step(sleeper_retirement,all_gone(Sleepers)).

% Short bounded reads, because a signal does not wake an indefinitely
% blocked queue read. The 3-second bound matches the original waiter.
probe_collector(Kind,Q,Parent,I) :-
    thread_send_message(Parent,collector_started(I)),
    get_time(Start),Deadline is Start+3,
    collector_loop(Kind,Q,Deadline).
collector_loop(Kind,Q,Deadline) :-
    (Kind==concurrent -> with_mutex(probe_lifecycle,true) ; true),
    (thread_get_message(Q,_,[timeout(0.05)]) -> true
    ; get_time(Now),(Now<Deadline -> collector_loop(Kind,Q,Deadline) ; true)).

start_sleepers([W,T]) :-
    thread_create(catch(sleep(60),_,true),W,[detached(true)]),
    thread_create(catch(sleep(60),_,true),T,[detached(true)]).

disturb(Q,Sleepers) :-
    with_mutex(probe_lifecycle,thread_send_message(Q,disposed)),
    forall(member(S,Sleepers),
        catch(thread_signal(S,throw(probe_disposed)),
              error(existence_error(thread_object,_),_),true)).

all_gone(Threads) :- forall(member(T,Threads),poll(thread_gone(T),400)).

thread_gone(T) :- \+ catch(thread_property(T,status(_)),_,fail).

poll(Goal,Left) :-
    (call(Goal) -> true
    ; Left>0 -> sleep(0.005),Next is Left-1,poll(Goal,Next)
    ; throw(error(probe_wait_timeout(Goal),standalone_cancel/2))).
