% SPDX-License-Identifier: MIT
:- module(call_arity_admission_tests,[run/0]).
:- use_module(sandbox_policy).
run :-
    forall(member(Mode,[blacklist,whitelist,off]),
      (sandbox_check_goal(Mode,actor,actor_context,call(succ,1.5,V)),var(V),
       Goal=call(=,A,B),term_variables(Goal,Before),
       sandbox_check_goal(Mode,actor,actor_context,Goal),
       term_variables(Goal,After),Before==After,var(A),var(B),A\==B)),
    denied(call(unknown_call_target,_,_),not_whitelisted),
    denied(call(C,_,_),opaque_meta_call),var(C),
    denied(call(halt),_),
    forall(member(M,[blacklist,whitelist]),
      (catch(sandbox_check_goal(M,actor,actor_context,
               call(call(system:shell),a,b,c,d)),E,true),
       nonvar(E),E=error(permission_error(call,sandboxed,_),_))),
    writeln('Static call/N completed arity, variable preservation and denial: passed').
denied(Goal,Category) :-
    catch(sandbox_check_goal(whitelist,actor,actor_context,Goal),E,true),
    nonvar(E),E=error(permission_error(call,sandboxed,_),context(_,Category)).
