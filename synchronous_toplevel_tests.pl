% SPDX-License-Identifier: MIT
:- module(synchronous_toplevel_tests,[run/0,live/1]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(sandbox_policy,[]).
:- use_module(profile_policy,[]).
:- use_module(distribution,[]).
:- meta_predicate with_top(1), no_choicepoint(0).

no_choicepoint(Goal) :-
    call_cleanup(call(Goal),Done=true),
    (Done==true -> true ; throw(spurious_synchronous_choicepoint)).

run :-
    with_top(synchronous_toplevel_tests:answers),
    with_top(synchronous_toplevel_tests:routing),
    with_top(synchronous_toplevel_tests:stale_answer),
    timeout_callbacks,
    deadline_and_unrelated,
    termination,
    exit_unwind,
    admission,
    private_context,
    private_query,
    sandbox_local_queries,
    forall(member(Mode,[blacklist,whitelist]),sandbox_private_context(Mode)),
    writeln('Synchronous toplevel wrappers: all regressions passed').

with_top(Goal) :-
    toplevel_spawn(P,[session(true),link(false)]),
    setup_call_cleanup(true,call(Goal,P),synchronous_toplevel_tests:finish_test_top(P)).
% Finish finite timed-out queries before halting the session. Interrupting a
% running PTCP has a separate existing actor_exit-handling diagnostic.
finish_test_top(P) :-
    toplevel_call_synch(P,true,_,[timeout(1)]),
    toplevel_halt(P,true).
answers(P) :-
    toplevel_call_synch(P,member(X,[a,b,c]),A,[template(X),limit(1)]),
    A==success(P,[a],true),var(X),
    toplevel_next_synch(P,B,[limit(2)]),B==success(P,[b,c],false),
    toplevel_call_synch(P,fail,F),F==failure(P),
    toplevel_call_synch(P,throw(probe),E),E==error(P,probe),
    toplevel_call_synch(P,L='$VAR'(1),Rich,[template(row(pair(V,V),pair(B1,C1),L))]),
    Rich=success(P,[row(pair(R1,R2),pair(R3,R4),Literal)],false),
    var(R1),R1==R2,var(R3),var(R4),R3\==R4,R1\==R3,Literal=='$VAR'(1),
    var(V),var(B1),var(C1),var(L),
    toplevel_call_synch(P,X=pair(Y,Y),S,[template(X-Y)]),
    S=success(P,[pair(U,V)-W],false),var(U),U==V,V==W,var(X),var(Y),
    \+toplevel_call_synch(P,true,wrong),
    toplevel_call_synch(P,true,Good),Good==success(P,[true],false),
    writeln('answers, next, sharing and output mismatch: ok').
routing(P) :-
    self(Self),
    catch(toplevel_call_synch(P,true,_,[target(other)]),Bad,true),
    Bad=error(domain_error(synchronous_toplevel_target,other),_),
    catch(toplevel_call_synch(P,true,_,[limit(1),limit(0)]),Duplicate,true),nonvar(Duplicate),
    catch(toplevel_next_synch(P,_,[template(x)]),NextBad,true),nonvar(NextBad),
    toplevel_call_synch(P,true,A,[target(Self)]),A==success(P,[true],false),
    register(sync_wrapper_alias,P),
    setup_call_cleanup(true,
      (toplevel_call_synch(sync_wrapper_alias,true,AliasReply,[timeout(2)]),
       AliasReply==success(P,[true],false)),
      unregister(sync_wrapper_alias)),
    Self ! unrelated,
    toplevel_call(P,true,[template(async)]),
    toplevel_call_synch(P,true,B),B==success(P,[true],false),
    receive({success(P,[async],false) -> true},[timeout(1),on_timeout(fail)]),
    receive({unrelated -> true},[timeout(0),on_timeout(fail)]),
    toplevel_call(P,true,[template(after_sync)]),
    receive({success(P,[after_sync],false) -> true},[timeout(1),on_timeout(fail)]),
    writeln('routing validation and asynchronous replies retained: ok').
stale_answer(P) :-
    toplevel_call_synch(P,(sleep(0.08),X=old),Early,[template(X),timeout(0)]),var(Early),
    toplevel_call_synch(P,(sleep(0.08),Y=new),A,[template(Y),timeout(1)]),
    A==success(P,[new],false),var(X),var(Y),
    receive({'$toplevel_reply'(_,success(P,[old],_)) -> fail},[timeout(0),on_timeout(true)]),
    writeln('late answer cannot satisfy a later call: ok').

timeout_callbacks :-
    with_top(synchronous_toplevel_tests:callback_binding),
    with_top(synchronous_toplevel_tests:callback_failure),
    with_top(synchronous_toplevel_tests:callback_exception),
    with_top(synchronous_toplevel_tests:next_callback),
    writeln('timeout callback context, bindings, failure and exception: ok').
callback_value(waiting).
callback_binding(P) :-
    nb_setval(sync_callback_count,0),
    toplevel_call_synch(P,sleep(0.2),A,
      [timeout(0),on_timeout(one_callback(A))]),
    A==waiting,nb_getval(sync_callback_count,1).
one_callback(A) :-
    nb_getval(sync_callback_count,N),Next is N+1,nb_setval(sync_callback_count,Next),
    callback_value(A),(true;throw(repeated_callback)).
callback_failure(P) :-
    \+toplevel_call_synch(P,sleep(0.2),_,[timeout(0),on_timeout(fail)]).
callback_exception(P) :-
    catch(toplevel_call_synch(P,sleep(0.2),_,
                            [timeout(0),on_timeout(throw(callback_error))]),E,true),
    E==callback_error.

next_callback(P) :-
    toplevel_call_synch(P,(X=a;(sleep(0.1),X=b)),_,[template(X),limit(1)]),
    toplevel_next_synch(P,A,synchronous_toplevel_tests:[timeout(0),on_timeout(callback_value(A))]),
    A==waiting.

deadline_and_unrelated :-
    self(Self),spawn(receive({finish -> true}),Other,[link(false)]),monitor(Other,OtherRef),
    spawn(synchronous_toplevel_tests:stale_peer,Peer,[link(false),src_predicates([stale_peer/0])]),
    setup_call_cleanup(true,
      (Self ! '$toplevel_reply'(foreign,success(Other,[keep],false)),
       get_time(Start),
       toplevel_call_synch(Peer,true,Answer,[timeout(0.12)]),var(Answer),
       get_time(End),Elapsed is End-Start,Elapsed>=0.08,Elapsed<0.35,
       Other ! finish,
       receive({down(Other,OtherRef,true) -> true},[timeout(1),on_timeout(fail)]),
       receive({'$toplevel_reply'(foreign,success(Other,[keep],false)) -> true},
               [timeout(0),on_timeout(fail)])),
      (exit(Peer,kill),exit(Other,kill),demonitor(OtherRef,[flush]))),
    writeln('stale replies retain original deadline and unrelated monitor/messages: ok').
stale_peer :-
    self(Me),receive({'$call'(_,Options) -> memberchk(target(Target),Options)}),
    forall(between(1,10,N),(sleep(0.04),Target ! '$toplevel_reply'(N,success(Me,[stale],false)))).
termination :-
    self(Self),findall(R,actors:monitor(Self,_,R),Before),
    catch(toplevel_call_synch(999999999999,true,_,[timeout(1)]),Missing,true),
    Missing==toplevel_down(no_process),
    dies,
    findall(R,actors:monitor(Self,_,R),After),Before==After,
    writeln('termination fails fast and private monitors are removed: ok').
% A committed actor exit must terminate a toplevel between pages or during
% execution, rather than becoming error(P,actor_exit). A user-thrown
% actor_exit remains an ordinary query error, and unrelated monitors stay.
exit_unwind :-
    spawn(receive({finish -> true}),Other,[link(false)]),monitor(Other,OtherRef),
    setup_call_cleanup(true,
      (exit_between_pages,exit_during_query,user_actor_exit,
       \+receive({down(Other,OtherRef,_) -> true},[timeout(0),on_timeout(fail)]),
       Other ! finish,
       receive({down(Other,OtherRef,true) -> true},[timeout(1),on_timeout(fail)])),
      (exit(Other,kill),demonitor(OtherRef,[flush]))),
    writeln('committed exit escapes query errors; user actor_exit and unrelated monitors kept: ok').
exit_between_pages :-
    toplevel_spawn(P,[session(true),link(false)]),monitor(P,Ref),
    toplevel_call_synch(P,member(X,[a,b]),A,[template(X),limit(1)]),
    A==success(P,[a],true),
    exit(P,kill),
    exit_down(P,Ref).
exit_during_query :-
    toplevel_spawn(P,[session(true),link(false)]),monitor(P,Ref),
    toplevel_call(P,(sleep(0.05),self(Me),Me ! never,receive({never_sent -> true}))),
    sleep(0.2),
    exit(P,kill),
    exit_down(P,Ref).
exit_down(P,Ref) :-
    receive({down(P,Ref,Reason) -> true},[timeout(2),on_timeout(throw(no_toplevel_down(P)))]),
    (Reason==kill -> true ; throw(unexpected_toplevel_down(Reason))),
    \+receive({error(P,_) -> true;'$toplevel_reply'(_,error(P,_)) -> true},
              [timeout(0),on_timeout(fail)]).
user_actor_exit :-
    toplevel_spawn(P,[session(true),link(false)]),monitor(P,Ref),
    setup_call_cleanup(true,
      (toplevel_call_synch(P,throw(actor_exit),E),E==error(P,actor_exit),
       toplevel_call_synch(P,true,T),T==success(P,[true],false),
       \+receive({down(P,Ref,_) -> true},[timeout(0),on_timeout(fail)])),
      (exit(P,kill),demonitor(Ref,[flush]))).
dies :-
    spawn(receive({'$call'(_,_) -> exit(killed)}),P,[link(false)]),
    catch(toplevel_call_synch(P,true,_,[timeout(1)]),E,true),
    E==toplevel_down(killed).
admission :-
    catch(profile_policy:profile_check_goal(isobase,toplevel_call_synch(1,true,_)),E,true),nonvar(E),
    forall(member(Mode,[blacklist,whitelist]),
      (catch(sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
               toplevel_call_synch(1,open('/not-a-real-file',read,_),_),_),Bad,true),nonvar(Bad),
       sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
               toplevel_call_synch(1,true,_,[on_timeout(open('/not-a-real-file',read,_))]),Prepared),
       catch(call(Prepared),CallbackBad,true),nonvar(CallbackBad))),
    writeln('profile, query and computed callback admission: ok').
