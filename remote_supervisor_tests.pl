% SPDX-License-Identifier: MIT
:- module(remote_supervisor_tests,[remote_supervisor_tests/0,remote_supervisor_live_test/1,remote_supervisor_source_test/1,remote_supervisor_policy_tests/0,remote_supervisor_extended_test/1]).
:- use_module(actors).
:- use_module(distribution).
:- use_module(supervisor_actor).
:- use_module(remote_supervisor, []).

remote_supervisor_tests :-
    remote_supervisor:prepare(blacklist,actor,sup_init([],sup(one_for_one,1,5,[],[])),[],Entry,[],yes),
    Entry=remote_supervisor:run([],_),
    remote_supervisor:prepare(blacklist,actor,true,[],_,_,no),
    remote_supervisor:prepare(blacklist,actor,sup_init(a,b),[src_list([sup_init(a,b)])],_,_,no),
    writeln('Narrow receiver supervisor adapter: ok').

remote_supervisor_live_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    setup_call_cleanup(true,remote_supervisor_tests:live_supervisors(URL),remote_drop_connection(URL)),
    format('Live remote supervisor entry and control on ~w: ok~n',[Port]).
live_supervisors(URL) :-
    supervisor_spawn([],Empty,[node(URL),link(false),monitor(true)]),
    supervisor_count_children(Empty,C),memberchk(specs-0,C),memberchk(active-0,C),
    supervisor_halt(Empty),receive({down(Empty,Empty,_) -> true},[timeout(4),on_timeout(fail)]),
    make_ref(Id),format(atom(Name),'remote_supervisor_~w',[Id]),
    supervisor_spawn(remote_supervisor_tests:[child(waiter,[start(receive({finish -> true})),restart(temporary)])],Sup,
        [node(URL),name(Name),link(false),monitor(true)]),
    whereis(Name,Sup),supervisor_which_children(Sup,Children),
    Children=[info(waiter,_,worker,temporary)],
    supervisor_count_children(Sup,Counts),memberchk(specs-1,Counts),memberchk(active-1,Counts),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(4),on_timeout(fail)]),
    whereis(Name,undefined),
    spawn(receive({finish -> true}),P,[node(URL),link(false),monitor(true)]),
    P ! finish,receive({down(P,P,true) -> true},[timeout(4),on_timeout(fail)]).

source_waiter :- receive({finish -> true}).
remote_supervisor_source_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    setup_call_cleanup(true,
        (supervisor_spawn(remote_supervisor_tests:[child(sourced,[start(source_waiter),restart(temporary)])],Sup,
             [node(URL),link(false),monitor(true),src_predicates([source_waiter/0])]),
         supervisor_count_children(Sup,Counts),memberchk(active-1,Counts),
         supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(4),on_timeout(fail)])),
        remote_drop_connection(URL)),
    writeln('Source-backed remote supervisor child: ok').

:- meta_predicate rejected(0).
rejected(Goal) :- catch(call(Goal),E,true),nonvar(E).
wire(Start,sup_init([spec(test,Start,temporary,1,worker)],sup(one_for_one,1,5,[],[]))).
remote_supervisor_policy_tests :-
    forall(member(M,[blacklist,whitelist]),remote_supervisor_tests:policy_mode(M)),
    callback_execution,
    wire(true,G),rejected(remote_supervisor:prepare(off,relation,G,[],_,_,_)),
    writeln('Receiver sandbox/profile/fresh-state and nested-source regressions: ok').
