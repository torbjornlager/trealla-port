 :- use_module(sandbox_policy).
:- use_module(profile_policy).
probe(Label, Goal) :-
    catch((call(Goal)->Result=pass;Result=fail),Error,Result=error(Error)),
    writeq(Label-Result),nl.
main :-
 probe(profile_unbound,profile_check_spawn_options(actor,[src_list(_)])),
 probe(admission_runtime_list,sandbox_prepare_goal(blacklist,actor,user,
       (Clauses=[p(1)],spawn(p(_),_,[src_list(Clauses)])),_)),
 probe(admission_literal_list,sandbox_prepare_goal(blacklist,actor,user,
       spawn(p(_),_,[src_list([p(1)])]),_)),
 probe(runtime_preparation_bound,sandbox_prepare_spawn(blacklist,actor,user,
       p(_),[src_list([p(1)])],_,_)),
 probe(runtime_preparation_variables,(sandbox_prepare_spawn(blacklist,actor,user,
       p(_),[src_list([p([97,98]),pair(X,X)])],_,_),var(X))),
 probe(runtime_preparation_unbound,sandbox_prepare_spawn(blacklist,actor,user,
       p(_),[src_list(_)],_,_)),
 halt.