private_context :-
    self(Self),
    spawn((toplevel_spawn(P,[session(true)]),
           setup_call_cleanup(true,
             (toplevel_call_synch(P,sleep(0.2),A,
                [timeout(0),on_timeout(local_wait(A))]),Self ! private_result(A)),
             (toplevel_call_synch(P,true,_,[timeout(1)]),toplevel_halt(P,true)))),Child,
          [src_text('local_wait(private_waiting).'),link(false),monitor(true)]),
    receive({private_result(private_waiting) -> true;
             down(Child,Child,Reason) -> throw(private_callback_failed(Reason))},
            [timeout(2),on_timeout(fail)]),
    receive({down(Child,Child,true) -> true},[timeout(2),on_timeout(fail)]),
    writeln('private actor callback source context: ok').

private_query :-
    toplevel_spawn(P,[session(true),src_text('probe(ok).')]),
    setup_call_cleanup(true,
      (toplevel_call_synch(P,probe(X),A,[template(X),timeout(1)]),
       A==success(P,[ok],false),var(X)),
      toplevel_halt(P,true)).

% Exercise the checked public API with goals whose preparation introduces a
% qualified helper at the root. Both source modes must retain that helper and
% its shared variables, without changing ordinary receiver-side execution.
sandbox_local_queries :-
    forall(member(Source,[[],[src_text('probe(ok).')]]),
      (toplevel_spawn(P,[session(true),link(false)|Source]),
       setup_call_cleanup(true,
         forall(member(Mode,[blacklist,whitelist]),sandbox_query_answers(Mode,P)),
         toplevel_halt(P,true)))),
    with_top(synchronous_toplevel_tests:sandbox_workers),
    writeln('sandbox-prepared local queries in both source modes: ok').
