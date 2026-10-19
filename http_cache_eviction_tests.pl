% SPDX-License-Identifier: MIT
:- module(http_cache_eviction_tests,[run/0]).
:- use_module(actors).
:- use_module(node).
:- dynamic paused_exit/2, created/1.
:- multifile actors:hook_exit/2.

% Pause before the real exit signal, outside the cache mutex.
actors:hook_exit(Pid,kill) :-
    retract(http_cache_eviction_tests:paused_exit(Pid,Parent)),
    actors:self(Self),actors:send(Parent,eviction_paused(Self)),
    actors:receive({resume_eviction -> true}),fail.

run :-
    setup_call_cleanup(true,
      (fifo_overflow, multiple_evictions, checkout_before_eviction,
       concurrent_checkout, interrupted_eviction),
      clear_cache),
    forall(created(Pid),\+actors:actor_thread(Pid,_)),
    \+node:http_page_claim(_,_),
    writeln('HTTP cache eviction: all regressions passed').

page(Tag,Offset,Answer) :-
    node:compute_answer(member(X,[Tag,tail(Tag)]),X,Offset,1,Answer).
entry(Tag,Pid) :-
    node:goal_id(member(X,[Tag,tail(Tag)])-X,Gid),
    node:cache(Gid,1,Pid,_).

fifo_overflow :-
    node:cache_size(Size),
    forall(between(1,Size,N),
      (page(N,0,success([N],true)),entry(N,Pid),assertz(created(Pid)))),
    entry(1,Oldest),monitor(Oldest,AppRef),
    self(Self),send(Self,unrelated_eviction_message),
    Next is Size+1,page(Next,0,success([Next],true)),
    entry(Next,Newest),assertz(created(Newest)),
    \+actors:actor_thread(Oldest,_),\+entry(1,_),
    findall(P,node:cache(_,_,P,_),Cached),length(Cached,Size),
    entry(2,Second),Cached=[Second|_],last(Cached,Newest),
    receive({down(Oldest,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    receive({unrelated_eviction_message -> true},[timeout(0),on_timeout(fail)]),
    page(2,1,success([tail(2)],false)),
    page(Next,1,success([tail(Next)],false)),
    clear_cache,
    writeln('real page overflow stops FIFO victim, retains paging and application monitor: ok'),flush_output.

% Stage a batch of real producers without trimming, to exercise a single
% pass removing several entries. All other tests enter through page publication.
stage(Tag,Pid) :-
    self(Parent),
    node:goal_id(member(X,[Tag,tail(Tag)])-X,Gid),
    node:with_http_page_scope(Scope,
      (node:spawn_http_page_producer(Scope,
         (actors:self(Me),actors:send(Parent,cache_ready(Me)),
          member(X,[Tag,tail(Tag)])),X,Pid),
       assertz(created(Pid)),
       receive({cache_ready(Pid) -> true},[timeout(3),on_timeout(fail)]),
       with_mutex('$http_page_cache',
         (assertz(node:cache(Gid,0,Pid,none)),
          retractall(node:http_page_claim(Pid,Scope)))))).

multiple_evictions :-
    node:cache_size(Size),Count is Size+3,
    findall(Pid,(between(1,Count,N),stage(batch(N),Pid)),Pids),
    Pids=[A,B,C,FirstRetained|_],
    % Reinsert the newest entry through the legacy insertion helper as well
    % as testing the page-publication path used by fifo_overflow/0.
    node:goal_id(member(X,[batch(Count),tail(batch(Count))])-X,Gid),
    node:cache_retract(Gid,0,Newest,Lookahead),
    node:cache_update(Gid,0,Newest,Lookahead),
    forall(member(P,[A,B,C]),\+actors:actor_thread(P,_)),
    findall(P,node:cache(_,_,P,_),Cached),length(Cached,Size),
    Cached=[FirstRetained|_],
    forall(member(P,Cached),actors:actor_thread(P,_)),
    clear_cache,
    writeln('one trim reclaims every excess producer in FIFO order: ok'),flush_output.

concurrent_checkout :-
    node:cache_size(Size),Count is Size+2,
    findall(Pid,(between(1,Count,N),stage(race(N),Pid)),[A,B|_]),
    start_paused_eviction(A,Request,AppRef),
    checkout_during_eviction,
    send(Request,resume_eviction),
    receive({trim_complete(Request) -> true},
      [timeout(3),on_timeout(throw(eviction_completion_timeout))]),
    receive({down(Request,Request,true) -> true},
      [timeout(3),on_timeout(throw(eviction_request_down_timeout))]),
    \+actors:actor_thread(A,_),\+actors:actor_thread(B,_),
    receive({down(A,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    page(race(3),1,success([tail(race(3))],false)),
    clear_cache,
    writeln('concurrent checkout remains usable while eviction waits for termination: ok'),flush_output.

start_paused_eviction(Victim,Request,AppRef) :-
    self(Parent),assertz(paused_exit(Victim,Parent)),monitor(Victim,AppRef),
    spawn_runtime(http_cache_eviction_tests:trim_request(Parent),Request,
      [monitor(true),link(false),'$entry_context'(caller)]),
    receive({eviction_paused(Request) -> true},
      [timeout(3),on_timeout(throw(eviction_pause_timeout))]).

checkout_during_eviction :-
    % Both removals commit before waiting for termination; checkout can proceed
    % concurrently, proving that the cache mutex is not held by cleanup.
    node:goal_id(member(X,[race(1),tail(race(1))])-X,EvictedGid),
    node:with_http_page_scope(Scope,
      \+node:checkout_http_page(Scope,EvictedGid,0,_,_)),
    page(race(3),0,success([race(3)],true)).

interrupted_eviction :-
    node:cache_size(Size),Count is Size+2,
    findall(Pid,(between(1,Count,N),stage(interrupted(N),Pid)),[A,B|_]),
    monitor(A,AppRef),
    catch(node:with_http_page_scope(Scope,
      (with_mutex('$http_page_cache',node:trim_cache_owned(Scope)),
       throw(eviction_interrupted))),Error,true),
    Error==eviction_interrupted,
    \+actors:actor_thread(A,_),\+actors:actor_thread(B,_),
    receive({down(A,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    page(interrupted(3),0,success([interrupted(3)],true)),
    clear_cache,
    writeln('exception after removal reclaims every victim and preserves the original error: ok'),flush_output.

checkout_before_eviction :-
    node:cache_size(Size),Count is Size+2,
    findall(Pid,(between(1,Count,N),stage(checkout(N),Pid)),[A,B,C|_]),
    node:goal_id(member(X,[checkout(1),tail(checkout(1))])-X,Gid),
    catch(node:with_http_page_scope(Scope,
      (node:checkout_http_page(Scope,Gid,0,A,_),
       node:trim_cache,
       actors:actor_thread(A,_),\+actors:actor_thread(B,_),
       actors:actor_thread(C,_),
       throw(checkout_finished))),checkout_finished,true),
    \+actors:actor_thread(A,_),
    page(checkout(3),0,success([checkout(3)],true)),
    clear_cache,
    writeln('checkout before eviction keeps ownership; trimming skips the active request: ok'),flush_output.

trim_request(Parent) :-
    node:trim_cache,self(Self),send(Parent,trim_complete(Self)).

clear_cache :-
    retractall(paused_exit(_,_)),
    (node:cache_retract(_,_,Pid,_)
    -> node:stop_http_page_producer(Pid),clear_cache
    ; true).
