% SPDX-License-Identifier: MIT
:- module(promise_callback_context_tests,[run/0]).
:- use_module(actors).
:- use_module(rpc).
:- use_module(toplevel_actors).
:- use_module(sandbox_policy).

run :-
    variable_goal_guard,
    with_pending(source_less),
    with_pending(private_helper),
    with_pending(explicit_callback),
    with_pending(sandbox_callbacks),
    writeln('Promise callback context: all regressions passed').

% Deterministic pending/ready lifecycle fixtures avoid network scheduling.
with_pending(Test) :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_)),
    setup_call_cleanup(true,call(Test,Ref),promise_cleanup(Ref)).
with_shell(Options,Goal) :-
    self(Self),toplevel_spawn(Pid,[target(Self),session(true),link(false)|Options]),
    setup_call_cleanup(true,call(Goal,Pid),exit(Pid,kill)).
query(Pid,Goal) :-
    toplevel_call_synch(Pid,call(Goal),Answer,
      [template(ok),limit(1),timeout(3),on_timeout(throw(callback_query_timeout))]),
    (Answer==success(Pid,[ok],false) -> true ; throw(callback_query_answer(Answer))).

source_less(Ref) :- with_shell([],source_less_queries(Ref)).
source_less_queries(Ref,Pid) :-
    format(atom(Text),'self(S),S!unrelated,yield(~q,A,[timeout(0),on_timeout((A=waiting(X,X),X=shared,S!seen(A)))]),A==waiting(shared,shared),receive({seen(Seen)->Seen==A},[timeout(1)]),receive({seen(_)->fail},[timeout(0),on_timeout(true)]),receive({unrelated->true},[timeout(1)])',[Ref]),
    read_term_from_atom(Text,Goal,[]),
    sandbox_prepare_goal(blacklist,actor,actor_context,Goal,Checked),
    query(Pid,Checked),
    rpc:deliver_promise_answer(Ref,success([ok],false)),
    query(Pid,(yield(Ref,A),A==success([ok],false))),
    writeln('source-less context, sharing, one callback, unrelated data and retry: ok').

private_helper(Ref) :-
    Source='wait_here(A) :- A=waiting, self(S), S ! seen(A). callback_wait(R,A) :- yield(R,A,[timeout(0),on_timeout(wait_here(A))]).',
    sandbox_prepare_options(blacklist,actor,actor_context,[src_text(Source)],Options),
    with_shell(Options,private_queries(Ref)).
private_queries(Ref,Pid) :-
    query(Pid,(yield(Ref,A,[timeout(0),on_timeout(wait_here(A))]),A==waiting,
      receive({seen(X)->X==waiting},[timeout(1)]))),
    query(Pid,(self(S),spawn((callback_wait(Ref,A),S!copied(A)),Child,
      [src_predicates([callback_wait/2,wait_here/1]),monitor(true),link(false)]),
      receive({copied(X)->X==waiting},[timeout(2)]),
      receive({down(Child,Child,true)->true},[timeout(2)]))),
    rpc:deliver_promise_answer(Ref,success([ok],false)),query(Pid,yield(Ref,success([ok],false))),
    writeln('private callback helper and retry: ok').

explicit_callback(Ref) :-
    yield(Ref,A,promise_callback_context_tests:[timeout(0),on_timeout(explicit_wait(A))]),
    A==explicit,
    yield(Ref,B,[timeout(0),on_timeout(promise_callback_context_tests:explicit_wait(B))]),
    B==explicit,
    writeln('explicit option and callback qualification: ok').
explicit_wait(explicit).

sandbox_callbacks(Ref) :- with_shell([],sandbox_queries(Ref)).
sandbox_queries(Ref,Pid) :-
    % Prepare before the shell call, but compute the options inside it. The
    % callback policy must run before a pending promise is claimed/consumed.
    sandbox_prepare_goal(blacklist,actor,actor_context,
      yield(Ref,_,Options),Guarded),
    writeln(checking_forbidden),
    query(Pid,(Options=[timeout(0),on_timeout(halt)],
      catch(Guarded,E,true),nonvar(E),E=error(permission_error(call,sandboxed,halt),_))),
    sandbox_prepare_goal(whitelist,actor,actor_context,
      yield(Ref,A,[timeout(0),on_timeout((A=waiting,self(S),S!guarded_seen))]),Allowed),
    writeln(checking_allowed),
    query(Pid,(Allowed,A==waiting,receive({guarded_seen->true},[timeout(1)]))),
    rpc:deliver_promise_answer(Ref,success([ok],false)),query(Pid,yield(Ref,success([ok],false))),
    writeln('computed forbidden callback rejected; permitted callback and retry preserved: ok').

variable_goal_guard :-
    sandbox_policy:rewrite_goal(blacklist,actor,actor_context,[],Goal,Prepared),
    var(Goal),Prepared=sandbox_policy:sandbox_call(blacklist,actor,actor_context,[],Goal),
    writeln('variable meta-goals remain uninstantiated: ok').
