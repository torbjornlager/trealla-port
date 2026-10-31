% SPDX-License-Identifier: MIT
:- module(actor_authority_tests, [actor_authority_tests/0]).
:- use_module(actors).
:- use_module(actor_authority, []).
:- op(200, xfx, @).

actor_authority_tests :-
    foreign_exit_is_denied,
    owner_exit_is_allowed,
    trusted_exit_is_allowed,
    remote_route_is_not_authority,
    writeln('Actor exit authority: all regressions passed').

ready_worker(Parent) :-
    self(Me), send(Parent,ready(Me)),
    receive({probe(Who)->send(Who,alive),ready_worker_wait(Parent)}).
ready_worker_wait(_) :- receive({stop->true}).

make_worker(Namespace, Pid) :-
    self(Self),
    actors:with_actor_namespace(Namespace,
        spawn((self(Me),send(Self,ready(Me)),receive({probe(Who)->send(Who,alive),receive({stop->true})})),Pid,[monitor(true)])),
    receive({ready(Pid)->true},[timeout(2),on_timeout(throw(no_readiness))]).

foreign_exit_is_denied :-
    make_worker(ws_client(authority_owner),Pid),
    catch((actors:with_actor_namespace(ws_client(authority_stranger),
                                      actors:exit(Pid,forbidden)), Outcome=returned),
          Error,Outcome=thrown),
    Outcome==thrown,nonvar(Error),Error=error(permission_error(exit,actor,Pid),_),
    self(Self),send(Pid,probe(Self)),
    receive({alive->true},[timeout(2),on_timeout(throw(target_was_affected))]),
    actors:with_actor_namespace(ws_client(authority_owner),exit(Pid,owner_done)),
    receive({down(Pid,Pid,owner_done)->true},[timeout(2),on_timeout(throw(no_owner_exit))]).

owner_exit_is_allowed :-
    make_worker(ws_client(authority_target),Pid),
    actor_authority:open_namespace(ws_client(authority_admin),principal(admin,[admin])),
    call_cleanup(
        actors:with_actor_namespace(ws_client(authority_admin),exit(Pid,admin_done)),
        actor_authority:close_namespace(ws_client(authority_admin))),
    receive({down(Pid,Pid,admin_done)->true},[timeout(2),on_timeout(throw(no_admin_exit))]).

trusted_exit_is_allowed :-
    make_worker(ws_client(authority_trusted_target),Pid),
    exit(Pid,trusted_done),
    receive({down(Pid,Pid,trusted_done)->true},[timeout(2),on_timeout(throw(no_trusted_exit))]).

remote_route_is_not_authority :-
    self(Self),
    Remote=1234567890@'http://authority.invalid',
    setup_call_cleanup(
        (assertz(actors:actor_namespace(Self,ws_client(remote_owner))),
         assertz(actors:link(Self,Remote))),
        (actors:with_actor_namespace(ws_client(remote_owner),actor_authority:check_exit(Remote)),
         catch((actors:with_actor_namespace(ws_client(remote_stranger),
                    actor_authority:check_exit(Remote)),Outcome=returned),E,Outcome=thrown),
         Outcome==thrown,nonvar(E),E=error(permission_error(exit,actor,Remote),_)),
        (retractall(actors:link(Self,Remote)),
         retractall(actors:actor_namespace(Self,ws_client(remote_owner))))).
