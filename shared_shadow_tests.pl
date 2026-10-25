% SPDX-License-Identifier: MIT
:- module(shared_shadow_tests,[run/0]).
:- use_module(actors).
:- use_module(actor_api).
:- use_module(isolation,[]).
:- use_module(sandbox_policy,[]).
:- use_module(toplevel_actors).
run :-
    load_text("shadow_zero :- fail. shadow_one(host).",[module(user)]),
    setup_call_cleanup(
      isolation:configure_shared_db(['fixtures/source/shared-shadow.pl']),
      (forall(member(Mode,[blacklist,whitelist]),check_mode(Mode)),
       predicate_property(user:shadow_zero,static),\+user:shadow_zero,
       findall(X,user:shadow_one(X),[host]),
       writeln('Private shared-predicate shadowing: all regressions passed')),
      isolation:clear_shared_db).
check_mode(Mode) :-
    Options=[session(true),monitor(true),src_text('shadow_zero. shadow_one(private).')],
    sandbox_policy:sandbox_prepare_options(Mode,actor,actor_context,Options,Prepared),
    setup_call_cleanup(toplevel_spawn(P,Prepared),
      (toplevel_call_synch(P,(shadow_zero,findall(X,shadow_one(X),Xs)),Reply,[template(Xs),timeout(2)]),
       must_equal(Reply,success(P,[[private]],false),private_source),
       (Mode==blacklist -> check_parsed_entry(P) ; true),
       isolation:actor_module(P,SourceModule),
       isolation:rewrite_source_options([src_predicates([shadow_zero/0,shadow_one/1])],SourceModule,[src_list(Copied)]),
       memberchk(shadow_zero,Copied),memberchk(shadow_one(private),Copied),
       \+memberchk(shadow_one(host),Copied),\+memberchk(shadow_one(shared),Copied),
       self(Me),spawn((findall(X,shadow_one(X),Xs),Me ! untouched(Xs)),Other,[monitor(true)]),
       receive({untouched(Xs)->must_equal(Xs,[shared],other_actor)},[timeout(2),on_timeout(throw(other_actor_timeout))]),
       receive({down(Other,Other,true)->true},[timeout(2),on_timeout(throw(other_actor_down_timeout))]),
       findall(X,user:shadow_one(X),[host]),predicate_property(user:shadow_zero,static)),
      (toplevel_halt(P),receive({down(P,P,_)->true},[timeout(2),on_timeout(throw(toplevel_down_timeout))]))).
must_equal(Actual,Expected,Label) :-
    (Actual==Expected->true;throw(mismatch(Label,Actual,Expected))).

check_parsed_entry(P) :-
    forall(member(Text,['(shadow_zero,true)','shadow_one(private)']),check_parsed_entry(P,Text)).
check_parsed_entry(P,Text) :-
    read_term_from_atom(Text,Parsed,[]),
    sandbox_policy:sandbox_prepare_spawn(blacklist,actor,actor_context,Parsed,[],Guarded,CallOptions),
    toplevel_call_synch(P,Guarded,DirectReply,[template(ok),timeout(2)|CallOptions]),
    must_equal(DirectReply,success(P,[ok],false),parsed_private_entry).
