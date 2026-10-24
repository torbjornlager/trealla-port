% SPDX-License-Identifier: MIT
:- module(supervisor_admission_tests,[run/0]).
:- use_module(actors).
:- use_module(actor_api).
:- use_module(profile_policy).
:- use_module(sandbox_policy).
:- use_module(supervisor_admission).

check(Goal) :- (call(Goal)->true;throw(admission_assertion_failed(Goal))).
:- meta_predicate check(0).

run :-
    nonbinding_walks,
    known_and_opaque,
    forbidden_starts,
    runtime_recheck,
    source_context,
    writeln('Nonbinding supervisor admission: all regressions passed').

nonbinding_walks :-
    check_nonbinding(supervisor_spawn(_,_)),
    check_nonbinding(supervisor_spawn_child(_,_,_)),
    check_nonbinding(supervisor_spawn([_],_)),
    check_nonbinding(supervisor_spawn([child(a,_)],_)),
    check_nonbinding(supervisor_spawn([child(a,[_])],_)),
    check_nonbinding(supervisor_spawn([child(a,[start(_)])],_)),
    check_nonbinding(supervisor_spawn([child(a,[start(start_sub_supervisor([_],[]))])],_)),
    check_nonbinding(supervisor_spawn([child(a,[start(true)])|_],_)),
    % Sharing of an argument with an ordinary goal must survive inspection.
    Goal=(supervisor_spawn([child(a,[start(member(X,[X,Y]))])],_),X=Y),
    check_nonbinding(Goal).
check_nonbinding(Goal) :-
    term_variables(Goal,Vars),
    profile_check_goal(actor,Goal),
    sandbox_prepare_goal(blacklist,actor,supervisor_admission_tests,Goal,_),
    maplist(var,Vars),term_variables(Goal,After),check(Vars==After),
    catch(sandbox_prepare_goal(whitelist,actor,supervisor_admission_tests,Goal,_),_,true),
    maplist(var,Vars),term_variables(Goal,Final),check(Vars==Final).

known_and_opaque :-
    forall(member(Mode,[blacklist,whitelist]),
      (sandbox_check_goal(Mode,actor,supervisor_admission_tests,
          supervisor_spawn([child(a,[start(true)])],_)),
       sandbox_check_goal(Mode,actor,supervisor_admission_tests,
          supervisor_spawn([child(a,[start(server(callback,[]))])],_)),
       sandbox_check_goal(Mode,actor,supervisor_admission_tests,
          supervisor_spawn([child(a,[start(start_sub_supervisor([child(b,[start(true)])],[]))])],_)))),
    catch(sandbox_prepare_goal(whitelist,actor,supervisor_admission_tests,
        supervisor_spawn_child(_,Spec,_),_),Error,true),
    check(nonvar(Error)),check(var(Spec)),
    check(Error=error(permission_error(call,sandboxed,_),context(_,opaque_meta_call))).

forbidden_starts :-
    forall(member(Mode,[blacklist,whitelist]),
      (rejects(Mode,supervisor_spawn([child(a,[start(open(missing,read,_))])],_)),
       rejects(Mode,supervisor_spawn_child(_,child(a,[start(open(missing,read,_))]),_)),
       rejects(Mode,supervisor_spawn([child(a,[start(start_sub_supervisor([child(b,[start(open(missing,read,_))])],[]))])],_)))).
rejects(Mode,Goal) :-
    catch(sandbox_prepare_goal(Mode,actor,supervisor_admission_tests,Goal,_),E,true),
    check(nonvar(E)),check(E=error(permission_error(call,sandboxed,_),_)).

runtime_recheck :-
    % No unsafe operation is executed: all three dispatches must reject before
    % creation/request. A dead supervisor would otherwise yield a different error.
    sandbox_prepare_goal(blacklist,actor,supervisor_admission_tests,
        supervisor_spawn_child(999999999999,Spec,_),Guarded),
    check(var(Spec)),Spec=child(a,[start(open(missing,read,_))]),
    catch(call(Guarded),E,true),check(nonvar(E)),
    check(E=error(permission_error(call,sandboxed,_),_)),
    sandbox_prepare_goal(blacklist,actor,supervisor_admission_tests,
        supervisor_spawn(Specs,_),GuardedSpawn),
    check(var(Specs)),Specs=[child(a,[start(open(missing,read,_))])],
    catch(call(GuardedSpawn),E2,true),check(nonvar(E2)),
    check(E2=error(permission_error(call,sandboxed,_),_)),
    sandbox_prepare_goal(blacklist,actor,supervisor_admission_tests,
        supervisor_spawn([child(a,[start(Start)])],_),GuardedStart),
    check(var(Start)),Start=open(missing,read,_),
    catch(call(GuardedStart),E3,true),check(nonvar(E3)),
    check(E3=error(permission_error(call,sandboxed,_),_)).

source_context :-
    % Use the same public preparation path as the WebSocket endpoint, including
    % private source and a copied helper that contains a guarded constructor.
    forall(member(Mode,[blacklist,whitelist]),
        (private_source(Mode),private_copy(Mode))).
private_source(Mode) :-
    Source='probe_child(Parent) :- self(Me), Parent ! probe_started(Me), receive({never -> true}). make_sup(Parent,Sup) :- supervisor_spawn([child(probe,[start(probe_child(Parent)),restart(temporary)])],Sup,[monitor(true)]).',
    sandbox_prepare_spawn(Mode,actor,actor_context,
      (self(Parent),make_sup(Parent,Sup),receive({probe_started(Child)->true},[timeout(2),on_timeout(throw(missing_private_child))]),monitor(Child,R),supervisor_halt(Sup),receive({down(Sup,Sup,_)->true},[timeout(2),on_timeout(fail)]),receive({down(Child,R,_)->true},[timeout(2),on_timeout(fail)])),
      [src_text(Source),monitor(true)],Goal,Options),
    spawn(Goal,Session,Options),
    receive({down(Session,Session,Reason)->true},[timeout(5),on_timeout(throw(missing_private_session))]),
    check(Reason==true).

private_copy(Mode) :-
    Source='probe_copy(Parent) :- self(Me), Parent ! copy_child(Me), receive({never -> true}). copied_maker(Parent) :- self(Me), supervisor_spawn([child(copy_probe,[start(probe_copy(Parent)),restart(temporary)])],Sup), Parent ! copy_maker(Me), receive({finish -> true}), supervisor_halt(Sup).',
    sandbox_prepare_spawn(Mode,actor,actor_context,
      (self(Parent),spawn(copied_maker(Parent),Maker,[src_predicates([copied_maker/1,probe_copy/1]),monitor(true)]),
       receive({copy_maker(Maker)->true},[timeout(2),on_timeout(throw(missing_copied_maker))]),
       receive({copy_child(Child)->true},[timeout(2),on_timeout(throw(missing_copied_child))]),
       monitor(Child,R),Maker!finish,
       receive({down(Maker,Maker,true)->true},[timeout(2),on_timeout(fail)]),
       receive({down(Child,R,_)->true},[timeout(2),on_timeout(fail)])),
      [src_text(Source),monitor(true)],Goal,Options),
    spawn(Goal,Session,Options),
    receive({down(Session,Session,Reason)->true},[timeout(5),on_timeout(throw(missing_copy_session))]),
    check(Reason==true).
