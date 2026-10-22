% Diagnostic only: no runtime modifications.
:- use_module('../../rpc').
:- use_module('../../actors').
mark(Stage) :- writeq(stage(Stage)),nl,flush_output.
run :-
    mark(begin),make_ref(Ref),
    rpc:promise_transaction(rpc:new_promise_state(Ref,_)),mark(promise_created),
    self(Parent),mark(parent(Parent)),
    spawn((writeq(stage(child_enter)),nl,flush_output,
           catch(yield(Ref,Answer,[timeout(0),on_timeout(local_wait(Answer))]),
                 E,(writeq(stage(child_error(E))),nl,flush_output,throw(E))),
           writeq(stage(child_yield(Answer))),nl,flush_output,
           Parent ! promise_callback_result(Answer)),Pid,
          [src_text('local_wait(waiting).'),monitor(true),link(false)]),
    mark(spawn_returned(Pid)),
    receive({promise_callback_result(Answer) -> mark(answer(Answer))},
            [timeout(2),on_timeout(mark(answer_timeout))]),
    receive({down(Pid,Pid,Reason) -> mark(down(Reason))},
            [timeout(2),on_timeout(mark(down_timeout))]),
    mark(before_cleanup),promise_cleanup(Ref),mark(done).

steps :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_)),self(Parent),
    mutex_property('$rpc_promise_lifecycle',status(MS)),mark(parent_mutex(MS)),
    mark(before_spawn),spawn(user:yield_steps(Ref,Parent),Pid,
        [src_text('local_wait(waiting).'),monitor(true),link(false)]),
    mark(spawn_returned(Pid)),
    receive({promise_callback_result(A) -> mark(answer(A))},[timeout(2)]),
    receive({down(Pid,Pid,R) -> mark(down(R))},[timeout(2)]),
    promise_cleanup(Ref),mark(done).
yield_steps(Ref,Parent) :-
    mark(owner_begin),rpc:promise_owner_context(Owner),mark(owner(Owner)),
    thread_self(T),Claim=collector(T),
    mutex_property('$rpc_promise_lifecycle',status(MS)),mark(child_mutex(MS)),
    mark(claim_begin),rpc:promise_transaction(user:claim_steps(Ref,Claim,Q,Ready,Owner)),
    mark(claimed(Q,Ready)),
    mark(wait_begin),once(rpc:yield_wait(0,Q,Wait)),mark(waited(Wait)),
    rpc:promise_transaction(rpc:finish_promise_wait(Ref,Claim,Outcome,Threads)),
    mark(finished(Outcome,Threads)),rpc:stop_promise_threads(Threads),
    rpc:promise_transaction(rpc:release_promise_claim(Ref,Claim)),mark(released),
    Parent ! promise_callback_result(Outcome),mark(sent).

claim_steps(Ref,Claim,Q,Ready,Owner) :- mark(inside_lock),claim_detail(Ref,Claim,Q,Ready,Owner),mark(after_claim).
claim_detail(Ref,Claim,Q,Ready,Owner) :-
    mark(access_begin),rpc:promise_accessible(Ref,Owner),mark(access_ok),
    rpc:reap_stale_promise_claim(Ref),mark(reap_ok),
    rpc:promise_state(Ref,Q,W,T,C,R,Owner),mark(state(Q,W,T,C,R,Owner)),
    R \== disposed,C==none,
    mark(retract_begin),retract(rpc:promise_state(Ref,Q,W,T,C,R,Owner)),mark(retracted),
    assertz(rpc:promise_state(Ref,Q,W,T,Claim,R,Owner)),mark(asserted),
    (R=ready(_) -> Ready=true ; Ready=false).
observe :-
    thread_self(Main),thread_create(user:observer(Main),_,[detached(true)]),steps.
observer(Main) :-
    sleep(0.3),
    findall(T-S,thread_property(T,status(S)),Ts),mark(all_threads(Ts)),
    findall(S,rpc:promise_state(_,_,_,_,_,S,_),States),mark(all_promise_states(States)),
    (thread_peek_message(Main,M) -> mark(main_mailbox(M)) ; mark(main_mailbox_empty)),
    findall(P-T,actors:pid_thread(P,T),Ps),mark(pid_threads(Ps)).

import_tables(Path) :-
    make_ref(Ref),rpc:promise_transaction(rpc:new_promise_state(Ref,_)),self(_),
    table_counts(before),
    format(atom(Text),':- use_module(~q).',[Path]),
    load_text(Text,[module(callback_table_probe)]),table_counts(after).
table_counts(Stage) :-
    findall(R,rpc:promise_state(R,_,_,_,_,_,_),Rs),
    findall(P-T,actors:pid_thread(P,T),Ps),mark(tables(Stage,Rs,Ps)).
