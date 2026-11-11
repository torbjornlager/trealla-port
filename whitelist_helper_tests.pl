% SPDX-License-Identifier: MIT
:- module(whitelist_helper_tests,[run/0]).
:- use_module(actors).
:- use_module(actor_api).
:- use_module(isolation,[]).
:- use_module(sandbox_policy).

check(Goal) :- (call(Goal)->true;throw(error(helper_admission_check_failed(Goal),run/0))).
rejected(Goal,Formal) :-
    catch(call(Goal),Error,true),check(nonvar(Error)),check(Error=error(Formal,_)).

run :-
    setup_call_cleanup(
      isolation:configure_shared_db(['fixtures/source/whitelist-helper-shared.pl']),
      forall(member(Mode,[blacklist,whitelist]),session_checks(Mode)),
      isolation:clear_shared_db),
    forall(member(Mode,[blacklist,whitelist,off]),reject_call_sources(Mode)),
    writeln('Private helper admission, target isolation and guarded calls: passed').

session_checks(Mode) :-
    Source='ha_probe(ok). ha_pair(X,X). ha_shadow(private).',
    sandbox_prepare_options(Mode,actor,actor_context,
                            [session(true),src_text(Source)],Options),
    setup_call_cleanup(toplevel_spawn(P,Options),check_session(Mode,P),toplevel_halt(P)).

check_session(Mode,P) :-
    isolation:actor_application_predicates(P,PIs),
    check(PIs==[ha_pair/2,ha_probe/1,ha_shadow/1]),
    Raw=(ha_probe(X),ha_pair(X,Y),ha_shadow(V)),
    term_variables(Raw,Before),
    sandbox_prepare_session_call(Mode,actor,P,Raw,[limit(1)],Prepared,_),
    term_variables(Raw,After),check(Before==After),check(var(X)),check(var(Y)),check(var(V)),
    toplevel_call_synch(P,Prepared,Reply,[template(values(X,Y,V)),limit(1),timeout(2)]),
    check(Reply==success(P,[values(ok,ok,private)],false)),
    check(var(X)),check(var(Y)),check(var(V)),
    rejected(sandbox_prepare_session_call(Mode,actor,P,current_prolog_flag(bounded,_),[],_,_),
             permission_error(call,sandboxed,_)),
    (Mode==whitelist ->
      rejected(sandbox_prepare_session_call(Mode,actor,P,ha_owner_only(_),[],_,_),
               permission_error(call,sandboxed,_)),
      rejected(sandbox_prepare_session_call(Mode,actor,P,'$actor_source_pi'(_),[],_,_),
               permission_error(call,sandboxed,_)),
      setup_call_cleanup(toplevel_spawn(Other,[session(true)]),
        (isolation:actor_application_predicates(Other,[]),
         rejected(sandbox_prepare_session_call(Mode,actor,Other,ha_probe(_),[],_,_),
                  permission_error(call,sandboxed,_))),toplevel_halt(Other))
    ; true).

reject_call_sources(Mode) :-
    forall(member(Option,[src_text('ha_forged.'),src_list([ha_forged]),
                          src_predicates([ha_forged/0]),src_uri('https://must-not-be-fetched.invalid/')]),
      rejected(sandbox_prepare_session_call(Mode,actor,unused,ha_forged,[Option],_,_),
               domain_error(toplevel_call_option,Option))).
