% SPDX-License-Identifier: MIT
:- module(public_worker_routing_tests,[run/0]).
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(sandbox_policy).

run :-
    native_control_scope,
    source_less,
    private_source,
    writeln('Public worker routing: all regressions passed').

source_less :-
    self(Self),
    toplevel_spawn(Pid,[target(Self),session(true),link(false)]),
    setup_call_cleanup(true,
      (query(Pid,parallel([X=one,Y=two]),X-Y,[one-two]),
       query(Pid,first_solution(A,[A=fast,(sleep(0.1),A=slow)]),A,[fast]),
       query(Pid,first_solution(B,[exit(killed),(sleep(0.1),B=ok)],
                             [on_error(continue)]),B,[ok]),
       query(Pid,catch(parallel([exit(killed)]),Error,true),Error,[ExitError]),
       ExitError=worker_exit(_,killed),
       sandbox_prepare_goal(blacklist,actor,actor_context,
         catch(parallel([exit(killed)]),Caught,true),Checked),
       query(Pid,Checked,Caught,[CheckedError]),CheckedError=worker_exit(_,killed),
       query(Pid,(parallel([C=one,D=two]),C==one,D==two),C-D,[one-two]),
       query(Pid,parallel([(self(Me),Me!hello,receive({hello -> true}))]),ok,[ok]),
       query_fails(Pid,((parallel([true]),!,fail);true)),
       query_fails(Pid,(parallel([true])->fail;true))),
      exit(Pid,kill)),
    writeln('Source-less toplevel worker calls: all regressions passed').

private_source :-
    self(Self),
    toplevel_spawn(Pid,[target(Self),session(true),link(false),src_text('probe(ok).')]),
    setup_call_cleanup(true,
      (query(Pid,parallel([probe(X),Y=other]),X-Y,[ok-other]),
       query(Pid,first_solution(A,[probe(A)]),A,[ok]),
       query(Pid,first_solution(B,[exit(killed),probe(B)],[on_error(continue)]),B,[ok])),
      exit(Pid,kill)),
    writeln('Private-source worker predicates and sharing remain available: ok').

query(Pid,Goal,Template,Expected) :-
    toplevel_call(Pid,Goal,[template(Template),limit(1)]),
    receive({
      success(Pid,Slice,More) ->
        Slice=Expected,
        (More==false -> true
        ; throw(unexpected_worker_continuation(Goal)));
      error(Pid,Error) -> throw(public_worker_query_error(Error));
      failure(Pid) -> throw(public_worker_query_failed(Goal))
    },[timeout(3),on_timeout(throw(public_worker_query_timeout(Goal)))]).

% Check the preparer itself without PTCP's native offset/2 wrapper.
native_control_scope :-
    isolation:sourceless_worker_goal(((parallel([true]),!,fail);true),Cut),
    \+call(Cut),
    isolation:sourceless_worker_goal((parallel([true])->fail;true),Conditional),
    \+call(Conditional),
    writeln('Worker preparation preserves native cut and conditional scopes: ok').

query_fails(Pid,Goal) :-
    toplevel_call(Pid,Goal,[limit(1)]),
    receive({failure(Pid) -> true;
             success(Pid,_,_) -> throw(unexpected_control_success);
             error(Pid,Error) -> throw(Error)},
      [timeout(3),on_timeout(throw(public_control_timeout(Goal)))]).
