% Standalone engine diagnostic. No Web Prolog imports or global flag changes.
% Run: tpl -g "consult('reproducers/port-cyclic-exception-copy.pl'),run,halt"
% SWI: swipl -f none -q -s reproducers/port-cyclic-exception-copy.pl -g run -t halt
run :-
    catch((X=f(X),report(before_throw,X),throw(error(cycle_probe(X),ctx))),
          E,report(after_catch,E)).
report(Stage,Term) :-
    (acyclic_term(Term) -> Kind=acyclic ; Kind=cyclic),
    write(Stage-Kind),nl.
