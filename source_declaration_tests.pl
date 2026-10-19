% SPDX-License-Identifier: MIT
:- module(source_declaration_tests,[run/0]).
:- use_module(actors).
:- use_module(isolation,[]).
:- use_module(sandbox_policy,[]).
run :-
 forall(member(Form,[list,text]),empty_sources(Form)),
 preserved_clauses_and_copy,
 forall(member(Mode,[blacklist,whitelist]),sandboxed_empty(Mode)),
 rejected_declarations,multifile_policy,
 writeln('Discontiguous source declarations: all regressions passed').
source(list,Terms,[src_list(Terms)]).
source(text,Terms,[src_text(Text)]) :- isolation:source_terms_text(Terms,Text).
with_source(Options,Goal) :-
 setup_call_cleanup(isolation:prepare_actor(discontiguous_test,user,Options,M),
                    call(Goal,M),isolation:cleanup_actor(discontiguous_test)).
:- meta_predicate with_source(+,1).
empty_sources(Form) :-
 Terms=[(:- discontiguous((empty_zero/0,empty_one/1)))],
 source(Form,Terms,Options),with_source(Options,source_declaration_tests:check_discontiguous_empty),
 format('empty zero/unary predicates, negation and current_predicate via ~w: ok~n',[Form]).
check_empty(M) :-
 isolation:run_actor_query(M,current_predicate(empty_zero/0)),
 isolation:run_actor_query(M,current_predicate(empty_one/1)),
 \+ isolation:run_actor_query(M,empty_zero),
 \+ isolation:run_actor_query(M,empty_one(_)),
 isolation:run_actor_query(M,(\+empty_zero,\+empty_one(_))).
check_discontiguous_empty(M) :-
 check_empty(M),
 \+ isolation:run_actor_query(M,clause(empty_zero,_)),
 \+ isolation:run_actor_query(M,clause(empty_one(_),_)).
preserved_clauses_and_copy :-
 Terms=[(:- discontiguous((empty_zero/0,empty_one/1))),kept(a),
        (:- discontiguous(kept/1)),other(x),kept(b),pair(X,X),
        (:- dynamic(pair/2)),(:- discontiguous(pair/2))],
 with_source([src_list(Terms)],source_declaration_tests:copy_check),
 writeln('clause order, variable sharing and copied empty/mixed declarations: ok').
copy_check(M) :-
 isolation:run_actor_query(M,findall(X,kept(X),[a,b])),
 isolation:rewrite_source_options([src_predicates([empty_zero/0,empty_one/1,kept/1,pair/2])],M,[src_list(Copied)]),
 memberchk((:- discontiguous(empty_zero/0)),Copied),
 memberchk((:- discontiguous(empty_one/1)),Copied),
 memberchk((:- dynamic(pair/2)),Copied),memberchk((:- discontiguous(pair/2)),Copied),
 \+memberchk((:- dynamic(empty_zero/0)),Copied),
 setup_call_cleanup(isolation:prepare_actor(discontiguous_copy,user,[src_list(Copied)],Child),
  (check_discontiguous_empty(Child),isolation:run_actor_query(Child,findall(Y,kept(Y),[a,b])),
   isolation:run_actor_query(Child,pair(A,B)),A==B),
  isolation:cleanup_actor(discontiguous_copy)).
sandboxed_empty(Mode) :-
 self(Self),
 Terms=[(:- discontiguous((empty_zero/0,empty_one/1)))],
 sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,
  (\+empty_zero,\+empty_one(_),Self ! declarations_ok),[src_list(Terms)],Goal,Options),
 spawn(Goal,P,[monitor(true),link(false)|Options]),
 receive({declarations_ok -> true;down(P,P,R) -> throw(sandbox_declaration_failed(Mode,R))},[timeout(2),on_timeout(fail)]),
 receive({down(P,P,true) -> true},[timeout(2),on_timeout(fail)]),
 format('empty declarations execute under ~w policy: ok~n',[Mode]).
:- meta_predicate rejects(0).
rejects(Goal) :- catch(call(Goal),E,true),nonvar(E).
rejected_declarations :-
 forall(member(Decl,[42,foo/(-1),'$actor_cleanup'/0,system:foo/0,(valid/0,_),_]),
  rejects(sandbox_policy:sandbox_prepare_options(blacklist,actor,user,
     [src_list([(:- discontiguous(Decl))])],_))),
 forall(member(Bad,[42,foo/(-1),(valid/0,_),_]),
  rejects(with_source([src_list([(:-discontiguous(Bad))])],source_declaration_tests:check_empty))),
 writeln('invalid and reserved declaration targets remain rejected: ok').
multifile_policy :-
 forall(member(Mode,[blacklist,whitelist]),
  (catch(sandbox_policy:sandbox_prepare_options(Mode,actor,user,
      [src_list([(:- multifile(untrusted/0))])],_),E,true),
   E=error(permission_error(execute,sandboxed_directive,(:-multifile(untrusted/0))),_))),
 with_source([src_list([(:-multifile(empty_zero/0)),(:-multifile(empty_one/1))])],source_declaration_tests:check_empty),
 writeln('multifile sandbox rejection and trusted empty behavior unchanged: ok').
