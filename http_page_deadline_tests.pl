% SPDX-License-Identifier: MIT
:- module(http_page_deadline_tests,[run/0]).
:- use_module(actors).
:- use_module(node).
:- use_module(resource_policy).
:- dynamic produced/1, startup_delay/1, slow_stop/1.
:- multifile actors:hook_spawn_reserved/2, actors:hook_stop/1.

actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),
    assertz(http_page_deadline_tests:produced(Pid)),
    thread_self(Thread),
    (http_page_deadline_tests:startup_delay(Thread) -> sleep(0.4);true).

actors:hook_stop(Pid) :-
    (retract(http_page_deadline_tests:slow_stop(Pid)) -> sleep(0.3);true).

run :-
    setup_call_cleanup(configure_resource_policy([time_limit(0.2)],_),
      (startup_timeout, collection_timeout, skipping_timeout, lookahead_timeout,
       cached_requests, published_handoff, timer_cancellation, cleanup_after_cancellation,
       reply_selection, reply_cleanup, infinite_deadline),
      reset_resource_policy),
    forall(produced(Pid),\+actors:actor_thread(Pid,_)),
    \+node:http_page_claim(_,_),\+node:cache(_,_,_,_),
    writeln('HTTP whole-page deadline: all regressions passed').

time_error(error(resource_error(time),_)).

startup_timeout :-
    thread_self(Thread),
    setup_call_cleanup(assertz(startup_delay(Thread)),
      catch(node:compute_answer(true,true,0,1,_),Error,true),
      retractall(startup_delay(Thread))),
    nonvar(Error),time_error(Error),
    all_stopped,
    writeln('deadline covers startup before the producer thread exists: ok').

slow(X) :- between(1,10,X),sleep(0.05).

collection_timeout :-
    spawn(receive({stop -> true}),Witness,[link(false)]),monitor(Witness,Ref),
    self(Self),send(Self,unrelated_page_deadline_message),
    catch(node:compute_answer(http_page_deadline_tests:slow(X),X,0,8,_),Error,true),
    nonvar(Error),time_error(Error),
    send(Witness,stop),
    receive({down(Witness,Ref,true) -> true},[timeout(2),on_timeout(fail)]),
    receive({unrelated_page_deadline_message -> true},[timeout(0),on_timeout(fail)]),
    all_stopped,
    writeln('many individually fast answers exceed one page budget; unrelated monitor/message retained: ok').

skipping_timeout :-
    catch(node:compute_answer(http_page_deadline_tests:slow(X),X,8,1,_),Error,true),
    nonvar(Error),time_error(Error),all_stopped,
    writeln('offset skipping shares the page deadline: ok').

lookahead(Parent,X) :-
    between(1,3,X),
    (X==3 -> send(Parent,deadline_lookahead_reached),sleep(0.15);sleep(0.05)).
lookahead_timeout :-
    self(Parent),
    catch(node:compute_answer(http_page_deadline_tests:lookahead(Parent,X),X,0,2,_),Error,true),
    nonvar(Error),time_error(Error),
    receive({deadline_lookahead_reached -> true},[timeout(0),on_timeout(fail)]),all_stopped,
    writeln('lookahead shares the budget already spent collecting the page: ok').

cached_requests :-
    % Retain an unrelated cache entry throughout the timed-out request.
    Other=member(Y,[other_a,other_b]),
    node:compute_answer(Other,Y,0,1,success([other_a],true)),
    Goal=http_page_deadline_tests:slow(X),
    node:compute_answer(Goal,X,0,1,success([1],true)),
    sleep(0.25),
    node:compute_answer(Goal,X,1,1,success([2],true)),
    node:goal_id(Goal-X,Gid),node:cache(Gid,2,Pid,_),
    catch(node:compute_answer(Goal,X,2,8,_),Error,true),
    nonvar(Error),time_error(Error),\+node:cache(Gid,_,_,_),
    \+actors:actor_thread(Pid,_),
    node:compute_answer(Other,Y,1,1,success([other_b],false)),
    all_stopped,
    writeln('cached pages get fresh budgets; idle time and unrelated continuations are preserved: ok').

