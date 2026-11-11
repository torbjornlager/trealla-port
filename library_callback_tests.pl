% SPDX-License-Identifier: MIT
:- module(library_callback_tests,[run/0]).
:- use_module(actor_api).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(sandbox_policy,[]).

run :-
    % The host forall/2 checks its test eagerly. The runtime must defer it.
    isolation:actor_library(toplevel_actors,forall(fail,7)),
    isolation:actor_library(toplevel_actors,maplist(forall(fail),[7])),
    catch(isolation:actor_library(toplevel_actors,maplist(7,[a])),E,true),
    E=error(type_error(callable,7),_),
    isolation:prepare_actor(987654321,user,[src_text('eq(X,X). run:-maplist(eq,[a],[a]),forall(fail,7).')],Module),
    isolation:rewrite_source_options([src_predicates([run/0,eq/2])],Module,[src_list(Terms)]),
    member((run :- (maplist(eq,[a],[a]),forall(fail,7))),Terms),
    isolation:cleanup_actor(987654321),
    self(Me),
    Source='eq(X,X). worker(To):-maplist(eq,[a],[a]),forall(fail,7),To!copied_library. parent(To):-spawn(worker(To),P,[src_predicates([worker/1,eq/2]),monitor(true)]),receive({down(P,P,true)->true},[timeout(2),on_timeout(fail)]).',
    spawn(parent(Me),P,[src_text(Source),monitor(true)]),
    receive({copied_library->true},[timeout(3),on_timeout(throw(copy_message_missing))]),
    receive({down(P,P,true)->true},[timeout(3),on_timeout(throw(parent_down_missing))]),
    forall(member(Mode,[blacklist,whitelist]),admission_checks(Mode)),
    writeln('Library callback laziness, public source copying and admission: passed').

admission_checks(Mode) :-
    sandbox_policy:sandbox_prepare_spawn(Mode,actor,user,
      maplist(eq,[a],[a]),[src_text('eq(X,X).')],_,_),
    catch(sandbox_policy:sandbox_prepare_spawn(Mode,actor,user,
      maplist(call(system:shell),[a]),[],_,_),E,true),
    E=error(permission_error(call,sandboxed,_),_),
    sandbox_policy:sandbox_prepare_spawn(Mode,actor,user,forall(fail,7),[],_,_).