sandbox_workers(P) :-
    forall(member(Mode,[blacklist,whitelist]),
      (sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
         toplevel_call_synch(P,catch(parallel([exit(killed)]),WorkerError,true),Workers,
           [template(WorkerError),timeout(2)]),WorkerQuery),
       call(WorkerQuery),Workers=success(P,[worker_exit(_,killed)],false),var(WorkerError))).
sandbox_query_answers(Mode,P) :-
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,true,Default),DefaultCall),
    no_choicepoint(DefaultCall),Default==success(P,[true],false),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,member(DefaultX,[a,b]),FirstDefault,
        [limit(1),timeout(2)]),DefaultPage),
    no_choicepoint(DefaultPage),FirstDefault==success(P,[member(a,[a,b])],true),var(DefaultX),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_next_synch(P,LastDefault),DefaultNext),
    no_choicepoint(DefaultNext),LastDefault==success(P,[member(b,[a,b])],false),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,catch(throw(pair(V,V)),E,true),Answer,
        [template(E),timeout(2)]),Checked),
    no_choicepoint(Checked),
    Answer=success(P,[pair(A,B)],false),var(A),A==B,var(V),var(E),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,between(1,2,X),Page,
        [template(X-X),limit(1),timeout(2)]),Paged),
    no_choicepoint(Paged),Page==success(P,[1-1],true),var(X),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_next_synch(P,Last,[timeout(2)]),Next),
    no_choicepoint(Next),Last==success(P,[2-2],false),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,fail,Failed,[timeout(2)]),Failure),
    no_choicepoint(Failure),Failed==failure(P),
    sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
      toplevel_call_synch(P,throw(query_error),Error,[timeout(2)]),Thrown),
    no_choicepoint(Thrown),Error==error(P,query_error),
    (Mode==blacklist ->
      sandbox_policy:sandbox_prepare_goal(Mode,actor,user,
        toplevel_call_synch(P,missing_sync_probe(Who),Missing,
          [template(Who),limit(1)]),MissingCall),
      no_choicepoint(MissingCall),
      Missing=error(P,error(existence_error(procedure,_),_)),var(Who)
    ; true).