policy_mode(M) :-
    wire(shell(true),Unsafe),rejected(remote_supervisor:prepare(M,actor,Unsafe,[],_,_,_)),
    wire(sandbox_policy:sandbox_builtin_call(shell(true)),PrivateHelper),
    rejected(remote_supervisor:prepare(M,actor,PrivateHelper,[],_,_,_)),
    wire(call(system:shell(true)),Qualified),rejected(remote_supervisor:prepare(M,actor,Qualified,[],_,_,_)),
    rejected(remote_supervisor:prepare(M,actor,sup_init([],sup(one_for_one,1,5,[injected],[])),[],_,_,_)),
    rejected(remote_supervisor:prepare(M,actor,sup_init([wrong],sup(one_for_one,1,5,[],[])),[],_,_,_)),
    wire(foo(X),Sourced),remote_supervisor:prepare(M,actor,Sourced,[src_list([foo(ok)])],Entry,_,yes),
    var(X),Entry=remote_supervisor:run([child(test,Opts)],_),member(start(remote_supervisor:invoke_child(foo(Y),_)),Opts),X==Y,
    wire(foo(_),BadSource),rejected(remote_supervisor:prepare(M,actor,BadSource,[src_list([(foo(_):-shell(true))])],_,_,_)),
    wire(server(call(system:shell),[]),BadCallback),rejected(remote_supervisor:prepare(M,actor,BadCallback,[],_,_,_)),
    wire(start_sub_supervisor([child(b,[start(shell(true))])],[]),BadNested),
    rejected(remote_supervisor:prepare(M,actor,BadNested,[],_,_,_)),
    rejected(sandbox_policy:sandbox_prepare_spawn(M,actor,actor_context,
        remote_supervisor:run([],[]),[],_,_)),
    (M==blacklist -> runtime_guard(M)
    ; wire(call(_),Opaque),rejected(remote_supervisor:prepare(M,actor,Opaque,[],_,_,_))).
runtime_guard(M) :-
    self(Parent),
    Goal=(self(Child),Parent ! child_started(Child),receive({go -> (Opaque=shell(true),call(Opaque))})),
    wire(Goal,Wire),remote_supervisor:prepare(M,actor,Wire,[],Entry,Options,yes),
    spawn_runtime(Entry,Sup,['$entry_context'(caller),link(false),monitor(true)|Options]),
    receive({child_started(Pid) -> true},[timeout(3),on_timeout(fail)]),monitor(Pid,Ref),Pid ! go,
    receive({down(Pid,Ref,Reason) -> true},[timeout(3),on_timeout(fail)]),
    Reason=exception(error(permission_error(_,sandboxed,_),_)),
    supervisor_spawn_child(Sup,child(dynamic,[start(shell(true))]),Rejected),
    Rejected=error(error(permission_error(_,sandboxed,_),_)),
    supervisor_count_children(Sup,Counts),memberchk(active-0,Counts),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(3),on_timeout(fail)]).

local_echo(Request,State,Request,State).
remote_supervisor_extended_test(Port) :-
    format(atom(URL),'http://localhost:~w',[Port]),
    setup_call_cleanup(true,remote_supervisor_tests:extended_session(URL),remote_drop_connection(URL)),
    writeln('Nested/source/server supervisors and dynamic admission: ok').
extended_session(URL) :-
    supervisor_spawn(remote_supervisor_tests:[
        child(nested,[start(start_sub_supervisor([child(leaf,[start(source_waiter),restart(temporary)])],[])),type(supervisor)]),
        child(echo,[start(server(local_echo,[initial_state([])])),restart(temporary)])],Sup,
        [node(URL),link(false),monitor(true),src_predicates([source_waiter/0,local_echo/4])]),
    supervisor_count_children(Sup,Counts),memberchk(active-2,Counts),memberchk(supervisors-1,Counts),
    supervisor_spawn_child(Sup,remote_supervisor_tests:child(extra,[start(receive({finish -> true})),restart(temporary)]),ok),
    supervisor_spawn_child(Sup,remote_supervisor_tests:child(bad,[start(shell(true))]),Rejected),
    Rejected=error(error(permission_error(_,sandboxed,_),_)),
    supervisor_count_children(Sup,After),memberchk(active-3,After),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(4),on_timeout(fail)]).

callback_execution :-
    wire(server(cb,[initial_state(state)]),Wire),
    remote_supervisor:prepare(whitelist,actor,Wire,[src_list([cb(Request,State,Request,State)])],Entry,Options,yes),
    spawn_runtime(Entry,Sup,['$entry_context'(caller),link(false),monitor(true)|Options]),
    supervisor_which_children(Sup,[info(test,Child,worker,temporary)]),
    server_actor:server_request(Child,hello,Reply,[timeout(2)]),Reply==hello,
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(3),on_timeout(fail)]).
