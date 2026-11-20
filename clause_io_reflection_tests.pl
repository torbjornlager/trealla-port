% SPDX-License-Identifier: MIT
:- module(clause_io_reflection_tests,[run/0]).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(sandbox_policy).
:- use_module(toplevel_actors).

run :-
    % An explicit terminal_output/2 call with pending options is not an I/O
    % rewrite. Reflection must not bind those options to manufacture a match.
    sandbox_policy:restore_clause_body(probe,actors:terminal_output(X,Options),Body),
    var(X),var(Options),Body==actors:terminal_output(X,Options),
    forall(member(Mode,[blacklist,whitelist,off]),checks(Mode)),
    writeln('Public clause I/O: original operations, sharing, repeated copies and scoped access passed').

checks(Mode) :-
    Source='emit(X) :- writeln(X). put_pair(X) :- write(pair(X,X)). inspect :- clause(emit(X),B), B=writeln(Y), var(X), X==Y, clause(put_pair(A),C), C=write(pair(D,E)), var(A), A==D, A==E.',
    sandbox_prepare_options(Mode,actor,actor_context,[src_text(Source)],Options),
    self(Self),
    setup_call_cleanup(toplevel_spawn(Session,[target(Self),session(true)|Options]),
      (checked_query(Session,inspect),
       isolation:actor_module(Session,Module),
       isolation:load_options_text(Module,[src_predicates([emit/1,put_pair/1,inspect/0])],Copy),
       \+ sub_atom(Copy,_,_,_,'terminal_output'),
       copied_check(Mode,Copy),
       denied_runtime_clause(Mode,Session)),
      clean_session(Session)),
    format('~w: reflected and recopied I/O preserves sharing and runtime scope~n',[Mode]).

copied_check(Mode,Source) :-
    self(Self),
    sandbox_prepare_options(Mode,actor,actor_context,[src_text(Source)],Options),
    setup_call_cleanup(toplevel_spawn(Copy,[target(Self),session(true)|Options]),
      checked_query(Copy,inspect),clean_session(Copy)).

checked_query(Session,Goal) :-
    toplevel_call(Session,Goal,[template(ok),limit(1)]),
    receive({success(Session,[ok],false)->true;
             failure(Session)->throw(reflected_io_failed);
             error(Session,E)->throw(E)},
            [timeout(2),on_timeout(throw(reflected_io_timeout))]).

% Off mode deliberately does not sandbox query goals.
denied_runtime_clause(off,_) :- !.
denied_runtime_clause(Mode,Session) :-
    sandbox_prepare_goal(Mode,actor,actor_context,
                         clause(current_prolog_flag(_,_),_),Guarded),
    toplevel_call(Session,Guarded,[template(ok),limit(1)]),
    receive({error(Session,error(permission_error(access,procedure,_),clause/2))->true},
            [timeout(2),on_timeout(throw(runtime_clause_scope_lost))]),
    catch(sandbox_prepare_goal(Mode,actor,actor_context,write(user_output,leak),_),E,true),
    nonvar(E), E=error(permission_error(call,sandboxed,_),_).

clean_session(Session) :-
    catch(exit(Session,kill),_,true),
    catch(demonitor(Session,[flush]),_,true).
