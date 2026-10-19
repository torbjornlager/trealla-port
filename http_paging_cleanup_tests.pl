% SPDX-License-Identifier: MIT
:- module(http_paging_cleanup_tests,[run/0]).
:- use_module(actors).
:- use_module(node).
:- dynamic startup_fault/1, produced/1.
:- use_module(resource_policy).
:- multifile actors:hook_spawn_reserved/2.
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),
    thread_self(Thread),http_paging_cleanup_tests:startup_fault(Thread),
    nb_setval('$test_page_pid',Pid),throw(page_start_error).
actors:hook_spawn_reserved(Pid,_) :-
    nb_current('$http_starting_page',_),
    assertz(http_paging_cleanup_tests:produced(Pid)).

run :-
    startup_failure,
    forall(member(Stage,[skip,collect,lookahead]),interruption(Stage)),
    cached_interruption,
    handoff,
    eviction_policy,
    terminal_answers,
    execution_timeout,
    forall(produced(Pid),\+actors:actor_thread(Pid,_)),
    \+node:http_page_claim(_,_),
    writeln('HTTP paging cleanup: all regressions passed').

startup_failure :-
    thread_self(Thread),assertz(startup_fault(Thread)),
    catch(node:compute_answer(true,true,0,1,_),Error,true),
    retractall(startup_fault(_)),Error==page_start_error,
    nb_getval('$test_page_pid',Pid),\+actors:actor_thread(Pid,_),
    writeln('startup exception before thread creation leaves no owned producer: ok').

% Block the actual producer at different points in the paging protocol, then
% interrupt its request thread. No sleeps or simulated collector are used.
interruption(Stage) :-
    self(Parent),
    spawn_runtime(http_paging_cleanup_tests:request(Parent,Stage),Request,
      [monitor(true),link(false),'$entry_context'(caller)]),
    receive({page_started(Producer) -> true},[timeout(3),on_timeout(fail)]),
    monitor(Producer,AppRef),
    actors:actor_thread(Request,Thread),thread_signal(Thread,throw(page_interrupted)),
    receive({request_error(page_interrupted) -> true},[timeout(3),on_timeout(fail)]),
    \+actors:actor_thread(Producer,_),
    receive({down(Producer,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    receive({down(Request,Request,true) -> true},[timeout(3),on_timeout(fail)]),
    format('interrupted ~w reclaims producer before returning, application monitor retained: ok~n',[Stage]).
request(Parent,Stage) :-
    (Stage==skip -> Offset=1;Offset=0),
    catch(node:compute_answer(http_paging_cleanup_tests:solutions(Parent,Stage,X),X,Offset,1,_),
      Error,send(Parent,request_error(Error))).
solutions(Parent,lookahead,X) :- !,
    (X=first;blocked(Parent),X=second).
solutions(Parent,_,X) :- blocked(Parent),X=first.
blocked(Parent) :- self(Pid),send(Parent,page_started(Pid)),receive({continue -> true}).

cached_interruption :-
    Goal=member(X,[cache_a,cache_b,cache_c]),
    node:compute_answer(Goal,X,0,1,success([cache_a],true)),
    node:goal_id(Goal-X,Gid),node:cache(Gid,1,Pid,_),
    monitor(Pid,AppRef),self(Self),send(Self,unrelated_page_message),
    catch(node:with_http_page_scope(Scope,
       (node:checkout_http_page(Scope,Gid,1,Pid,_),throw(checkout_interrupted))),Error,true),
    Error==checkout_interrupted,\+node:cache(Gid,1,_,_),\+actors:actor_thread(Pid,_),
    receive({down(Pid,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]),
    receive({unrelated_page_message -> true},[timeout(0),on_timeout(fail)]),
    writeln('abandoned cache checkout reclaims producer; unrelated message and monitor preserved: ok').

handoff :-
    Goal=member(X,[handoff_a,handoff_b,handoff_c]),
    node:goal_id(Goal-X,Gid),
    % An exception after publication must preserve the cached continuation.
    catch(node:with_http_page_scope(Scope,
      (node:compute_owned_answer(Scope,Goal,X,0,1,success([handoff_a],true)),
       throw(after_publication))),after_publication,true),
    node:cache(Gid,1,Pid,_),actors:actor_thread(Pid,_),
    % An earlier request may still be unwinding when the next checks out.
    node:with_http_page_scope(Old,
      (assertz(node:http_page_claim(Pid,Old)),
       node:with_http_page_scope(New,
         (node:checkout_http_page(New,Gid,1,Pid,Lookahead),
          node:close_http_page_scope(Old),actors:actor_thread(Pid,_),
          node:stream_collect(Pid,_,1,Lookahead,[handoff_b],false),
          node:publish_http_page(New,Gid,2,Pid,none))))),
    node:compute_answer(Goal,X,2,1,success([handoff_c],false)),
    \+actors:actor_thread(Pid,_),
    writeln('published and rechecked-out continuations survive prior request cleanup: ok').

terminal_answers :-
    node:compute_answer(true,ok,0,1,success([ok],false)),
    node:compute_answer(fail,_,0,1,failure),
    catch(node:compute_answer(throw(page_query_error),_,0,1,_),Error,true),Error==page_query_error,
    \+node:compute_answer(true,ok,0,1,wrong_answer),
    writeln('terminal success/failure, original query errors and output mismatch clean up: ok').

execution_timeout :-
    setup_call_cleanup(configure_resource_policy([time_limit(0.05)],_),
      (catch(node:compute_answer((repeat,fail),value,0,1,_),Error,true),
       Error=error(resource_error(time),_)),
      reset_resource_policy),
    writeln('execution timeout keeps its resource error and reclaims the producer: ok').

% Publication has already released request ownership before later eviction.
% Removing the entry models eviction without changing the cache-size policy.
eviction_policy :-
    Goal=member(X,[evict_a,evict_b]),node:goal_id(Goal-X,Gid),
    node:with_http_page_scope(Scope,
      (node:compute_owned_answer(Scope,Goal,X,0,1,success([evict_a],true)),
       \+node:http_page_claim(_,Scope),
       node:cache_retract(Gid,1,Pid,_))),
    actors:actor_thread(Pid,_),
    node:stop_http_page_producer(Pid),
    writeln('publication releases ownership before later cache eviction: ok').
