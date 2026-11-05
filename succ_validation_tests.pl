% SPDX-License-Identifier: MIT
:- module(succ_validation_tests,[run/0]).
:- use_module(actors).
:- use_module(actor_api).
:- use_module(isolation,[]).
:- use_module(sandbox_policy,[]).
:- use_module(toplevel_actors).

run :-
    forall(member(Mode,[blacklist,whitelist,off]),check_mode(Mode)),
    writeln('succ integer validation, callback, receive and copied source: passed').

source(Source) :-
    atomic_list_concat([
      'succ_private(A,B) :- succ(A,B).',
      'succ_guard_case :- self(Me),send(Me,succ_guard_probe),receive({succ_guard_probe if catch(succ(1.5,V),error(type_error(integer,1.5),_),Caught=true)->Caught==true},[timeout(1),on_timeout(throw(succ_guard_not_selected))]),var(V).',
      'succ_body_case :- self(Me),send(Me,succ_body_probe),catch(receive({succ_body_probe->succ(V,1.5)}),E,true),nonvar(E),E=error(type_error(integer,1.5),_),var(V).'
    ],' ',Source).
check_mode(Mode) :-
    source(Source),
    sandbox_policy:sandbox_prepare_options(Mode,actor,actor_context,
      [session(true),monitor(true),src_text(Source)],Options),
    BaseGoals=[succ(1.5,V),succ(V,1.5),succ(1.5,2),succ(1,1.5),
               maplist(succ,[1.5],[V]),
               succ_private(1.5,V),succ_private(V,1.5)],
    (Mode==whitelist -> Goals=BaseGoals
    ; Goals=[(G=succ,call(G,1.5,V))|BaseGoals]),
    setup_call_cleanup(toplevel_spawn(P,Options),
      (forall(member(Goal,Goals),
          query(P,Mode,Source,(catch(Goal,E,true),nonvar(E),
              E=error(type_error(integer,1.5),_),var(V)))),
       forall(member(Bad,[0.0,-1.0,bad,[a],pair(a,b)]),
         (query(P,Mode,Source,(catch(succ(Bad,V),E,true),nonvar(E),
              E=error(type_error(integer,Bad),_),var(V))),
          query(P,Mode,Source,(catch(succ(V,Bad),E,true),nonvar(E),
              E=error(type_error(integer,Bad),_),var(V))))),
       query(P,Mode,Source,succ_guard_case),
       query(P,Mode,Source,succ_body_case),
       query(P,Mode,Source,(succ(2,S),S==3,succ(B,3),B==2,
                           findall(ok,succ(2,3),[ok]),\+succ(_,0))),
       query(P,Mode,Source,(catch(succ(A,B),E,true),nonvar(E),
                           E=error(instantiation_error,_),var(A),var(B))),
       isolation:actor_module(P,Module),
       isolation:rewrite_source_options([src_predicates([succ_private/2])],Module,[src_list(Terms)]),
       member((succ_private(A,B):-succ(A,B)),Terms),var(A),var(B),A\==B,
       sandbox_policy:sandbox_prepare_options(Mode,actor,actor_context,
         [session(true),monitor(true),src_list(Terms)],CopiedOptions),
       setup_call_cleanup(toplevel_spawn(C,CopiedOptions),
         query(C,Mode,Source,(catch(succ_private(1.5,V),E,true),nonvar(E),
                 E=error(type_error(integer,1.5),_),var(V))),
         halt_and_wait(C))),
      halt_and_wait(P)).

query(P,Mode,Source,Goal) :-
    sandbox_policy:sandbox_prepare_spawn(Mode,actor,actor_context,Goal,
       [src_text(Source)],Guarded,_),
    toplevel_call_synch(P,Guarded,Reply,[template(ok),timeout(2)]),
    (Reply==success(P,[ok],false)->true;throw(unexpected_succ_reply(Mode,Reply))).
halt_and_wait(P) :-
    toplevel_halt(P),
    receive({down(P,P,_)->true},[timeout(2),on_timeout(throw(succ_halt_timeout))]).
