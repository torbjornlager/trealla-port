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
    nb_setval('$paging_test_case',case(Stage,Request,unknown,unknown)),
    page_expect(producer_started,(receive({page_started(Producer) -> true},[timeout(3),on_timeout(fail)]))),
    nb_setval('$paging_test_case',case(Stage,Request,Producer,unknown)),
    page_expect(producer_monitor,(monitor(Producer,AppRef))),
    nb_setval('$paging_test_case',case(Stage,Request,Producer,AppRef)),
    page_expect(request_thread,(actors:actor_thread(Request,Thread))),page_expect(request_signal,(thread_signal(Thread,throw(page_interrupted)))),
    page_expect(request_error,(receive({request_error(page_interrupted) -> true},[timeout(3),on_timeout(fail)]))),
    page_expect(producer_retired,(\+actors:actor_thread(Producer,_))),
    page_expect(application_monitor,(receive({down(Producer,AppRef,kill) -> true},[timeout(2),on_timeout(fail)]))),
    page_expect(request_terminated,(receive({down(Request,Request,true) -> true},[timeout(3),on_timeout(fail)]))),
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

% Publication releases request ownership. The low-level removal primitive
% transfers responsibility to its caller; actual overflow reclamation is
% covered separately by http_cache_eviction_tests.pl.
eviction_policy :-
    Goal=member(X,[evict_a,evict_b]),node:goal_id(Goal-X,Gid),
    node:with_http_page_scope(Scope,
      (node:compute_owned_answer(Scope,Goal,X,0,1,success([evict_a],true)),
       \+node:http_page_claim(_,Scope),
       node:cache_retract(Gid,1,Pid,_))),
    actors:actor_thread(Pid,_),
    node:stop_http_page_producer(Pid),
    writeln('publication releases ownership before explicit cache removal: ok').

% Diagnostics only. Preserve the checked goals, exact reply patterns and
% timeout budgets. Successful checks are quiet; a failed check reports its
% stage instead of returning an unlabelled failure to the test runner.
:- meta_predicate page_expect(+,0).
page_expect(Check,Goal) :-
    ( catch(call(Goal),Error,
        (page_failure_snapshot(exception(Check,Error)),throw(Error))) -> true
    ; page_failure_snapshot(failed(Check)),
      throw(page_assertion_failed(Check))
    ).

page_failure_snapshot(Check) :-
    nb_getval('$paging_test_case',Case),
    writeq(paging_failure(Case,Check)),nl,flush_output,
    page_probe_step(deferred),actors:deferred_list(Deferred),
    writeq(main_deferred(Deferred)),nl,flush_output,
    page_probe_step(native_head),thread_self(Main),
    (thread_peek_message(Main,Head) -> NativeHead=some(Head);NativeHead=none),
    writeq(main_native_head(NativeHead)),nl,flush_output,
    page_probe_step(actor_registry),
    (setup_call_cleanup(mutex_trylock('$actor_registry'),
      (findall(P-T,actors:pid_thread(P,T),Mappings),
       findall(P,actors:actor_alive(P),Live),
       findall(Owner-P-Ref,actors:monitor(Owner,P,Ref),Monitors)),
      mutex_unlock('$actor_registry'))
    -> Registry=state(Mappings,Live,Monitors);Registry=busy),
    writeq(registry_snapshot(Registry)),nl,flush_output,
    page_probe_step(page_cache),
    (setup_call_cleanup(mutex_trylock('$http_page_cache'),
      (findall(P-Scope,node:http_page_claim(P,Scope),Claims),
       findall(cache(Gid,Offset,P,Lookahead),node:cache(Gid,Offset,P,Lookahead),Cache)),
      mutex_unlock('$http_page_cache'))
    -> CacheState=state(Claims,Cache);CacheState=busy),
    writeq(cache_snapshot(CacheState)),nl,flush_output,
    page_probe_step(done).
page_probe_step(Step) :- writeq(snapshot_step(Step)),nl,flush_output.