sandbox_private_context(Mode) :-
    self(Self),
    Goal=(toplevel_spawn(P,[session(true)]),
          setup_call_cleanup(true,
            (toplevel_call_synch(P,sleep(0.1),A,[timeout(0),on_timeout(local_wait(A))]),
             Self ! sandbox_private(Mode,A)),
            (toplevel_call_synch(P,true,_,[timeout(1)]),toplevel_halt(P,true)))),
    sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,Goal,
      [src_text('local_wait(private_waiting).')],Prepared,Options),
    spawn(Prepared,Child,[link(false),monitor(true)|Options]),
    receive({sandbox_private(Mode,private_waiting) -> true;
             down(Child,Child,R) -> throw(sandbox_private_failed(Mode,R))},
            [timeout(2),on_timeout(fail)]),
    receive({down(Child,Child,true) -> true},[timeout(2),on_timeout(fail)]).

live(NodeURL) :-
    distribution:remote_node_open(NodeURL,Node),
    setup_call_cleanup(true,
      (distribution:remote_toplevel_spawn(Node,P,[session(true)]),
       setup_call_cleanup(true,
         (answers(P),routing(P),stale_answer(P),
          callback_binding(P),toplevel_call_synch(P,true,_,[timeout(2)]),
          callback_failure(P),toplevel_call_synch(P,true,_,[timeout(2)]),
          callback_exception(P),toplevel_call_synch(P,true,_,[timeout(2)]),
          next_callback(P),toplevel_call_synch(P,true,_,[timeout(2)]),
          distribution:remote_toplevel_call_synch(Node,P,Z=legacy,Legacy,[template(Z),timeout(2)]),
          Legacy==success(P,[legacy],false),var(Z),
          distribution:remote_toplevel_call(Node,P,true,[template(explicit_async)]),
          receive({success(P,[explicit_async],false) -> true},[timeout(2),on_timeout(fail)]),
          forall(member(Mode,[blacklist,whitelist]),sandbox_query_answers(Mode,P)),
          sandbox_workers(P),shared_remote_caller(P),remote_termination(Node)),
         distribution:remote_exit(Node,P,kill))),
      distribution:remote_node_close(Node)),
    writeln('Public remote synchronous wrappers: passed').

shared_remote_caller(P) :-
    self(Parent),
    spawn((toplevel_call_synch(P,true,A,[template(shared),timeout(2)]),
           Parent ! shared_public_reply(A)),Child,[link(false),monitor(true)]),
    receive({shared_public_reply(A) -> A==success(P,[shared],false);
             down(Child,Child,R) -> throw(shared_public_failed(R))},[timeout(3),on_timeout(fail)]),
    receive({down(Child,Child,true) -> true},[timeout(2),on_timeout(fail)]).

remote_termination(Node) :-
    distribution:remote_toplevel_spawn(Node,P,[session(true)]),
    distribution:remote_monitor(Node,P,ApplicationRef),
    spawn((sleep(0.1),exit(P,kill)),Killer,[link(false),monitor(true)]),
    catch(toplevel_next_synch(P,_,[timeout(2)]),Observed,true),
    receive({down(P,ApplicationRef,Reason) -> Observed==toplevel_down(Reason)},
            [timeout(2),on_timeout(fail)]),
    receive({down(Killer,Killer,true) -> true},[timeout(2),on_timeout(fail)]).
