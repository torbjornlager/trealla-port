:- use_module(library(json)).
:- use_module(library(lists)).

probe(Codes) :-
    phrase(json_chars(string(Chars)), "\"\\uD83D\\uDE00\""),
    maplist(char_code, Chars, Codes).
