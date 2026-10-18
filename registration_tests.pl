% SPDX-License-Identifier: MIT
:- module(registration_tests,[registration_tests/0]).
:- use_module(actors).
:- use_module(distribution).

fresh_name(Name) :- make_ref(Id),format(atom(Name),'registration_~w',[Id]).
expect_missing(Name,Pid) :-
    catch(register(Name,Pid),Error,true),nonvar(Error),
    Error=error(existence_error(process,Pid),context(actors:register/2,_)),
    whereis(Name,undefined).
stop_waiter(Pid) :-
    Pid ! finish,receive({down(Pid,Pid,_) -> true},[timeout(2),on_timeout(fail)]).
waiter(Pid) :- spawn(receive({finish -> true}),Pid,[link(false),monitor(true)]).

registration_tests :-
    registration_live_and_dead,
    registration_terminating,
    registration_raw_thread,
    registration_qualified,
    forall(between(1,30,_),registration_race),
    writeln('Stale local PID registration: all regressions passed').

registration_live_and_dead :-
    fresh_name(Name),waiter(P),register(Name,P),whereis(Name,P),
    fresh_name(Other),catch(register(Other,P),Already,true),Already==process_already_has_a_name(P),
    stop_waiter(P),whereis(Name,undefined),expect_missing(Name,P),
    fresh_name(Missing),expect_missing(Missing,999999999999),
    self(Self),register(Name,Self),whereis(Name,Self),unregister(Name),
    writeln('live actors/shell accepted, stale and absent local PIDs rejected: ok').

committed_worker(Parent) :-
    self(Me),catch(exit(done),_,true),Parent ! committed(Me),receive({finish -> true}).
registration_terminating :-
    self(Parent),spawn_runtime(registration_tests:committed_worker(Parent),P,
        [link(false),monitor(true),'$entry_context'(caller)]),
    receive({committed(P) -> true},[timeout(2),on_timeout(fail)]),
    fresh_name(Name),expect_missing(Name,P),stop_waiter(P),
    writeln('committed termination rejected before bookkeeping removal: ok').

raw_self(Queue) :- self(P),thread_send_message(Queue,P).
registration_raw_thread :-
    message_queue_create(Q),thread_create(registration_tests:raw_self(Q),T,[]),
    thread_get_message(Q,P),thread_join(T,_),message_queue_destroy(Q),
    fresh_name(Name),expect_missing(Name,P),
    writeln('retired self/1 native-thread mapping is insufficient for registration: ok').

registration_qualified :-
    setup_call_cleanup(asserta(web_prolog:node_public_url('http://registration-local.test')),
        registration_tests:qualified_checks,
        retract(web_prolog:node_public_url('http://registration-local.test'))).
qualified_checks :-
    fresh_name(Name),waiter(P),
    Local=P@localhost,register(Name,Local),whereis(Name,Stored),Stored==Local,
    stop_waiter(P),whereis(Name,undefined),expect_missing(Name,Local),
    waiter(Q),Qualified=Q@'http://registration-local.test',
    register(Name,Qualified),whereis(Name,Qualified),stop_waiter(Q),
    whereis(Name,undefined),expect_missing(Name,Qualified),
    % A remote alias with exactly the same wire PID must remain untouched.
    waiter(R),Remote=R@'http://registration-remote.test',register(Name,Remote),
    stop_waiter(R),whereis(Name,Kept),Kept==Remote,unregister(Name),
    register(Name,Remote),whereis(Name,Remote),
    catch(register(Name,999999999999),Taken,true),Taken==name_is_in_use(Name),
    unregister(Name),
    writeln('qualified local aliases checked/cleaned; remote alias identity and precedence preserved: ok').

racing_registration(Gate,Results,Name,Pid) :-
    thread_get_message(Gate,go),
    catch((register(Name,Pid),Result=registered),Error,Result=error(Error)),
    thread_send_message(Results,Result).
registration_race :-
    waiter(P),fresh_name(Name),message_queue_create(Gate),message_queue_create(Results),
    thread_create(registration_tests:racing_registration(Gate,Results,Name,P),T,[]),
    thread_send_message(Gate,go),P ! finish,
    receive({down(P,P,_) -> true},[timeout(2),on_timeout(fail)]),
    thread_get_message(Results,Result),thread_join(T,_),
    ( Result==registered -> true
    ; Result=error(error(existence_error(process,P),context(actors:register/2,_))) ),
    whereis(Name,undefined),message_queue_destroy(Gate),message_queue_destroy(Results).
