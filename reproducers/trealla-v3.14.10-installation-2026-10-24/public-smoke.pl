:- module(public_update_smoke,[run/0]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/actors').
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/actor_api').
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/distribution',[]).
:- use_module('/Users/torbjorn.lager/Documents/GitHub/trealla-port/rpc_once_tests',[]).
run :-
    URL='http://localhost:3060',
    rpc_once_tests:live(URL),
    promise(URL,(sleep(0.15),PX=ok),Ref,[template(PX)]),
    yield(Ref,Early,[timeout(0),on_timeout(Early=waiting)]),Early==waiting,
    yield(Ref,PromiseAnswer,[timeout(3)]),PromiseAnswer==success([ok],false),var(PX),
    writeln('public promise timeout callback and retry: ok'),
    findall(X,rpc(URL,father_child(X,sally),[limit(1)]),[tom]),
    writeln('public HTTP paging, once, promise retry, sharing and shared database: ok'),
    toplevel_spawn(P,[node(URL),session(true),monitor(true),link(false)]),
    writeq(spawned(P)),nl,
    setup_call_cleanup(true,
      (toplevel_call_synch(P,member(X,[a,b,c]),A,[template(X),limit(2),timeout(3)]),
       writeq(first_answer(A)),nl,A==success(P,[a,b],true),var(X),
       toplevel_next_synch(P,B,[limit(2),timeout(3)]),writeq(next_answer(B)),nl,B==success(P,[c],false),
       toplevel_call_synch(P,receive({never -> true},[timeout(0.03),on_timeout(W=waiting)]),C,[template(W),timeout(3)]),
       writeq(timeout_answer(C)),nl,C==success(P,[waiting],false),
       toplevel_call_synch(P,(actors(Before),first_solution(F,[receive({never -> true}),F=fast]),actors(After),sort(Before,Sorted),sort(After,Sorted)),D,[template(F),timeout(3)]),
       writeq(worker_answer(D)),nl,D==success(P,[fast],false),
       toplevel_call_synch(P,(supervisor_spawn([],Sup),supervisor_count_children(Sup,Counts),supervisor_halt(Sup)),E,[template(Counts),timeout(3)]),
       writeq(supervisor_answer(E)),nl,E==success(P,[[specs-0,active-0,supervisors-0,workers-0]],false),
       toplevel_call_synch(P,(authorized(alice),owns(alice,Printer),online(Printer)),Shared,[template(Printer),timeout(3)]),
       writeq(shared_answer(Shared)),nl,Shared==success(P,[printer2],false),
       toplevel_call_synch(P,throw(smoke_error),Err,[timeout(3)]),Err==error(P,smoke_error),
       writeln('public WebSocket synchronous call/next, timeout callback, worker cleanup, supervisor and shared actor database: ok')),
      toplevel_halt(P,true)),
    receive({down(P,P,true) -> true},[timeout(3),on_timeout(throw(missing_spawn_notification))]),
    distribution:remote_drop_connection(URL),
    writeln('spawn monitor delivery and toplevel cleanup: ok').
