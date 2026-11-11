:- use_module(library(lists), [last/2]).
:- dynamic discovery_empty/1.
discovery_fact(visible).
discovery_rule(X) :- discovery_fact(X).
discovery_grammar(X) --> [X].
provides(ignored/9).
relation_filter(discovery_fact(_)).
'$owner_internal'(hidden).
