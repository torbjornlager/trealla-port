% SPDX-License-Identifier: MIT
:- module(named_creation_tests,[named_creation_tests/0]).
:- use_module(actors).
:- use_module(server_actor).
:- use_module(supervisor_actor).

named_echo(Request,State,Request,State).
name_for(Prefix,Name) :- make_ref(Id),format(atom(Name),'~w_~w',[Prefix,Id]).
expect_taken(Goal,Name) :- catch(call(Goal),Error,true),Error==name_is_in_use(Name).
:- meta_predicate expect_taken(0,+).

named_creation_tests :-
    named_occupied,
    named_first_goal,
    named_failure_release,
    named_immediate_exit,
    named_publication_conflict,
    catch(spawn(true,_,['$name_reservation'(1)]),PrivateError,true),
    PrivateError=error(permission_error(option,internal_spawn_option,'$name_reservation'(1)),_),
    forall(between(1,12,_),named_concurrent),
    writeln('Atomic local named creation: all regressions passed').

named_occupied :-
    name_for(named_occupied,Name),name_for(named_other,Other),
    server_spawn(named_echo,[],P,[name(Name),name(Other),link(false),monitor(true)]),
    actors(Before),
    expect_taken(server_spawn(no_such_callback,[],Loser,
        [name(Name),src_uri('http://invalid/source'),link(false)]),Name),var(Loser),
    expect_taken(supervisor_spawn([],LoserSup,[name(Name),link(false)]),Name),var(LoserSup),
    actors(After),sort(Before,Sorted),sort(After,Sorted),
    whereis(Name,P),whereis(Other,undefined),server_request(Name,hello,hello),
    server_halt(P,true),receive({down(P,P,_) -> true},[timeout(2),on_timeout(fail)]),
    whereis(Name,undefined),
    writeln('occupied names reject before source/actor work; scalar precedence preserved: ok').

named_probe(Parent,Name) :-
    self(Me),whereis(Name,Found),Parent ! observed(Me,Found),receive({stop -> true}).
named_first_goal :-
    self(Parent),name_for(named_first,Name),
    supervisor_spawn([child(probe,[start(named_probe(Parent,Name))])],Sup,
        [name(Name),monitor(true),link(false)]),
    receive({observed(Child,Found) -> true},[timeout(2),on_timeout(fail)]),
    Child \== Sup,Found==Sup,
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)]),
    whereis(Name,undefined),
    writeln('supervisor name visible before its first child goal: ok').

create_test_actor(Goal,Pid,Options,NameOptions) :-
    append(NameOptions,Options,All),spawn_runtime(Goal,Pid,All).
fail_creation(_) :- fail.
throw_creation(_) :- throw(named_source_failure).
reserved_probe(Name,Pid,_) :-
    whereis(Name,undefined),
    expect_taken(register(Name,Pid),Name),
    unregister(Name),expect_taken(register(Name,Pid),Name).

named_failure_release :-
    name_for(named_failure,Name),self(Self),
    \+ with_spawn_name([name(Name)],_,named_creation_tests:fail_creation),
    catch(with_spawn_name([name(Name)],_,named_creation_tests:throw_creation),E,true),E==named_source_failure,
    with_spawn_name([name(Name)],_,named_creation_tests:reserved_probe(Name,Self)),
    catch(server_spawn(named_echo,[],_,[name(Name),link(false),
        src_uri('file:///definitely-missing-named-creation.pl')]),ServerError,true),
    nonvar(ServerError),
    catch(supervisor_spawn([],_,[name(Name),link(false),
        src_uri('file:///definitely-missing-named-creation.pl')]),SupError,true),
    nonvar(SupError),
    % Fail inside the child's preparation, before publication/acknowledgement.
    catch(with_spawn_name([name(Name)],_,named_creation_tests:create_test_actor(true,_,
        [link(false),src_list([(:- throw(named_prepare_failure))])])),PrepError,true),
    nonvar(PrepError),whereis(Name,undefined),
    supervisor_spawn([],Sup,[name(Name),monitor(true),link(false)]),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)]),
    writeln('failure/exception/preparation cleanup releases reservations; register respects them: ok').

named_immediate_exit :-
    name_for(named_exit,Name),
    with_spawn_name([name(Name)],P,named_creation_tests:create_test_actor(true,P,[link(false),monitor(true)])),
    receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),whereis(Name,undefined),
    writeln('immediate termination leaves no stale registration: ok').

named_publication_conflict :-
    name_for(named_publish,Name),name_for(named_existing,Other),
    catch(with_spawn_name([name(Name)],_,named_creation_tests:create_test_actor(true,_,
        [link(false),monitor(true),src_list([
            (:- (actors:self(Me),actors:register(Other,Me)))])])),Error,true),
    nonvar(Error),Error=process_already_has_a_name(Dead),
    receive({down(Dead,Dead,_) -> true},[timeout(2),on_timeout(fail)]),
    whereis(Name,undefined),whereis(Other,undefined),
    supervisor_spawn([],Sup,[name(Name),monitor(true),link(false)]),
    supervisor_halt(Sup),receive({down(Sup,Sup,_) -> true},[timeout(2),on_timeout(fail)]),
    writeln('publication conflict preserves one-name rule and releases reservation: ok').

competing_creator(Gate,Results,Name) :-
    thread_get_message(Gate,go),
    catch((supervisor_spawn([],P,[name(Name),link(false)]),Result=won(P)),
          Error,Result=lost(Error)),
    thread_send_message(Results,Result).
named_concurrent :-
    name_for(named_race,Name),message_queue_create(Gate),message_queue_create(Results),
    thread_create(named_creation_tests:competing_creator(Gate,Results,Name),A,[]),
    thread_create(named_creation_tests:competing_creator(Gate,Results,Name),B,[]),
    thread_send_message(Gate,go),thread_send_message(Gate,go),
    thread_get_message(Results,R1),thread_get_message(Results,R2),
    thread_join(A,_),thread_join(B,_),
    sort([R1,R2],Replies),sort([won(P),lost(name_is_in_use(Name))],Replies),
    whereis(Name,P),supervisor_halt(P),
    message_queue_destroy(Gate),message_queue_destroy(Results).