published_handoff :-
    Goal=member(X,[published_a,published_b]),
    catch(node:with_http_page_scope(Scope,
      node:with_http_page_deadline(
        (node:compute_owned_answer(Scope,Goal,X,0,1,success([published_a],true)),
         sleep(0.4)))),Error,true),
    nonvar(Error),time_error(Error),
    node:goal_id(Goal-X,Gid),node:cache(Gid,1,Pid,_),actors:actor_thread(Pid,_),
    node:compute_answer(Goal,X,1,1,success([published_b],false)),all_stopped,
    writeln('expiry after cache publication does not reclaim the handed-off producer: ok').

timer_cancellation :-
    node:compute_answer(true,ok,0,1,success([ok],false)),sleep(0.25),
    \+node:with_http_page_deadline(fail),sleep(0.25),
    catch(node:with_http_page_deadline(throw(original_page_error)),Error,true),
    Error==original_page_error,sleep(0.25),
    % Normalization must not instantiate an ordinary user exception.
    catch(node:with_http_page_deadline(throw(error(UserError,context))),E,true),
    E=error(StillVariable,context),var(UserError),var(StillVariable),
    writeln('success, failure and exceptions cancel the timer before later caller work: ok').

infinite_deadline :-
    setup_call_cleanup(configure_resource_policy([time_limit(infinite)],_),
      node:compute_answer(http_page_deadline_tests:slow(X),X,0,12,
                         success([1,2,3,4,5,6,7,8,9,10],false)),
      configure_resource_policy([time_limit(0.2)],_)),
    all_stopped,writeln('infinite owner time limit remains unbounded: ok').

reply_selection :-
    self(Self),
    Messages=[sol(application),eos,producer_error(application),
      '$http_page_reply'(unrelated,sol(other)),
      '$http_page_reply'(unrelated,eos),
      '$http_page_reply'(unrelated,producer_error(other))],
    forall(member(M,Messages),send(Self,M)),
    Goal=member(X,[a,b,c,d]),
    node:compute_answer(Goal,X,1,1,success([b],true)),
    node:compute_answer(Goal,X,2,2,success([c,d],false)),
    forall(member(Expected,Messages),
      receive({Expected -> true},[timeout(0),on_timeout(fail)])),
    all_stopped,
    writeln('skipping, collection and lookahead select only their producer; unrelated replies remain: ok').

cleanup_after_cancellation :-
    catch(node:with_http_page_scope(Scope,
      node:with_http_page_deadline(
        (node:spawn_http_page_producer(Scope,true,ok,Pid),
         self(Self),node:stream_collect(Pid,Self,1,none,[ok],false),
         assertz(slow_stop(Pid)),throw(original_before_cleanup)))),Error,true),
    Error==original_before_cleanup,all_stopped,
    writeln('the request timer is cancelled before cleanup lasting longer than its budget: ok').

reply_cleanup :-
    self(Self),
    node:with_http_page_scope(Scope,
      (node:spawn_http_page_producer(Scope,true,ok,Pid),monitor(Pid,AppRef),
       node:stream_collect(Pid,Self,1,none,[ok],false),
       % Model replies already queued when the request unwinds. The private
       % down barrier must precede draining all three reply kinds.
       send(Self,'$http_page_reply'(Pid,sol(late))),
       send(Self,'$http_page_reply'(Pid,eos)),
       send(Self,'$http_page_reply'(Pid,producer_error(late_error))),
       send(Self,'$http_page_reply'(unrelated,sol(retained))))),
    receive({'$http_page_reply'(Pid,_) -> fail},[timeout(0)]),
    receive({'$http_page_reply'(unrelated,sol(retained)) -> true},
      [timeout(0),on_timeout(fail)]),
    receive({down(Pid,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    node:compute_answer(member(X,[fresh]),X,0,1,success([fresh],false)),all_stopped,
    writeln('cleanup drains owned solution/end/error replies only, preserving application monitors: ok').

all_stopped :- forall(produced(Pid),\+actors:actor_thread(Pid,_)).
