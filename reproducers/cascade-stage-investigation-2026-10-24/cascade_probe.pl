% Test-only observation of t145. Runtime files and original fixture stay intact.
:- use_module(toplevel_actors).
:- use_module(actors).
:- use_module(sandbox_policy).

probe :-
    get_time(Start),nb_setval(probe_start,Start),nb_setval(probe_session,none),
    nb_setval(probe_owned,[]),nb_setval(probe_monitors,[]),nb_setval(probe_snapshot,none),
    catch((fixture,Outcome=pass),Error,
      (trace(initial_failure(Error)),
       catch(post_failure,Diagnostic,trace(diagnostic_error(Diagnostic))),
       Outcome=failed(Error))),
    catch(cleanup,Error2,trace(cleanup_error(Error2))),
    trace(outcome(Outcome)),Outcome==pass.

trace(Stage) :- get_time(Now),nb_getval(probe_start,Start),Elapsed is Now-Start,
    writeq(at(Elapsed,Stage)),nl,flush_output.

fixture :-
    Source = 'root :- spawn(child, _, [src_predicates([child/0, grandchild/0])]), receive({}). child :- spawn(grandchild, _, [src_predicates([grandchild/0])]), receive({}). grandchild :- receive({}).',
    trace(enter(source_preparation)),
    sandbox_prepare_options(blacklist, actor, actor_context,
                            [src_text(Source)], SourceOptions),
    self(Me),
    toplevel_spawn(Session,
                   [target(Me),session(true),link(false)|SourceOptions]),
    nb_setval(probe_session,Session),trace(session(Session)),
    Spawn0 = spawn(root, Root,
                   [src_predicates([root/0,child/0,grandchild/0])]),
    sandbox_prepare_spawn(blacklist, actor, actor_context,
                          Spawn0, [], SpawnGoal, SpawnOptions),
    trace(enter(root_spawn_request)),
    toplevel_call(Session, SpawnGoal,
                  [template(Root),target(Me),limit(1)|SpawnOptions]),
    receive({success(Session, [Root], false) -> true;
             error(Session, Error) -> throw(Error)},
            [timeout(2),on_timeout(throw(t145_spawn_timeout))]),
    nb_setval(probe_owned,[Root]),trace(root(Root)),
    sleep(0.1),
    trace(enter(initial_actors_request)),
    toplevel_call(Session, actors(Alive),
                  [template(Alive),target(Me),limit(1)]),
    receive({success(Session, [FourAlive], false) -> true;
             error(Session, ActorError) -> throw(ActorError)},
            [timeout(2),on_timeout(throw(t145_actors_timeout))]),
    trace(initial_snapshot(FourAlive)),
    length(FourAlive, 4),
    observe_tree(Session,Root,FourAlive),
    trace(enter(exit_root(Root,die))),
    exit(Root, die),
    trace(returned(exit_root)),
    sleep(0.1),
    trace(enter(cascade_snapshot_request)),
    toplevel_call(Session, actors(Remaining),
                  [template(Remaining),target(Me),limit(1)]),
    % Same target assertion as [[Session]], false. A rejected snapshot is
    % logged by the guard and stays unmatched for the original two seconds.
    receive({success(Session, Rows, false) if target_snapshot(Session,Rows) -> true;
             error(Session, CascadeError) -> throw(CascadeError)},
            [timeout(2),on_timeout(throw(t145_cascade_timeout))]),
    trace(cascade_assertion_passed),drain_downs,
    toplevel_halt(Session, true),
    trace(original_fixture_completed).

target_snapshot(Session,Rows) :-
    nb_getval(probe_snapshot,Previous),
    (Previous==Rows -> true ; nb_setval(probe_snapshot,Rows),trace(cascade_snapshot(Rows))),
    Rows==[[Session]].

observe_tree(Session,Root,Alive) :-
    findall(P,(member(P,Alive),P\==Session),Owned),nb_setval(probe_owned,Owned),
    with_mutex('$actor_registry',findall(edge(P,C),actors:link(P,C),Edges)),
    trace(links(Edges)),
    (memberchk(edge(Root,Child),Edges),memberchk(edge(Child,Grandchild),Edges)
     -> trace(roles(root(Root),child(Child),grandchild(Grandchild)))
     ; trace(roles_unresolved(Root,Owned))),
    monitor_owned(Owned,Pairs),nb_setval(probe_monitors,Pairs),trace(monitors(Pairs)).
monitor_owned([],[]).
monitor_owned([P|Ps],[pair(P,R)|Pairs]) :- monitor(P,R),monitor_owned(Ps,Pairs).
owned_ref(P,R) :- nb_getval(probe_monitors,Pairs),memberchk(pair(P,R),Pairs).
drain_downs :-
    receive({down(P,R,Reason) if owned_ref(P,R) -> trace(down(P,R,Reason)),drain_downs},
            [timeout(0),on_timeout(true)]).

post_failure :-
    drain_downs,nb_getval(probe_session,Session),
    (Session==none -> true
     ; consume_original_snapshot(Session),
       fresh_snapshot(Session,immediate),
       sleep(0.1),fresh_snapshot(Session,after_additional_0_1),
       sleep(0.5),fresh_snapshot(Session,after_additional_0_6)),
    drain_downs.
consume_original_snapshot(Session) :-
    receive({success(Session,Rows,More) -> trace(retained_reply(Rows,More))},
            [timeout(0),on_timeout(trace(no_retained_reply))]).
fresh_snapshot(Session,Label) :-
    drain_downs,trace(post_failure_request(Label)),
    self(Me),toplevel_call(Session,actors(Alive),[template(Alive),target(Me),limit(1)]),
    receive({success(Session,Rows,More)->trace(post_failure_snapshot(Label,Rows,More));
             error(Session,E)->trace(post_failure_query_error(Label,E))},
            [timeout(0.5),on_timeout(trace(post_failure_no_reply(Label)))]),
    drain_downs.

cleanup :-
    trace(enter(fixture_cleanup)),nb_getval(probe_monitors,Pairs),
    demonitor_owned(Pairs),nb_getval(probe_owned,Owned),kill_owned(Owned),
    nb_getval(probe_session,Session),(Session==none->true;exit(Session,kill)),
    trace(returned(fixture_cleanup)).
demonitor_owned([]).
demonitor_owned([pair(_,R)|Pairs]) :- demonitor(R,[flush]),demonitor_owned(Pairs).
kill_owned([]).
kill_owned([P|Ps]) :- exit(P,kill),kill_owned(Ps).
